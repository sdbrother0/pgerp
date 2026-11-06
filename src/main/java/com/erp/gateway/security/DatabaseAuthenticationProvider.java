package com.erp.gateway.security;

import java.sql.Array;
import java.sql.SQLException;
import java.util.List;
import java.util.stream.Stream;

import org.springframework.context.i18n.LocaleContextHolder;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.security.authentication.AuthenticationProvider;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.stereotype.Component;

/**
 * Проверка логина и пароля в базе: {@code pgerp.auth_login(login, password)}.
 * <p>
 * Пароли, хеши (bcrypt, pgcrypto), блокировка после неудачных попыток и тексты ошибок — в базе;
 * ошибки — на языке пользователя или браузера (Accept-Language: локаль запроса выставляет
 * RequestContextFilter, он стоит раньше фильтров Spring Security).
 * Java только переносит результат в сессию: логин и роли ({@code ROLE_<роль>}).
 * Права на формы и действия проверяет маршрутизатор при каждом вызове, поэтому роли здесь нужны
 * только для доступа к страницам (редактор форм — роль {@code admin}).
 */
@Component
public class DatabaseAuthenticationProvider implements AuthenticationProvider {

	private static final String SQL = "SELECT user_login, user_roles, error_message FROM pgerp.auth_login(?, ?, ?)";

	private final JdbcClient jdbcClient;

	public DatabaseAuthenticationProvider(JdbcClient jdbcClient) {
		this.jdbcClient = jdbcClient;
	}

	@Override
	public Authentication authenticate(Authentication authentication) {
		String login = authentication.getName();
		Object credentials = authentication.getCredentials();
		LoginResult result = this.jdbcClient.sql(SQL)
			.param(login)
			.param((credentials != null) ? credentials.toString() : "")
			.param(LocaleContextHolder.getLocale().getLanguage())
			.query((rs, rowNum) -> new LoginResult(rs.getString(1), roles(rs.getArray(2)), rs.getString(3)))
			.single();
		if (result.error() != null || result.login() == null) {
			// Текст ошибки задаёт база и показывает страница входа
			throw new BadCredentialsException((result.error() != null) ? result.error() : "Invalid login or password");
		}
		List<GrantedAuthority> authorities = result.roles()
			.stream()
			.<GrantedAuthority>map((role) -> new SimpleGrantedAuthority("ROLE_" + role))
			.toList();
		return UsernamePasswordAuthenticationToken.authenticated(result.login(), null, authorities);
	}

	@Override
	public boolean supports(Class<?> authentication) {
		return UsernamePasswordAuthenticationToken.class.isAssignableFrom(authentication);
	}

	private static List<String> roles(Array array) throws SQLException {
		if (array == null) {
			return List.of();
		}
		return Stream.of((Object[]) array.getArray()).map(String::valueOf).toList();
	}

	private record LoginResult(String login, List<String> roles, String error) {
	}

}
