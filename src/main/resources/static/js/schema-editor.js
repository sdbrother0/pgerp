import { callAction, showMessage } from './ui-runtime.js';
import { codeArea, highlightSql } from './code-editor.js';
import { button, checkbox, el, field, hint, input, section, select, showSql, spacer, table } from './editor-kit.js';
import { t } from './i18n.js';

/** Частые типы колонок — подсказки поля «Тип»; можно ввести любой тип PostgreSQL. */
const TYPES = ['bigserial', 'bigint', 'integer', 'smallint', 'numeric(12,2)', 'text', 'varchar(100)', 'varchar(200)', 'boolean',
	'date', 'timestamptz', 'jsonb', 'uuid'];
const ON_DELETE = ['NO ACTION', 'CASCADE', 'SET NULL', 'RESTRICT'];

/**
 * Раздел «Схема данных» (editor.html?schema=table:<имя> | view:<имя>): таблицы и представления решения,
 * выбранного в боковой панели. Конструктор таблицы и редактор представления сначала показывают SQL изменений
 * (table_save / view_save с apply=false), затем применяют его. Переименования конструктора выпуск перенесёт
 * переименованием, а не удалением и созданием.
 *
 * getSolution() — решение из боковой панели ('' — все); solutions() — решения для выбора;
 * onNavigate(kind, name) — открыт объект; openConsole(sql) — открыть SQL-консоль с запросом.
 */
