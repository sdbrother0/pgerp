package org.sdbrother.pgerp.security;

import java.io.Serializable;

/**
 * Подробности удачного входа.
 *
 * @param stamp отметка сессии, прочитанная до проверки пароля: если пароль сменили во время входа,
 *              сессия окажется недействительной, а не наоборот
 */
record LoginDetails(String stamp) implements Serializable {

}
