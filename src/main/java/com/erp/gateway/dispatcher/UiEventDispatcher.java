package com.erp.gateway.dispatcher;

import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLWarning;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;

import org.postgresql.util.PSQLWarning;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.dao.DataAccessException;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Диспетчер UI-событий: транслирует любое действие пользователя (клик, выбор из списка,
 * переключение страницы, сохранение формы) в единую PL/pgSQL-функцию маршрутизатор.
 * <p>
 * JSON не разбирается на стороне Java: payload уходит в базу как есть, ответ базы
 * (данные + инструкции для UI) возвращается клиенту сырой строкой. Исключение — сообщения
 * {@code ui_print} («Сообщить»): они приходят как NOTICE с кодами U0010–U0012 и добавляются
 * в ответ массивом {@code messages}; без сообщений ответ не меняется.
 */
@Service
public class UiEventDispatcher {

	/** Коды NOTICE от {@code pgerp.ui_print} → вид сообщения. */
	private static final Map<String, String> MESSAGE_KINDS = Map.of("U0010", "info", "U0011", "warning", "U0012",
			"error");

	private final JdbcTemplate jdbcTemplate;

	private final JsonMapper jsonMapper;

	private final String sql;

	public UiEventDispatcher(JdbcTemplate jdbcTemplate, JsonMapper jsonMapper, DispatcherProperties properties) {
		this.jdbcTemplate = jdbcTemplate;
		this.jsonMapper = jsonMapper;
		// Типы соответствуют сигнатуре handle_ui_event(VARCHAR, VARCHAR, JSON, VARCHAR) из схемы.
		this.sql = "SELECT %s(?, ?, ?::json, ?)::text".formatted(properties.functionName());
	}

	/**
	 * @param user        логин вошедшего пользователя: база проверяет его права на действие
	 * @param action      имя действия, например {@code handle_product_save}
	 * @param payloadJson данные формы в виде JSON
	 * @param language    язык браузера, например {@code en}; язык из настройки пользователя важнее
	 * @return JSON-ответ, сформированный базой данных
	 * @throws UiEventFailedException ошибка базы, перед которой действие вывело сообщения
	 */
	public String dispatch(String user, String action, String payloadJson, String language) {
		List<UiMessage> messages = new ArrayList<>();
		String result;
		try {
			result = this.jdbcTemplate.execute(this.sql, (PreparedStatement statement) -> {
				statement.setString(1, user);
				statement.setString(2, action);
				statement.setString(3, payloadJson);
				statement.setString(4, language);
				// NOTICE, пришедшие до ошибки, тоже остаются в предупреждениях запроса
				try (ResultSet rows = statement.executeQuery()) {
					return rows.next() ? rows.getString(1) : null;
				}
				finally {
					collectMessages(statement.getWarnings(), messages);
				}
			});
		}
		catch (DataAccessException ex) {
			if (messages.isEmpty()) {
				throw ex;
			}
			throw new UiEventFailedException(ex, messages);
		}
		if (result == null) {
			throw new EmptyDispatchResultException(action);
		}
		return messages.isEmpty() ? result : withMessages(result, messages);
	}

	private static void collectMessages(SQLWarning warning, List<UiMessage> messages) {
		for (; warning != null; warning = warning.getNextWarning()) {
			String kind = MESSAGE_KINDS.get(warning.getSQLState());
			if (kind != null) {
				messages.add(new UiMessage(serverMessage(warning), kind));
			}
		}
	}

	/** Драйвер PostgreSQL может добавить к тексту префикс "NOTICE: " и контекст "Where: ...". */
	private static String serverMessage(SQLWarning warning) {
		if (warning instanceof PSQLWarning psql && psql.getServerErrorMessage() != null) {
			return psql.getServerErrorMessage().getMessage();
		}
		String message = String.valueOf(warning.getMessage());
		return message.startsWith("NOTICE: ") ? message.substring("NOTICE: ".length()) : message;
	}

	private String withMessages(String result, List<UiMessage> messages) {
		JsonNode response = this.jsonMapper.readTree(result);
		if (!(response instanceof ObjectNode object)) {
			return result;
		}
		object.set("messages", this.jsonMapper.valueToTree(messages));
		return this.jsonMapper.writeValueAsString(object);
	}

}
