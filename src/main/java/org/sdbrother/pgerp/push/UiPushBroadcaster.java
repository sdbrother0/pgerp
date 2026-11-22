package org.sdbrother.pgerp.push;

import java.nio.ByteBuffer;
import java.security.Principal;
import java.time.Duration;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Predicate;

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
import org.springframework.web.socket.handler.TextWebSocketHandler;
import org.springframework.web.socket.server.support.HttpSessionHandshakeInterceptor;

/**
 * Подписчики на команды из базы — открытые вкладки браузера вошедших пользователей
 * (WebSocket {@code /api/ui/ws}).
 * <p>
 * Сообщение базы отправляется как есть. Из него читается только поле {@code users} — логины
 * адресатов ({@code ui_push_to_user}, {@code ui_push_to_role}); без него сообщение получают все.
 * Адресата-форму определяет браузер. Сообщения от браузера не ожидаются и игнорируются.
 * <p>
 * Запись в сокет и его закрытие ждут клиента (в Tomcat — до 20 с), поэтому у каждой вкладки своя очередь и свой
 * поток: вызывающий (LISTEN, выход, остановка) не ждёт никого.
 */
@Component
public class UiPushBroadcaster extends TextWebSocketHandler {

	private static final Logger logger = LoggerFactory.getLogger(UiPushBroadcaster.class);

	/** Столько даётся очереди на отправку, когда подписка закрывается; дальше — принудительно. */
	private static final Duration CLOSE_TIME_LIMIT = Duration.ofSeconds(10);

	/**
	 * Предел очереди вкладки в символах. NOTIFY — не больше 8000 байт, но транзакция присылает их тысячами сразу,
	 * и исправную вкладку это отключать не должно. Строка сообщения у всех очередей общая.
	 */
	private static final long BACKLOG_LIMIT = 8 * 1024 * 1024;

	/** Учёт пустого сообщения в очереди (ping). */
	private static final int MESSAGE_OVERHEAD = 128;

	private final Set<Subscriber> subscribers = ConcurrentHashMap.newKeySet();

	private final JsonMapper jsonMapper;

	public UiPushBroadcaster(JsonMapper jsonMapper) {
		this.jsonMapper = jsonMapper;
	}

	@Override
	public void afterConnectionEstablished(WebSocketSession session) {
		this.subscribers.add(new Subscriber(session));
	}

	@Override
	public void afterConnectionClosed(WebSocketSession session, CloseStatus status) {
		for (Subscriber subscriber : this.subscribers) {
			if (subscriber.session.getId().equals(session.getId())) {
				subscriber.discard();
			}
		}
	}

	/** Сообщение базы — адресатам из поля {@code users} или, без него, всем подписчикам. */
	public void broadcast(String message) {
		Set<String> revoked = logins(message, "revoked_users");
		if (revoked != null) {
			closeUsers(revoked);
			return;
		}
		Set<String> users = logins(message, "users");
		TextMessage text = new TextMessage(message);
		for (Subscriber subscriber : this.subscribers) {
			if (users == null || users.contains(userName(subscriber.session))) {
				subscriber.send(text, message.length());
			}
		}
	}

	/** Ping держит соединение открытым через прокси и находит закрытые вкладки. */
	public void heartbeat() {
		for (Subscriber subscriber : this.subscribers) {
			subscriber.send(new PingMessage(ByteBuffer.allocate(0)), 0);
		}
	}

	/** Выход пользователя: закрыть подписки вкладок этой HTTP-сессии. */
	public void closeHttpSession(String httpSessionId) {
		if (httpSessionId == null) {
			return;
		}
		closeWhere((session) -> httpSessionId
			.equals(session.getAttributes().get(HttpSessionHandshakeInterceptor.HTTP_SESSION_ID_ATTR_NAME)),
				CloseStatus.NORMAL);
	}

	/**
	 * Сессии пользователей отозваны (сообщение базы {@code revoked_users}): подписки закрываются. Действительная
	 * сессия переподключится сама, отозванную не пустит проверка сессии при рукопожатии.
	 */
	private void closeUsers(Set<String> users) {
		closeWhere((session) -> {
			String user = userName(session);
			return user != null && users.contains(user);
		}, CloseStatus.NORMAL);
	}

	/** Закрыть все подписки: остановка приложения или обрыв LISTEN; браузеры переподключатся сами. */
	public void closeAll() {
		closeWhere((session) -> true, CloseStatus.GOING_AWAY);
	}

	private void closeWhere(Predicate<WebSocketSession> filter, CloseStatus status) {
		for (Subscriber subscriber : this.subscribers) {
			if (filter.test(subscriber.session)) {
				subscriber.closeAfterQueue(status);
			}
		}
	}

	/** Логины из поля сообщения; {@code null} — поля нет. */
	private Set<String> logins(String message, String field) {
		try {
			JsonNode users = this.jsonMapper.readTree(message).get(field);
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

	private static void close(WebSocketSession session, CloseStatus status) {
		try {
			session.close(status);
		}
		catch (Exception ex) {
			logger.debug("Closing WebSocket session {} failed: {}", session.getId(), ex.toString());
		}
	}

	/** Вкладка с очередью: пишет в сокет один поток, порядок сообщений сохраняется. */
	private final class Subscriber {

		private final WebSocketSession session;

		private final ExecutorService sender = Executors.newSingleThreadExecutor(Thread.ofVirtual().name("ui-push").factory());

		private final AtomicLong backlog = new AtomicLong();

		private volatile boolean discarded;

		private Subscriber(WebSocketSession session) {
			this.session = session;
		}

		void send(WebSocketMessage<?> message, int length) {
			long size = length + MESSAGE_OVERHEAD;
			if (this.backlog.addAndGet(size) > BACKLOG_LIMIT) {
				disconnect();
				return;
			}
			try {
				this.sender.execute(() -> write(message, size));
			}
			catch (RejectedExecutionException ex) {
				logger.debug("WebSocket session {} is already closing", this.session.getId());
			}
		}

		private void write(WebSocketMessage<?> message, long size) {
			if (this.discarded) {
				return;
			}
			try {
				this.session.sendMessage(message);
				this.backlog.addAndGet(-size);
			}
			catch (Exception ex) {
				logger.debug("Sending to WebSocket session {} failed: {}", this.session.getId(), ex.toString());
				disconnect();
			}
		}

		/** Новое не принимается; принятое раньше уходит, затем закрытие, но не дольше {@link #CLOSE_TIME_LIMIT}. */
		void closeAfterQueue(CloseStatus status) {
			if (!subscribers.remove(this)) {
				return;
			}
			try {
				this.sender.execute(() -> close(this.session, status));
			}
			catch (RejectedExecutionException ex) {
				logger.debug("WebSocket session {} is already closed", this.session.getId());
			}
			this.sender.shutdown();
			CompletableFuture
				.delayedExecutor(CLOSE_TIME_LIMIT.toMillis(), TimeUnit.MILLISECONDS, (task) -> Thread.ofVirtual().start(task))
				.execute(this::disconnect);
		}

		/**
		 * Клиент не успевает или недоступен. Код не NORMAL: такое закрытие Tomcat не ждёт 20 с, а через 50 мс
		 * рвёт соединение, даже если отправка застряла.
		 */
		void disconnect() {
			if (!this.discarded) {
				discard();
				Thread.ofVirtual().start(() -> close(this.session, CloseStatus.SESSION_NOT_RELIABLE));
			}
		}

		void discard() {
			this.discarded = true;
			subscribers.remove(this);
			this.sender.shutdown();
		}

	}

}
