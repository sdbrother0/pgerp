import { callAction, showMessage } from './ui-runtime.js';
import { codeArea, highlightSql } from './code-editor.js';
import { button, checkbox, el, field, hint, input, spacer } from './editor-kit.js';
import { t } from './i18n.js';

const HISTORY_KEY = 'erp-sql-history';
const HISTORY_LIMIT = 20;

/**
 * SQL-консоль (editor.html?console): запросы и скрипты от имени базы (действие sql_run) и проверка действия
 * так, как его вызывает форма, — от имени выбранного пользователя (action_run). Обе вкладки умеют откатывать
 * изменения. Ctrl+Enter — выполнить. Последние запросы хранятся в браузере.
 * Возвращает { open({sql}) }.
 */
export function createSqlConsole(root) {
	let tab = 'sql';
	let rollback = false;
	let maxRows = 200;
	let actionState = { action: '', user: '', data: '{\n    \n}', rollback: true };
	let actions = [];
	let users = [];

	const tabs = el('div', { className: 'erp-tablist dev-tabs', role: 'tablist' });
	const sqlPane = el('div', { className: 'dev-console' });
	const actionPane = el('div', { className: 'dev-console' });
	const canvas = el('section', { className: 'editor-canvas dev-canvas' }, tabs, sqlPane, actionPane);
	root.replaceChildren(canvas);

	// -----------------------------------------------------------------
	// SQL
	// -----------------------------------------------------------------
	const code = codeArea({ value: 'SELECT now();', highlight: highlightSql, label: t('SQL query') });
	code.element.classList.add('dev-console-code');
	const result = el('div', { className: 'dev-result' });
	const status = el('span', { className: 'function-status' });
	const runButton = button(t('Run'), runSql, { className: 'primary', title: t('Ctrl+Enter') });
	const historySelect = el('select', { title: t('Recent queries') });
	historySelect.addEventListener('change', () => {
		if (historySelect.value) {
			code.setValue(historySelect.value);
			historySelect.value = '';
		}
	});
	sqlPane.append(
		el('div', { className: 'toolbar dev-inline' },
			el('label', { className: 'dev-check', title: t('Run and roll back: handy for checking data changes') },
				checkbox(rollback, (v) => { rollback = v; }), t('Roll back after running')),
			el('label', { className: 'dev-check' }, t('Row limit'),
				input(String(maxRows), (v) => { maxRows = Number(v) || 200; }, { type: 'number', min: 1, max: 5000, className: 'dev-number' })),
			historySelect, spacer(), status, runButton),
		code.element,
		hint(t('Runs as the database with administrator rights — be careful with data changes. A multi-statement script runs as a whole; rows are shown only for a single query.')),
		result);
	code.element.addEventListener('keydown', (event) => {
		if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
			event.preventDefault();
			runSql();
		}
	});

	function history() {
		return JSON.parse(localStorage.getItem(HISTORY_KEY) ?? '[]');
	}

	function renderHistory() {
		historySelect.replaceChildren(new Option(t('History…'), ''),
			...history().map((sql) => new Option(sql.replace(/\s+/g, ' ').slice(0, 80), sql)));
	}

	function remember(sql) {
		localStorage.setItem(HISTORY_KEY, JSON.stringify([sql, ...history().filter((s) => s !== sql)].slice(0, HISTORY_LIMIT)));
		renderHistory();
	}

	async function runSql() {
		const sql = code.textarea.value;
		if (!sql.trim()) {
			return;
		}
		runButton.disabled = true;
		status.textContent = '';
		try {
			const r = await callAction('sql_run', { sql, rollback, max_rows: maxRows });
			remember(sql);
			renderResult(r);
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
		finally {
			runButton.disabled = false;
		}
	}

	function renderResult(r) {
		const info = [];
		if (r.error) {
			result.replaceChildren(el('pre', { className: 'function-error', textContent: [
				r.error.message, r.error.detail && `${t('Details')}: ${r.error.detail}`, r.error.hint && `${t('Hint')}: ${r.error.hint}`,
				r.error.context, `SQLSTATE ${r.error.sqlstate}`].filter(Boolean).join('\n') }));
			status.textContent = '';
			return;
		}
		info.push(r.mode === 'rows'
			? t('Rows: {0}{1}', r.row_count, r.truncated ? t(' (first {0} shown)', r.rows.length) : '')
			: t('Done. Rows affected: {0}', r.row_count));
		info.push(t('{0} ms', r.duration_ms));
		if (r.rolled_back) {
			info.push(t('changes rolled back'));
		}
		status.textContent = info.join(' · ');
		if (r.mode !== 'rows') {
			result.replaceChildren();
			return;
		}
		const cell = (value) => {
			if (value === null) {
				return el('td', { className: 'dev-null', textContent: 'NULL' });
			}
			const text = typeof value === 'object' ? JSON.stringify(value) : String(value);
			return el('td', { textContent: text.length > 300 ? `${text.slice(0, 300)}…` : text, title: text.length > 300 ? text : '' });
		};
		result.replaceChildren(el('div', { className: 'dev-result-scroll' }, el('table', { className: 'dev-table dev-rows' },
			el('thead', {}, el('tr', {}, ...r.columns.map((c) => el('th', { textContent: c })))),
			el('tbody', {}, ...r.rows.map((row) => el('tr', {}, ...row.map(cell)))))));
	}

	// -----------------------------------------------------------------
	// Действие
	// -----------------------------------------------------------------
	const actionResult = el('div', { className: 'dev-result' });
	const dataArea = codeArea({ value: actionState.data, highlight: highlightSql, label: t('Action data (JSON)'), onInput: () => { actionState.data = dataArea.textarea.value; } });
	dataArea.element.classList.add('dev-json-code');
	const actionInput = input('', (v) => { actionState.action = v.trim(); }, { list: 'dev-actions', spellcheck: false, placeholder: 'my_app_items_page' });
	const userInput = input('', (v) => { actionState.user = v.trim(); }, { list: 'dev-users', spellcheck: false, placeholder: t('current') });
	const actionsList = el('datalist', { id: 'dev-actions' });
	const usersList = el('datalist', { id: 'dev-users' });
	const runAction = button(t('Call'), callTestAction, { className: 'primary', title: t('Ctrl+Enter') });
	actionPane.append(
		el('div', { className: 'report-fields dev-fields' },
			field(t('Action'), actionInput, t('Like a form button: the handler receives the field values')),
			field(t('As user'), userInput, t('This user\'s role permissions; empty — you')),
			field(t('Rollback'), el('label', { className: 'dev-check' },
				checkbox(actionState.rollback, (v) => { actionState.rollback = v; }), t('Roll back changes')), ''),
			el('div', { className: 'toolbar dev-inline' }, spacer(), runAction)),
		actionsList, usersList,
		field(t('Data (JSON): form field values, for example {"id": "5"} or {"page": 1, "limit": 10}'), dataArea.element),
		actionResult);
	dataArea.element.addEventListener('keydown', (event) => {
		if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
			event.preventDefault();
			callTestAction();
		}
	});

	async function callTestAction() {
		let data;
		try {
			data = JSON.parse(actionState.data.trim() || '{}');
		}
		catch {
			showMessage(t('Data is a JSON object, for example {"id": "5"}'), 'error');
			return;
		}
		runAction.disabled = true;
		try {
			const r = await callAction('action_run', { action: actionState.action, user: actionState.user, data, rollback: actionState.rollback });
			const response = r.error ? null : r.response;
			actionResult.replaceChildren(...[
				hint(t('User: {0}{1}', r.user, r.rolled_back ? t(' · changes rolled back') : '')),
				r.error ? el('pre', { className: 'function-error', textContent: r.error.message })
					: response?.status === 'error'
						? el('pre', { className: 'function-error', textContent: response.message })
						: null,
				response ? el('pre', { className: 'dev-sql dev-json', textContent: JSON.stringify(response, null, 2) }) : null].filter(Boolean));
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
		finally {
			runAction.disabled = false;
		}
	}

	// -----------------------------------------------------------------
	// Вкладки
	// -----------------------------------------------------------------
	function renderTabs() {
		const tabButton = (id, text) => {
			const b = button(text, () => { tab = id; renderTabs(); }, { className: 'erp-tab' });
			b.setAttribute('role', 'tab');
			b.setAttribute('aria-selected', String(tab === id));
			return b;
		};
		tabs.replaceChildren(tabButton('sql', t('SQL')), tabButton('action', t('Action test')));
		sqlPane.hidden = tab !== 'sql';
		actionPane.hidden = tab !== 'action';
	}

	async function open({ sql } = {}) {
		if (sql) {
			tab = 'sql';
			code.setValue(sql);
		}
		renderTabs();
		renderHistory();
		const [forms, tokens] = await Promise.all([callAction('form_list'), callAction('mcp_tokens_list')]);
		actions = forms.actions;
		users = tokens.users;
		actionsList.replaceChildren(...actions.map((a) => el('option', { value: a.name, label: a.description ?? '' })));
		usersList.replaceChildren(...users.map((u) => el('option', { value: u.login, label: u.name })));
		if (sql) {
			await runSql();
		}
		code.textarea.focus();
	}

	return { open };
}
