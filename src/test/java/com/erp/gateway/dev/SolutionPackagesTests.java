package com.erp.gateway.dev;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Map;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import tools.jackson.databind.json.JsonMapper;

import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.transaction.PlatformTransactionManager;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;

class SolutionPackagesTests {

	@TempDir
	Path root;

	private SolutionPackages packages(String dir) {
		return new SolutionPackages(mock(JdbcTemplate.class), mock(PlatformTransactionManager.class), JsonMapper.builder().build(),
				new DevProperties(dir, null));
	}

	@Test
	void applicationPackagesAreFound() {
		Map<String, SolutionPackages.SolutionPackage> found = packages(null).packages();

		assertThat(found).containsKey("sample");
		assertThat(found.get("sample").schema()).isEqualTo("sample_schema");
		assertThat(found.get("sample").title().path("en").asString()).isEqualTo("Sample");
		assertThat(found.get("sample").releases().keySet()).containsExactly(1, 2);
		assertThat(found.get("sample").source()).isEqualTo("classpath");
	}

	@Test
	void folderPackageWinsAndReleasesAreOrdered() throws Exception {
		Path sample = Files.createDirectories(this.root.resolve("sample"));
		Files.writeString(sample.resolve("solution.json"), "{\"name\": \"sample\", \"title\": \"Sample dev\"}");
		Files.writeString(sample.resolve("V1__sample.sql"), "SELECT 1;");
		Files.writeString(sample.resolve("V10__sample_ten.sql"), "SELECT 10;");
		Files.writeString(sample.resolve("V2__sample_two.sql"), "SELECT 2;");
		Files.writeString(sample.resolve("notes.sql"), "-- не выпуск");
		Path todo = Files.createDirectories(this.root.resolve("todo"));
		Files.writeString(todo.resolve("solution.json"), "{\"name\": \"todo\", \"schema\": \"tasks\"}");

		Map<String, SolutionPackages.SolutionPackage> found = packages(this.root.toString()).packages();

		assertThat(found.get("sample").source()).isEqualTo("folder");
		assertThat(found.get("sample").title().asString()).isEqualTo("Sample dev");
		assertThat(found.get("sample").releases().keySet()).containsExactly(1, 2, 10);
		assertThat(found.get("sample").schema()).isEqualTo("sample");
		assertThat(found.get("todo").schema()).isEqualTo("tasks");
		assertThat(found.get("todo").latestVersion()).isZero();
		// Пакеты приложения с другими папками остаются
		assertThat(found.keySet()).hasSizeGreaterThanOrEqualTo(2);
	}

	@Test
	void duplicateVersionIsRejected() throws Exception {
		Path my_app = Files.createDirectories(this.root.resolve("my_app"));
		Files.writeString(my_app.resolve("solution.json"), "{\"name\": \"my_app\"}");
		Files.writeString(my_app.resolve("V1__my_app_a.sql"), "SELECT 1;");
		Files.writeString(my_app.resolve("V01__my_app_b.sql"), "SELECT 1;");

		assertThatThrownBy(() -> packages(this.root.toString()).packages()).hasMessageContaining("two releases of version");
	}

}