export function createSchemaEditor(root, { getSolution = () => '', solutions = () => [], onNavigate = () => {}, openConsole = () => {} } = {}) {
	let schema = { tables: [], views: [] };
	let allTables = [];
	let current = null;   // {kind: 'table'|'view', ...}
	let dirty = false;

	const list = el('nav', { className: 'dev-list' });
	const body = el('section', { className: 'editor-canvas dev-canvas' });
	root.replaceChildren(list, body);

	const dirtyMark = el('span', { className: 'editor-dirty', textContent: t('● Not saved'), hidden: true });

	function changed() {
		dirty = true;
		dirtyMark.hidden = false;
	}

	/** target: {kind, name}; без имени — новый объект; без kind — только список. */
	async function open(target = {}) {
		const [solutionSchema, wholeSchema] = await Promise.all([
			callAction('schema_get', { solution: getSolution() }),
			callAction('schema_get', {}),
		]);
		schema = solutionSchema;
		allTables = wholeSchema.tables.map((tb) => tb.name);
		dirty = false;
		if (target.kind === 'table') {
			const result = await callAction('table_get', target.name ? { name: target.name } : { solution: getSolution() });
			current = { kind: 'table', ...result.table };
			current.columns = current.columns.map((c) => ({ ...c, orig: current.is_new ? null : c.name, pk: current.primary_key.includes(c.name) }));
			current.new_fks = [];
			current.new_uniques = [];
			current.new_checks = [];
			current.new_indexes = [];
		}
		else if (target.kind === 'view') {
			const result = await callAction('view_get', target.name ? { name: target.name } : { solution: getSolution() });
			current = { kind: 'view', ...result.view };
		}
		else {
			current = null;
		}
		if (current) {
			current.orig_name = current.is_new ? null : current.name;
			current.solution ??= getSolution() || null;
		}
		render();
		onNavigate(current?.kind ?? '', current && !current.is_new ? current.name : '');
	}

	// -----------------------------------------------------------------
	// Список
	// -----------------------------------------------------------------
	function renderList() {
		const item = (kind, name, note) => {
			const link = el('a', { href: '#', textContent: name, title: note ?? '' });
			link.classList.toggle('active', current?.kind === kind && current?.orig_name === name);
			link.addEventListener('click', (event) => {
				event.preventDefault();
				guard(() => open({ kind, name }));
			});
			return el('li', {}, link);
		};
		list.replaceChildren(
			el('div', { className: 'toolbar dev-inline' },
				button(t('+ Table'), () => guard(() => open({ kind: 'table' }))),
				button(t('+ View'), () => guard(() => open({ kind: 'view' })))),
			el('h3', { className: 'sidebar-title', textContent: t('Tables') }),
			schema.tables.length
				? el('ul', { className: 'form-list' }, ...schema.tables.map((tb) => item('table', tb.name, tb.comment)))
				: hint(t('No tables')),
			el('h3', { className: 'sidebar-title', textContent: t('Views') }),
			schema.views.length
				? el('ul', { className: 'form-list' }, ...schema.views.map((v) => item('view', v.name, v.comment)))
				: hint(t('No views')));
	}

	function render() {
		renderList();
		dirtyMark.hidden = !dirty;
		if (!current) {
			body.replaceChildren(el('p', { className: 'content-empty', textContent: getSolution()
				? t('Select a table or view of the solution on the left or create a new one.')
				: t('Select a table or view on the left. Filter by solution in the sidebar.') }));
			return;
		}
		body.replaceChildren(...(current.kind === 'table' ? renderTable() : renderView()).filter(Boolean));
	}

	function solutionField() {
		return field(t('Solution'), select([['', t('— by name prefix —')],
			...solutions().filter((s) => !s.is_core).map((s) => [s.name, s.prefix ? `${s.title} (${s.prefix}…)` : s.title])],
		current.solution ?? '', (v) => { current.solution = v || null; changed(); }),
		t('If the name lacks a solution prefix, the object joins the selected solution explicitly'));
	}

	// -----------------------------------------------------------------
	// Таблица
	// -----------------------------------------------------------------
	function renderTable() {
		const tb = current;
		const toolbar = el('div', { className: 'toolbar' },
			el('h3', { className: 'report-heading', textContent: tb.is_new ? t('New table') : tb.orig_name }), spacer(), dirtyMark,
			button(t('Data'), () => openConsole(`SELECT *\nFROM ${tb.orig_name}\nORDER BY 1 DESC\nLIMIT 100`), { disabled: tb.is_new }),
			button(t('SQL'), () => saveTable(false), { title: t('Show the SQL of the changes without applying it') }),
			button(t('Delete'), () => drop('table', tb.orig_name), { className: 'danger', disabled: tb.is_new }),
			button(t('Save'), () => saveTable(true), { className: 'primary' }));

		const props = el('div', { className: 'report-fields dev-fields' },
			field(t('Name'), input(tb.name, (v) => { tb.name = v.trim(); changed(); }, { spellcheck: false }),
				tb.is_new ? t('With the solution prefix, for example my_app_items') : t('Renaming is remembered: the release will rename the table')),
			solutionField(),
			field(t('Comment'), input(tb.comment, (v) => { tb.comment = v || null; changed(); })),
			field(t('Rows (estimate)'), el('span', { textContent: tb.is_new ? '—' : String(tb.rows ?? 0) })));

		const columnRows = tb.columns.map((c, index) => [
			checkbox(c.pk, (v) => { c.pk = v; changed(); }, { title: t('Primary key') }),
			input(c.name, (v) => { c.name = v.trim(); changed(); }, { spellcheck: false, title: c.orig && c.orig !== c.name ? t('Was: {0}', c.orig) : '' }),
			input(c.type, (v) => { c.type = v.trim(); changed(); }, { list: 'dev-types', spellcheck: false }),
			checkbox(c.not_null, (v) => { c.not_null = v; changed(); }, { title: t('Required (NOT NULL)') }),
			input(c.default, (v) => { c.default = v.trim() || null; changed(); }, { spellcheck: false, placeholder: c.generated ? t('generated') : '' }),
			input(c.comment, (v) => { c.comment = v || null; changed(); }),
			el('span', { className: 'dev-row-tools' },
				tb.is_new ? button('↑', () => moveColumn(index, -1), { disabled: index === 0, title: t('Up') }) : null,
				tb.is_new ? button('↓', () => moveColumn(index, 1), { disabled: index === tb.columns.length - 1, title: t('Down') }) : null,
				button('✕', () => { tb.columns.splice(index, 1); changed(); render(); },
					{ title: c.orig ? t('Delete the column with its data') : t('Remove'), className: c.orig ? 'danger' : '' })),
		]);
		const columns = section(t('Columns'),
			table([t('Key'), t('Name'), t('Type'), t('Req.'), t('Default'), t('Comment'), ''], columnRows, 'dev-columns'),
			el('div', { className: 'toolbar dev-inline' },
				button(t('+ Column'), () => { tb.columns.push({ name: '', type: 'text', not_null: false, default: null, comment: null, pk: false, orig: null }); changed(); render(); }),
				button(t('+ Created / changed'), () => {
					tb.columns.push({ name: 'created_at', type: 'timestamptz', not_null: true, default: 'now()', comment: null, pk: false, orig: null });
					changed();
					render();
				}, { title: t('Column created_at with the creation time') })),
			el('datalist', { id: 'dev-types' }, ...TYPES.map((type) => el('option', { value: type }))),
			hint(t('Types as in PostgreSQL: bigserial (counter for id), text, varchar(200), numeric(12,2), date, timestamptz, boolean, jsonb. Default is an SQL expression: 0, now(), \'new\'.')));

		return [toolbar, props, columns, renderKeys(), renderInfo()];
	}

	/** Внешние ключи, уникальность, проверки и индексы: существующие — удалить, новые — добавить. */
	function renderKeys() {
		const tb = current;
		const columnNames = tb.columns.map((c) => c.name).filter(Boolean);
		// Списки колонок перечитываются при открытии: колонки могли добавить или переименовать после отрисовки
		const names = () => tb.columns.map((c) => c.name).filter(Boolean);
		const syncColumns = (selectElement) => {
			const value = selectElement.value;
			selectElement.replaceChildren(...names().map((n) => new Option(n, n, false, n === value)));
		};
		const existing = (items, kind) => items.map((item, index) => [
			el('code', { textContent: item.name }), el('code', {}, highlightSql(item.def)),
			button('✕', () => { items.splice(index, 1); changed(); render(); }, { className: 'danger', title: t('Delete') })]);
		const added = (items, describe) => items.map((item, index) => [
			el('em', { textContent: t('new') }), el('code', { textContent: describe(item) }),
			button('✕', () => { items.splice(index, 1); changed(); render(); }, { title: t('Remove') })]);

		// Новый внешний ключ
		const fk = { column: columnNames.find((n) => n.endsWith('_id')) ?? columnNames[0] ?? '', table: '', ref: 'id', on_delete: 'NO ACTION' };
		const fkForm = el('div', { className: 'toolbar dev-inline' },
			select(columnNames.map((n) => [n, n]), fk.column, (v) => { fk.column = v; },
				{ onfocus: (event) => syncColumns(event.target), onmousedown: (event) => syncColumns(event.target) }),
			el('span', { textContent: '→' }),
			select([['', t('— table —')], ...allTables.map((n) => [n, n]), ['pgerp.users', 'pgerp.users']], '', (v) => {
				fk.table = v;
				fk.ref = v === 'pgerp.users' ? 'login' : 'id';
				refInput.value = fk.ref;
			}),
			el('span', { textContent: '.' }));
		const refInput = input(fk.ref, (v) => { fk.ref = v.trim(); }, { size: 8, spellcheck: false });
		fkForm.append(refInput, el('span', { textContent: t('on delete') }),
			select(ON_DELETE.map((v) => [v, v]), fk.on_delete, (v) => { fk.on_delete = v; }),
			button(t('Add key'), () => {
				if (!fk.column || !fk.table) {
					showMessage(t('Select a column and a table'), 'error');
					return;
				}
				tb.new_fks.push({ columns: [fk.column], ref_table: fk.table, ref_columns: fk.ref ? [fk.ref] : [], on_delete: fk.on_delete });
				changed();
				render();
			}));

		// Новый индекс, уникальность, проверка
		const idx = { columns: '', unique: false };
		const idxForm = el('div', { className: 'toolbar dev-inline' },
			input('', (v) => { idx.columns = v; }, { placeholder: t('comma-separated columns'), spellcheck: false, list: 'dev-columns-list', onfocus: () => refreshHints() }),
			el('label', { className: 'dev-check' }, checkbox(false, (v) => { idx.unique = v; }), t('unique')),
			button(t('Add index'), () => {
				const cols = idx.columns.split(',').map((c) => c.trim()).filter(Boolean);
				if (!cols.length) {
					return;
				}
				tb.new_indexes.push({ columns: cols, unique: idx.unique });
				changed();
				render();
			}),
			el('datalist', { id: 'dev-columns-list' }, ...columnNames.map((n) => el('option', { value: n }))));
		// Подсказки индексов и уникальности — тоже по текущим колонкам
		const refreshHints = () => idxForm.querySelector('datalist').replaceChildren(...names().map((n) => el('option', { value: n })));
		const check = { expression: '' };
		const checkForm = el('div', { className: 'toolbar dev-inline' },
			input('', (v) => { check.expression = v; }, { placeholder: 'amount >= 0', spellcheck: false }),
			button(t('Add check'), () => {
				if (!check.expression.trim()) {
					return;
				}
				tb.new_checks.push({ expression: check.expression.trim() });
				changed();
				render();
			}));
		const uniq = { columns: '' };
		const uniqForm = el('div', { className: 'toolbar dev-inline' },
			input('', (v) => { uniq.columns = v; }, { placeholder: t('comma-separated columns'), spellcheck: false, list: 'dev-columns-list', onfocus: () => refreshHints() }),
			button(t('Add unique'), () => {
				const cols = uniq.columns.split(',').map((c) => c.trim()).filter(Boolean);
				if (!cols.length) {
					return;
				}
				tb.new_uniques.push({ columns: cols });
				changed();
				render();
			}));

		const rows = (items) => (items.length ? table(['', '', ''], items, 'dev-keys') : null);
		return el('div', { className: 'dev-keys-grid' },
			section(t('Foreign keys'),
				rows([...existing(tb.foreign_keys), ...added(tb.new_fks, (f) => `${f.columns.join(', ')} → ${f.ref_table}(${f.ref_columns.join(', ')}) ${f.on_delete}`)]),
				fkForm),
			section(t('Indexes'),
				rows([...existing(tb.indexes), ...added(tb.new_indexes, (i) => `${i.unique ? 'UNIQUE ' : ''}(${i.columns.join(', ')})`)]),
				idxForm),
			section(t('Unique'),
				rows([...existing(tb.uniques), ...added(tb.new_uniques, (u) => `UNIQUE (${u.columns.join(', ')})`)]),
				uniqForm),
			section(t('Checks'),
				rows([...existing(tb.checks), ...added(tb.new_checks, (c) => `CHECK (${c.expression})`)]),
				checkForm));
	}

	function renderInfo() {
		const tb = current;
		if (tb.is_new) {
			return null;
		}
		return section(t('Relations'),
			tb.triggers.length ? el('div', {}, el('strong', { textContent: t('Triggers: ') }),
				...tb.triggers.map((g) => el('code', { className: 'dev-chip', textContent: g.name, title: g.def }))) : null,
			tb.referenced_by.length ? el('div', {}, el('strong', { textContent: t('Referenced by: ') }),
				...tb.referenced_by.map((r) => el('code', { className: 'dev-chip', textContent: `${r.table} (${r.name})` }))) : null,
			!tb.triggers.length && !tb.referenced_by.length ? hint(t('No triggers or references from other tables')) : null,
			hint(t('Triggers and complex changes (generated columns, partitions) — via the SQL console.')));
	}

	function moveColumn(index, delta) {
		const [column] = current.columns.splice(index, 1);
		current.columns.splice(index + delta, 0, column);
		changed();
		render();
	}

	function tablePayload(apply) {
		const tb = current;
		return {
			is_new: tb.is_new,
			name: tb.name,
			old_name: tb.orig_name,
			solution: tb.solution,
			comment: tb.comment,
			columns: tb.columns.map((c) => ({ name: c.name, old_name: c.orig, type: c.type, not_null: c.not_null, default: c.default, comment: c.comment })),
			primary_key: tb.columns.filter((c) => c.pk).map((c) => c.name),
			foreign_keys: [...tb.foreign_keys.map((f) => ({ name: f.name })), ...tb.new_fks],
			uniques: [...tb.uniques.map((u) => ({ name: u.name })), ...tb.new_uniques],
			checks: [...tb.checks.map((c) => ({ name: c.name })), ...tb.new_checks],
			indexes: [...tb.indexes.map((i) => ({ name: i.name })), ...tb.new_indexes],
			apply,
		};
	}

	/** Предпросмотр SQL; withApply — с кнопкой «Применить». */
	async function saveTable(withApply) {
		try {
			const preview = await callAction('table_save', tablePayload(false));
			if (!preview.statements.length) {
				showMessage(t('No changes'));
				return;
			}
			const sql = preview.statements.join('\n\n');
			const destructive = /DROP (COLUMN|TABLE)|ALTER COLUMN .* TYPE/i.test(sql);
			const answer = await showSql(t('Changes to table {0}', preview.name), sql, {
				note: destructive ? t('Attention: dropping columns and changing types cannot be undone for the data.') : '',
				actions: withApply ? [{ text: t('Apply'), primary: !destructive, danger: destructive }] : [],
			});
			if (!answer) {
				return;
			}
			const result = await callAction('table_save', tablePayload(true));
			dirty = false;
			await open({ kind: 'table', name: result.name });
			showMessage(result.message ?? t('Table saved'));
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	// -----------------------------------------------------------------
	// Представление
	// -----------------------------------------------------------------
	function renderView() {
		const v = current;
		const code = codeArea({ value: v.sql, highlight: highlightSql, label: t('View query'), onInput: () => { v.sql = code.textarea.value; changed(); } });
		code.element.classList.add('dev-view-code');
		code.element.addEventListener('keydown', (event) => {
			if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
				event.preventDefault();
				saveView(true);
			}
		});
		const toolbar = el('div', { className: 'toolbar' },
			el('h3', { className: 'report-heading', textContent: v.is_new ? t('New view') : v.orig_name }), spacer(), dirtyMark,
			button(t('Data'), () => openConsole(`SELECT *\nFROM ${v.orig_name}\nLIMIT 100`), { disabled: v.is_new }),
			button(t('SQL'), () => saveView(false), { title: t('Show the SQL of the changes without applying it') }),
			button(t('Delete'), () => drop('view', v.orig_name), { className: 'danger', disabled: v.is_new }),
			button(t('Save'), () => saveView(true), { className: 'primary', title: t('Ctrl+S') }));
		const props = el('div', { className: 'report-fields dev-fields' },
			field(t('Name'), input(v.name, (value) => { v.name = value.trim(); changed(); }, { spellcheck: false }),
				t('For lists — usually <table>_v')),
			solutionField(),
			field(t('Comment'), input(v.comment, (value) => { v.comment = value || null; changed(); })));
		return [toolbar, props, code.element,
			v.columns ? hint(t('Columns: {0}', v.columns.map((c) => `${c.name} ${c.type}`).join(', '))) : null,
			v.dependents?.length ? hint(t('Depend on the view: {0}', v.dependents.join(', '))) : null,
			v.materialized ? hint(t('Materialized view: it is recreated on save.')) : null];
	}

	async function saveView(withApply) {
		const v = current;
		const payload = { is_new: v.is_new, name: v.name, old_name: v.orig_name, sql: v.sql, comment: v.comment, solution: v.solution };
		try {
			const preview = await callAction('view_save', { ...payload, apply: false });
			if (!await showSql(t('View {0}', preview.name), preview.statements.join('\n\n'),
				{ actions: withApply ? [{ text: t('Apply'), primary: true }] : [] })) {
				return;
			}
			const result = await callAction('view_save', { ...payload, apply: true });
			dirty = false;
			await open({ kind: 'view', name: result.name });
			showMessage(result.message);
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	// -----------------------------------------------------------------
	// Удаление
	// -----------------------------------------------------------------
	async function drop(type, name) {
		try {
			const preview = await callAction('object_drop', { type, name });
			const note = preview.dependents.length
				? t('Depend on the object: {0}. Deleting with CASCADE removes them too.', preview.dependents.join('; '))
				: (type === 'table' ? t('The table is deleted together with its data.') : '');
			const answer = await showSql(t('Delete {0}?', name), preview.statements.join('\n'), {
				note,
				actions: [{ text: t('Delete'), danger: true }, ...preview.dependents.length ? [{ text: t('Delete with dependents'), danger: true }] : []],
			});
			if (!answer) {
				return;
			}
			const result = await callAction('object_drop', { type, name, apply: true, cascade: answer === t('Delete with dependents') });
			dirty = false;
			await open({});
			showMessage(result.message);
		}
		catch (e) {
			showMessage(e.message, 'error');
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
	};
}
