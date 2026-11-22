package org.sdbrother.pgerp.push;

import java.sql.Connection;
import java.sql.Statement;
import java.time.Duration;
import java.util.List;

import javax.sql.DataSource;

import org.junit.jupiter.api.Test;
import org.postgresql.PGConnection;
import org.postgresql.PGNotification;

import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.intThat;
import static org.mockito.BDDMockito.given;
import static org.mockito.Mockito.atLeast;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.timeout;
import static org.mockito.Mockito.verify;

class PgNotificationListenerTests {

	@Test
	void heartbeatIsSentWhileNotificationsKeepComing() throws Exception {
		PGConnection pg = mock();
		PGNotification notification = mock();
		given(notification.getParameter()).willReturn("{}");
		given(pg.getNotifications(anyInt())).willAnswer((invocation) -> {
			Thread.sleep(5);
			return new PGNotification[] { notification };
		});
		Statement statement = mock();
		Connection connection = mock();
		given(connection.createStatement()).willReturn(statement);
		given(connection.unwrap(PGConnection.class)).willReturn(pg);
		DataSource dataSource = mock();
		given(dataSource.getConnection()).willReturn(connection);
		UiPushBroadcaster broadcaster = mock();

		PgNotificationListener listener = new PgNotificationListener(dataSource, broadcaster,
				new UiPushProperties("erp_ui", List.of()), Duration.ofMillis(50));
		listener.start();
		try {
			verify(broadcaster, timeout(3000).atLeast(3)).heartbeat();
			verify(broadcaster, atLeast(3)).broadcast("{}");
			verify(pg, never()).getNotifications(intThat((millis) -> millis <= 0));
		}
		finally {
			listener.stop();
		}
	}

}
