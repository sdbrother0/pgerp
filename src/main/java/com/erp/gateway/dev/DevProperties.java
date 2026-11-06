package com.erp.gateway.dev;

import org.springframework.boot.context.properties.ConfigurationProperties;

/**
 * Настройки пакетов и разработки прикладных решений.
 *
 * @param solutionsDir папка пакетов решений в исходниках проекта, например
 *                     {@code /home/dev/erp-gateway/src/main/resources/db/solutions}: выпуск решения (редактор или
 *                     MCP) сохраняет туда файл {@code <папка пакета>/V<n>__….sql}, а установка берёт пакеты из неё
 *                     раньше, чем из приложения. Пусто — файл выпуска скачивают из редактора или берут из ответа MCP.
 * @param autoUpdate   при запуске приложения обновлять установленные решения до последней версии их пакетов
 */
@ConfigurationProperties("erp.dev")
public record DevProperties(String solutionsDir, Boolean autoUpdate) {

	public DevProperties {
		if (solutionsDir != null && solutionsDir.isBlank()) {
			solutionsDir = null;
		}
		if (autoUpdate == null) {
			autoUpdate = Boolean.TRUE;
		}
	}

}
