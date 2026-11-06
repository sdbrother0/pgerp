package com.erp.gateway.report;

import java.nio.charset.StandardCharsets;
import java.security.Principal;
import java.util.Locale;
import java.util.Map;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import net.sf.jasperreports.engine.JasperReport;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.http.CacheControl;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Отчёты PDF. Шаблон, данные и права — в базе (действия report_*), здесь только JasperReports.
 * <ul>
 * <li>{@code GET /api/reports/{id}} — отчёт по запросу ui_report: база проверяет, что запрос этого
 * пользователя и не устарел, и отдаёт шаблон с данными;</li>
 * <li>{@code POST /api/reports/preview} — предпросмотр несохранённого шаблона (администратор);</li>
 * <li>{@code POST /api/reports/save} — сохранение: шаблон сначала компилируется (администратор).</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/reports")
public class ReportController {

	private final UiEventDispatcher dispatcher;

	private final ReportRenderer renderer;

	private final JsonMapper jsonMapper;

	public ReportController(UiEventDispatcher dispatcher, ReportRenderer renderer, JsonMapper jsonMapper) {
		this.dispatcher = dispatcher;
		this.renderer = renderer;
		// Суммы из базы — без потери точности: дробные числа читаются в BigDecimal, а не в double
		this.jsonMapper = jsonMapper.rebuild().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).build();
	}

	@GetMapping("/{id:[0-9a-fA-F-]{36}}")
	public ResponseEntity<byte[]> show(@PathVariable String id, Principal principal, Locale locale) {
		JsonNode result = call(principal, "report_fill", Map.of("request", id), locale);
		JsonNode report = result.get("report");
		JasperReport compiled = this.renderer.compiled(report.get("name").asString(), report.get("version").asString(),
				report.get("jrxml").asString());
		byte[] pdf = this.renderer.render(compiled, result.get("data"), result.get("texts"), lang(result));
		return pdf(pdf, report.get("title").asString());
	}

	@PostMapping(path = "/preview", consumes = MediaType.APPLICATION_JSON_VALUE)
	public ResponseEntity<byte[]> preview(@RequestBody JsonNode request, Principal principal, Locale locale) {
		// Сначала шаблон: ошибка в нём видна без обращения к данным
		JasperReport compiled = this.renderer.compile(request.path("jrxml").asString(""));
		JsonNode result = call(principal, "report_preview", request, locale);
		byte[] pdf = this.renderer.render(compiled, result.get("data"), result.get("texts"), lang(result));
		return pdf(pdf, request.path("title").asString("report"));
	}

	@PostMapping(path = "/save", consumes = MediaType.APPLICATION_JSON_VALUE, produces = MediaType.APPLICATION_JSON_VALUE)
	public String save(@RequestBody JsonNode request, Principal principal, Locale locale) {
		this.renderer.compile(request.path("jrxml").asString(""));
		return this.dispatcher.dispatch(principal.getName(), "report_save", this.jsonMapper.writeValueAsString(request),
				locale.getLanguage());
	}

	private JsonNode call(Principal principal, String action, Object payload, Locale locale) {
		String response = this.dispatcher.dispatch(principal.getName(), action, this.jsonMapper.writeValueAsString(payload),
				locale.getLanguage());
		JsonNode result = this.jsonMapper.readTree(response);
		if (!"success".equals(result.path("status").asString(""))) {
			throw new ReportException(result.path("message").asString("The report is unavailable"));
		}
		return result;
	}

	private static String lang(JsonNode result) {
		return result.path("lang").asString("en");
	}

	private static ResponseEntity<byte[]> pdf(byte[] pdf, String title) {
		return ResponseEntity.status(HttpStatus.OK)
			.contentType(MediaType.APPLICATION_PDF)
			.header(HttpHeaders.CONTENT_DISPOSITION,
					ContentDisposition.inline().filename(title + ".pdf", StandardCharsets.UTF_8).build().toString())
			.cacheControl(CacheControl.noStore())
			.body(pdf);
	}

}
