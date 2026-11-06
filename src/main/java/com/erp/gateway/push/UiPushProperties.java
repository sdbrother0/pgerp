package com.erp.gateway.push;

import java.util.List;

import jakarta.validation.constraints.Pattern;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Настройки команд в UI из базы.
 *
 * @param channel        канал NOTIFY, в который пишет {@code pgerp.ui_push}. Подставляется в {@code LISTEN}
 *                       как идентификатор, поэтому строго валидируется.
 * @param allowedOrigins адреса, с которых браузер может подписаться на WebSocket {@code /api/ui/ws}, например
 *                       {@code https://erp.example.com} (допускаются шаблоны {@code https://*.example.com}).
 *                       Пусто — только тот же адрес, что у запроса; за обратным прокси без
 *                       {@code server.forward-headers-strategy} он не совпадает с адресом в браузере.
 */
@Validated
@ConfigurationProperties("erp.push")
public record UiPushProperties(@Pattern(regexp = "[a-z_][a-z0-9_]*") String channel, List<String> allowedOrigins) {

	public UiPushProperties {
		if (channel == null) {
			channel = "erp_ui";
		}
		allowedOrigins = (allowedOrigins != null) ? allowedOrigins.stream().filter((o) -> !o.isBlank()).toList()
				: List.of();
	}

}
