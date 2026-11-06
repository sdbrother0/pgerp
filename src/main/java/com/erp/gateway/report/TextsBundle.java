package com.erp.gateway.report;

import java.util.Collections;
import java.util.Enumeration;
import java.util.Map;
import java.util.ResourceBundle;

/**
 * Тексты $R{...} отчёта: переводы из базы на язык пользователя. Текст без перевода выводится как есть.
 */
final class TextsBundle extends ResourceBundle {

	private final Map<String, String> texts;

	TextsBundle(Map<String, String> texts) {
		this.texts = texts;
	}

	@Override
	protected Object handleGetObject(String key) {
		return this.texts.getOrDefault(key, key);
	}

	@Override
	public Enumeration<String> getKeys() {
		return Collections.enumeration(this.texts.keySet());
	}

}
