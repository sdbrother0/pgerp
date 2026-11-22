package org.sdbrother.pgerp.security;

import java.util.Optional;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;

import org.springframework.boot.test.context.TestConfiguration;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Primary;
import org.springframework.security.core.Authentication;
import org.springframework.security.core.GrantedAuthority;

/**
 * Для тестов без базы: сессия действительна, роли — из неё. Саму проверку сессии проверяет
 * {@code SessionCheckTests}, базу — {@code .github/scripts/db_smoke.py}.
 */
@TestConfiguration
public class TrustedSessions {

	@Bean
	@Primary
	SessionGuard trustedSessionGuard() {
		return new SessionGuard(null) {
			@Override
			public Optional<State> check(HttpServletRequest request, Authentication authentication) {
				return Optional.of(new State("test", authentication.getAuthorities()
					.stream()
					.map(GrantedAuthority::getAuthority)
					.filter((authority) -> authority.startsWith("ROLE_"))
					.map((authority) -> authority.substring("ROLE_".length()))
					.toList(), false));
			}

			@Override
			public void started(HttpServletRequest request, HttpServletResponse response, Authentication authentication) {
			}

			@Override
			public void passwordChanged(HttpServletRequest request, String login) {
			}
		};
	}

}
