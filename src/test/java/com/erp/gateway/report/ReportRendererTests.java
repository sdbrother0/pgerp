package com.erp.gateway.report;

import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.util.Date;

import net.sf.jasperreports.engine.JasperReport;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.DeserializationFeature;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatExceptionOfType;

class ReportRendererTests {

	private static final String JRXML = """
			<jasperReport name="t" pageWidth="595" pageHeight="842" columnWidth="555" leftMargin="20" rightMargin="20" topMargin="20" bottomMargin="20">
				<parameter name="title" class="java.lang.String"/>
				<parameter name="day" class="java.util.Date"/>
				<parameter name="total" class="java.math.BigDecimal"/>
				<field name="name" class="java.lang.String"/>
				<field name="qty" class="java.lang.Integer"/>
				<field name="city" class="java.lang.String">
					<description><![CDATA[address.city]]></description>
				</field>
				<title height="40">
					<element kind="textField" x="0" y="0" width="555" height="20">
						<expression><![CDATA[$P{title} + " " + $R{Итого} + " " + $P{total}]]></expression>
					</element>
				</title>
				<detail>
					<band height="20">
						<element kind="textField" x="0" y="0" width="555" height="20">
							<expression><![CDATA[$F{name} + " " + $F{qty} + " " + $F{city}]]></expression>
						</element>
					</band>
				</detail>
			</jasperReport>
			""";

	private final ReportRenderer renderer = new ReportRenderer();

	private final JsonMapper json = JsonMapper.builder().enable(DeserializationFeature.USE_BIG_DECIMAL_FOR_FLOATS).build();

	@Test
	void fillsParametersAndRowsFromJson() {
		JasperReport report = this.renderer.compile(JRXML);
		JsonNode data = this.json.readTree("""
				{"title": "Запись №1", "day": "2026-11-04", "total": 12800.5, "ignored": 1,
				 "rows": [{"name": "Клавиатура", "qty": "4", "address": {"city": "Москва"}}]}
				""");
		byte[] pdf = this.renderer.render(report, data, this.json.readTree("""
				{"Итого": "Total"}
				"""), "en");
		assertThat(new String(pdf, 0, 5, StandardCharsets.ISO_8859_1)).isEqualTo("%PDF-");
	}

	@Test
	void reportWithoutRowsStillHasPage() {
		JasperReport report = this.renderer.compile(JRXML);
		byte[] pdf = this.renderer.render(report, this.json.readTree("""
				{"rows": []}
				"""), null, "ru");
		assertThat(new String(pdf, StandardCharsets.ISO_8859_1)).contains("/Count 1");
	}

	@Test
	void convertsJsonValuesToDeclaredClasses() {
		assertThat(JsonValues.convert(this.json.readTree("12800.50"), BigDecimal.class, "x")).isEqualTo(new BigDecimal("12800.50"));
		assertThat(JsonValues.convert(this.json.readTree("12345678901234567.89"), BigDecimal.class, "x"))
			.isEqualTo(new BigDecimal("12345678901234567.89"));
		assertThat(JsonValues.convert(this.json.readTree("\"7\""), Integer.class, "x")).isEqualTo(7);
		assertThat(JsonValues.convert(this.json.readTree("\"2026-11-04T10:15:00+01:00\""), Date.class, "x"))
			.isEqualTo(Date.from(java.time.OffsetDateTime.parse("2026-11-04T10:15:00+01:00").toInstant()));
		assertThat(JsonValues.convert(this.json.readTree("null"), String.class, "x")).isNull();
		assertThatExceptionOfType(ReportException.class)
			.isThrownBy(() -> JsonValues.convert(this.json.readTree("\"abc\""), Integer.class, "qty"))
			.withMessageContaining("“qty”");
	}

	@Test
	void unknownFieldIsTemplateError() {
		assertThatExceptionOfType(ReportException.class)
			.isThrownBy(() -> this.renderer.compile(JRXML.replace("$F{city}", "$F{town}")))
			.withMessageContaining("town");
	}

	@Test
	void brokenXmlIsTemplateError() {
		assertThatExceptionOfType(ReportException.class).isThrownBy(() -> this.renderer.compile("<jasperReport name='x'><title"));
		assertThatExceptionOfType(ReportException.class).isThrownBy(() -> this.renderer.compile("  "));
	}

	@Test
	void compiledReportIsCachedByVersion() {
		JasperReport first = this.renderer.compiled("t", "1", JRXML);
		assertThat(this.renderer.compiled("t", "1", "not used")).isSameAs(first);
		assertThat(this.renderer.compiled("t", "2", JRXML)).isNotSameAs(first);
	}

}
