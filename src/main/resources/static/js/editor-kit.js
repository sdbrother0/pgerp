// Общие элементы разделов редактора «Решения», «Схема данных», «SQL-консоль» и «Доступ MCP».

import { highlightSql } from './code-editor.js';
import { t } from './i18n.js';

/** Элемент: el('div', {className: 'x', onclick}, 'текст', другойЭлемент). */
export function el(tag, props = {}, ...children) {
	const element = document.createElement(tag);
	for (const [key, value] of Object.entries(props ?? {})) {
		if (value === undefined || value === null) {
			continue;
		}
		if (key.startsWith('on') && typeof value === 'function') {
			element.addEventListener(key.slice(2), value);
		}
		else if (key === 'dataset') {
			Object.assign(element.dataset, value);
		}
		else if (key in element) {
			try {
				element[key] = value;
			}
			catch {
				// Свойства только для чтения (list у input) задаются атрибутом
				element.setAttribute(key, value);
			}
		}
		else {
			element.setAttribute(key, value);
		}
	}
	element.append(...children.flat().filter((child) => child !== null && child !== undefined && child !== false));
	return element;
}

export function button(text, onClick, { title = '', className = '', disabled = false } = {}) {
	return el('button', { type: 'button', textContent: text, title, className, disabled, onclick: onClick });
}

export function spacer() {
	return el('span', { className: 'spacer' });
}

export function hint(text) {
	return el('p', { className: 'editor-hint', textContent: text });
}

/** Поле с подписью и подсказкой. */
export function field(caption, control, help) {
	return el('label', { className: 'erp-field' }, el('span', { textContent: caption }), control, help ? hint(help) : null);
}

export function input(value, onInput, props = {}) {
	const element = el('input', { value: value ?? '', ...props });
	element.addEventListener('input', () => onInput(element.value));
	return element;
}

export function checkbox(checked, onChange, props = {}) {
	const element = el('input', { type: 'checkbox', checked: Boolean(checked), ...props });
	element.addEventListener('change', () => onChange(element.checked));
	return element;
}

/** Выпадающий список: options — [[значение, текст]]. */
export function select(options, value, onChange, props = {}) {
	const element = el('select', props);
	for (const [optionValue, text] of options) {
		element.add(new Option(text, optionValue, false, String(optionValue) === String(value ?? '')));
	}
	element.addEventListener('change', () => onChange(element.value));
	return element;
}

export function section(title, ...children) {
	return el('section', { className: 'dev-section' }, el('h4', { textContent: title }), ...children);
}

/** Таблица: columns — заголовки, rows — массивы ячеек (текст или элементы). */
export function table(columns, rows, className = '') {
	return el('table', { className: `dev-table ${className}` },
		el('thead', {}, el('tr', {}, ...columns.map((c) => el('th', { textContent: c })))),
		el('tbody', {}, ...rows.map((cells) => el('tr', {}, ...cells.map((c) => el('td', {},
			c instanceof Node ? c : String(c ?? '')))))));
}

/** SQL с подсветкой — только для чтения. */
export function sqlBlock(text) {
	return el('pre', { className: 'dev-sql' }, el('code', {}, highlightSql(text ?? '')));
}

/** Скачать текст файлом. */
export function downloadText(fileName, text, type = 'application/sql') {
	const link = el('a', { href: URL.createObjectURL(new Blob([text], { type: `${type};charset=utf-8` })), download: fileName });
	link.click();
	setTimeout(() => URL.revokeObjectURL(link.href), 1000);
}

/** Кнопка «Копировать»: после копирования — «Скопировано». */
export function copyButton(text, caption = t('Copy')) {
	const element = button(caption, async () => {
		await navigator.clipboard.writeText(typeof text === 'function' ? text() : text);
		element.textContent = t('Copied');
		setTimeout(() => { element.textContent = caption; }, 1500);
	});
	return element;
}

/**
 * Окно SQL: заголовок, пояснение, текст с подсветкой; actions — дополнительные кнопки [{text, primary, onClick}].
 * Возвращает Promise, который разрешается текстом нажатой кнопки или null (закрыто).
 */
export function showSql(title, sql, { note = '', fileName = null, actions = [] } = {}) {
	return new Promise((resolve) => {
		const dialog = el('dialog', { className: 'code-view' });
		const close = (value) => {
			dialog.close();
			resolve(value);
		};
		const footer = el('div', { className: 'toolbar' }, spacer(), copyButton(sql),
			fileName ? button(t('Download'), () => downloadText(fileName, sql)) : null,
			...actions.map((action) => button(action.text, () => close(action.text), { className: action.primary ? 'primary' : (action.danger ? 'danger' : '') })),
			button(actions.length ? t('Cancel') : t('Close'), () => close(null), { className: actions.length ? '' : 'primary' }));
		dialog.append(el('header', {}, el('h3', { textContent: title }), note ? el('p', { textContent: note }) : null),
			el('pre', {}, el('code', {}, highlightSql(sql))), footer);
		dialog.addEventListener('close', () => {
			dialog.remove();
			resolve(null);
		});
		document.body.append(dialog);
		dialog.showModal();
	});
}

/** Подпись типа объекта решения. */
export function objectTypeLabel(type) {
	return {
		table: t('Table'), view: t('View'), sequence: t('Sequence'), function: t('Function'),
		type: t('Type'), form: t('Form'), action: t('Action'), report: t('Report'), role: t('Role'),
	}[type] ?? type;
}

/** Дата и время для списков. */
export function formatTime(value) {
	return value ? new Date(value).toLocaleString(document.documentElement.lang || undefined,
		{ dateStyle: 'short', timeStyle: 'short' }) : '';
}
