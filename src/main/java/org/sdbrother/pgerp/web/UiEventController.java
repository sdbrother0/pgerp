package org.sdbrother.pgerp.web;

import java.security.Principal;
import java.util.Locale;

import jakarta.servlet.http.HttpServletRequest;
import jakarta.validation.constraints.NotBlank;
import org.sdbrother.pgerp.dispatcher.UiEventDispatcher;
import org.sdbrother.pgerp.security.SessionGuard;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

/**
 * Универсальная точка входа для всех событий UI ERP-системы.
 * Вызывается только после входа: имя пользователя и язык браузера (Accept-Language) уходят в базу
 * вместе с действием; права и язык ответа определяет маршрутизатор.
 */
@RestController
@RequestMapping("/api/ui")
public class UiEventController {

	/** Смена своего пароля: после неё эта сессия остаётся действительной. */
	private static final String PASSWORD_CHANGE = "password_change";

	private final UiEventDispatcher dispatcher;

	private final SessionGuard sessions;

	public UiEventController(UiEventDispatcher dispatcher, SessionGuard sessions) {
		this.dispatcher = dispatcher;
		this.sessions = sessions;
	}

	@PostMapping(path = "/event", consumes = MediaType.APPLICATION_JSON_VALUE,
			produces = MediaType.APPLICATION_JSON_VALUE)
	public String handleUiEvent(@RequestParam("action") @NotBlank String action,
			@RequestBody(required = false) String payloadJson, Principal principal, Locale locale,
			HttpServletRequest request) {
		String response = this.dispatcher.dispatch(principal.getName(), action, (payloadJson != null) ? payloadJson : "{}",
				locale.getLanguage());
		// Неверный старый пароль — исключение, сюда не доходит. Ответ ещё не отправлен: следующий запрос увидит новую отметку
		if (PASSWORD_CHANGE.equals(action)) {
			this.sessions.passwordChanged(request, principal.getName());
		}
		return response;
	}

}
