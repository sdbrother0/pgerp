package com.erp.gateway.report;

/**
 * Ошибка в шаблоне отчёта: jrxml не разбирается или не компилируется, выражение не вычисляется,
 * данные не приводятся к типу параметра или поля. Текст предназначен автору отчёта.
 */
public class ReportException extends RuntimeException {

	public ReportException(String message) {
		super(message);
	}

	public ReportException(String message, Throwable cause) {
		super(message, cause);
	}

}
