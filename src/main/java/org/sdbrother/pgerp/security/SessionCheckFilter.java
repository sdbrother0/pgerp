package org.sdbrother.pgerp.security;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Optional;

import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import jakarta.servlet.http.HttpSession;

import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.security.authentication.AnonymousAuthenticationToken;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;
import org.springframework.security.core.authority.SimpleGrantedAuthority;
import org.springframework.security.core.context.SecurityContext;
import org.springframework.security.core.context.SecurityContextHolder;
import org.springframework.security.web.util.matcher.RequestMatcher;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * Перед проверкой прав: недействительная сессия становится анонимной (API ответит 401, страница уведёт на вход),
 * у действительной роли берутся из базы. Пока пароль не сменён, API администратора закрыты.
 * Не бин: работает только в основной цепочке безопасности.
 */
class SessionCheckFilter extends OncePerRequestFilter {

	private final SessionGuard guard;

	private final RequestMatcher publicPaths;

	private final RequestMatcher adminApi;

	SessionCheckFilter(SessionGuard guard, RequestMatcher publicPaths, RequestMatcher adminApi) {
		this.guard = guard;
		this.publicPaths = publicPaths;
		this.adminApi = adminApi;
	}

	@Override
	protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
			throws ServletException, IOException {
		Authentication current = SecurityContextHolder.getContext().getAuthentication();
		// Публичные пути базу не спрашивают: страница входа открывается и при недоступной базе
		if (current == null || current instanceof AnonymousAuthenticationToken || !current.isAuthenticated()
				|| this.publicPaths.matches(request)) {
			chain.doFilter(request, response);
			return;
		}
		Optional<SessionGuard.State> state = this.guard.check(request, current);
		SecurityContext context = SecurityContextHolder.createEmptyContext();
		if (state.isEmpty()) {
			HttpSession session = request.getSession(false);
			if (session != null) {
				session.invalidate();
			}
		}
		else {
			if (state.get().mustChange() && this.adminApi.matches(request)) {
				response.setStatus(HttpStatus.FORBIDDEN.value());
				response.setContentType(MediaType.APPLICATION_JSON_VALUE);
				response.setCharacterEncoding(StandardCharsets.UTF_8.name());
				response.getWriter().write("{\"status\":\"error\",\"message\":\"Change your password to continue\"}");
				return;
			}
			List<GrantedAuthority> authorities = state.get()
				.roles()
				.stream()
				.<GrantedAuthority>map((role) -> new SimpleGrantedAuthority("ROLE_" + role))
				.toList();
			UsernamePasswordAuthenticationToken actual = UsernamePasswordAuthenticationToken
				.authenticated(current.getName(), null, authorities);
			actual.setDetails(current.getDetails());
			context.setAuthentication(actual);
		}
		SecurityContextHolder.setContext(context);
		chain.doFilter(request, response);
	}

}
