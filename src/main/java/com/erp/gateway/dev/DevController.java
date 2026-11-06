package com.erp.gateway.dev;

import java.nio.file.Path;
import java.security.Principal;
import java.sql.SQLException;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import org.postgresql.util.PSQLException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.core.NestedExceptionUtils;
import org.springframework.dao.DataAccessException;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Разработка решений в редакторе (только администратор):
 * <ul>
 * <li>{@code GET /api/dev/settings} — настроена ли папка пакетов решений;</li>
 * <li>{@code POST /api/dev/release} — действие {@code release_create}; файл выпуска сохраняется в пакет
 * решения, если папка пакетов настроена: в ответе {@code saved_to} или {@code save_error};</li>
 * <li>{@code GET /api/dev/solutions} — пакеты решений, их версии и установленные версии;</li>
 * <li>{@code POST /api/dev/solutions/install} — {@code {name, schema, reset}}: установка или обновление решения;
 * {@code reset: true} — чистая установка (схема решения удаляется перед установкой).</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/dev")
public class DevController {

	private final UiEventDispatcher dispatcher;

	private final MigrationWriter writer;

	private final SolutionPackages packages;

	private final JsonMapper jsonMapper;

	public DevController(UiEventDispatcher dispatcher, MigrationWriter writer, SolutionPackages packages,
			JsonMapper jsonMapper) {
		this.dispatcher = dispatcher;
		this.writer = writer;
		this.packages = packages;
		this.jsonMapper = jsonMapper;
	}

	@GetMapping(path = "/settings", produces = MediaType.APPLICATION_JSON_VALUE)
	public Map<String, Object> settings() {
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("status", "success");
		body.put("solutions_dir", this.writer.root().map(Path::toString).orElse(null));
		return body;
	}

	@PostMapping(path = "/release", consumes = MediaType.APPLICATION_JSON_VALUE, produces = MediaType.APPLICATION_JSON_VALUE)
	public String release(@RequestBody String payload, Principal principal, Locale locale) {
		String response = this.dispatcher.dispatch(principal.getName(), "release_create", payload, locale.getLanguage());
		JsonNode result = this.jsonMapper.readTree(response);
		if (!(result instanceof ObjectNode object) || !"success".equals(object.path("status").asString(""))
				|| !this.writer.isConfigured()) {
			return response;
		}
		try {
			JsonNode manifest = object.path("manifest");
			Path saved = this.writer.write(object.path("folder").asString(null), object.path("file_name").asString(null),
					object.path("content").asString(null), manifest.isObject() ? manifestText(manifest) : null);
			object.put("saved_to", saved.toString());
		}
		catch (MigrationWriteException ex) {
			object.put("save_error", ex.getMessage());
		}
		return this.jsonMapper.writeValueAsString(object);
	}

	@GetMapping(path = "/solutions", produces = MediaType.APPLICATION_JSON_VALUE)
	public Map<String, Object> solutions() {
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("status", "success");
		body.put("packages", this.packages.list());
		return body;
	}

	/**
	 * Ошибка в файле выпуска возвращается текстом базы: её видит только администратор, а без текста не понять,
	 * что исправлять в пакете.
	 */
	@PostMapping(path = "/solutions/install", consumes = MediaType.APPLICATION_JSON_VALUE,
			produces = MediaType.APPLICATION_JSON_VALUE)
	public ResponseEntity<Map<String, Object>> install(@RequestBody Map<String, Object> request, Principal principal) {
		Map<String, Object> body = new LinkedHashMap<>();
		try {
			body.put("status", "success");
			body.put("solution", this.packages.install(principal.getName(), text(request.get("name")), text(request.get("schema")),
					Boolean.TRUE.equals(request.get("reset"))));
			return ResponseEntity.ok(body);
		}
		catch (SolutionInstallException ex) {
			return installError(HttpStatus.UNPROCESSABLE_CONTENT, ex.getMessage());
		}
		catch (DataAccessException ex) {
			if (NestedExceptionUtils.getMostSpecificCause(ex) instanceof SQLException sql) {
				String message = (sql instanceof PSQLException psql && psql.getServerErrorMessage() != null)
						? psql.getServerErrorMessage().getMessage() : String.valueOf(sql.getMessage());
				HttpStatus status = "U0003".equals(sql.getSQLState()) ? HttpStatus.FORBIDDEN : HttpStatus.UNPROCESSABLE_CONTENT;
				return installError(status, message);
			}
			throw ex;
		}
	}

	private static ResponseEntity<Map<String, Object>> installError(HttpStatus status, String message) {
		Map<String, Object> body = new LinkedHashMap<>();
		body.put("status", "error");
		body.put("message", message);
		return ResponseEntity.status(status).body(body);
	}

	private static String text(Object value) {
		return (value != null) ? value.toString() : null;
	}

	/** Описание пакета из выпуска: title и description — на исходном языке. */
	private String manifestText(JsonNode manifest) {
		return this.jsonMapper.writerWithDefaultPrettyPrinter().writeValueAsString(manifest) + "\n";
	}

}
