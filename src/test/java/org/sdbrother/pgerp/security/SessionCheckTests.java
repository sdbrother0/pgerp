package org.sdbrother.pgerp.security;

import java.net.URI;
import java.util.List;
import java.util.Optional;

import jakarta.servlet.http.Cookie;
import org.junit.jupiter.api.Test;
import org.sdbrother.pgerp.dev.DevController;
import org.sdbrother.pgerp.dev.MigrationWriter;
import org.sdbrother.pgerp.dev.SolutionPackages;
import org.sdbrother.pgerp.dispatcher.UiEventDispatcher;
import org.sdbrother.pgerp.push.UiPushBroadcaster;
import org.sdbrother.pgerp.web.UiEventController;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockHttpSession;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.never;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest({ UiEventController.class, DevController.class })
@Import(SecurityConfig.class)
class SessionCheckTests {

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private SessionGuard sessions;

	@MockitoBean
	private UiEventDispatcher dispatcher;

	@MockitoBean
	private SolutionPackages packages;

	@MockitoBean
	private MigrationWriter writer;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	private void state(boolean mustChange, String... roles) {
		given(this.sessions.check(any(), any()))
			.willReturn(Optional.of(new SessionGuard.State("stamp", List.of(roles), mustChange)));
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void revokedSessionGets401AndIsInvalidated() throws Exception {
		given(this.sessions.check(any(), any())).willReturn(Optional.empty());
		MockHttpSession session = new MockHttpSession();
		this.mvc.perform(post("/api/ui/event").session(session).param("action", "menu_get").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isUnauthorized());
		assertThat(session.isInvalid()).isTrue();
		then(this.dispatcher).shouldHaveNoInteractions();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void revokedSessionCannotOpenWebSocket() throws Exception {
		given(this.sessions.check(any(), any())).willReturn(Optional.empty());
		this.mvc.perform(get("/api/ui/ws")).andExpect(status().isUnauthorized());
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void revokedSessionPageLeadsToLogin() throws Exception {
		given(this.sessions.check(any(), any())).willReturn(Optional.empty());
		this.mvc.perform(get("/editor.html").accept(MediaType.TEXT_HTML))
			.andExpect(status().is3xxRedirection())
			.andExpect(redirectedUrl("/login.html"));
	}

	@Test
	@WithMockUser(username = "anna", roles = "admin")
	void removedRoleStopsWorkingAtOnce() throws Exception {
		state(false, "manager");
		this.mvc.perform(get("/editor.html")).andExpect(status().isForbidden());
		this.mvc.perform(get("/api/dev/settings")).andExpect(status().isForbidden());
	}

	@Test
	@WithMockUser(username = "anna", roles = "manager")
	void grantedRoleWorksAtOnce() throws Exception {
		state(false, "admin");
		this.mvc.perform(get("/api/dev/settings")).andExpect(status().isOk());
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void adminApiIsClosedUntilPasswordChange() throws Exception {
		state(true, "admin");
		this.mvc.perform(get("/api/dev/settings")).andExpect(status().isForbidden());
		this.mvc.perform(get("/api/dev/solutions")).andExpect(status().isForbidden());
		this.mvc.perform(post("/api/reports/preview").with(csrf())).andExpect(status().isForbidden());
		this.mvc.perform(post("/api/reports/save").with(csrf())).andExpect(status().isForbidden());
		then(this.packages).should(never()).list();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void percentEncodingDoesNotBypassPasswordChange() throws Exception {
		state(true, "admin");
		this.mvc.perform(get(URI.create("/api/%64ev/solutions"))).andExpect(status().isForbidden());
		then(this.packages).should(never()).list();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void loginPageDoesNotAskDatabase() throws Exception {
		this.mvc.perform(get("/login.html")).andExpect(status().isOk());
		then(this.sessions).shouldHaveNoInteractions();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void ownPasswordChangeKeepsThisSession() throws Exception {
		state(true, "admin");
		given(this.dispatcher.dispatch(any(), any(), any(), any())).willReturn("{\"status\":\"success\"}");
		this.mvc.perform(post("/api/ui/event").param("action", "password_change").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isOk());
		then(this.sessions).should().passwordChanged(any(), eq("admin"));
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void otherActionDoesNotRenewSession() throws Exception {
		state(false, "admin");
		given(this.dispatcher.dispatch(any(), any(), any(), any())).willReturn("{\"status\":\"success\"}");
		this.mvc.perform(post("/api/ui/event").param("action", "menu_get").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isOk());
		then(this.sessions).should(never()).passwordChanged(any(), any());
	}

	@Test
	void loginPassesAddressAndDeviceAndStartsSession() throws Exception {
		given(this.authenticationProvider.supports(any())).willReturn(true);
		given(this.authenticationProvider.authenticate(any())).willAnswer((invocation) -> {
			Authentication request = invocation.getArgument(0);
			assertThat(request.getDetails()).isEqualTo(new LoginRequest("127.0.0.1", "known-browser"));
			UsernamePasswordAuthenticationToken result = UsernamePasswordAuthenticationToken
				.authenticated(request.getName(), null, List.of());
			result.setDetails(new LoginDetails("stamp"));
			return result;
		});
		this.mvc.perform(post("/api/auth/login").with(csrf()).param("username", "anna").param("password", "secret")
				.cookie(new Cookie(LoginRequest.DEVICE_COOKIE, "known-browser")))
			.andExpect(status().isOk());
		then(this.sessions).should().started(any(), any(), argThat(
				(authentication) -> new LoginDetails("stamp").equals(authentication.getDetails())));
	}

}
