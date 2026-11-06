package com.erp.gateway.report;

import java.math.BigDecimal;
import java.math.BigInteger;
import java.sql.Timestamp;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.time.OffsetDateTime;
import java.time.ZoneId;
import java.time.format.DateTimeParseException;
import java.util.Date;

import net.sf.jasperreports.engine.JRDataSource;
import tools.jackson.databind.JsonNode;

/**
 * Значение из JSON функции данных → класс параметра или поля отчёта (class="..." в jrxml).
 * Даты приходят из PostgreSQL строками: {@code 2026-11-04} или {@code 2026-11-04T10:15:00+01:00}.
 */
final class JsonValues {

	private JsonValues() {
	}

	static Object convert(JsonNode node, Class<?> type, String name) {
		if (node == null || node.isNull() || node.isMissingNode()) {
			return null;
		}
		try {
			return doConvert(node, type);
		}
		catch (RuntimeException ex) {
			throw new ReportException("“%s”: value %s cannot be converted to %s".formatted(name, node, type.getName()), ex);
		}
	}

	private static Object doConvert(JsonNode node, Class<?> type) {
		if (type == String.class) {
			return node.isValueNode() ? node.asString() : node.toString();
		}
		if (type == Integer.class) {
			return node.isNumber() ? node.intValue() : Integer.valueOf(text(node));
		}
		if (type == Long.class) {
			return node.isNumber() ? node.longValue() : Long.valueOf(text(node));
		}
		if (type == Short.class) {
			return node.isNumber() ? node.shortValue() : Short.valueOf(text(node));
		}
		if (type == BigDecimal.class) {
			return node.isNumber() ? node.decimalValue() : new BigDecimal(text(node));
		}
		if (type == BigInteger.class) {
			return node.isNumber() ? node.bigIntegerValue() : new BigInteger(text(node));
		}
		if (type == Double.class) {
			return node.isNumber() ? node.doubleValue() : Double.valueOf(text(node));
		}
		if (type == Float.class) {
			return node.isNumber() ? node.floatValue() : Float.valueOf(text(node));
		}
		if (type == Boolean.class) {
			return node.isBoolean() ? node.booleanValue() : Boolean.valueOf(text(node));
		}
		if (type == LocalDate.class) {
			return LocalDate.parse(text(node).substring(0, 10));
		}
		if (type == LocalDateTime.class) {
			return instant(text(node)).atZone(ZoneId.systemDefault()).toLocalDateTime();
		}
		if (type == OffsetDateTime.class) {
			return instant(text(node)).atZone(ZoneId.systemDefault()).toOffsetDateTime();
		}
		if (type == Instant.class) {
			return instant(text(node));
		}
		if (type == Timestamp.class) {
			return Timestamp.from(instant(text(node)));
		}
		if (type == java.sql.Date.class) {
			return java.sql.Date.valueOf(LocalDate.parse(text(node).substring(0, 10)));
		}
		if (type == Date.class) {
			return Date.from(instant(text(node)));
		}
		// Вложенный массив — источник данных для подотчёта или таблицы
		if (JRDataSource.class.isAssignableFrom(type) && node.isArray()) {
			return new JsonRowsDataSource(node);
		}
		if (type == Object.class) {
			if (node.isNumber()) {
				return node.decimalValue();
			}
			if (node.isBoolean()) {
				return node.booleanValue();
			}
			return node.isValueNode() ? node.asString() : node;
		}
		if (type.isInstance(node)) {
			return node;
		}
		throw new IllegalArgumentException("unsupported type");
	}

	private static String text(JsonNode node) {
		return node.asString().trim();
	}

	/** Дата без времени — начало дня по часовому поясу сервера; время без пояса — тоже в нём. */
	private static Instant instant(String text) {
		if (text.length() == 10) {
			return LocalDate.parse(text).atStartOfDay(ZoneId.systemDefault()).toInstant();
		}
		try {
			return OffsetDateTime.parse(text).toInstant();
		}
		catch (DateTimeParseException ex) {
			return LocalDateTime.parse(text).atZone(ZoneId.systemDefault()).toInstant();
		}
	}

}
