package com.erp.gateway.mcp;

import java.nio.file.Path;
import java.util.List;

import com.erp.gateway.dev.MigrationWriteException;
import com.erp.gateway.dev.MigrationWriter;
import com.erp.gateway.dev.SolutionPackages;
import com.erp.gateway.push.UiPushBroadcaster;
import com.erp.gateway.report.ReportException;
import com.erp.gateway.report.ReportRenderer;
import com.erp.gateway.security.DatabaseAuthenticationProvider;
import com.erp.gateway.security.SecurityConfig;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.mockito.Mockito.never;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(McpController.class)
@Import({ McpSecurityConfig.class, SecurityConfig.class, McpControllerTests.Properties.class })
class McpControllerTests {

	private static final String TOKEN = "pgerp_0123456789abcdef0123456789abcdef";

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private McpGateway gateway;

	@MockitoBean
	private ReportRenderer renderer;

	@MockitoBean
	private MigrationWriter writer;

	@MockitoBean
	private SolutionPackages packages;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	@Test
	void requestWithoutTokenIsRejected() throws Exception {
		this.mvc.perform(post("/mcp").contentType(MediaType.APPLICATION_JSON).content("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
			.andExpect(status().isUnauthorized())
			.andExpect(header().string("WWW-Authenticate", "Bearer realm=\"pgerp\""))
			.andExpect(jsonPath("$.error.code").value(-32001));
		then(this.gateway).should(never()).handle(anyString(), anyString(), anyString());
	}

	@Test
	void unknownTokenIsRejected() throws Exception {
		given(this.gateway.login("wrong-token-wrong-token")).willReturn(null);
		this.mvc.perform(post("/mcp").header("Authorization", "Bearer wrong-token-wrong-token")
				.contentType(MediaType.APPLICATION_JSON).content("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
			.andExpect(status().isUnauthorized());
	}

	@Test
	void requestGoesToDatabaseAsIsWithoutCsrf() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}";
		String response = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, null)).willReturn(new McpGateway.Result(response, List.of()));

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isOk())
			.andExpect(content().json(response, true))
			.andExpect(header().doesNotExist("Set-Cookie"));
	}

	@Test
	void browserLanguageIsPassedWhenSent() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, "de"))
			.willReturn(new McpGateway.Result("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", List.of()));
		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).header("Accept-Language", "de")
				.contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.result").exists());
	}

	@Test
	void notificationIsAccepted() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, null)).willReturn(new McpGateway.Result(null, List.of()));

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isAccepted())
			.andExpect(content().string(""));
	}

	@Test
	void invalidJsonIsParseError() throws Exception {
		given(this.gateway.login(TOKEN)).willReturn("admin");
		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content("{oops"))
			.andExpect(status().isBadRequest())
			.andExpect(jsonPath("$.error.code").value(-32700));
	}

	@Test
	void foreignOriginIsRejected() throws Exception {
		given(this.gateway.login(TOKEN)).willReturn("admin");
		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).header("Origin", "https://evil.example")
				.contentType(MediaType.APPLICATION_JSON).content("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))
			.andExpect(status().isForbidden());
		then(this.gateway).should(never()).handle(anyString(), anyString(), anyString());
	}

	@Test
	void sameOriginIsAllowed() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, null))
			.willReturn(new McpGateway.Result("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}", List.of()));
		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).header("Origin", "http://localhost")
				.contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isOk());
	}

	@Test
	void brokenReportTemplateIsNotSaved() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"report_save\","
				+ "\"arguments\":{\"name\":\"r\",\"jrxml\":\"<jasperReport\"}}}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.toolHook("report_save")).willReturn("compile_jrxml");
		given(this.renderer.compile("<jasperReport")).willThrow(new ReportException("XML document structures must start and end"));

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$.id").value(7))
			.andExpect(jsonPath("$.result.isError").value(true))
			.andExpect(jsonPath("$.result.content[0].text").value("Report template error: XML document structures must start and end"));
		then(this.gateway).should(never()).handle(anyString(), anyString(), anyString());
	}

	@Test
	void releaseFileIsWrittenAndGatewayFieldRemoved() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"release_create\",\"arguments\":{}}}";
		String response = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{}\"}],\"isError\":false},"
				+ "\"_gateway\":{\"write_migration\":{\"folder\":\"my_app\",\"file_name\":\"V14__my_app_first.sql\",\"content\":\"SELECT 1;\"}}}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, null)).willReturn(new McpGateway.Result(response, List.of("Готово")));
		given(this.writer.isConfigured()).willReturn(true);
		given(this.writer.write("my_app", "V14__my_app_first.sql", "SELECT 1;", null)).willReturn(Path.of("/project/db/solutions/my_app/V14__my_app_first.sql"));

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isOk())
			.andExpect(jsonPath("$._gateway").doesNotExist())
			.andExpect(jsonPath("$.result.content[1].text").value("Release file saved: /project/db/solutions/my_app/V14__my_app_first.sql"))
			.andExpect(jsonPath("$.result.content[2].text").value("ui_print messages:\nГотово"));
	}

	@Test
	void releaseFileErrorIsReported() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"release_create\"}}";
		String response = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"{}\"}],\"isError\":false},"
				+ "\"_gateway\":{\"write_migration\":{\"folder\":\"my_app\",\"file_name\":\"V14__my_app_first.sql\",\"content\":\"SELECT 1;\"}}}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.handle("admin", request, null)).willReturn(new McpGateway.Result(response, List.of()));
		given(this.writer.isConfigured()).willReturn(true);
		given(this.writer.write(any(), any(), any(), any())).willThrow(new MigrationWriteException("Release version 14 already exists: my_app/V14__x.sql"));

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(jsonPath("$.result.content[1].text").value(
					"Release file not saved: Release version 14 already exists: my_app/V14__x.sql. Save content from the result to the project file path."));
	}

	@Test
	void packagesToolIsRunByGateway() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"solution_install\","
				+ "\"arguments\":{\"name\":\"my_app\",\"schema\":\"sales\"}}}";
		given(this.gateway.login(TOKEN)).willReturn("admin");
		given(this.gateway.toolHook("solution_install")).willReturn("packages");
		given(this.packages.isAdmin("admin")).willReturn(true);
		ObjectNode installed = JsonMapper.builder().build().createObjectNode().put("name", "my_app").put("db_schema", "sales");
		given(this.packages.install("admin", "my_app", "sales")).willReturn(installed);

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(jsonPath("$.id").value(5))
			.andExpect(jsonPath("$.result.isError").value(false))
			.andExpect(jsonPath("$.result.content[0].text").value("{\"name\":\"my_app\",\"db_schema\":\"sales\"}"));
		then(this.gateway).should(never()).handle(anyString(), anyString(), any());
	}

	@Test
	void packagesToolNeedsAdmin() throws Exception {
		String request = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"solution_packages\"}}";
		given(this.gateway.login(TOKEN)).willReturn("anna");
		given(this.gateway.toolHook("solution_packages")).willReturn("packages");

		this.mvc.perform(post("/mcp").header("Authorization", "Bearer " + TOKEN).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(jsonPath("$.result.isError").value(true));
		then(this.packages).should(never()).list();
	}

	@Test
	void streamIsNotOffered() throws Exception {
		given(this.gateway.login(TOKEN)).willReturn("admin");
		this.mvc.perform(get("/mcp").header("Authorization", "Bearer " + TOKEN))
			.andExpect(status().isMethodNotAllowed());
	}

	@Test
	void mcpTokenDoesNotOpenApplication() throws Exception {
		given(this.gateway.login(TOKEN)).willReturn("admin");
		this.mvc.perform(post("/api/ui/event").param("action", "solution_list").header("Authorization", "Bearer " + TOKEN)
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().is4xxClientError());
	}

	@TestConfiguration
	@EnableConfigurationProperties(McpProperties.class)
	static class Properties {

	}

}
