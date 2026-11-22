package org.sdbrother.pgerp.push;

import java.sql.Connection;
import java.sql.SQLException;
import java.sql.Statement;
import java.time.Duration;

import javax.sql.DataSource;

import org.postgresql.PGConnection;
import org.postgresql.PGNotification;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.context.SmartLifecycle;
import org.springframework.stereotype.Component;

/**
 * Слушает канал NOTIFY ({@code LISTEN erp_ui}) и передаёт каждое уведомление браузерам.
 * <p>
 * Держит одно подключение из пула на отдельном потоке; при обрыве переподключается.
 * Раз в {@link #HEARTBEAT_INTERVAL} отправляет браузерам heartbeat, в том числе когда уведомления идут непрерывно:
 * адресное уведомление видит не каждая вкладка, а молчащее соединение закрывает прокси.
 */
@Component
public class PgNotificationListener implements SmartLifecycle {

	private static final Logger logger = LoggerFactory.getLogger(PgNotificationListener.class);

	private static final Duration HEARTBEAT_INTERVAL = Duration.ofSeconds(25);

	private static final Duration RECONNECT_DELAY = Duration.ofSeconds(5);

	private final DataSource dataSource;

	private final UiPushBroadcaster broadcaster;

	private final String channel;

	private final Duration heartbeatInterval;

	private volatile Thread thread;

	@Autowired
	public PgNotificationListener(DataSource dataSource, UiPushBroadcaster broadcaster, UiPushProperties properties) {
		this(dataSource, broadcaster, properties, HEARTBEAT_INTERVAL);
	}

	PgNotificationListener(DataSource dataSource, UiPushBroadcaster broadcaster, UiPushProperties properties,
			Duration heartbeatInterval) {
		this.heartbeatInterval = heartbeatInterval;
		this.dataSource = dataSource;
		this.broadcaster = broadcaster;
		this.channel = properties.channel();
	}

	@Override
	public void start() {
		this.thread = Thread.ofVirtual().name("pg-listen-" + this.channel).start(this::run);
	}

	@Override
	public void stop() {
		Thread current = this.thread;
		this.thread = null;
		if (current != null) {
			current.interrupt();
		}
		// Фаза этого компонента останавливается раньше веб-сервера: подписки закрываются до того,
		// как сервер начнёт ждать завершения соединений
		this.broadcaster.closeAll();
	}

	@Override
	public boolean isRunning() {
		return this.thread != null;
	}

	private void run() {
		while (isRunning()) {
			try (Connection connection = this.dataSource.getConnection()) {
				listen(connection);
			}
			catch (SQLException ex) {
				if (isRunning()) {
					logger.warn("LISTEN {} interrupted, reconnecting in {}s: {}", this.channel,
							RECONNECT_DELAY.toSeconds(), ex.getMessage());
					pause();
				}
			}
		}
	}

	private void listen(Connection connection) throws SQLException {
		try (Statement statement = connection.createStatement()) {
			// channel проверен шаблоном в UiPushProperties
			statement.execute("LISTEN " + this.channel);
		}
		PGConnection pg = connection.unwrap(PGConnection.class);
		logger.info("Listening for UI commands on channel {}", this.channel);
		// Пока LISTEN не работал, отзыв сессий мог пройти мимо: подписки переподключаются через проверку сессии
		this.broadcaster.closeAll();
		long lastHeartbeat = System.nanoTime();
		while (isRunning()) {
			long untilHeartbeat = this.heartbeatInterval.toMillis()
					- Duration.ofNanos(System.nanoTime() - lastHeartbeat).toMillis();
			if (untilHeartbeat <= 0) {
				this.broadcaster.heartbeat();
				lastHeartbeat = System.nanoTime();
				continue;
			}
			// Не 0: для драйвера это «ждать без ограничения»
			PGNotification[] notifications = pg.getNotifications((int) untilHeartbeat);
			if (notifications != null) {
				for (PGNotification notification : notifications) {
					this.broadcaster.broadcast(notification.getParameter());
				}
			}
		}
	}

	private void pause() {
		try {
			Thread.sleep(RECONNECT_DELAY);
		}
		catch (InterruptedException ex) {
			Thread.currentThread().interrupt();
		}
	}

}
