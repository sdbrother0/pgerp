package org.sdbrother.pgerp.push;

import java.io.IOException;
import java.security.Principal;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.stream.IntStream;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.web.socket.CloseStatus;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.server.support.HttpSessionHandshakeInterceptor;

import static org.assertj.core.api.Assertions.assertThat;
import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;
import static org.mockito.BDDMockito.willAnswer;
import static org.mockito.Mockito.mock;

/** Вкладка, которая перестала читать сокет, не задерживает рассылку, выход и отзыв сессий. */
class UiPushSlowClientTests {

	private final UiPushBroadcaster broadcaster = new UiPushBroadcaster(JsonMapper.builder().build());

	private final CountDownLatch release = new CountDownLatch(1);

	@AfterEach
	void releaseStuckClients() {
		this.release.countDown();
	}

	@Test
	void stuckClientDoesNotDelayOthers() throws Exception {
		Tab stuck = stuckTab("anna");
		Tab bob = tab("bob");
		List<String> messages = messages(200, 10);
		promptly(() -> messages.forEach(this.broadcaster::broadcast));
		await().atMost(5, TimeUnit.SECONDS).until(() -> bob.received.equals(messages));
		assertThat(stuck.closed).isEmpty();
	}

	@Test
	void burstReachesClientCompletelyAndInOrder() throws Exception {
		Tab bob = tab("bob");
		// Одна транзакция может прислать мегабайты сразу: исправную вкладку это не отключает
		List<String> messages = messages(500, 7000);
		promptly(() -> messages.forEach(this.broadcaster::broadcast));
		await().atMost(5, TimeUnit.SECONDS).until(() -> bob.received.equals(messages));
		assertThat(bob.closed).isEmpty();
	}

	@Test
	void clientWithTooLongBacklogIsDisconnected() throws Exception {
		Tab stuck = stuckTab("anna");
		List<String> messages = messages(1500, 7000);
		promptly(() -> messages.forEach(this.broadcaster::broadcast));
		await().atMost(5, TimeUnit.SECONDS).until(() -> !stuck.closed.isEmpty());
		assertThat(stuck.closed.getFirst()).isEqualTo(CloseStatus.SESSION_NOT_RELIABLE);
		this.release.countDown();
		await().during(300, TimeUnit.MILLISECONDS).atMost(2, TimeUnit.SECONDS).until(() -> stuck.received.size() <= 1);
	}

	@Test
	void revocationKeepsEarlierMessagesAndDropsLater() throws Exception {
		Tab anna = tab("anna");
		promptly(() -> {
			this.broadcaster.broadcast("{\"n\": 1}");
			this.broadcaster.broadcast("{\"revoked_users\": [\"anna\"]}");
			this.broadcaster.broadcast("{\"n\": 2}");
		});
		await().atMost(5, TimeUnit.SECONDS).until(() -> !anna.closed.isEmpty());
		assertThat(anna.received).containsExactly("{\"n\": 1}");
	}

	@Test
	void revokedStuckClientIsDisconnected() throws Exception {
		Tab stuck = stuckTab("anna");
		promptly(() -> {
			this.broadcaster.broadcast("{\"n\": 1}");
			this.broadcaster.broadcast("{\"revoked_users\": [\"anna\"]}");
		});
		await().atMost(13, TimeUnit.SECONDS).until(() -> stuck.closed.contains(CloseStatus.SESSION_NOT_RELIABLE));
	}

	@Test
	void logoutAndShutdownDoNotWaitForClose() throws Exception {
		Tab first = slowClosingTab("anna");
		slowClosingTab("bob");
		promptly(() -> {
			this.broadcaster.closeHttpSession("http-anna");
			this.broadcaster.closeAll();
		});
		await().atMost(5, TimeUnit.SECONDS).until(() -> !first.closed.isEmpty());
	}

	@Test
	void failedSendDisconnectsClient() throws Exception {
		Tab broken = tab("anna", () -> {
			throw new IOException("reset");
		}, () -> { });
		promptly(this.broadcaster::heartbeat);
		await().atMost(5, TimeUnit.SECONDS).until(() -> broken.closed.contains(CloseStatus.SESSION_NOT_RELIABLE));
	}

	@Test
	void unclearRecipientsReceiveNothing() throws Exception {
		Tab anna = tab("anna");
		promptly(() -> {
			List.of("", "x", "null", "[]", "{\"users\": \"bob\"}", "{\"users\": null}",
					"{\"users\": [{\"login\": \"bob\"}]}", "{\"users\": [null]}", "{\"revoked_users\": \"anna\"}")
				.forEach(this.broadcaster::broadcast);
			this.broadcaster.broadcast("{\"users\": [\"anna\"]}");
		});
		await().atMost(5, TimeUnit.SECONDS).until(() -> !anna.received.isEmpty());
		assertThat(anna.received).containsExactly("{\"users\": [\"anna\"]}");
		assertThat(anna.closed).isEmpty();
	}

	private void promptly(Runnable action) throws Exception {
		var executor = Executors.newVirtualThreadPerTaskExecutor();
		CompletableFuture.runAsync(action, executor).get(2, TimeUnit.SECONDS);
		executor.shutdown();
	}

	private static List<String> messages(int count, int size) {
		String padding = "x".repeat(size);
		return IntStream.range(0, count).mapToObj((i) -> "{\"n\": " + i + ", \"p\": \"" + padding + "\"}").toList();
	}

	private Tab tab(String user) throws IOException {
		return tab(user, () -> { }, () -> { });
	}

	private Tab stuckTab(String user) throws IOException {
		return tab(user, this::stall, () -> { });
	}

	private Tab slowClosingTab(String user) throws IOException {
		return tab(user, () -> { }, this::stall);
	}

	private void stall() throws IOException {
		try {
			this.release.await();
		}
		catch (InterruptedException ex) {
			throw new IOException(ex);
		}
	}

	private Tab tab(String user, Step onSend, Step onClose) throws IOException {
		Tab tab = new Tab(new CopyOnWriteArrayList<>(), new CopyOnWriteArrayList<>());
		WebSocketSession session = mock();
		Principal principal = () -> user;
		given(session.getId()).willReturn("ws-" + user);
		given(session.isOpen()).willReturn(true);
		given(session.getPrincipal()).willReturn(principal);
		given(session.getAttributes())
			.willReturn(Map.of(HttpSessionHandshakeInterceptor.HTTP_SESSION_ID_ATTR_NAME, "http-" + user));
		willAnswer((invocation) -> {
			onSend.run();
			if (invocation.getArgument(0) instanceof TextMessage text) {
				tab.received().add(text.getPayload());
			}
			return null;
		}).given(session).sendMessage(any());
		willAnswer((invocation) -> {
			tab.closed().add(invocation.getArgument(0));
			onClose.run();
			return null;
		}).given(session).close(any());
		this.broadcaster.afterConnectionEstablished(session);
		return tab;
	}

	private record Tab(List<String> received, List<CloseStatus> closed) {
	}

	private interface Step {

		void run() throws IOException;

	}

}
