package com.erp.gateway.report;

import java.util.Map;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import com.erp.gateway.push.UiPushBroadcaster;
import com.erp.gateway.security.DatabaseAuthenticationProvider;
import com.erp.gateway.security.SecurityConfig;
import com.erp.gateway.web.GatewayExceptionHandler;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.containsString;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.header;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(ReportController.class)
@Import({ SecurityConfig.class, ReportRenderer.class, GatewayExceptionHandler.class })
class ReportControllerTests {

	private static final String JRXML = """
			<jasperReport name="r">
				<parameter name="title" class="java.lang.String"/>
				<title height="20">
					<element kind="textField" x="0" y="0" width="200" height="20">
						<expression><![CDATA[$P{title}]]></expression>
					</element>
				</title>
			</jasperReport>
			""";

	private final JsonMapper json = JsonMapper.builder().build();

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private UiEventDispatcher dispatcher;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	@Test
	@WithMockUser("anna")
	void reportRequestReturnsPdfFromDatabaseTemplateAndData() throws Exception {
		String id = "aa23bb50-59ec-4a64-a0c0-f1f3ae5beb20";
		String fill = this.json.writeValueAsString(Map.of(
				"status", "success",
				"report", Map.of("name", "r", "title", "Запись №45", "version", "1", "jrxml", JRXML),
				"data", Map.of("title", "Привет"),
				"texts", Map.of(),
				"lang", "ru"));
		given(this.dispatcher.dispatch(eq("anna"), eq("report_fill"), eq(this.json.writeValueAsString(Map.of("request", id))),
				anyString()))
			.willReturn(fill);

		this.mvc.perform(get("/api/reports/" + id))
			.andExpect(status().isOk())
			.andExpect(content().contentType(MediaType.APPLICATION_PDF))
			.andExpect(header().string("Content-Disposition", containsString("filename*=UTF-8''")))
			.andExpect(header().string("Cache-Control", containsString("no-store")));
	}

	@Test
	@WithMockUser("anna")
	void previewAndSaveAreForAdminsOnly() throws Exception {
		this.mvc.perform(post("/api/reports/preview").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isForbidden());
		this.mvc.perform(post("/api/reports/save").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isForbidden());
		then(this.dispatcher).shouldHaveNoInteractions();
	}

	@Test
	@WithMockUser(username = "admin", roles = "admin")
	void templateErrorIsNotSavedToDatabase() throws Exception {
		String request = this.json.writeValueAsString(Map.of("name", "r", "jrxml", "<jasperReport name='r'><title"));
		this.mvc.perform(post("/api/reports/save").with(csrf()).contentType(MediaType.APPLICATION_JSON).content(request))
			.andExpect(status().isUnprocessableContent())
			.andExpect(jsonPath("$.kind").value("report"));
		then(this.dispatcher).shouldHaveNoInteractions();
	}

}
