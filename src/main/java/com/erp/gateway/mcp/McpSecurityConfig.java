package com.erp.gateway.mcp;

import java.nio.charset.StandardCharsets;

import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.core.annotation.Order;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.config.annotation.web.builders.HttpSecurity;
import org.springframework.security.config.annotation.web.configurers.AbstractHttpConfigurer;
import org.springframework.security.config.http.SessionCreationPolicy;
import org.springframework.security.web.SecurityFilterChain;
import org.springframework.security.web.access.intercept.AuthorizationFilter;

/**
 * Цепочка безопасности MCP-сервера: только {@code /mcp}, вход по токену, без сессии и CSRF
 * (токен — не cookie, браузер его сам не отправит). Стоит раньше основной цепочки приложения.
 */
@Configuration
public class McpSecurityConfig {

	static final String MCP_PATH = "/mcp";

	@Bean
	@Order(1)
	SecurityFilterChain mcpSecurityFilterChain(HttpSecurity http, McpGateway gateway) throws Exception {
		http.securityMatcher(MCP_PATH, MCP_PATH + "/**")
			.authorizeHttpRequests((requests) -> requests.anyRequest().authenticated())
			.csrf(AbstractHttpConfigurer::disable)
			.formLogin(AbstractHttpConfigurer::disable)
			.httpBasic(AbstractHttpConfigurer::disable)
			.logout(AbstractHttpConfigurer::disable)
			.requestCache(AbstractHttpConfigurer::disable)
			.sessionManagement((session) -> session.sessionCreationPolicy(SessionCreationPolicy.STATELESS))
			.exceptionHandling((exceptions) -> exceptions.authenticationEntryPoint((request, response, exception) -> {
				response.setStatus(HttpStatus.UNAUTHORIZED.value());
				response.setHeader(HttpHeaders.WWW_AUTHENTICATE, "Bearer realm=\"pgerp\"");
				response.setContentType(MediaType.APPLICATION_JSON_VALUE);
				response.setCharacterEncoding(StandardCharsets.UTF_8.name());
				response.getWriter()
					.write("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32001,"
							+ "\"message\":\"An MCP token is required: header Authorization: Bearer <token>\"}}");
			}))
			.addFilterBefore(new McpTokenFilter(gateway), AuthorizationFilter.class);
		return http.build();
	}

}
