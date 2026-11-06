package com.erp.gateway.web;

import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import com.erp.gateway.dispatcher.EmptyDispatchResultException;
import com.erp.gateway.dispatcher.UiEventFailedException;
import com.erp.gateway.dispatcher.UiMessage;
import com.erp.gateway.report.ReportException;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.HandlerMethodValidationException;

/**
 * Приводит ошибки к формату ответа PL/pgSQL-функций: {@code {"status": "error", "message": ...}}.
 */
@RestControllerAdvice
public class GatewayExceptionHandler {

	private static final Logger logger = LoggerFactory.getLogger(GatewayExceptionHandler.class);

	/** RAISE EXCEPTION в PL/pgSQL — бизнес-ошибка, текст предназначен пользователю. */
	private static final String RAISE_EXCEPTION = "P0001";

	/** Пользователь отключён или удалён — нужен повторный вход. */
	private static final String NOT_AUTHENTICATED = "U0002";

	/** Нет прав на действие или форму. */
	private static final String ACCESS_DENIED = "U0003";

	/** Некорректный JSON в payload. */
	private static final String INVALID_TEXT_REPRESENTATION = "22P02";

	/** Ошибка после ui_print: сообщения, выведенные до неё, идут в ответ вместе с ошибкой. */
	@ExceptionHandler(UiEventFailedException.class)
	ResponseEntity<Map<String, Object>> handleFailedWithMessages(UiEventFailedException ex) {
		ResponseEntity<Map<String, String>> response = handleDataAccess(ex.getCause());
		Map<String, Object> body = new LinkedHashMap<>(response.getBody());
		List<UiMessage> messages = ex.getMessages();
		body.put("messages", messages);
		return ResponseEntity.status(response.getStatusCode()).body(body);
	}

	@ExceptionHandler(DataAccessException.class)
	ResponseEntity<Map<String, String>> handleDataAccess(DataAccessException ex) {
		if (NestedExceptionUtils.getMostSpecificCause(ex) instanceof SQLException sqlEx) {
			if (RAISE_EXCEPTION.equals(sqlEx.getSQLState())) {
				return error(HttpStatus.UNPROCESSABLE_CONTENT, serverMessage(sqlEx));
			}
			if (NOT_AUTHENTICATED.equals(sqlEx.getSQLState())) {
				return error(HttpStatus.UNAUTHORIZED, serverMessage(sqlEx));
			}
			if (ACCESS_DENIED.equals(sqlEx.getSQLState())) {
				return error(HttpStatus.FORBIDDEN, serverMessage(sqlEx));
			}
			if (INVALID_TEXT_REPRESENTATION.equals(sqlEx.getSQLState())) {
				return error(HttpStatus.BAD_REQUEST, "Invalid JSON payload");
			}
		}
		logger.error("Database error while dispatching UI event", ex);
		return error(HttpStatus.INTERNAL_SERVER_ERROR, "Gateway database error");
	}

	/** Ошибка в шаблоне отчёта: текст для автора отчёта, клиент добавляет «Ошибка в шаблоне отчёта». */
	@ExceptionHandler(ReportException.class)
	ResponseEntity<Map<String, String>> handleReport(ReportException ex) {
		return ResponseEntity.status(HttpStatus.UNPROCESSABLE_CONTENT)
			.body(Map.of("status", "error", "kind", "report", "message", ex.getMessage()));
	}

	@ExceptionHandler(EmptyDispatchResultException.class)
	ResponseEntity<Map<String, String>> handleEmptyResult(EmptyDispatchResultException ex) {
		logger.error(ex.getMessage());
		return error(HttpStatus.INTERNAL_SERVER_ERROR, "Empty response from router function");
	}

	@ExceptionHandler(HandlerMethodValidationException.class)
	ResponseEntity<Map<String, String>> handleValidation(HandlerMethodValidationException ex) {
		return error(HttpStatus.BAD_REQUEST, "Parameter 'action' must not be blank");
	}

	private static ResponseEntity<Map<String, String>> error(HttpStatus status, String message) {
		return ResponseEntity.status(status).body(Map.of("status", "error", "message", message));
	}

	/** Драйвер PostgreSQL добавляет к сообщению префикс "ERROR: " и контекст "Where: ...". */
	private static String serverMessage(SQLException ex) {
		String message = String.valueOf(ex.getMessage()).lines().findFirst().orElse("");
		return message.startsWith("ERROR: ") ? message.substring("ERROR: ".length()) : message;
	}

}
