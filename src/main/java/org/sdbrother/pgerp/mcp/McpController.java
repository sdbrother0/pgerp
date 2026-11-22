package org.sdbrother.pgerp.mcp;

import java.net.URI;
import java.nio.file.Path;
import java.security.Principal;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import jakarta.servlet.http.HttpServletRequest;
import org.postgresql.util.PSQLException;
import org.sdbrother.pgerp.dev.MigrationWriteException;
import org.sdbrother.pgerp.dev.MigrationWriter;
import org.sdbrother.pgerp.dev.SolutionInstallException;
import org.sdbrother.pgerp.dev.SolutionPackages;
import org.sdbrother.pgerp.report.ReportException;
import org.sdbrother.pgerp.report.ReportRenderer;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;

/**
 * MCP-сервер (Model Context Protocol, транспорт Streamable HTTP без потока SSE): {@code POST /mcp}.
 * <p>
 * Запрос JSON-RPC уходит в базу ({@code pgerp.mcp_handle}) как есть; ответ возвращается клиенту, уведомления
 * получают {@code 202 Accepted}. Шлюз добавляет только то, чего нет в базе:
 * <ul>
 * <li>{@code compile_jrxml} — шаблон отчёта компилируется до сохранения (как {@code POST /api/reports/save});</li>
 * <li>{@code write_migration} — файл выпуска сохраняется в пакет решения ({@code erp.dev.solutions-dir});</li>
 * <li>{@code packages} — пакеты решений: список и установка выполняются шлюзом ({@link SolutionPackages});</li>
 * <li>сообщения {@code ui_print}, выведенные инструментом, добавляются к его результату.</li>
 * </ul>
 */
@RestController
public class McpController {

	private static final Logger logger = LoggerFactory.getLogger(McpController.class);

	private final McpGateway gateway;

	private final ReportRenderer renderer;

	private final MigrationWriter writer;

	private final SolutionPackages packages;

	private static final int BATCH_LIMIT = 50;

	private final JsonMapper jsonMapper;

	/** Дробные числа — без потери точности: элементы batch уходят в базу записанными заново. */
	private final JsonMapper exactMapper;

	private final McpProperties properties;

