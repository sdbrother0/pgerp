package com.erp.gateway.dev;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import tools.jackson.databind.JsonNode;
import tools.jackson.databind.json.JsonMapper;
import tools.jackson.databind.node.ArrayNode;
import tools.jackson.databind.node.ObjectNode;

import org.springframework.aot.hint.RuntimeHints;
import org.springframework.aot.hint.RuntimeHintsRegistrar;
import org.springframework.context.annotation.ImportRuntimeHints;
import org.springframework.core.io.Resource;
import org.springframework.core.io.support.PathMatchingResourcePatternResolver;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.StatementCallback;
import org.springframework.stereotype.Service;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Пакеты прикладных решений: {@code db/solutions/<папка>/solution.json} и файлы выпусков
 * {@code V<n>__….sql} (каждый — {@code SELECT pgerp.solution_release_apply(...)}).
 * <p>
 * Пакеты лежат в приложении ({@code classpath:db/solutions}) и, при разработке, в папке
 * {@code erp.dev.solutions-dir}: пакет из папки важнее пакета с тем же именем папки в приложении.
 * Ядро ставит Flyway, решения — администратор (окно первого входа, редактор, MCP); установленные решения
 * обновляются до последнего выпуска пакета при запуске приложения.
 * <p>
 * Установка — одна транзакция: {@code pgerp.solution_install_begin} (права, схема нового решения, установленная
 * версия) → файлы с версиями больше установленной по порядку → {@code pgerp.solution_install_end}.
 */
@Service
@ImportRuntimeHints(SolutionPackages.PackageResources.class)
public class SolutionPackages {

	public static final String MANIFEST = "solution.json";

	private static final Logger logger = LoggerFactory.getLogger(SolutionPackages.class);

	private static final Pattern RELEASE = Pattern.compile("V(\\d{1,9})__[^/]*\\.sql");

	private static final Pattern FOLDER = Pattern.compile("[a-z][a-z0-9_]{0,99}");

	private final JdbcTemplate jdbcTemplate;

	private final TransactionTemplate transaction;

	private final JsonMapper jsonMapper;

	private final DevProperties properties;

	private final PathMatchingResourcePatternResolver resolver = new PathMatchingResourcePatternResolver();

	public SolutionPackages(JdbcTemplate jdbcTemplate, PlatformTransactionManager transactionManager, JsonMapper jsonMapper,
			DevProperties properties) {
		this.jdbcTemplate = jdbcTemplate;
		this.transaction = new TransactionTemplate(transactionManager);
		this.jsonMapper = jsonMapper;
		this.properties = properties;
	}

	/** Пакет решения: описание и выпуски по версиям. */
	public record SolutionPackage(String folder, String name, JsonNode title, JsonNode description, String schema,
			TreeMap<Integer, Resource> releases, String source) {

		public int latestVersion() {
			return this.releases.isEmpty() ? 0 : this.releases.lastKey();
		}

	}

	/** Пакеты по имени решения: из приложения, затем из папки разработки (она важнее). */
	public Map<String, SolutionPackage> packages() {
		Map<String, SolutionPackage> byFolder = new TreeMap<>();
		scan("classpath*:db/solutions/", "classpath", byFolder);
		if (this.properties.solutionsDir() != null) {
			scan(Path.of(this.properties.solutionsDir()).toAbsolutePath().normalize().toUri() + "", "folder", byFolder);
		}
		Map<String, SolutionPackage> byName = new LinkedHashMap<>();
		byFolder.values().forEach((p) -> byName.put(p.name(), p));
		return byName;
	}

	private void scan(String base, String source, Map<String, SolutionPackage> byFolder) {
		String root = base.endsWith("/") ? base : base + "/";
		try {
			for (Resource manifest : this.resolver.getResources(root + "*/" + MANIFEST)) {
				String folder = parentName(manifest);
				if (folder == null || !FOLDER.matcher(folder).matches()) {
					continue;
				}
				JsonNode json;
				try (InputStream in = manifest.getInputStream()) {
					json = this.jsonMapper.readTree(new String(in.readAllBytes(), StandardCharsets.UTF_8));
				}
				catch (RuntimeException ex) {
					logger.warn("Solution package {}: {} could not be read: {}", folder, MANIFEST, ex.getMessage());
					continue;
				}
				TreeMap<Integer, Resource> releases = new TreeMap<>();
				for (Resource file : this.resolver.getResources(root + folder + "/V*__*.sql")) {
					Matcher matcher = RELEASE.matcher(String.valueOf(file.getFilename()));
					if (matcher.matches()) {
						Resource previous = releases.put(Integer.parseInt(matcher.group(1)), file);
						if (previous != null) {
							throw new IllegalStateException("Solution package %s: two releases of version %s — %s and %s"
								.formatted(folder, matcher.group(1), previous.getFilename(), file.getFilename()));
						}
					}
				}
				String name = json.path("name").asString(folder);
				byFolder.put(folder, new SolutionPackage(folder, name, json.path("title"), json.path("description"),
						json.path("schema").asString(name), releases, source));
			}
		}
		catch (IOException ex) {
			throw new UncheckedIOException(ex);
		}
	}

