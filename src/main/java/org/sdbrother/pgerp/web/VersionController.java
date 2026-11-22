package org.sdbrother.pgerp.web;

import java.util.Map;

import org.springframework.beans.factory.ObjectProvider;
import org.springframework.boot.info.BuildProperties;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Версия приложения для шапки: {@code GET /api/version}, только после входа.
 * <p>
 * Версию из {@code pom.xml} записывает в сборку цель {@code build-info}. При запуске из IDE без Maven
 * её нет — версия пустая, и шапка её не показывает.
 */
@RestController
public class VersionController {

	private final String version;

	public VersionController(ObjectProvider<BuildProperties> build) {
		BuildProperties properties = build.getIfAvailable();
		String value = (properties != null) ? properties.getVersion() : null;
		this.version = (value != null) ? value : "";
	}

	@GetMapping(path = "/api/version", produces = MediaType.APPLICATION_JSON_VALUE)
	public Map<String, String> version() {
		return Map.of("version", this.version);
	}

}
