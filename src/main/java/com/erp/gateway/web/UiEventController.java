package com.erp.gateway.web;

import java.security.Principal;
import java.util.Locale;

import com.erp.gateway.dispatcher.UiEventDispatcher;
import jakarta.validation.constraints.NotBlank;

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

	private final UiEventDispatcher dispatcher;

	public UiEventController(UiEventDispatcher dispatcher) {
		this.dispatcher = dispatcher;
	}

	@PostMapping(path = "/event", consumes = MediaType.APPLICATION_JSON_VALUE,
			produces = MediaType.APPLICATION_JSON_VALUE)
	public String handleUiEvent(@RequestParam("action") @NotBlank String action,
			@RequestBody(required = false) String payloadJson, Principal principal, Locale locale) {
		return this.dispatcher.dispatch(principal.getName(), action, (payloadJson != null) ? payloadJson : "{}",
				locale.getLanguage());
	}

}