	public McpController(McpGateway gateway, ReportRenderer renderer, MigrationWriter writer, SolutionPackages packages,
			JsonMapper jsonMapper, McpProperties properties) {
		this.gateway = gateway;
		this.renderer = renderer;
		this.writer = writer;
		this.packages = packages;
		this.jsonMapper = jsonMapper;
		this.exactMapper = jsonMapper.rebuild().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).build();
		this.properties = properties;
	}

	@PostMapping(path = McpSecurityConfig.MCP_PATH, consumes = MediaType.APPLICATION_JSON_VALUE,
			produces = MediaType.APPLICATION_JSON_VALUE)
	public ResponseEntity<String> handle(@RequestBody String body, HttpServletRequest request, Principal principal,
			Locale locale) {
		String origin = request.getHeader("Origin");
		if (origin != null && !originAllowed(origin, request)) {
			return json(HttpStatus.FORBIDDEN, error(null, -32000, "Origin not allowed"));
		}
		JsonNode rpc;
		try {
			rpc = this.exactMapper.readTree(body);
		}
		catch (JacksonException ex) {
			return json(HttpStatus.BAD_REQUEST, error(null, -32700, "Parse error"));
		}
		// Без Accept-Language — язык пользователя, иначе исходный язык платформы, а не локаль сервера
		String lang = (request.getHeader("Accept-Language") != null) ? locale.getLanguage() : null;
		if (!(rpc instanceof ArrayNode batch)) {
			JsonNode response = single(rpc, body, principal.getName(), lang);
			return (response != null) ? json(HttpStatus.OK, response) : ResponseEntity.accepted().build();
		}
		if (batch.isEmpty() || batch.size() > BATCH_LIMIT) {
			return json(HttpStatus.OK, error(null, -32600, "Invalid Request"));
		}
		// Каждый элемент — как одиночный запрос, с теми же проверками шлюза
		ArrayNode responses = this.exactMapper.createArrayNode();
		for (JsonNode item : batch) {
			JsonNode response = item.isObject()
					? single(item, this.exactMapper.writeValueAsString(item), principal.getName(), lang)
					: error(null, -32600, "Invalid Request");
			if (response != null) {
				responses.add(response);
			}
		}
		return responses.isEmpty() ? ResponseEntity.accepted().build() : json(HttpStatus.OK, responses);
	}

	/** Один запрос JSON-RPC; {@code null} — уведомление, ответа нет. */
	private JsonNode single(JsonNode rpc, String body, String login, String lang) {
		if ("tools/call".equals(rpc.path("method").asString(""))) {
			// Вызов без id — уведомление: база его не выполняет, шлюз тоже
			if (!rpc.has("id")) {
				return null;
			}
		}
		try {
			ObjectNode early = checkReport(rpc, login);
			if (early == null) {
				early = packagesTool(rpc, login);
			}
			if (early != null) {
				return early;
			}
			McpGateway.Result result = this.gateway.handle(login, body, lang);
			if (result.response() == null) {
				return null;
			}
			JsonNode response = this.exactMapper.readTree(result.response());
			complete(response, result.messages());
			return response;
		}
		catch (DataAccessException ex) {
			logger.error("MCP request failed", ex);
			return error(rpc.path("id"), -32603, "Internal error");
		}
	}

	/** {@code report_save}: шаблон с ошибкой не уходит в базу — агент получает текст ошибки компиляции. */
	private ObjectNode checkReport(JsonNode rpc, String login) {
		if (!"tools/call".equals(rpc.path("method").asString(""))) {
			return null;
		}
		String tool = rpc.path("params").path("name").asString("");
		// Без права компилятор не запускается: отказ вернёт база
		if (!"compile_jrxml".equals(this.gateway.toolHook(tool)) || !this.gateway.toolAllowed(login, tool)) {
			return null;
		}
		try {
			this.renderer.compile(rpc.path("params").path("arguments").path("jrxml").asString(""));
			return null;
		}
		catch (ReportException ex) {
			ObjectNode response = this.jsonMapper.createObjectNode();
			response.put("jsonrpc", "2.0");
			response.set("id", rpc.path("id"));
			ObjectNode toolResult = response.putObject("result");
			toolResult.putArray("content").addObject().put("type", "text").put("text", "Report template error: " + ex.getMessage());
			toolResult.put("isError", true);
			return response;
		}
	}

	/** Инструменты пакетов решений ({@code hook = packages}) выполняет шлюз: файлы пакетов лежат в приложении. */
	private ObjectNode packagesTool(JsonNode rpc, String login) {
		if (!"tools/call".equals(rpc.path("method").asString(""))) {
			return null;
		}
		String tool = rpc.path("params").path("name").asString("");
		if (!"packages".equals(this.gateway.toolHook(tool))) {
			return null;
		}
		JsonNode args = rpc.path("params").path("arguments");
		String text;
		boolean failed = false;
		try {
			if (!this.packages.isAdmin(login)) {
				text = "Solution packages are available to the administrator only, after the initial password change";
				failed = true;
			}
			else if ("solution_install".equals(tool)) {
				text = this.jsonMapper.writeValueAsString(this.packages.install(login, args.path("name").asString(null),
						args.path("schema").asString(null)));
			}
			else {
				text = this.jsonMapper.writeValueAsString(this.packages.list());
			}
		}
		catch (SolutionInstallException ex) {
			text = ex.getMessage();
			failed = true;
		}
		catch (DataAccessException ex) {
			Throwable cause = NestedExceptionUtils.getMostSpecificCause(ex);
			text = (cause instanceof PSQLException psql && psql.getServerErrorMessage() != null)
					? psql.getServerErrorMessage().getMessage() : String.valueOf(cause.getMessage());
			failed = true;
		}
		ObjectNode response = this.jsonMapper.createObjectNode();
		response.put("jsonrpc", "2.0");
		response.set("id", rpc.path("id"));
		ObjectNode toolResult = response.putObject("result");
		toolResult.putArray("content").addObject().put("type", "text").put("text", text);
		toolResult.put("isError", failed);
		return response;
	}

	/** Сохранение файла выпуска и сообщения ui_print — дополнительными блоками текста результата. */
	private void complete(JsonNode item, List<String> messages) {
		if (!(item instanceof ObjectNode response)) {
			return;
		}
		List<String> notes = new ArrayList<>();
		JsonNode gatewayTasks = response.remove("_gateway");
		if (gatewayTasks != null && gatewayTasks.has("write_migration")) {
			notes.add(writeMigration(gatewayTasks.get("write_migration")));
		}
		if (!messages.isEmpty()) {
			notes.add("ui_print messages:\n" + String.join("\n", messages));
		}
		JsonNode content = response.path("result").path("content");
		if (content instanceof ArrayNode blocks) {
			notes.forEach((note) -> blocks.addObject().put("type", "text").put("text", note));
		}
	}

	private String writeMigration(JsonNode file) {
		String folder = file.path("folder").asString(null);
		String name = file.path("file_name").asString(null);
		if (!this.writer.isConfigured()) {
			return "The gateway solution packages folder is not configured (ERP_DEV_SOLUTIONS_DIR): save content from the result to the project file path"
					+ " and manifest to solution.json next to it, if it does not exist yet.";
		}
		try {
			JsonNode manifest = file.path("manifest");
			Path saved = this.writer.write(folder, name, file.path("content").asString(null),
					manifest.isObject() ? this.jsonMapper.writerWithDefaultPrettyPrinter().writeValueAsString(manifest) + "\n" : null);
			return "Release file saved: " + saved;
		}
		catch (MigrationWriteException ex) {
			return "Release file not saved: " + ex.getMessage() + ". Save content from the result to the project file path.";
		}
	}

	/** Тот же адрес, что у запроса, или адрес из erp.mcp.allowed-origins. */
	private boolean originAllowed(String origin, HttpServletRequest request) {
		if (this.properties.allowedOrigins().contains(origin)) {
			return true;
		}
		try {
			URI uri = URI.create(origin);
			int port = (uri.getPort() != -1) ? uri.getPort() : ("https".equals(uri.getScheme()) ? 443 : 80);
			return request.getScheme().equalsIgnoreCase(uri.getScheme()) && request.getServerName().equalsIgnoreCase(uri.getHost())
					&& request.getServerPort() == port;
		}
		catch (IllegalArgumentException ex) {
			return false;
		}
	}

	private ObjectNode error(JsonNode id, int code, String message) {
		ObjectNode response = this.jsonMapper.createObjectNode();
		response.put("jsonrpc", "2.0");
		if (id == null || id.isMissingNode()) {
			response.putNull("id");
		}
		else {
			response.set("id", id);
		}
		response.putObject("error").put("code", code).put("message", message);
		return response;
	}

	private ResponseEntity<String> json(HttpStatus status, JsonNode body) {
		return ResponseEntity.status(status)
			.contentType(MediaType.APPLICATION_JSON)
			.body(this.jsonMapper.writeValueAsString(body));
	}

}
