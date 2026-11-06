import { callAction, csrfHeaders, showConfirm, showMessage } from './ui-runtime.js';
import { button, checkbox, copyButton, downloadText, el, field, formatTime, hint, input, objectTypeLabel, section, showSql, spacer, sqlBlock, table } from './editor-kit.js';
import { language, t } from './i18n.js';
import { showSolutionPackages } from './solution-packages.js';

/**
 * Раздел «Решения» (editor.html?solutions=<имя>): свойства решения, его состав, выпуск и история выпусков.
 * Список решений — в боковой панели редактора (её рисует editor.html).
 *
 * Выпуск — файл пакета решения (db/solutions/<папка>/V<n>__….sql), который собирает база: изменения после
 * прошлого выпуска. «Проверить изменения» показывает их и текст выпуска; «Создать выпуск» записывает выпуск
 * (POST api/dev/release) — шлюз сохраняет файл в папку пакетов, если она настроена, иначе файл скачивается.
 * «Установить решения» — окно пакетов решений из приложения (solution-packages.js).
 *
 * root — контейнер; onNavigate(name) — открыто другое решение (пусто — новое); onChanged() — решения изменились.
 * Возвращает { open(name), dirty, name }.
 */
export function createSolutionEditor(root, { onNavigate = () => {}, onChanged = () => {} } = {}) {
	let solution = null;   // {is_new, name, title, prefix, menu_folder, migration_folder, db_schema, description, is_core, counts}
	let objects = [];
	let unassigned = [];
	let releases = [];
	let dirty = false;
	let migrationsDir = null;
	let preview = null;    // последний предпросмотр выпуска
	let label = '';

	const canvas = el('section', { className: 'editor-canvas dev-canvas' });
	root.replaceChildren(canvas);

	async function open(name) {
		const [result, settings] = await Promise.all([
			callAction('solution_get', name ? { name } : {}),
			fetch('api/dev/settings', { headers: { 'Accept-Language': language() } }).then((r) => (r.ok ? r.json() : {})),
		]);
		solution = result.solution;
		objects = result.objects;
		unassigned = result.unassigned;
		releases = result.releases;
		migrationsDir = settings.solutions_dir ?? null;
		preview = null;
		label = '';
		dirty = false;
		render();
		onNavigate(solution.is_new ? '' : solution.name);
	}

	function changed() {
		dirty = true;
		dirtyMark.hidden = false;
	}

	const dirtyMark = el('span', { className: 'editor-dirty', textContent: t('● Not saved'), hidden: true });

	// -----------------------------------------------------------------
	// Отрисовка
	// -----------------------------------------------------------------
	function render() {
		dirtyMark.hidden = !dirty;
		const readOnly = solution.is_core;
		const heading = el('h3', { className: 'report-heading', textContent: solution.title || solution.name || t('New solution') });
		const saveButton = button(t('Save'), save, { className: 'primary', disabled: readOnly });
		const deleteButton = button(t('Delete'), remove, { className: 'danger', disabled: solution.is_new || readOnly,
			title: t('The solution is deleted; its objects stay in the database') });
		const toolbar = el('div', { className: 'toolbar' }, heading, spacer(), dirtyMark,
			button(t('Install solutions'), () => guard(installPackages), { title: t('Solution packages shipped with the application: install and update') }),
			button(t('+ New solution'), () => guard(() => open(''))), deleteButton, saveButton);

		const props = el('div', { className: 'report-fields dev-fields' },
			field(t('Name'), input(solution.name, (v) => { solution.name = v.trim(); changed(); },
				{ disabled: !solution.is_new, spellcheck: false, placeholder: 'my_app' }), t('Latin letters, digits and _')),
			field(t('Title'), input(solution.title, (v) => { solution.title = v; changed(); }, { disabled: readOnly })),
			field(t('Prefix'), input(solution.prefix, (v) => { solution.prefix = v.trim() || null; changed(); },
				{ disabled: readOnly, spellcheck: false, placeholder: 'my_app_' }), t('Objects whose names start with it belong to the solution automatically')),
			field(t('Menu folder'), input(solution.menu_folder, (v) => { solution.menu_folder = v.trim() || null; changed(); },
				{ disabled: readOnly }), t('Top-level menu folder that a release carries over')),
			field(t('Database schema'), input(solution.db_schema, (v) => { solution.db_schema = v.trim() || null; changed(); },
				{ disabled: !solution.is_new, spellcheck: false, placeholder: solution.name || 'my_app' }),
				solution.is_new ? t('Tables, views and functions of the solution; defaults to the solution name') : t('Set on creation')),
			field(t('Package folder'), input(solution.migration_folder, (v) => { solution.migration_folder = v.trim() || null; changed(); },
				{ disabled: readOnly, spellcheck: false, placeholder: solution.name || 'my_app' }), t('db/solutions/<folder>; defaults to the solution name')),
			field(t('Description'), input(solution.description, (v) => { solution.description = v || null; changed(); }, { disabled: readOnly })));

		const parts = [toolbar, props];
		if (readOnly) {
			parts.push(hint(t('The platform core changes only through core migrations: only its contents are shown here.')));
		}
		if (!solution.is_new) {
			parts.push(renderObjects(readOnly));
			if (!readOnly) {
				parts.push(renderRelease(), renderHistory());
			}
		}
		else {
			parts.push(hint(t('Save the solution — then its contents and releases will appear.')));
		}
		canvas.replaceChildren(...parts);
	}

	function renderObjects(readOnly) {
		const counts = Object.entries(solution.counts ?? {}).map(([type, n]) => `${objectTypeLabel(type)}: ${n}`).join(' · ');
		const rows = objects.map((o) => [
			objectTypeLabel(o.type),
			el('code', { textContent: o.name }),
			o.explicit ? t('explicitly') : t('by prefix'),
			o.type === 'table' && !readOnly
				? checkbox(o.data, (v) => setData(o.name, v), { title: t('Carry the table rows in a release (reference data)') })
				: '',
			o.explicit && !readOnly ? button(t('Exclude'), () => setObject(o, '')) : '',
		]);
		const add = el('select');
		add.add(new Option(t('— object outside solutions —'), ''));
		for (const o of unassigned) {
			add.add(new Option(`${objectTypeLabel(o.type)}: ${o.name}`, `${o.type}:${o.name}`));
		}
		const addButton = button(t('Add to solution'), () => {
			const [type, ...name] = add.value.split(':');
			if (type) {
				setObject({ type, name: name.join(':') }, solution.name);
			}
		}, { disabled: unassigned.length === 0 });
		return section(t('Contents'),
			hint(counts || t('No objects yet: create tables and forms with the solution prefix or add objects explicitly.')),
			objects.length ? table([t('Type'), t('Name'), t('Included'), t('Data'), ''], rows, 'dev-objects') : null,
			readOnly ? null : el('div', { className: 'toolbar dev-inline' }, add, addButton,
				hint(unassigned.length ? t('Objects outside solutions: {0}', unassigned.length) : t('All objects belong to solutions'))));
	}

	function renderRelease() {
		const last = releases[0];
		const labelInput = input(label, (v) => { label = v; }, { placeholder: t('For example: Search by title') });
		const out = el('div', { className: 'dev-release-out' });
		if (preview) {
			out.append(...[
				preview.empty
					? hint(t('No changes since release {0}.', preview.base_version))
					: el('ul', { className: 'dev-changes' }, ...preview.changes.map((c) => el('li', { textContent: c }))),
				preview.warnings.length
					? el('ul', { className: 'dev-warnings' }, ...preview.warnings.map((w) => el('li', { textContent: w })))
					: null,
				el('div', { className: 'toolbar dev-inline' },
					el('code', { textContent: preview.path }), spacer(), copyButton(preview.content),
					button(t('Download'), () => downloadText(preview.file_name, preview.content))),
				sqlBlock(preview.content)].filter(Boolean));
		}
		return section(t('Release'),
			hint(last ? t('Last release — {0} “{1}”, {2}. A release collects the changes made after it.', last.version, last.label, formatTime(last.created_at))
				: t('No releases yet: the first release carries the whole solution.')),
			hint(migrationsDir ? t('The release file will be saved to {0}', migrationsDir)
				: t('The packages folder is not configured (ERP_DEV_SOLUTIONS_DIR): the release file will be downloaded; put it into src/main/resources/db/solutions/{0}/.', solution.migration_folder)),
			el('div', { className: 'dev-release-form' }, field(t('Release name'), labelInput),
				el('div', { className: 'toolbar dev-inline' },
					button(t('Check changes'), () => runPreview(false)),
					button(t('Full script'), () => runPreview(true), { title: t('The whole solution — for example, to install on an empty database') }),
					button(t('Create release'), createRelease, { className: 'primary' }))),
			out);
	}

	function renderHistory() {
		const rows = releases.map((r, index) => [
			String(r.version), r.label, formatTime(r.created_at), r.created_by ?? '', r.file_name ?? '',
			el('span', { className: 'dev-row-tools' },
				r.has_script ? button(t('Download'), () => downloadRelease(r)) : '',
				index === 0 && r.version > 0 ? button(t('Undo'), () => cancelRelease(r), { className: 'danger',
					title: t('Cancel the last release: the next one will collect its changes again') }) : ''),
		]);
		return section(t('Release history'), releases.length
			? table([t('Version'), t('Title'), t('Created'), t('By'), t('File'), ''], rows)
			: hint(t('No releases yet.')));
	}

	// -----------------------------------------------------------------
	// Действия
	// -----------------------------------------------------------------
	async function save() {
		try {
			const result = await callAction('solution_save', solution);
			dirty = false;
			await open(result.name);
			onChanged();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function remove() {
		if (!await showConfirm(t('Delete solution “{0}”? Its tables, functions and forms stay in the database but leave the solution.', solution.title), t('Delete'))) {
			return;
		}
		try {
			await callAction('solution_delete', { name: solution.name });
			dirty = false;
			onChanged();
			await open('');
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function setObject(object, target) {
		try {
			await callAction('solution_object_set', { type: object.type, name: object.name, solution: target });
			await reload();
			onChanged();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function setData(table, enabled) {
		try {
			await callAction('solution_data_set', { table, enabled });
			await reload();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	/** Перечитать состав и выпуски, не теряя несохранённых свойств. */
	async function reload() {
		const result = await callAction('solution_get', { name: solution.name });
		objects = result.objects;
		unassigned = result.unassigned;
		releases = result.releases;
		solution.counts = result.solution.counts;
		render();
	}

	async function runPreview(full) {
		try {
			preview = await callAction('release_preview', { solution: solution.name, label, full });
			render();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function createRelease() {
		if (dirty) {
			showMessage(t('Save the solution properties first'), 'error');
			return;
		}
		if (!label.trim()) {
			showMessage(t('Enter the release name'), 'error');
			return;
		}
		try {
			const check = await callAction('release_preview', { solution: solution.name, label });
			if (check.empty) {
				showMessage(t('Nothing has changed in the solution since the last release'));
				return;
			}
			const note = [t('Changes:'), ...check.changes.map((c) => `• ${c}`),
				...check.warnings.length ? [t('Attention:'), ...check.warnings.map((w) => `! ${w}`)] : []].join('\n');
			if (await showSql(t('Release {0}: {1}', check.version, check.file_name), check.content,
				{ note, actions: [{ text: t('Create release'), primary: true }] }) === null) {
				return;
			}
			const response = await fetch('api/dev/release', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json', 'Accept-Language': language(), ...csrfHeaders() },
				body: JSON.stringify({ solution: solution.name, label }),
			});
			const result = await response.json().catch(() => ({ status: 'error', message: `HTTP ${response.status}` }));
			if (!response.ok || result.status === 'error') {
				throw new Error(result.message);
			}
			if (result.saved_to) {
				showMessage(t('Release {0} created. Release file: {1}', result.version, result.saved_to));
			}
			else {
				downloadText(result.file_name, result.content);
				showMessage(result.save_error
					? t('Release {0} created, but the file was not saved: {1}. The file was downloaded — put it into {2}', result.version, result.save_error, result.path)
					: t('Release {0} created. The file was downloaded — put it into {1}', result.version, result.path));
			}
			preview = null;
			label = '';
			await reload();
			onChanged();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function downloadRelease(release) {
		try {
			const result = await callAction('release_get', { solution: solution.name, version: release.version });
			downloadText(result.release.file_name ?? `V${release.version}__${solution.name}.sql`, result.release.content);
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function cancelRelease(release) {
		if (!await showConfirm(t('Cancel release {0}? The next release will collect its changes again. Delete the saved release file manually.', release.version), t('Cancel release'))) {
			return;
		}
		try {
			await callAction('release_delete', { solution: solution.name, version: release.version });
			await reload();
			onChanged();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function installPackages() {
		if (await showSolutionPackages()) {
			// Установленное решение добавило формы и меню: проще всего перечитать редактор целиком
			location.reload();
		}
	}

	async function guard(action) {
		if (!dirty || confirm(t('There are unsaved changes. Continue without saving?'))) {
			await action().catch((e) => showMessage(e.message, 'error'));
		}
	}

	return {
		open,
		get dirty() {
			return dirty;
		},
		get name() {
			return solution && !solution.is_new ? solution.name : '';
		},
	};
}

/** Подпись решения для списков: «Моё приложение (my_app)». */
export function solutionLabel(s) {
	return s.is_core ? `${s.title}` : `${s.title} (${s.name})`;
}

