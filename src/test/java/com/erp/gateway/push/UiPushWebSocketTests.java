package com.erp.gateway.push;

import java.net.CookieManager;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;

import com.erp.gateway.security.DatabaseAuthenticationProvider;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.web.socket.TextMessage;
import org.springframework.web.socket.WebSocketHttpHeaders;
import org.springframework.web.socket.WebSocketSession;
import org.springframework.web.socket.client.standard.StandardWebSocketClient;
import org.springframework.web.socket.handler.TextWebSocketHandler;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatExceptionOfType;
import static org.awaitility.Awaitility.await;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
		properties = { "spring.flyway.enabled=false", "erp.dev.auto-update=false" })
class UiPushWebSocketTests {

	@LocalServerPort
	private int port;

	@Autowired
	private UiPushBroadcaster broadcaster;

	@MockitoBean
	private DatabaseAuthenticationProvider authenticationProvider;

	@BeforeEach
	void acceptAnyPassword() {
		given(this.authenticationProvider.supports(any())).willReturn(true);
		given(this.authenticationProvider.authenticate(any())).willAnswer((invocation) -> {
			Authentication request = invocation.getArgument(0);
			return UsernamePasswordAuthenticationToken.authenticated(request.getName(), null, List.of());
		});
	}

	@Test
	void databaseMessageReachesBrowserUnchanged() throws Exception {
		BlockingQueue<String> received = new LinkedBlockingQueue<>();
		WebSocketSession session = connect(login("anna"), received);

		String message = "{\"form\": null, \"ui_instructions\": [{\"command\": \"show_message\", \"text\": \"Привет\"}]}";
		// Сессия регистрируется на сервере сразу после рукопожатия — повторяем, пока сообщение не придёт
		await().atMost(5, TimeUnit.SECONDS).untilAsserted(() -> {
			this.broadcaster.broadcast(message);
			assertThat(received.poll(200, TimeUnit.MILLISECONDS)).isEqualTo(message);
		});
		session.close();
	}

	@Test
	void addressedMessageReachesOnlyItsUsers() throws Exception {
		BlockingQueue<String> anna = new LinkedBlockingQueue<>();
		BlockingQueue<String> bob = new LinkedBlockingQueue<>();
		WebSocketSession annaSession = connect(login("anna"), anna);
		WebSocketSession bobSession = connect(login("bob"), bob);

		String forAnna = "{\"form\": null, \"users\": [\"anna\"], \"ui_instructions\": []}";
		await().atMost(5, TimeUnit.SECONDS).untilAsserted(() -> {
			this.broadcaster.broadcast(forAnna);
			assertThat(anna.poll(200, TimeUnit.MILLISECONDS)).isEqualTo(forAnna);
		});
		assertThat(bob).isEmpty();
		annaSession.close();
		bobSession.close();
	}

	@Test
	void subscriptionFromForeignSiteIsRejected() throws Exception {
		WebSocketHttpHeaders headers = login("anna");
		headers.setOrigin("https://evil.example");
		assertThatExceptionOfType(ExecutionException.class)
			.isThrownBy(() -> connect(headers, new LinkedBlockingQueue<>()));
	}

	@Test
	void subscriptionRequiresLogin() {
		assertThatExceptionOfType(ExecutionException.class)
			.isThrownBy(() -> connect(new WebSocketHttpHeaders(), new LinkedBlockingQueue<>()));
	}

	/** Вход через страницу входа: cookie сессии и токен CSRF, как в браузере. */
	private WebSocketHttpHeaders login(String user) throws Exception {
		CookieManager cookies = new CookieManager();
		HttpClient http = HttpClient.newBuilder().cookieHandler(cookies).build();
		String base = "http://localhost:" + this.port;
		http.send(HttpRequest.newBuilder(URI.create(base + "/login.html")).build(), HttpResponse.BodyHandlers.discarding());
		String csrf = cookies.getCookieStore()
			.getCookies()
			.stream()
			.filter((c) -> c.getName().equals("XSRF-TOKEN"))
			.findFirst()
			.orElseThrow()
			.getValue();
		HttpResponse<String> response = http.send(HttpRequest.newBuilder(URI.create(base + "/api/auth/login"))
			.header("Content-Type", "application/x-www-form-urlencoded")
			.header("X-XSRF-TOKEN", csrf)
			.POST(HttpRequest.BodyPublishers.ofString("username=" + user + "&password=secret"))
			.build(), HttpResponse.BodyHandlers.ofString());
		assertThat(response.statusCode()).isEqualTo(200);

		WebSocketHttpHeaders headers = new WebSocketHttpHeaders();
		headers.add("Cookie", cookies.getCookieStore()
			.getCookies()
			.stream()
			.map((c) -> c.getName() + "=" + c.getValue())
			.collect(Collectors.joining("; ")));
		return headers;
	}

	private WebSocketSession connect(WebSocketHttpHeaders headers, BlockingQueue<String> received) throws Exception {
		return new StandardWebSocketClient()
			.execute(new TextWebSocketHandler() {
				@Override
				protected void handleTextMessage(WebSocketSession session, TextMessage message) {
					received.add(message.getPayload());
				}
			}, headers, URI.create("ws://localhost:" + this.port + "/api/ui/ws"))
			.get(5, TimeUnit.SECONDS);
	}

}
