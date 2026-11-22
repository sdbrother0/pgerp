package org.sdbrother.pgerp.security;

import java.security.SecureRandom;
import java.time.Duration;
import java.util.HexFormat;
import java.util.List;
import java.util.Optional;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import org.springframework.http.HttpHeaders;
import org.springframework.http.ResponseCookie;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.core.Authentication;
import org.springframework.stereotype.Component;

/**
 * Действительна ли сессия: отметка, запомненная при входе, сверяется с базой ({@code pgerp.auth_session})
 * на каждом запросе. Смена или сброс пароля, отключение и удаление пользователя закрывают его сессии.
 */
@Component
public class SessionGuard {

	static final String STAMP = SessionGuard.class.getName() + ".STAMP";

	private static final String SQL = "SELECT stamp, user_roles, must_change FROM pgerp.auth_session(?)";

	private static final Duration DEVICE_LIFETIME = Duration.ofDays(180);

	private final JdbcClient jdbcClient;

	private final SecureRandom random = new SecureRandom();

	public SessionGuard(JdbcClient jdbcClient) {
		this.jdbcClient = jdbcClient;
	}

	/**
	 * Состояние пользователя в базе.
	 *
	 * @param stamp      отметка сессии
	 * @param roles      роли сейчас
	 * @param mustChange пароль нужно сменить
	 */
	public record State(String stamp, List<String> roles, boolean mustChange) {
	}

	Optional<State> state(String login) {
		return this.jdbcClient.sql(SQL)
			.param(login)
			.query((rs, rowNum) -> new State(rs.getString(1), DatabaseAuthenticationProvider.roles(rs.getArray(2)),
					rs.getBoolean(3)))
			.optional();
	}

	/** Состояние, если сессия запроса действительна; пусто — нужен новый вход. */
	public Optional<State> check(HttpServletRequest request, Authentication authentication) {
		HttpSession session = request.getSession(false);
		Object stamp = (session != null) ? session.getAttribute(STAMP) : null;
		if (stamp == null) {
			return Optional.empty();
		}
		return state(authentication.getName()).filter((state) -> state.stamp().equals(stamp));
	}

	/** После входа: отметка — в сессию, браузер запоминается как известный. */
	public void started(HttpServletRequest request, HttpServletResponse response, Authentication authentication) {
		if (authentication.getDetails() instanceof LoginDetails details) {
			request.getSession().setAttribute(STAMP, details.stamp());
			byte[] bytes = new byte[32];
			this.random.nextBytes(bytes);
			String token = HexFormat.of().formatHex(bytes);
			// Функция возвращает void: строку результата читаем и не используем
			this.jdbcClient.sql("SELECT pgerp.auth_device_remember(?, ?, ?)::text")
				.param(authentication.getName())
				.param(token)
				.param(LoginRequest.of(request).device())
				.query((rs, rowNum) -> true)
				.list();
			response.addHeader(HttpHeaders.SET_COOKIE, ResponseCookie.from(LoginRequest.DEVICE_COOKIE, token)
				.path(request.getContextPath() + SecurityConfig.LOGIN_URL)
				.maxAge(DEVICE_LIFETIME)
				.httpOnly(true)
				.secure(request.isSecure())
				.sameSite("Strict")
				.build()
				.toString());
		}
	}

	/** После смены своего пароля сессия, где его сменили, остаётся; остальные сессии пользователя закрываются. */
	public void passwordChanged(HttpServletRequest request, String login) {
		HttpSession session = request.getSession(false);
		if (session != null) {
			state(login).ifPresent((state) -> session.setAttribute(STAMP, state.stamp()));
		}
	}

}
