package com.erp.gateway.security;

import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.Map;

import com.erp.gateway.push.UiPushBroadcaster;
import jakarta.servlet.http.HttpServletResponse;
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
import org.springframework.security.web.csrf.CsrfFilter;
import org.springframework.security.web.savedrequest.HttpSessionRequestCache;
import org.springframework.security.web.savedrequest.RequestCache;
import org.springframework.security.web.savedrequest.SavedRequest;
import org.springframework.security.web.servlet.util.matcher.PathPatternRequestMatcher;

/**
 * Вход по логину и паролю из базы, сессия в cookie, защита от CSRF.
 * <ul>
 * <li>Все страницы и API — только после входа; без него страницы ведут на {@code /login.html},
 * а {@code /api/**} (включая WebSocket) отвечает 401.</li>
 * <li>{@code POST /api/auth/login} (username, password) и {@code POST /api/auth/logout} отвечают JSON.</li>
 * <li>Редактор форм и разработка решений ({@code /api/dev/**}) — только роль {@code admin}; права на формы
 * и действия проверяет база. MCP-сервер {@code /mcp} — своя цепочка с входом по токену ({@code McpSecurityConfig}).</li>
 * <li>CSRF: токен в cookie {@code XSRF-TOKEN}, браузер возвращает его в заголовке {@code X-XSRF-TOKEN}.</li>
 * </ul>
 */
@Configuration
@EnableWebSecurity
public class SecurityConfig {

	static final String LOGIN_PAGE = "/login.html";

	static final String LOGIN_URL = "/api/auth/login";

	static final String LOGOUT_URL = "/api/auth/logout";

	@Bean
	SecurityFilterChain securityFilterChain(HttpSecurity http, UiPushBroadcaster broadcaster, JsonMapper jsonMapper)
			throws Exception {
		RequestCache requestCache = new HttpSessionRequestCache();
		// Проверку пароля выполняет DatabaseAuthenticationProvider — бин глобального AuthenticationManager.
		// В HttpSecurity его не добавлять: при неверном пароле ProviderManager повторил бы вызов через
		// родителя, и база засчитала бы одну попытку дважды
		http.authorizeHttpRequests((requests) -> requests
				.requestMatchers(LOGIN_PAGE, "/css/**", "/js/i18n.js", "/js/theme.js", "/favicon.ico", "/error").permitAll()
				.requestMatchers("/editor.html", "/js/menu-editor.js", "/js/code-editor.js", "/js/report-editor.js",
						"/js/grid-columns-editor.js", "/js/solution-editor.js", "/js/schema-editor.js", "/js/sql-console.js",
						"/js/mcp-access.js", "/js/editor-kit.js", "/js/solution-packages.js", "/api/reports/preview", "/api/reports/save", "/api/dev/**")
				.hasRole("admin")
				.anyRequest().authenticated())
			.formLogin((form) -> form.loginPage(LOGIN_PAGE)
				.loginProcessingUrl(LOGIN_URL)
				.successHandler((request, response, authentication) -> {
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
			.addFilterAfter(new CsrfCookieFilter(), CsrfFilter.class);
		return http.build();
	}

	private static void writeJson(HttpServletResponse response, HttpStatus status, Map<String, String> body,
			JsonMapper jsonMapper) throws IOException {
		response.setStatus(status.value());
		response.setContentType(MediaType.APPLICATION_JSON_VALUE);
		response.setCharacterEncoding("UTF-8");
		response.getWriter().write(jsonMapper.writeValueAsString(body));
	}

}
