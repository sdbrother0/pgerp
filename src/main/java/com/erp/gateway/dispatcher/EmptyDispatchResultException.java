package com.erp.gateway.dispatcher;

/**
 * Функция маршрутизатор вернула NULL — обработчик действия не сформировал ответ.
 */
public class EmptyDispatchResultException extends RuntimeException {

	public EmptyDispatchResultException(String action) {
		super("Router function returned no result for action '" + action + "'");
	}

}
