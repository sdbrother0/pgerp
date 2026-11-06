package com.erp.gateway.security;

import java.io.IOException;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.security.web.csrf.CsrfToken;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Выставляет cookie {@code XSRF-TOKEN} на каждом ответе.
 * <p>
 * Токен CSRF загружается лениво: без обращения к нему cookie не появится, а страницы — статические
 * и сами токен не запрашивают. Браузер читает cookie и отправляет значение в заголовке
 * {@code X-XSRF-TOKEN} с каждым POST.
 */
class CsrfCookieFilter extends OncePerRequestFilter {

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
			throws ServletException, IOException {
		if (request.getAttribute(CsrfToken.class.getName()) instanceof CsrfToken token) {
			token.getToken();
		}
		chain.doFilter(request, response);
	}

}
