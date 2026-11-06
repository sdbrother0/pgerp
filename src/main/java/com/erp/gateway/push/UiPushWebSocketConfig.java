package com.erp.gateway.push;

import org.springframework.context.annotation.Configuration;
import org.springframework.web.socket.config.annotation.EnableWebSocket;
import org.springframework.web.socket.config.annotation.WebSocketConfigurer;
import org.springframework.web.socket.config.annotation.WebSocketHandlerRegistry;
import org.springframework.web.socket.server.support.HttpSessionHandshakeInterceptor;

/**
 * Подписка браузера на команды из базы: WebSocket {@code /api/ui/ws}.
 * Подключаться можно только со страниц этого же сервера (проверка Origin; другие адреса —
 * {@code erp.push.allowed-origins}) и только
 * после входа (Spring Security). Id HTTP-сессии сохраняется в подписке: при выходе её вкладки отключаются.
 */
@Configuration
@EnableWebSocket
public class UiPushWebSocketConfig implements WebSocketConfigurer {

	private final UiPushBroadcaster broadcaster;

	private final UiPushProperties properties;

	public UiPushWebSocketConfig(UiPushBroadcaster broadcaster, UiPushProperties properties) {
		this.broadcaster = broadcaster;
		this.properties = properties;
	}

	@Override
	public void registerWebSocketHandlers(WebSocketHandlerRegistry registry) {
		var registration = registry.addHandler(this.broadcaster, "/api/ui/ws")
			.addInterceptors(new HttpSessionHandshakeInterceptor());
		if (!this.properties.allowedOrigins().isEmpty()) {
			registration.setAllowedOriginPatterns(this.properties.allowedOrigins().toArray(String[]::new));
		}
	}

}
