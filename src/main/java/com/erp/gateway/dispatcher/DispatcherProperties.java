package com.erp.gateway.dispatcher;

import jakarta.validation.constraints.Pattern;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Настройки диспетчера UI-событий.
 *
 * @param functionName имя PL/pgSQL-функции маршрутизатора (допускается схема: {@code pgerp.handle_ui_event}).
 *                     Подставляется в SQL как идентификатор, поэтому строго валидируется.
 */
@Validated
@ConfigurationProperties("erp.dispatcher")
public record DispatcherProperties(
		@Pattern(regexp = "[a-z_][a-z0-9_]*(\\.[a-z_][a-z0-9_]*)?") String functionName) {

	public DispatcherProperties {
		if (functionName == null) {
			functionName = "pgerp.handle_ui_event";
		}
	}

}
