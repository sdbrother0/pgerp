package com.erp.gateway.dispatcher;

import java.util.List;

import org.springframework.dao.DataAccessException;

/**
 * Действие завершилось ошибкой, но до неё успело вывести сообщения через {@code ui_print}:
 * они показываются вместе с ошибкой.
 */
public class UiEventFailedException extends RuntimeException {

	private final List<UiMessage> messages;

	public UiEventFailedException(DataAccessException cause, List<UiMessage> messages) {
		super(cause.getMessage(), cause);
		this.messages = List.copyOf(messages);
	}

	@Override
	public synchronized DataAccessException getCause() {
		return (DataAccessException) super.getCause();
	}

	public List<UiMessage> getMessages() {
		return this.messages;
	}

}
