package com.erp.gateway.report;

import java.util.ArrayList;
import java.util.List;

import net.sf.jasperreports.engine.JRField;
import net.sf.jasperreports.engine.JRRewindableDataSource;
import tools.jackson.databind.JsonNode;

/**
 * Строки отчёта из JSON-массива объектов. Поле отчёта берёт значение по описанию
 * ({@code <description>} в jrxml, путь через точку: {@code customer.name}) или, без описания, по имени.
 */
final class JsonRowsDataSource implements JRRewindableDataSource {

	private final List<JsonNode> rows = new ArrayList<>();

	private int index = -1;

	JsonRowsDataSource(JsonNode array) {
		array.forEach(this.rows::add);
	}

	@Override
	public boolean next() {
		return ++this.index < this.rows.size();
	}

	@Override
	public Object getFieldValue(JRField field) {
		String path = (field.getDescription() != null && !field.getDescription().isBlank())
				? field.getDescription().trim() : field.getName();
		JsonNode node = this.rows.get(this.index);
		for (String part : path.split("\\.")) {
			node = (node != null) ? node.get(part) : null;
		}
		return JsonValues.convert(node, field.getValueClass(), field.getName());
	}

	@Override
	public void moveFirst() {
		this.index = -1;
	}

}
