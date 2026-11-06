package com.erp.gateway.report;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import net.sf.jasperreports.engine.JREmptyDataSource;
import net.sf.jasperreports.engine.JRDataSource;
import net.sf.jasperreports.engine.JRException;
import net.sf.jasperreports.engine.JRParameter;
import net.sf.jasperreports.engine.JRRuntimeException;
import net.sf.jasperreports.engine.JasperCompileManager;
import net.sf.jasperreports.engine.JasperExportManager;
import net.sf.jasperreports.engine.JasperFillManager;
import net.sf.jasperreports.engine.JasperPrint;
import net.sf.jasperreports.engine.JasperReport;
import net.sf.jasperreports.engine.design.JasperDesign;
import net.sf.jasperreports.engine.type.WhenNoDataTypeEnum;
import net.sf.jasperreports.engine.xml.JRXmlLoader;
import tools.jackson.databind.JsonNode;

import org.springframework.stereotype.Component;

/**
 * Компилирует шаблоны jrxml и заполняет их данными из базы в PDF.
 * <p>
 * Данные — JSON-объект функции данных: ключи верхнего уровня становятся параметрами отчёта ($P{...})
 * с приведением к их классам, массив {@code rows} — строками ($F{...}). Тексты $R{...} берутся из
 * переводов, присланных базой; числа и даты форматируются по языку пользователя.
 */
@Component
public class ReportRenderer {

	/** Скомпилированные шаблоны: ключ — имя и время изменения отчёта, старая версия просто не запрашивается. */
	private static final int CACHE_LIMIT = 64;

	private static final int MESSAGE_LIMIT = 2000;

	private final Map<String, JasperReport> cache = new ConcurrentHashMap<>();

	/** Компиляция с проверкой: ошибка разбора XML или выражений — {@link ReportException}. */
	public JasperReport compile(String jrxml) {
		if (jrxml == null || jrxml.isBlank()) {
			throw new ReportException("The report template is empty");
		}
		try {
			JasperDesign design = JRXmlLoader.load(new ByteArrayInputStream(jrxml.getBytes(StandardCharsets.UTF_8)));
			// Без строк — пустой отчёт с шапкой и итогами, а не PDF без страниц
			if (design.getWhenNoDataType() == null) {
				design.setWhenNoDataType(WhenNoDataTypeEnum.ALL_SECTIONS_NO_DETAIL);
			}
			return JasperCompileManager.compileReport(design);
		}
		catch (JRException | RuntimeException ex) {
			throw new ReportException(describe(ex), ex);
		}
	}

	/** Скомпилированный шаблон сохранённого отчёта: версия меняется при каждом сохранении. */
	public JasperReport compiled(String name, String version, String jrxml) {
		String key = name + '@' + version;
		JasperReport report = this.cache.get(key);
		if (report == null) {
			report = compile(jrxml);
			if (this.cache.size() >= CACHE_LIMIT) {
				this.cache.clear();
			}
			this.cache.put(key, report);
		}
		return report;
	}

	/**
	 * @param data  JSON-объект функции данных
	 * @param texts переводы текстов $R{...}: {"Итого": "Total"}
	 * @param lang  язык пользователя: формат чисел и дат
	 */
	public byte[] render(JasperReport report, JsonNode data, JsonNode texts, String lang) {
		Map<String, Object> parameters = new HashMap<>();
		for (JRParameter parameter : report.getParameters()) {
			if (!parameter.isSystemDefined() && data != null && data.has(parameter.getName())) {
				parameters.put(parameter.getName(),
						JsonValues.convert(data.get(parameter.getName()), parameter.getValueClass(), parameter.getName()));
			}
		}
		parameters.put(JRParameter.REPORT_LOCALE, Locale.forLanguageTag((lang != null) ? lang : "en"));
		parameters.put(JRParameter.REPORT_RESOURCE_BUNDLE, new TextsBundle(textMap(texts)));

		JsonNode rows = (data != null) ? data.get("rows") : null;
		JRDataSource source = (rows != null && rows.isArray()) ? new JsonRowsDataSource(rows) : new JREmptyDataSource(1);
		try {
			JasperPrint print = JasperFillManager.fillReport(report, parameters, source);
			return JasperExportManager.exportReportToPdf(print);
		}
		catch (JRException | RuntimeException ex) {
			if (ex instanceof ReportException reportException) {
				throw reportException;
			}
			throw new ReportException(describe(ex), ex);
		}
	}

	private static Map<String, String> textMap(JsonNode texts) {
		Map<String, String> map = new LinkedHashMap<>();
		if (texts != null && texts.isObject()) {
			texts.properties().forEach((entry) -> map.put(entry.getKey(), entry.getValue().asString()));
		}
		return map;
	}

	/** Сообщение и причины без повторов: «Error evaluating expression … ← NullPointerException: …». */
	private static String describe(Throwable ex) {
		StringBuilder text = new StringBuilder();
		for (Throwable cause = ex; cause != null; cause = (cause.getCause() != cause) ? cause.getCause() : null) {
			String message = (cause.getMessage() != null) ? cause.getMessage().strip() : cause.getClass().getSimpleName();
			if (!text.toString().contains(message)) {
				if (!text.isEmpty()) {
					text.append("\n← ");
				}
				text.append((cause == ex || cause.getMessage() != null) ? message : cause.getClass().getName());
			}
		}
		return (text.length() > MESSAGE_LIMIT) ? text.substring(0, MESSAGE_LIMIT) + "…" : text.toString();
	}

}
