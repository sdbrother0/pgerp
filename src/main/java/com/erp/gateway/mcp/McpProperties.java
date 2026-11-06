package com.erp.gateway.mcp;

import java.util.List;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Настройки MCP-сервера ({@code POST /mcp}).
 *
 * @param allowedOrigins адреса страниц, которым разрешено обращаться к {@code /mcp} из браузера (заголовок
 *                       {@code Origin}). Клиенты MCP (Claude Code, Claude Desktop) {@code Origin} не присылают;
 *                       запрос с чужим {@code Origin} отклоняется — защита от DNS rebinding.
 */
@ConfigurationProperties("erp.mcp")
public record McpProperties(List<String> allowedOrigins) {

	public McpProperties {
		allowedOrigins = (allowedOrigins != null) ? allowedOrigins.stream().filter((o) -> !o.isBlank()).toList()
				: List.of();
	}

}
