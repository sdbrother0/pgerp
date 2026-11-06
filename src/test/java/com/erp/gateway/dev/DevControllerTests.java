package com.erp.gateway.dev;

import java.nio.file.Path;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import com.erp.gateway.push.UiPushBroadcaster;
import com.erp.gateway.security.DatabaseAuthenticationProvider;
import com.erp.gateway.security.SecurityConfig;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.never;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DevController.class)
@Import(SecurityConfig.class)
class DevControllerTests {

	private static final String RELEASE = "{\"status\":\"success\",\"version\":14,\"folder\":\"my_app\","
			+ "\"file_name\":\"V14__my_app_first.sql\",\"content\":\"SELECT 1;\"}";

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private UiEventDispatcher dispatcher;

	@MockitoBean
	private MigrationWriter writer;

	@MockitoBean
	private SolutionPackages packages;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void releaseIsSavedToMigrationFolder() throws Exception {
		given(this.dispatcher.dispatch("admin", "release_create", "{\"solution\":\"my_app\"}", "en")).willReturn(RELEASE);
		given(this.writer.isConfigured()).willReturn(true);
		given(this.writer.write("my_app", "V14__my_app_first.sql", "SELECT 1;", null)).willReturn(Path.of("/p/my_app/V14__my_app_first.sql"));

		this.mvc.perform(post("/api/dev/release").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"solution\":\"my_app\"}"))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.version").value(14))
			.andExpect(jsonPath("$.saved_to").value("/p/my_app/V14__my_app_first.sql"));
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void withoutFolderReleaseIsOnlyReturned() throws Exception {
		given(this.dispatcher.dispatch("admin", "release_create", "{}", "en")).willReturn(RELEASE);
		given(this.writer.isConfigured()).willReturn(false);

		this.mvc.perform(post("/api/dev/release").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(jsonPath("$.content").value("SELECT 1;"))
			.andExpect(jsonPath("$.saved_to").doesNotExist());
		then(this.writer).should(never()).write(any(), any(), any(), any());
	}

	@Test
	@WithMockUser(username = "anna", roles = "my_app_clerk")
	void onlyAdminReleases() throws Exception {
		this.mvc.perform(post("/api/dev/release").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isForbidden());
		then(this.dispatcher).shouldHaveNoInteractions();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void solutionIsInstalled() throws Exception {
		ObjectNode installed = JsonMapper.builder().build().createObjectNode().put("name", "my_app").put("db_schema", "sales");
		given(this.packages.install("admin", "my_app", "sales", false)).willReturn(installed);

		this.mvc.perform(post("/api/dev/solutions/install").with(csrf()).contentType(MediaType.APPLICATION_JSON)
				.content("{\"name\":\"my_app\",\"schema\":\"sales\"}"))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.status").value("success"))
			.andExpect(jsonPath("$.solution.db_schema").value("sales"));
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void cleanInstallDropsSchemaFirst() throws Exception {
		ObjectNode installed = JsonMapper.builder().build().createObjectNode().put("name", "my_app").put("db_schema", "my_app");
		given(this.packages.install("admin", "my_app", "my_app", true)).willReturn(installed);

		this.mvc.perform(post("/api/dev/solutions/install").with(csrf()).contentType(MediaType.APPLICATION_JSON)
				.content("{\"name\":\"my_app\",\"schema\":\"my_app\",\"reset\":true}"))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.solution.db_schema").value("my_app"));
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void installErrorIsShown() throws Exception {
		given(this.packages.install("admin", "nope", null, false)).willThrow(new SolutionInstallException("Solution package “nope” not found"));

		this.mvc.perform(post("/api/dev/solutions/install").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"nope\"}"))
			.andExpect(status().isUnprocessableContent())
			.andExpect(jsonPath("$.message").value("Solution package “nope” not found"));
	}

	@Test
	@WithMockUser(username = "anna", roles = "my_app_clerk")
	void onlyAdminInstalls() throws Exception {
		this.mvc.perform(post("/api/dev/solutions/install").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{\"name\":\"my_app\"}"))
			.andExpect(status().isForbidden());
		then(this.packages).shouldHaveNoInteractions();
	}

}
