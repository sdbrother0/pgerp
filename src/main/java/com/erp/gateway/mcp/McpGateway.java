package com.erp.gateway.mcp;

import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLWarning;
import java.util.ArrayList;
import java.util.List;
import java.util.Set;

import org.postgresql.util.PSQLWarning;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;

/**
 * Обращения MCP-сервера к базе. Протокол (JSON-RPC, список инструментов, вызовы) реализует
 * {@code pgerp.mcp_handle}: запрос уходит в базу как есть, как и действия UI.
 */
@Service
public class McpGateway {

	/** NOTICE от {@code ui_print}: показываются агенту вместе с результатом инструмента. */
	private static final Set<String> MESSAGE_STATES = Set.of("U0010", "U0011", "U0012");

	private final JdbcTemplate jdbcTemplate;

	public McpGateway(JdbcTemplate jdbcTemplate) {
		this.jdbcTemplate = jdbcTemplate;
	}

	/** Логин владельца действующего токена; {@code null} — токен не принят. */
	public String login(String token) {
		return this.jdbcTemplate.queryForObject("SELECT pgerp.mcp_token_login(?)", String.class, token);
	}

	/** Обработка шлюзом для инструмента: {@code compile_jrxml}, {@code write_migration} или {@code null}. */
	public String toolHook(String tool) {
		List<String> hooks = this.jdbcTemplate.queryForList("SELECT hook FROM pgerp.mcp_tools WHERE name = ?",
				String.class, tool);
		return hooks.isEmpty() ? null : hooks.get(0);
	}

	/**
	 * @param login   владелец токена
	 * @param request тело запроса JSON-RPC
	 * @param lang    язык из Accept-Language
	 * @return ответ базы ({@code response} {@code null} — только уведомления) и сообщения {@code ui_print}
	 */
	public Result handle(String login, String request, String lang) {
		List<String> messages = new ArrayList<>();
		String response = this.jdbcTemplate.execute("SELECT pgerp.mcp_handle(?, ?::json, ?)::text",
				(PreparedStatement statement) -> {
					statement.setString(1, login);
					statement.setString(2, request);
					statement.setString(3, lang);
					try (ResultSet rows = statement.executeQuery()) {
						return rows.next() ? rows.getString(1) : null;
					}
					finally {
						collectMessages(statement.getWarnings(), messages);
					}
				});
		return new Result(response, messages);
	}

	private static void collectMessages(SQLWarning warning, List<String> messages) {
		for (; warning != null; warning = warning.getNextWarning()) {
			if (MESSAGE_STATES.contains(warning.getSQLState())) {
				messages.add((warning instanceof PSQLWarning psql && psql.getServerErrorMessage() != null)
						? psql.getServerErrorMessage().getMessage() : String.valueOf(warning.getMessage()));
			}
		}
	}

	/** Ответ базы и сообщения {@code ui_print}, выведенные при обработке. */
	public record Result(String response, List<String> messages) {
	}

}
