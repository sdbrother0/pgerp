package com.erp.gateway.dev;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Optional;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.Stream;

import org.springframework.stereotype.Component;

/**
 * Сохраняет файл выпуска решения в пакет решения в исходниках проекта ({@code erp.dev.solutions-dir}).
 * <p>
 * Имя папки и файла приходят из базы, но всё равно проверяются: только {@code <папка>/V<n>__<имя>.sql}
 * внутри настроенной папки. Выпуск с той же версией в папке пакета — ошибка: установщик не примет два.
 * Существующий файл не перезаписывается. Описание пакета {@code solution.json} создаётся, если его ещё нет.
 */
@Component
public class MigrationWriter {

	private static final Pattern FOLDER = Pattern.compile("[a-z][a-z0-9_]{0,99}");

	private static final Pattern FILE = Pattern.compile("V(\\d{1,9})__[a-z0-9_]{1,150}\\.sql");

	private final Path root;

	public MigrationWriter(DevProperties properties) {
		this.root = (properties.solutionsDir() != null) ? Path.of(properties.solutionsDir()).toAbsolutePath().normalize()
				: null;
	}

	/** Папка пакетов настроена. */
	public boolean isConfigured() {
		return this.root != null;
	}

	public Optional<Path> root() {
		return Optional.ofNullable(this.root);
	}

	public Path write(String folder, String fileName, String content) {
		return write(folder, fileName, content, null);
	}

	/**
	 * @param manifest текст {@code solution.json}; пишется, только если в папке пакета его ещё нет
	 * @return путь сохранённого файла
	 * @throws MigrationWriteException папка не настроена, имя недопустимо, версия занята или файл не записан
	 */
	public Path write(String folder, String fileName, String content, String manifest) {
		if (this.root == null) {
			throw new MigrationWriteException("The solution packages folder is not configured (ERP_DEV_SOLUTIONS_DIR)");
		}
		if (folder == null || !FOLDER.matcher(folder).matches()) {
			throw new MigrationWriteException("Invalid package folder: " + folder);
		}
		Matcher file = (fileName != null) ? FILE.matcher(fileName) : null;
		if (file == null || !file.matches()) {
			throw new MigrationWriteException("Invalid release file name: " + fileName);
		}
		if (content == null || content.isBlank()) {
			throw new MigrationWriteException("The release text is empty");
		}
		int version = Integer.parseInt(file.group(1));
		Path target = this.root.resolve(folder).resolve(fileName).normalize();
		if (!target.startsWith(this.root)) {
			throw new MigrationWriteException("Invalid release path: " + target);
		}
		try {
			Optional<Path> taken = findVersion(target.getParent(), version);
			if (taken.isPresent()) {
				throw new MigrationWriteException(
						"Release version %d already exists: %s".formatted(version, this.root.relativize(taken.get())));
			}
			Files.createDirectories(target.getParent());
			Files.writeString(target, content, StandardCharsets.UTF_8, StandardOpenOption.CREATE_NEW);
			Path manifestFile = target.getParent().resolve(SolutionPackages.MANIFEST);
			if (manifest != null && !manifest.isBlank() && !Files.exists(manifestFile)) {
				Files.writeString(manifestFile, manifest, StandardCharsets.UTF_8, StandardOpenOption.CREATE_NEW);
			}
			return target;
		}
		catch (FileAlreadyExistsException ex) {
			throw new MigrationWriteException("The file already exists: " + target);
		}
		catch (IOException | UncheckedIOException ex) {
			throw new MigrationWriteException("The release file was not written: " + ex.getMessage());
		}
	}

	/** Файл выпуска с этой версией в папке пакета. */
	private static Optional<Path> findVersion(Path folder, int version) throws IOException {
		if (!Files.isDirectory(folder)) {
			return Optional.empty();
		}
		try (Stream<Path> files = Files.list(folder)) {
			return files.filter(Files::isRegularFile).filter((path) -> {
				Matcher matcher = Pattern.compile("V(\\d+)__.*").matcher(path.getFileName().toString());
				return matcher.matches() && matcher.group(1).length() <= 9 && Integer.parseInt(matcher.group(1)) == version;
			}).findFirst();
		}
	}

}
