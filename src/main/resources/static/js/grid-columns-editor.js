import { callAction } from './ui-runtime.js';
import { language, t } from './i18n.js';

/**
 * Окно «Колонки таблицы» в редакторе форм: какие поля источника показывать, в каком порядке,
 * с какими заголовками и форматом, по каким можно сортировать. Колонки принадлежат действию-источнику
 * (pgerp.grid_columns), поэтому меняются во всех формах с этим источником — окно их перечисляет.
 * Сохраняется сразу, отдельно от формы (действие grid_columns_save).
 */
export async function openGridColumnsEditor(action) {
	const data = await callAction('grid_columns_get', { action });
	const fields = data.fields.map((f) => f.name);
	const dataTypes = new Map(data.fields.map((f) => [f.name, f.data_type]));
	let columns = data.columns.map((c) => ({ ...c }));
	let dirty = false;

	const TYPES = [
		['text', t('Text')],
		['number', t('Number')],
		['money', t('Money')],
		['datetime', t('Date and time')],
		['badge', t('Badge')],
	];

	const dialog = document.createElement('dialog');
	dialog.className = 'code-view grid-columns-editor';
	const header = document.createElement('header');
	const title = document.createElement('h3');
	title.textContent = t('Table columns');
	const note = document.createElement('p');
	const formsText = data.forms.map((f) => `${f.title} (${f.name})`).join(', ');
	note.textContent = t('Data source: {0}', action)
		+ (data.forms.length > 1 ? ' · ' + t('columns are shared by forms: {0}', formsText) : '');
	header.append(title, note);

	const table = document.createElement('table');
	table.className = 'grid-columns-table';
	const tbody = document.createElement('tbody');
	const head = document.createElement('thead');
	head.innerHTML = '<tr><th></th><th></th><th></th><th></th><th></th><th></th></tr>';
	[t('Order'), t('Field'), t('Heading'), t('Format'), t('Sorting'), ''].forEach((text, i) => {
		head.rows[0].cells[i].textContent = text;
	});
	table.append(head, tbody);

	const addButton = button(t('+ Column'), () => {
		const free = fields.find((f) => !columns.some((c) => c.field === f));
		columns.push(newColumn(free ?? ''));
		changed();
	});
	const addAllButton = button(t('Add all fields'), () => {
		for (const f of fields.filter((name) => !columns.some((c) => c.field === name))) {
			columns.push(newColumn(f));
		}
		changed();
	});
	const tools = document.createElement('div');
	tools.className = 'toolbar grid-columns-tools';
	const emptyHint = document.createElement('span');
	emptyHint.className = 'editor-hint';
	tools.append(addButton, addAllButton, emptyHint);

	const previewTitle = document.createElement('h4');
	previewTitle.textContent = t('Sample data');
	const preview = document.createElement('div');
	preview.className = 'grid-columns-preview erp-grid';

	const error = document.createElement('p');
	error.className = 'function-error';
	error.setAttribute('role', 'alert');
	error.hidden = true;

	const footer = document.createElement('div');
	footer.className = 'toolbar';
	const status = document.createElement('span');
	status.className = 'function-status';
	status.setAttribute('role', 'status');
	const spacer = document.createElement('span');
	spacer.className = 'spacer';
	const save = button(t('Save'), async () => {
		save.disabled = true;
		error.hidden = true;
		try {
			await callAction('grid_columns_save', {
				action,
				columns: columns.map(({ field, title: caption, type, sort_column: sortColumn }) =>
					({ field, title: caption, type, sort_column: sortColumn })),
			});
			dirty = false;
			status.textContent = t('Saved');
		}
		catch (e) {
			error.textContent = e.message;
			error.hidden = false;
		}
		finally {
			save.disabled = false;
		}
	});
	save.className = 'primary';
	const tryClose = () => {
		if (!dirty || confirm(t('Close without saving? Column changes will be lost.'))) {
			dialog.close();
		}
	};
	const close = button(t('Close'), tryClose);
	footer.append(status, spacer, close, save);

	dialog.addEventListener('cancel', (event) => {
		event.preventDefault();
		tryClose();
	});
	dialog.addEventListener('keydown', (event) => {
		if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
			event.preventDefault();
			save.click();
		}
	});
	dialog.addEventListener('close', () => dialog.remove());

	dialog.append(header, table, tools, previewTitle, preview, error, footer);
	document.body.append(dialog);
	render();
	dialog.showModal();

	// -----------------------------------------------------------------
	function newColumn(field) {
		return { field, title: field, type: suggestType(field), sort_column: field || null };
	}

	/** Формат по типу поля в источнике: время — дата и время, суммы — деньги, числа — число. */
	function suggestType(field) {
		const type = (dataTypes.get(field) ?? '').toLowerCase();
		if (type.startsWith('timestamp')) {
			return 'datetime';
		}
		if (/^(numeric|integer|bigint|smallint|real|double|number)/.test(type)) {
			return /price|amount|total|sum|paid|cost|balance/.test(field) ? 'money' : 'number';
		}
		return 'text';
	}

	function changed() {
		dirty = true;
		status.textContent = '';
		render();
	}

	function render() {
		tbody.replaceChildren(...columns.map((column, index) => {
			const row = document.createElement('tr');
			const order = document.createElement('td');
			order.className = 'grid-columns-order';
			order.append(
				button('↑', () => move(index, -1), index === 0, t('Up')),
				button('↓', () => move(index, 1), index === columns.length - 1, t('Down')));

			const fieldSelect = document.createElement('select');
			const options = [...fields];
			if (column.field && !options.includes(column.field)) {
				options.unshift(column.field);  // поля уже нет в источнике — видно, что колонка устарела
			}
			for (const name of options) {
				const used = name !== column.field && columns.some((c) => c.field === name);
				const option = new Option(fields.includes(name) ? name : `${name} — ${t('not in the source')}`, name, false,
					name === column.field);
				option.disabled = used;
				fieldSelect.add(option);
			}
			fieldSelect.addEventListener('change', () => {
				const old = column.field;
				column.field = fieldSelect.value;
				if (column.title === old || !column.title) {
					column.title = column.field;
				}
				if (column.sort_column === old) {
					column.sort_column = column.field;
				}
				column.type = column.type === suggestType(old) ? suggestType(column.field) : column.type;
				changed();
			});

			const titleInput = document.createElement('input');
			titleInput.value = column.title;
			titleInput.addEventListener('input', () => {
				column.title = titleInput.value;
				dirty = true;
				status.textContent = '';
				renderPreview();
			});

			const typeSelect = document.createElement('select');
			for (const [value, label] of TYPES) {
				typeSelect.add(new Option(label, value, false, value === column.type));
			}
			typeSelect.addEventListener('change', () => { column.type = typeSelect.value; changed(); });

			const sortLabel = document.createElement('label');
			sortLabel.className = 'grid-columns-sort';
			const sortBox = document.createElement('input');
			sortBox.type = 'checkbox';
			sortBox.checked = Boolean(column.sort_column);
			sortBox.title = column.sort_column && column.sort_column !== column.field
				? t('Sorted by field {0}', column.sort_column) : '';
			sortBox.addEventListener('change', () => {
				column.sort_column = sortBox.checked ? column.field : null;
				changed();
			});
			sortLabel.append(sortBox);

			const removeButton = button('✕', () => { columns.splice(index, 1); changed(); }, false, t('Remove column'));
			removeButton.className = 'danger';

			for (const control of [order, fieldSelect, titleInput, typeSelect, sortLabel, removeButton]) {
				const cell = control.tagName === 'TD' ? control : document.createElement('td');
				if (cell !== control) {
					cell.append(control);
				}
				row.append(cell);
			}
			return row;
		}));
		addButton.disabled = fields.length > 0 && fields.every((f) => columns.some((c) => c.field === f));
		addAllButton.disabled = addButton.disabled || fields.length === 0;
		emptyHint.textContent = columns.length === 0
			? t('Without columns the table shows all row fields as is')
			: '';
		renderPreview();
	}

	/** Заголовки и первые строки источника — как будет выглядеть таблица. */
	function renderPreview() {
		const rows = data.sample ?? [];
		const shown = columns.length > 0 ? columns : fields.map((f) => ({ field: f, title: f, type: 'text' }));
		if (shown.length === 0) {
			preview.textContent = t('The source returned no rows — no sample available');
			return;
		}
		const sample = document.createElement('table');
		const headRow = sample.createTHead().insertRow();
		for (const column of shown) {
			const th = document.createElement('th');
			th.textContent = column.title;
			th.className = `cell-${column.type}`;
			headRow.append(th);
		}
		const body = sample.createTBody();
		for (const source of rows) {
			const tr = body.insertRow();
			for (const column of shown) {
				const td = tr.insertCell();
				td.textContent = format(source[column.field], column.type);
				td.className = `cell-${column.type}`;
			}
		}
		if (rows.length === 0) {
			const td = body.insertRow().insertCell();
			td.colSpan = shown.length;
			td.className = 'editor-hint';
			td.textContent = t('The source returned no rows — no sample available');
		}
		preview.replaceChildren(sample);
	}

	function format(value, type) {
		if (value === null || value === undefined) {
			return '';
		}
		if (type === 'money' && !Number.isNaN(Number(value))) {
			return Number(value).toLocaleString(language(), { minimumFractionDigits: 2, maximumFractionDigits: 2 });
		}
		if (type === 'datetime' && !Number.isNaN(Date.parse(value))) {
			return new Date(value).toLocaleString(language());
		}
		return typeof value === 'object' ? JSON.stringify(value) : String(value);
	}

	function move(index, delta) {
		const [column] = columns.splice(index, 1);
		columns.splice(index + delta, 0, column);
		changed();
	}

	function button(text, onClick, disabled = false, hintText = '') {
		const element = document.createElement('button');
		element.type = 'button';
		element.textContent = text;
		element.disabled = disabled;
		element.title = hintText;
		element.addEventListener('click', onClick);
		return element;
	}
}
