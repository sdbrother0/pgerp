package com.erp.gateway.dispatcher;

/**
 * Сообщение для панели сообщений: выводится функцией {@code pgerp.ui_print}.
 *
 * @param text текст, уже переведённый базой
 * @param kind вид: {@code info}, {@code warning} или {@code error}
 */
public record UiMessage(String text, String kind) {

}
