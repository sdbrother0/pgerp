package com.erp.gateway.dev;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class MigrationWriterTests {

	@TempDir
	Path root;

	@Test
	void writesFileIntoSolutionFolder() throws Exception {
		MigrationWriter writer = new MigrationWriter(new DevProperties(this.root.toString(), null));

		Path saved = writer.write("my_app", "V14__my_app_first.sql", "SELECT 1;\n");

		assertThat(saved).isEqualTo(this.root.resolve("my_app/V14__my_app_first.sql"));
		assertThat(Files.readString(saved, StandardCharsets.UTF_8)).isEqualTo("SELECT 1;\n");
	}

	@Test
	void manifestIsWrittenOnlyOnce() throws Exception {
		MigrationWriter writer = new MigrationWriter(new DevProperties(this.root.toString(), null));

		writer.write("my_app", "V1__my_app_first.sql", "SELECT 1;\n", "{\"name\": \"my_app\"}\n");
		writer.write("my_app", "V2__my_app_second.sql", "SELECT 2;\n", "{\"name\": \"other\"}\n");

		assertThat(Files.readString(this.root.resolve("my_app/solution.json"))).isEqualTo("{\"name\": \"my_app\"}\n");
	}

	@Test
	void versionTakenInSameFolderIsRejected() throws Exception {
		Files.createDirectories(this.root.resolve("my_app"));
		Files.writeString(this.root.resolve("my_app/V14__my_app_change.sql"), "SELECT 1;");
		Files.createDirectories(this.root.resolve("stock"));
		Files.writeString(this.root.resolve("stock/V15__stock_change.sql"), "SELECT 1;");
		MigrationWriter writer = new MigrationWriter(new DevProperties(this.root.toString(), null));

		assertThatThrownBy(() -> writer.write("my_app", "V14__my_app_first.sql", "SELECT 2;"))
			.isInstanceOf(MigrationWriteException.class)
			.hasMessageContaining("Release version 14 already exists")
			.hasMessageContaining("V14__my_app_change.sql");
		assertThat(this.root.resolve("my_app/V14__my_app_first.sql")).doesNotExist();
		// Версии пакетов независимы: V15 есть только у другого решения
		assertThat(writer.write("my_app", "V15__my_app_next.sql", "SELECT 3;")).exists();
	}

	@Test
	void namesOutsideSolutionsFolderAreRejected() {
		MigrationWriter writer = new MigrationWriter(new DevProperties(this.root.toString(), null));

		assertThatThrownBy(() -> writer.write("../etc", "V1__x.sql", "SELECT 1;")).isInstanceOf(MigrationWriteException.class);
		assertThatThrownBy(() -> writer.write("my_app", "../V1__x.sql", "SELECT 1;")).isInstanceOf(MigrationWriteException.class);
		assertThatThrownBy(() -> writer.write("my_app", "V1__x.sh", "SELECT 1;")).isInstanceOf(MigrationWriteException.class);
	}

	@Test
	void withoutFolderNothingIsWritten() {
		MigrationWriter writer = new MigrationWriter(new DevProperties(" ", null));

		assertThat(writer.isConfigured()).isFalse();
		assertThatThrownBy(() -> writer.write("my_app", "V1__x.sql", "SELECT 1;"))
			.isInstanceOf(MigrationWriteException.class)
			.hasMessageContaining("ERP_DEV_SOLUTIONS_DIR");
	}

}
