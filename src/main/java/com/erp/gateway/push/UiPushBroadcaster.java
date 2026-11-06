package com.erp.gateway.push;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.security.Principal;
import java.time.Duration;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Predicate;
import java.util.function.Supplier;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.core.JacksonException;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.stereotype.Component;
import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.PingMessage;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.handler.ConcurrentWebSocketSessionDecorator;
import org.springframework.web.socket.handler.TextWebSocketHandler;
import org.springframework.web.socket.server.support.HttpSessionHandshakeInterceptor;

/**
 * Подписчики на команды из базы — открытые вкладки браузера вошедших пользователей
 * (WebSocket {@code /api/ui/ws}).
 * <p>
 * Сообщение базы отправляется как есть. Из него читается только поле {@code users} — логины
 * адресатов ({@code ui_push_to_user}, {@code ui_push_to_role}); без него сообщение получают все.
 * Адресата-форму определяет браузер. Сообщения от браузера не ожидаются и игнорируются.
 */
@Component
public class UiPushBroadcaster extends TextWebSocketHandler {

	private static final Logger logger = LoggerFactory.getLogger(UiPushBroadcaster.class);

	/** Отправка в медленную вкладку не задерживает остальных: сверх лимитов сессия закрывается. */
	private static final Duration SEND_TIME_LIMIT = Duration.ofSeconds(10);

	private static final int BUFFER_SIZE_LIMIT = 512 * 1024;

	private final Set<WebSocketSession> sessions = ConcurrentHashMap.newKeySet();

	private final JsonMapper jsonMapper;

	public UiPushBroadcaster(JsonMapper jsonMapper) {
		this.jsonMapper = jsonMapper;
	}

	@Override
	public void afterConnectionEstablished(WebSocketSession session) {
		// Рассылка (поток LISTEN) и heartbeat не должны писать в одну сессию одновременно
		this.sessions.add(new ConcurrentWebSocketSessionDecorator(session, (int) SEND_TIME_LIMIT.toMillis(),
				BUFFER_SIZE_LIMIT));
	}

	@Override
	public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
		this.sessions.removeIf((decorated) -> decorated.getId().equals(session.getId()));
	}

	/** Сообщение базы — адресатам из поля {@code users} или, без него, всем подписчикам. */
	public void broadcast(String message) {
		Set<String> users = recipients(message);
		send(() -> new TextMessage(message), (session) -> users == null || users.contains(userName(session)));
	}

	/** Ping держит соединение открытым через прокси и находит закрытые вкладки. */
	public void heartbeat() {
		send(() -> new PingMessage(ByteBuffer.allocate(0)), (session) -> true);
	}

	/** Выход пользователя: закрыть подписки вкладок этой HTTP-сессии. */
	public void closeHttpSession(String httpSessionId) {
		if (httpSessionId == null) {
			return;
		}
		for (WebSocketSession session : this.sessions) {
			if (httpSessionId.equals(session.getAttributes().get(HttpSessionHandshakeInterceptor.HTTP_SESSION_ID_ATTR_NAME))) {
				this.sessions.remove(session);
				close(session, CloseStatus.NORMAL);
			}
		}
	}

	/** Закрыть все подписки при остановке приложения; браузеры потом переподключатся сами. */
	public void closeAll() {
		for (WebSocketSession session : this.sessions) {
			this.sessions.remove(session);
			close(session, CloseStatus.GOING_AWAY);
		}
	}

	/** Логины из поля {@code users}; {@code null} — сообщение для всех. */
	private Set<String> recipients(String message) {
		try {
			JsonNode users = this.jsonMapper.readTree(message).get("users");
			if (users == null || !users.isArray()) {
				return null;
			}
			Set<String> result = new HashSet<>();
			for (JsonNode user : users) {
				result.add(user.asString());
			}
			return result;
		}
		catch (JacksonException ex) {
			logger.warn("UI command from database is not valid JSON: {}", ex.getOriginalMessage());
			return null;
		}
	}

	private static String userName(WebSocketSession session) {
		Principal principal = session.getPrincipal();
		return (principal != null) ? principal.getName() : null;
	}

	private void send(Supplier<WebSocketMessage<?>> message, Predicate<WebSocketSession> filter) {
		for (WebSocketSession session : this.sessions) {
			if (!filter.test(session)) {
				continue;
			}
			try {
				session.sendMessage(message.get());
			}
			catch (IOException | IllegalStateException ex) {
				// Вкладка закрыта или не успевает принимать: соединение больше не нужно
				this.sessions.remove(session);
				close(session, CloseStatus.SESSION_NOT_RELIABLE);
			}
		}
	}

	private static void close(WebSocketSession session, CloseStatus status) {
		try {
			session.close(status);
		}
		catch (IOException ex) {
			logger.debug("Closing WebSocket session {} failed: {}", session.getId(), ex.getMessage());
		}
	}

}
