package org.sdbrother.pgerp.security;

import java.io.Serializable;

import jakarta.servlet.http.Cookie;
import jakarta.servlet.http.HttpServletRequest;

/**
 * Откуда входят: адрес и cookie известного браузера. По ним база считает неудачные попытки.
 *
 * @param address адрес клиента (за прокси — из {@code X-Forwarded-For})
 * @param device  токен известного браузера или пустая строка
 */
record LoginRequest(String address, String device) implements Serializable {

	static final String DEVICE_COOKIE = "PGERP-DEVICE";

	private static final int DEVICE_MAX_LENGTH = 100;

	static LoginRequest of(HttpServletRequest request) {
		String device = "";
		if (request.getCookies() != null) {
			for (Cookie cookie : request.getCookies()) {
				if (DEVICE_COOKIE.equals(cookie.getName()) && cookie.getValue().length() <= DEVICE_MAX_LENGTH) {
					device = cookie.getValue();
				}
			}
		}
		return new LoginRequest(request.getRemoteAddr(), device);
	}

}
