package com.erp.gateway.web;

import java.sql.SQLException;
import java.util.List;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import com.erp.gateway.dispatcher.UiEventFailedException;
import com.erp.gateway.dispatcher.UiMessage;
import com.erp.gateway.push.UiPushBroadcaster;
import com.erp.gateway.security.DatabaseAuthenticationProvider;
import com.erp.gateway.security.SecurityConfig;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.context.annotation.Import;
import org.springframework.http.MediaType;
import org.springframework.jdbc.UncategorizedSQLException;
import org.springframework.security.test.context.support.WithMockUser;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.MockMvc;

import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.then;
import static org.springframework.security.test.web.servlet.request.SecurityMockMvcRequestPostProcessors.csrf;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(UiEventController.class)
@Import(SecurityConfig.class)
@WithMockUser("anna")
class UiEventControllerTests {

	@Autowired
	private MockMvc mvc;

	@MockitoBean
	private UiEventDispatcher dispatcher;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@MockitoBean
	private UiPushBroadcaster broadcaster;

	@Test
	void passesDatabaseResponseThroughUnchanged() throws Exception {
		String payload = "{\"prod_name\":\"Стол\",\"prod_price\":100}";
		String response = "{\"status\":\"success\",\"ui_instructions\":{\"command\":\"close_form\"}}";
		given(this.dispatcher.dispatch("anna", "handle_product_save", payload, "en")).willReturn(response);

		this.mvc.perform(post("/api/ui/event").param("action", "handle_product_save")
				.with(csrf()).contentType(MediaType.APPLICATION_JSON)
				.content(payload))
			.andExpect(status().isOk())
			.andExpect(content().contentTypeCompatibleWith(MediaType.APPLICATION_JSON))
			.andExpect(content().json(response, true));
	}

	@Test
	void missingBodyIsSentAsEmptyObject() throws Exception {
		given(this.dispatcher.dispatch("anna", "refresh", "{}", "en")).willReturn("{\"status\":\"success\"}");

		this.mvc.perform(post("/api/ui/event").param("action", "refresh").with(csrf()).contentType(MediaType.APPLICATION_JSON))
			.andExpect(status().isOk());
		then(this.dispatcher).should().dispatch("anna", "refresh", "{}", "en");
	}

	@Test
	void blankActionIsRejected() throws Exception {
		this.mvc.perform(post("/api/ui/event").param("action", " ").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isBadRequest())
			.andExpect(jsonPath("$.status").value("error"));
	}

	@Test
	void raiseExceptionIsReturnedAsBusinessError() throws Exception {
		SQLException sqlEx = new SQLException("ERROR: Название записи обязательно\n  Where: PL/pgSQL function",
				"P0001");
		given(this.dispatcher.dispatch("anna", "handle_product_save", "{}", "en"))
			.willThrow(new UncategorizedSQLException("dispatch", "SELECT ...", sqlEx));

		this.mvc.perform(post("/api/ui/event").param("action", "handle_product_save")
				.with(csrf()).contentType(MediaType.APPLICATION_JSON)
				.content("{}"))
			.andExpect(status().isUnprocessableContent())
			.andExpect(jsonPath("$.status").value("error"))
			.andExpect(jsonPath("$.message").value("Название записи обязательно"));
	}

	@Test
	void messagesPrintedBeforeErrorAreReturnedWithIt() throws Exception {
		SQLException sqlEx = new SQLException("ERROR: Расчёт прерван", "P0001");
		given(this.dispatcher.dispatch("anna", "recalc", "{}", "en"))
			.willThrow(new UiEventFailedException(new UncategorizedSQLException("dispatch", "SELECT ...", sqlEx),
					List.of(new UiMessage("Обработано строк: 42", "info"), new UiMessage("Остаток меньше нуля", "warning"))));

		this.mvc.perform(post("/api/ui/event").param("action", "recalc").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isUnprocessableContent())
			.andExpect(jsonPath("$.message").value("Расчёт прерван"))
			.andExpect(jsonPath("$.messages[0].text").value("Обработано строк: 42"))
			.andExpect(jsonPath("$.messages[1].kind").value("warning"));
	}

	@Test
	void unexpectedDatabaseErrorDoesNotLeakDetails() throws Exception {
		SQLException sqlEx = new SQLException("connection refused to db-host:5432", "08001");
		given(this.dispatcher.dispatch("anna", "x", "{}", "en")).willThrow(new UncategorizedSQLException("dispatch", "SELECT ...", sqlEx));

		this.mvc.perform(post("/api/ui/event").param("action", "x").with(csrf()).contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isInternalServerError())
			.andExpect(jsonPath("$.message").value("Gateway database error"));
	}

	@Test
	@WithMockUser(username = "anna", roles = {})
	void accessDeniedByDatabaseIsForbidden() throws Exception {
		SQLException sqlEx = new SQLException("ERROR: Нет доступа к действию «Удаление записи»", "U0003");
		given(this.dispatcher.dispatch("anna", "my_app_item_delete", "{}", "en"))
			.willThrow(new UncategorizedSQLException("dispatch", "SELECT ...", sqlEx));

		this.mvc.perform(post("/api/ui/event").param("action", "my_app_item_delete").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isForbidden())
			.andExpect(jsonPath("$.message").value("Нет доступа к действию «Удаление записи»"));
	}

	@Test
	void disabledUserMustLogInAgain() throws Exception {
		SQLException sqlEx = new SQLException("ERROR: Сеанс завершён — войдите снова", "U0002");
		given(this.dispatcher.dispatch("anna", "x", "{}", "en"))
			.willThrow(new UncategorizedSQLException("dispatch", "SELECT ...", sqlEx));

		this.mvc.perform(post("/api/ui/event").param("action", "x").with(csrf())
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isUnauthorized());
	}

	@Test
	void requestWithoutCsrfTokenIsRejected() throws Exception {
		this.mvc.perform(post("/api/ui/event").param("action", "x").contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isForbidden());
		then(this.dispatcher).shouldHaveNoInteractions();
	}

	@Test
	void browserLanguageIsPassedToDatabase() throws Exception {
		given(this.dispatcher.dispatch("anna", "menu_get", "{}", "de")).willReturn("{\"status\":\"success\"}");

		this.mvc.perform(post("/api/ui/event").param("action", "menu_get").with(csrf())
				.header("Accept-Language", "de-AT,de;q=0.9,en;q=0.5")
				.contentType(MediaType.APPLICATION_JSON).content("{}"))
			.andExpect(status().isOk());
		then(this.dispatcher).should().dispatch("anna", "menu_get", "{}", "de");
	}

}
