package org.sdbrother.pgerp.security;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.stream.Stream;

import jakarta.servlet.http.HttpServletResponse;
import org.sdbrother.pgerp.push.UiPushBroadcaster;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configuration.EnableWebSecurity;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.authentication.HttpStatusEntryPoint;
import org.springframework.security.web.authentication.logout.HttpStatusReturningLogoutSuccessHandler;
import org.springframework.security.web.access.intercept.AuthorizationFilter;
import org.springframework.security.web.csrf.CsrfFilter;
import org.springframework.security.web.savedrequest.HttpSessionRequestCache;
import org.springframework.security.web.savedrequest.RequestCache;
import org.springframework.security.web.savedrequest.SavedRequest;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;
import org.springframework.security.web.util.matcher.OrRequestMatcher;
import org.springframework.security.web.util.matcher.RequestMatcher;

/**
 * Вход по логину и паролю из базы, сессия в cookie, защита от CSRF.
 * <ul>
 * <li>Все страницы и API — только после входа; без него страницы ведут на {@code /login.html},
 * а {@code /api/**} (включая WebSocket) отвечает 401.</li>
 * <li>{@code POST /api/auth/login} (username, password) и {@code POST /api/auth/logout} отвечают JSON.</li>
 * <li>Редактор форм и разработка решений ({@code /api/dev/**}) — только роль {@code admin}; права на формы
 * и действия проверяет база. MCP-сервер {@code /mcp} — своя цепочка с входом по токену ({@code McpSecurityConfig}).</li>
 * <li>Сессию и роли на каждом запросе сверяет с базой {@code SessionCheckFilter}.</li>
 * <li>CSRF: токен в cookie {@code XSRF-TOKEN}, браузер возвращает его в заголовке {@code X-XSRF-TOKEN}.</li>
 * </ul>
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig {

	static final String LOGIN_PAGE = "/login.html";

	static final String LOGIN_URL = "/api/auth/login";

	static final String LOGOUT_URL = "/api/auth/logout";

	private static final String[] PUBLIC = { LOGIN_PAGE, "/css/**", "/js/i18n.js", "/js/theme.js", "/favicon.ico",
			"/error" };

	/** API администратора мимо маршрутизатора базы: до смены начального пароля закрыты. */
	private static final String[] ADMIN_API = { "/api/reports/preview", "/api/reports/save", "/api/dev/**" };

	@Bean
	SecurityFilterChain securityFilterChain(HttpSecurity http, UiPushBroadcaster broadcaster, JsonMapper jsonMapper,
			SessionGuard sessions)
			throws Exception {
		RequestCache requestCache = new HttpSessionRequestCache();
		// Проверку пароля выполняет DatabaseAuthenticationProvider — бин глобального AuthenticationManager.
		// В HttpSecurity его не добавлять: при неверном пароле ProviderManager повторил бы вызов через
		// родителя, и база засчитала бы одну попытку дважды
		http.authorizeHttpRequests((requests) -> requests
				.requestMatchers(PUBLIC).permitAll()
				.requestMatchers("/editor.html", "/js/menu-editor.js", "/js/code-editor.js", "/js/report-editor.js",
						"/js/grid-columns-editor.js", "/js/solution-editor.js", "/js/schema-editor.js", "/js/sql-console.js",
						"/js/mcp-access.js", "/js/editor-kit.js", "/js/solution-packages.js")
				.hasRole("admin")
				.requestMatchers(ADMIN_API).hasRole("admin")
				.anyRequest().authenticated())
			.formLogin((form) -> form.loginPage(LOGIN_PAGE)
				.loginProcessingUrl(LOGIN_URL)
				.authenticationDetailsSource(LoginRequest::of)
				.successHandler((request, response, authentication) -> {
					sessions.started(request, response, authentication);
					// После входа — на страницу, с которой отправили на вход
					SavedRequest saved = requestCache.getRequest(request, response);
					Map<String, String> body = new LinkedHashMap<>();
					body.put("status", "success");
					if (saved != null) {
						body.put("redirect", saved.getRedirectUrl());
					}
					writeJson(response, HttpStatus.OK, body, jsonMapper);
				})
				.failureHandler((request, response, exception) -> writeJson(response, HttpStatus.UNAUTHORIZED,
						Map.of("status", "error", "message", exception.getMessage()), jsonMapper))
				.permitAll())
			.logout((logout) -> logout.logoutUrl(LOGOUT_URL)
				// Вкладки этой сессии перестают получать команды из базы
				.addLogoutHandler((request, response, authentication) -> broadcaster
					.closeHttpSession(request.getRequestedSessionId()))
				.logoutSuccessHandler(new HttpStatusReturningLogoutSuccessHandler(HttpStatus.OK)))
			.exceptionHandling((exceptions) -> exceptions.defaultAuthenticationEntryPointFor(
					new HttpStatusEntryPoint(HttpStatus.UNAUTHORIZED),
					PathPatternRequestMatcher.withDefaults().matcher("/api/**")))
			.csrf((csrf) -> csrf.spa())
			.addFilterBefore(new SessionCheckFilter(sessions, anyOf(PUBLIC), anyOf(ADMIN_API)), AuthorizationFilter.class)
			.addFilterAfter(new CsrfCookieFilter(), CsrfFilter.class);
		return http.build();
	}

	/** Те же правила сравнения путей, что у authorizeHttpRequests: сравнение строк обходилось бы через %-кодирование. */
	private static RequestMatcher anyOf(String... patterns) {
		return new OrRequestMatcher(Stream.of(patterns)
			.<RequestMatcher>map((pattern) -> PathPatternRequestMatcher.withDefaults().matcher(pattern))
			.toList());
	}

	private static void writeJson(HttpServletResponse response, HttpStatus status, Map<String, String> body,
			JsonMapper jsonMapper) throws IOException {
		response.setStatus(status.value());
		response.setContentType(MediaType.APPLICATION_JSON_VALUE);
		response.setCharacterEncoding("UTF-8");
		response.getWriter().write(jsonMapper.writeValueAsString(body));
	}

}