	/** Имя папки файла: {@code file:/…/my_app/solution.json}, {@code jar:file:/…!/db/solutions/my_app/solution.json}. */
	private static String parentName(Resource resource) {
		try {
			String[] parts = resource.getURL().toString().split("/");
			return (parts.length >= 2) ? parts[parts.length - 2] : null;
		}
		catch (IOException ex) {
			return null;
		}
	}

	/** Действующий пользователь — администратор. */
	public boolean isAdmin(String login) {
		return Boolean.TRUE.equals(this.jdbcTemplate.query(
				"SELECT pgerp.auth_is_admin(id) FROM pgerp.users WHERE login = ? AND is_active",
				(rows) -> rows.next() && rows.getBoolean(1), login));
	}

	/** Установленные решения: имя → {title, db_schema, version}. */
	public JsonNode installed() {
		return this.jsonMapper.readTree(
				this.jdbcTemplate.queryForObject("SELECT pgerp.solution_packages_state()::text", String.class));
	}

	/** Список пакетов для окна установки: описание, последняя и установленная версии, схема. */
	public ArrayNode list() {
		JsonNode installed = installed();
		ArrayNode list = this.jsonMapper.createArrayNode();
		for (SolutionPackage p : packages().values()) {
			ObjectNode item = list.addObject();
			item.put("name", p.name());
			item.put("folder", p.folder());
			item.set("title", p.title().isMissingNode() ? item.stringNode(p.name()) : p.title());
			item.set("description", p.description().isMissingNode() ? item.nullNode() : p.description());
			item.put("schema", p.schema());
			item.put("version", p.latestVersion());
			item.put("source", p.source());
			JsonNode state = installed.path(p.name());
			if (state.isObject()) {
				item.put("installed_version", state.path("version").asInt(0));
				item.put("db_schema", state.path("db_schema").asString(null));
			}
			else {
				item.putNull("installed_version");
			}
		}
		return list;
	}

	/**
	 * Установка или обновление решения из пакета.
	 *
	 * @param login  администратор; {@code null} — обновление при запуске приложения
	 * @param name   имя решения
	 * @param schema схема базы для нового решения; пусто — из {@code solution.json}
	 * @return {@code {name, title, db_schema, version, applied: [версии]}}
	 */
	public ObjectNode install(String login, String name, String schema) {
		return install(login, name, schema, false);
	}

	/**
	 * Установка решения из пакета; {@code reset} — чистая установка: решение, его метаданные и схема
	 * с данными удаляются перед установкой ({@code pgerp.solution_reset}), затем ставятся все выпуски пакета.
	 */
	public ObjectNode install(String login, String name, String schema, boolean reset) {
		SolutionPackage p = packages().get(name);
		if (p == null) {
			throw new SolutionInstallException("Solution package “%s” not found".formatted(name));
		}
		if (p.releases().isEmpty()) {
			throw new SolutionInstallException("Solution package “%s” has no releases".formatted(name));
		}
		String targetSchema = (schema != null && !schema.isBlank()) ? schema.trim() : p.schema();
		return this.transaction.execute((status) -> {
			this.jdbcTemplate.queryForObject("SELECT set_config('search_path', pgerp.app_search_path(), TRUE)", String.class);
			Integer installed = this.jdbcTemplate.queryForObject("SELECT pgerp.solution_install_begin(?, ?, ?, ?)",
					Integer.class, login, p.name(), targetSchema, reset);
			List<Integer> applied = new ArrayList<>();
			for (Map.Entry<Integer, Resource> release : p.releases().tailMap(installed, false).entrySet()) {
				String script = read(release.getValue());
				this.jdbcTemplate.execute((StatementCallback<Boolean>) (statement) -> {
					// Текст выпуска — как в psql: без JDBC-экранирования {fn …} внутри данных
					statement.setEscapeProcessing(false);
					return statement.execute(script);
				});
				applied.add(release.getKey());
			}
			ObjectNode result = (ObjectNode) this.jsonMapper.readTree(this.jdbcTemplate
				.queryForObject("SELECT pgerp.solution_install_end(?)::text", String.class, p.name()));
			ArrayNode versions = result.putArray("applied");
			applied.forEach(versions::add);
			return result;
		});
	}

	/** Обновление установленных решений до последнего выпуска их пакетов (при запуске приложения). */
	public void upgradeInstalled() {
		JsonNode installed = installed();
		for (SolutionPackage p : packages().values()) {
			JsonNode state = installed.path(p.name());
			if (state.isObject() && state.path("version").asInt(0) < p.latestVersion()) {
				ObjectNode result = install(null, p.name(), null);
				logger.info("Solution {} updated to release {} (releases {})", p.name(), p.latestVersion(), result.path("applied"));
			}
		}
	}

	/** Нативный образ (GraalVM): файлы пакетов — ресурсы образа. */
	static class PackageResources implements RuntimeHintsRegistrar {

		@Override
		public void registerHints(RuntimeHints hints, ClassLoader classLoader) {
			hints.resources().registerPattern("db/solutions/*/" + MANIFEST).registerPattern("db/solutions/*/V*.sql");
		}

	}

	private static String read(Resource resource) {
		try (InputStream in = resource.getInputStream()) {
			return new String(in.readAllBytes(), StandardCharsets.UTF_8);
		}
		catch (IOException ex) {
			throw new UncheckedIOException(ex);
		}
	}

}
