package com.erp.gateway.mcp;

import java.io.IOException;
import java.util.List;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.http.HttpHeaders;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Вход в MCP по токену: {@code Authorization: Bearer <токен>}. Токен проверяет база
 * ({@code pgerp.mcp_token_login}); принятый — запрос выполняется от имени владельца токена.
 * Не бин: работает только в цепочке безопасности {@code /mcp}.
 */
class McpTokenFilter extends OncePerRequestFilter {

	private static final String BEARER = "Bearer ";

	private final McpGateway gateway;

	McpTokenFilter(McpGateway gateway) {
		this.gateway = gateway;
	}

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
			throws ServletException, IOException {
		String header = request.getHeader(HttpHeaders.AUTHORIZATION);
		if (header != null && header.regionMatches(true, 0, BEARER, 0, BEARER.length())) {
			String login = this.gateway.login(header.substring(BEARER.length()).trim());
			if (login != null) {
				SecurityContext context = SecurityContextHolder.createEmptyContext();
				context.setAuthentication(UsernamePasswordAuthenticationToken.authenticated(login, null,
						List.of(new SimpleGrantedAuthority("ROLE_mcp"))));
				SecurityContextHolder.setContext(context);
			}
		}
		chain.doFilter(request, response);
	}

}
