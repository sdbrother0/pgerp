package com.erp.gateway.dev;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import org.springframework.boot.ApplicationArguments;
import org.springframework.boot.ApplicationRunner;
import org.springframework.stereotype.Component;

/**
 * При запуске приложения (после миграций ядра) обновляет установленные решения до последнего выпуска их пакетов.
 * Ошибка не останавливает приложение: она пишется в журнал, решение остаётся на прежней версии.
 * Отключается {@code erp.dev.auto-update=false} ({@code ERP_SOLUTIONS_AUTO_UPDATE=false}).
 */
@Component
public class SolutionUpgradeRunner implements ApplicationRunner {

	private static final Logger logger = LoggerFactory.getLogger(SolutionUpgradeRunner.class);

	private final SolutionPackages packages;

	private final DevProperties properties;

	public SolutionUpgradeRunner(SolutionPackages packages, DevProperties properties) {
		this.packages = packages;
		this.properties = properties;
	}

	@Override
	public void run(ApplicationArguments args) {
		if (!this.properties.autoUpdate()) {
			return;
		}
		try {
			this.packages.upgradeInstalled();
		}
		catch (RuntimeException ex) {
			logger.error("Solution update at startup failed: {}", ex.getMessage(), ex);
		}
	}

}
