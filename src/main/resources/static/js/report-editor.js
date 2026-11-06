import { callAction, csrfHeaders, showMessage } from './ui-runtime.js';
import { codeArea, highlightXml, openFunctionEditor } from './code-editor.js';
import { pdfFromResponse, showPdf } from './report-viewer.js';
import { language, t } from './i18n.js';

/**
 * Редактор отчётов PDF (editor.html?reports=<имя>): шаблон jrxml выбранного отчёта. Список отчётов —
 * в боковой панели редактора, под пунктом «Отчёты» (её рисует editor.html).
 * У отчёта — имя (для ui_report), название, действие с функцией данных («{ }» — правка её кода
 * или заготовка), параметры предпросмотра и шаблон JasperReports 7. «Предпросмотр» заполняет
 * несохранённый шаблон данными; «Сохранить» сначала компилирует шаблон на сервере.
 * jrxml можно загрузить из файла (Jaspersoft Studio) и скачать обратно.
 *
 * root — контейнер редактора; onNavigate(name) — открыт другой отчёт (пусто — новый);
 * onChanged() — отчёт сохранён или удалён: список отчётов нужно перечитать.
 * Возвращает { open(name), dirty, name }.
 */
export function createReportEditor(root, { onNavigate = () => {}, onChanged = () => {} } = {}) {
	let actions = [];
	let report = null;   // {is_new, name, title, data_action, sample_params, jrxml}
	let paramsText = '{}';
	let dirty = false;

	// -----------------------------------------------------------------
	// Разметка
	// -----------------------------------------------------------------
	const newButton = button(t('+ New report'), () => guard(() => open('')));
	const canvas = document.createElement('section');
	canvas.className = 'editor-canvas report-canvas';
	const toolbar = document.createElement('div');
	toolbar.className = 'toolbar';
	const title = document.createElement('h3');
	title.className = 'report-heading';
	const dirtyMark = document.createElement('span');
	dirtyMark.className = 'editor-dirty';
	dirtyMark.title = t('There are unsaved changes');
	dirtyMark.textContent = t('● Not saved');
	dirtyMark.hidden = true;
	const fileInput = document.createElement('input');
	fileInput.type = 'file';
	fileInput.accept = '.jrxml,.xml,text/xml';
	fileInput.hidden = true;
	fileInput.addEventListener('change', loadFile);
	const uploadButton = button(t('Upload jrxml'), () => fileInput.click(), false,
		t('Replace the template with a .jrxml file, e.g. from Jaspersoft Studio (JasperReports 7 format)'));
	const downloadButton = button(t('Download jrxml'), downloadFile);
	const deleteButton = button(t('Delete'), remove);
	deleteButton.className = 'danger';
	const previewButton = button(t('Preview'), preview, false, t('Fill the template with data using the preview parameters (Ctrl+Enter)'));
	const saveButton = button(t('Save'), save, false, t('Ctrl+S'));
	saveButton.className = 'primary';
	toolbar.append(title, spacer(), dirtyMark, newButton, fileInput, uploadButton, downloadButton, deleteButton, previewButton, saveButton);

	const fields = document.createElement('div');
	fields.className = 'report-fields';
	const nameInput = input((v) => { report.name = v.trim(); changed(); });
	nameInput.spellcheck = false;
	const titleInput = input((v) => { report.title = v; changed(); });
	const actionSelect = document.createElement('select');
	actionSelect.addEventListener('change', () => { report.data_action = actionSelect.value || null; changed(); });
	const codeButton = button('{ }', () => editDataFunction().catch((e) => showMessage(e.message, 'error')), false,
		t('Data function code: open it or create a template'));
	const actionCell = document.createElement('span');
	actionCell.className = 'action-cell';
	actionCell.append(actionSelect, codeButton);
	const paramsInput = input((v) => { paramsText = v; changed(); });
	paramsInput.spellcheck = false;
	paramsInput.placeholder = '{"id": 1}';
	fields.append(
		field(t('Name'), nameInput, t('For ui_report: Latin letters, digits and _')),
		field(t('Title'), titleInput, t('Window title and file name')),
		field(t('Data'), actionCell, t('The action whose function returns parameters and rows')),
		field(t('Preview parameters'), paramsInput, t('JSON for the data function, as in ui_report')));

	const error = document.createElement('pre');
	error.className = 'function-error report-error';
	error.setAttribute('role', 'alert');
	error.hidden = true;
	const status = document.createElement('span');
	status.className = 'function-status';
	status.setAttribute('role', 'status');
	toolbar.insertBefore(status, dirtyMark);

	const code = codeArea({ highlight: highlightXml, label: t('Report template (jrxml)'), onInput: () => {
		report.jrxml = code.textarea.value;
		changed();
	} });
	code.element.classList.add('report-code');
	canvas.append(toolbar, fields, error, code.element);
	root.replaceChildren(canvas);

	root.addEventListener('keydown', (event) => {
		if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
			event.preventDefault();
			save();
		}
		else if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
			event.preventDefault();
			preview();
		}
	});

	// -----------------------------------------------------------------
	// Загрузка, сохранение, предпросмотр
	// -----------------------------------------------------------------
	/** Открыть отчёт по имени; пустое имя — новый отчёт по заготовке. */
	async function open(name) {
		actions = (await callAction('report_list')).actions;
		const result = await callAction('report_get', name ? { name } : {});
		report = result.report;
		paramsText = JSON.stringify(report.sample_params ?? {});
		setDirty(false);
		status.textContent = '';
		error.hidden = true;
		render();
		code.setValue(report.jrxml);
		onNavigate(report.is_new ? '' : report.name);
	}

	function payload() {
		return {
			is_new: report.is_new,
			name: report.name,
			title: report.title,
			data_action: report.data_action,
			sample_params: parseParams(),
			jrxml: code.textarea.value,
		};
	}

	function parseParams() {
		try {
			const value = JSON.parse(paramsText.trim() || '{}');
			if (value === null || typeof value !== 'object' || Array.isArray(value)) {
				throw new Error();
			}
			return value;
		}
		catch {
			throw new Error(t('Preview parameters must be a JSON object, e.g. {"id": 1}'));
		}
	}

	async function post(url, body) {
		return fetch(url, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'Accept-Language': language(), ...csrfHeaders() },
			body: JSON.stringify(body),
		});
	}

	function showError(message) {
		error.textContent = message;
		error.hidden = false;
	}

	async function save() {
		error.hidden = true;
		saveButton.disabled = true;
		try {
			const response = await post('api/reports/save', payload());
			const result = await response.json().catch(() => ({ message: `HTTP ${response.status}` }));
			if (!response.ok || result.status === 'error') {
				throw new Error(result.kind === 'report'
					? t('Report template error: {0}', result.message) : result.message);
			}
			await open(result.name);
			status.textContent = t('Saved');
			onChanged();
		}
		catch (e) {
			showError(e.message);
		}
		finally {
			saveButton.disabled = false;
		}
	}

	async function preview() {
		error.hidden = true;
		previewButton.disabled = true;
		try {
			const body = payload();
			const response = await post('api/reports/preview', {
				data_action: body.data_action,
				params: body.sample_params,
				jrxml: body.jrxml,
				title: body.title,
			});
			showPdf(await pdfFromResponse(response), `${report.title || report.name || t('Report')} — ${t('preview')}`);
		}
		catch (e) {
			showError(e.message);
		}
		finally {
			previewButton.disabled = false;
		}
	}

	async function remove() {
		if (report.is_new || !confirm(t('Delete report “{0}”?', report.title || report.name))) {
			return;
		}
		try {
			await callAction('report_delete', { name: report.name });
			await open('');
			onChanged();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	/** Функция данных: код выбранного действия или заготовка «<имя отчёта>_data». */
	async function editDataFunction() {
		const request = report.data_action ? { action: report.data_action } : {
			form: report.name || 'report',
			component: 'data',
			type: 'report',
			label: report.title || report.name || t('Report'),
		};
		const { function: fn } = await callAction('function_get', request);
		openFunctionEditor(fn, async (name) => {
			if (report.data_action !== name) {
				actions = (await callAction('report_list')).actions;
				report.data_action = name;
				changed();
				render();
			}
		});
	}

	async function loadFile() {
		const file = fileInput.files[0];
		fileInput.value = '';
		if (file) {
			code.setValue(await file.text());
			report.jrxml = code.textarea.value;
			changed();
		}
	}

	function downloadFile() {
		const link = document.createElement('a');
		link.href = URL.createObjectURL(new Blob([code.textarea.value], { type: 'application/xml' }));
		link.download = `${report.name || 'report'}.jrxml`;
		link.click();
		setTimeout(() => URL.revokeObjectURL(link.href), 1000);
	}

	function setDirty(value) {
		dirty = value;
		dirtyMark.hidden = !dirty;
		if (dirty) {
			status.textContent = '';
		}
	}

	function changed() {
		setDirty(true);
		title.textContent = report.title || report.name || t('New report');
	}

	/** Несохранённые изменения — переспросить. */
	async function guard(action) {
		if (!dirty || confirm(t('There are unsaved changes. Continue without saving?'))) {
			await action().catch((e) => showMessage(e.message, 'error'));
		}
	}

	// -----------------------------------------------------------------
	// Отрисовка
	// -----------------------------------------------------------------
	function render() {
		title.textContent = report.title || report.name || t('New report');
		nameInput.value = report.name;
		nameInput.disabled = !report.is_new;
		titleInput.value = report.title;
		actionSelect.replaceChildren(new Option(t('— no data —'), ''),
			...actions.map((a) => new Option(a.description ? `${a.name} — ${a.description}` : a.name, a.name)));
		actionSelect.value = report.data_action ?? '';
		paramsInput.value = paramsText;
		deleteButton.disabled = report.is_new;
	}

	// -----------------------------------------------------------------
	// Элементы
	// -----------------------------------------------------------------
	function field(caption, control, help) {
		const wrapper = document.createElement('label');
		wrapper.className = 'erp-field';
		const span = document.createElement('span');
		span.textContent = caption;
		wrapper.append(span, control);
		if (help) {
			const hint = document.createElement('p');
			hint.className = 'editor-hint';
			hint.textContent = help;
			wrapper.append(hint);
		}
		return wrapper;
	}

	function input(onInput) {
		const element = document.createElement('input');
		element.addEventListener('input', () => onInput(element.value));
		return element;
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

	function spacer() {
		const element = document.createElement('span');
		element.className = 'spacer';
		return element;
	}

	return {
		open,
		get dirty() {
			return dirty;
		},
		/** Имя открытого отчёта; пусто — новый. */
		get name() {
			return report && !report.is_new ? report.name : '';
		},
	};
}
