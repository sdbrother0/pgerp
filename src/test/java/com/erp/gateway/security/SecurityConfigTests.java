package com.erp.gateway.security;

import java.util.List;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import com.erp.gateway.push.UiPushBroadcaster;
import com.erp.gateway.web.UiEventController;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.times;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.redirectedUrl;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(UiEventController.class)
@Import(SecurityConfig.class)
class SecurityConfigTests {

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private UiEventDispatcher dispatcher;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	// Cookie XSRF-TOKEN на настоящем сервере проверяет UiPushWebSocketTests (вход через страницу входа):
	// здесь csrf() из spring-security-test подменяет хранилище токенов во всём тестовом контексте
	@Test
	void loginPageIsPublic() throws Exception {
		this.mvc.perform(get("/login.html")).andExpect(status().isOk());
	}

	@Test
	void dictionaryAndThemeArePublicForLoginPage() throws Exception {
		this.mvc.perform(get("/js/i18n.js")).andExpect(status().isOk());
		this.mvc.perform(get("/js/theme.js")).andExpect(status().isOk());
		this.mvc.perform(get("/js/ui-runtime.js").accept(MediaType.TEXT_HTML)).andExpect(status().is3xxRedirection());
	}

	@Test
	void pagesRedirectToLoginWithoutSession() throws Exception {
		this.mvc.perform(get("/index.html").accept(MediaType.TEXT_HTML))
			.andExpect(status().is3xxRedirection())
			.andExpect(redirectedUrl("/login.html"));
	}

	@Test
	void apiAnswers401WithoutSession() throws Exception {
		this.mvc.perform(post("/api/ui/event").param("action", "menu_get").with(csrf())
				.contentType("application/json").content("{}"))
			.andExpect(status().isUnauthorized());
		then(this.dispatcher).shouldHaveNoInteractions();
	}

	@Test
	void successfulLoginAnswersJson() throws Exception {
		given(this.authenticationProvider.supports(any())).willReturn(true);
		given(this.authenticationProvider.authenticate(any())).willReturn(UsernamePasswordAuthenticationToken
			.authenticated("anna", null, List.of(new SimpleGrantedAuthority("ROLE_manager"))));

		this.mvc.perform(post("/api/auth/login").with(csrf()).param("username", "anna").param("password", "secret"))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.status").value("success"));
	}

	@Test
	void failedLoginShowsDatabaseMessage() throws Exception {
		given(this.authenticationProvider.supports(any())).willReturn(true);
		given(this.authenticationProvider.authenticate(any()))
			.willThrow(new BadCredentialsException("Invalid login or password"));

		this.mvc.perform(post("/api/auth/login").with(csrf()).param("username", "anna").param("password", "x"))
			.andExpect(status().isUnauthorized())
			.andExpect(jsonPath("$.status").value("error"))
			.andExpect(jsonPath("$.message").value("Invalid login or password"));
		// База считает неудачные попытки: пароль проверяется ровно один раз
		then(this.authenticationProvider).should(times(1)).authenticate(any());
	}

	@Test
	void loginWithoutCsrfTokenIsRejected() throws Exception {
		this.mvc.perform(post("/api/auth/login").param("username", "anna").param("password", "secret"))
			.andExpect(status().isForbidden());
	}

	@Test
	@WithMockUser(username = "anna", roles = "manager")
	void editorIsForbiddenForNonAdmin() throws Exception {
		this.mvc.perform(get("/editor.html")).andExpect(status().isForbidden());
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void editorIsOpenForAdmin() throws Exception {
		this.mvc.perform(get("/editor.html")).andExpect(status().isOk());
	}

	@Test
	@WithMockUser("anna")
	void logoutClosesPushSubscriptionsOfTheSession() throws Exception {
		this.mvc.perform(post("/api/auth/logout").with(csrf())).andExpect(status().isOk());
		then(this.broadcaster).should().closeHttpSession(any());
	}

}
