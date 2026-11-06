// Редактор кода: подсветка SQL и XML, поле правки с подсветкой и окно правки функции действия.
// Используется редактором форм (функции действий) и редактором отчётов (jrxml, функция данных).

import { callAction } from './ui-runtime.js';
import { t } from './i18n.js';

function field(caption, control) {
	const wrapper = document.createElement('label');
	wrapper.className = 'erp-field';
	const span = document.createElement('span');
	span.textContent = caption;
	wrapper.append(span, control);
	return wrapper;
}

function selectBox(options, value, onChange) {
	const element = document.createElement('select');
	for (const [optionValue, text] of options) {
		element.add(new Option(text, optionValue, false, optionValue === (value ?? '')));
	}
	element.addEventListener('change', () => onChange(element.value));
	return element;
}

function input(value, onInput) {
	const element = document.createElement('input');
	element.value = value ?? '';
	element.addEventListener('input', () => onInput(element.value));
	return element;
}

function button(text, onClick, disabled = false, title = '') {
	const element = document.createElement('button');
	element.type = 'button';
	element.textContent = text;
	element.disabled = disabled;
	element.title = title;
	element.addEventListener('click', onClick);
	return element;
}

// -----------------------------------------------------------------
// Подсветка SQL
// -----------------------------------------------------------------
const SQL_KEYWORDS = 'CREATE|OR|REPLACE|FUNCTION|RETURNS|RETURN|RETURNING|LANGUAGE|DECLARE|BEGIN|END|IF|THEN|ELSIF|ELSE|CASE|WHEN|'
	+ 'LOOP|WHILE|FOR|FOREACH|EXIT|CONTINUE|IN|NOT|NULL|AND|IS|SELECT|DISTINCT|FROM|WHERE|INTO|STRICT|INSERT|VALUES|UPDATE|SET|'
	+ 'DELETE|ORDER|GROUP|HAVING|BY|LIMIT|OFFSET|AS|ON|JOIN|LEFT|RIGHT|INNER|OUTER|CROSS|LATERAL|UNION|ALL|ANY|BETWEEN|LIKE|ILIKE|'
	+ 'CONFLICT|DO|NOTHING|EXISTS|RAISE|EXCEPTION|NOTICE|USING|ERRCODE|MESSAGE|DETAIL|HINT|FOUND|EXECUTE|PERFORM|GET|DIAGNOSTICS|'
	+ 'WITH|RECURSIVE|ORDINALITY|ASC|DESC|NULLS|FIRST|LAST|TRUE|FALSE|STABLE|IMMUTABLE|VOLATILE|CONSTANT|DEFAULT|ARRAY|ROW|OTHERS|'
	+ 'SQLSTATE|SQLERRM|LOCK|SHARE|NOWAIT|SKIP|LOCKED|FILTER|OVER|PARTITION|WINDOW|INTERVAL|CAST';
const SQL_TYPES = 'JSON|JSONB|TEXT|VARCHAR|CHAR|INT|INTEGER|SMALLINT|BIGINT|NUMERIC|DECIMAL|REAL|BOOLEAN|BOOL|DATE|TIME|'
	+ 'TIMESTAMP|TIMESTAMPTZ|UUID|RECORD|REGPROCEDURE|REGCLASS|BYTEA|SERIAL|BIGSERIAL|VOID|TRIGGER';
/** Порядок групп важен: комментарии и строки поглощают всё внутри себя. */
const SQL_TOKENS = new RegExp([
	/(--[^\n]*|\/\*[\s\S]*?(?:\*\/|$))/.source,       // 1 комментарий (незакрытый — до конца)
	/([EeUu]?'(?:[^']|'')*(?:'|$))/.source,                 // 2 строка
	/(\$[A-Za-z_0-9]*\$)/.source,                          // 3 $$-кавычки
	/("(?:[^"]|"")*(?:"|$))/.source,                         // 4 идентификатор в кавычках — без цвета
	/\b(\d+(?:\.\d+)?)\b/.source,                          // 5 число
	`\\b(${SQL_TYPES})\\b`,                                     // 6 тип
	`\\b(${SQL_KEYWORDS})\\b`,                                  // 7 ключевое слово
	/\b([A-Za-z_][A-Za-z0-9_]*)(?=\s*\()/.source,           // 8 вызов функции
].join('|'), 'gi');
const SQL_CLASSES = [null, 'sql-comment', 'sql-string', 'sql-dollar', null, 'sql-number', 'sql-type', 'sql-keyword', 'sql-function'];

/** Подсветка SQL и PL/pgSQL: комментарии, строки, $$-кавычки, числа, типы, ключевые слова, вызовы функций. */
export function highlightSql(source) {
	const fragment = document.createDocumentFragment();
	let last = 0;
	for (const match of source.matchAll(SQL_TOKENS)) {
		const className = SQL_CLASSES[match.findIndex((group, i) => i > 0 && group !== undefined)];
		if (!className) {
			continue;  // остаётся простым текстом
		}
		fragment.append(source.slice(last, match.index));
		const span = document.createElement('span');
		span.className = className;
		span.textContent = match[0];
		fragment.append(span);
		last = match.index + match[0].length;
	}
	fragment.append(source.slice(last));
	return fragment;
}

// -----------------------------------------------------------------
// Подсветка XML (jrxml): комментарии, CDATA с выражениями отчёта, теги, атрибуты и их значения
// -----------------------------------------------------------------
const XML_TOKENS = /(<!--[\s\S]*?(?:-->|$))|(<!\[CDATA\[)([\s\S]*?)(\]\]>|$)|(<\/?[\w:.-]+)|([\w:.-]+)(?==)|("[^"]*"?|'[^']*'?)|(\/?>)/g;

/** Выражения отчёта в CDATA: $F{поле}, $P{параметр}, $V{переменная}, $R{текст}, строки Java. */
const EXPRESSION_TOKENS = /(\$[FPVR]\{[^}]*\}?)|("(?:[^"\\]|\\.)*"?)/g;

function span(className, text) {
	const element = document.createElement('span');
	element.className = className;
	element.textContent = text;
	return element;
}

function appendTokens(fragment, source, pattern, classify) {
	let last = 0;
	for (const match of source.matchAll(pattern)) {
		fragment.append(source.slice(last, match.index));
		classify(fragment, match);
		last = match.index + match[0].length;
	}
	fragment.append(source.slice(last));
}

export function highlightXml(source) {
	const fragment = document.createDocumentFragment();
	appendTokens(fragment, source, XML_TOKENS, (out, m) => {
		if (m[1] !== undefined) {
			out.append(span('sql-comment', m[1]));
		}
		else if (m[2] !== undefined) {
			out.append(span('sql-dollar', m[2]));
			appendTokens(out, m[3], EXPRESSION_TOKENS, (inner, e) => inner.append(
				span(e[1] !== undefined ? 'sql-function' : 'sql-string', e[0])));
			out.append(span('sql-dollar', m[4]));
		}
		else if (m[5] !== undefined) {
			out.append(span('sql-keyword', m[5]));
		}
		else if (m[6] !== undefined) {
			out.append(span('sql-type', m[6]));
		}
		else if (m[7] !== undefined) {
			out.append(span('sql-string', m[7]));
		}
		else {
			out.append(span('sql-keyword', m[8]));
		}
	});
	return fragment;
}

// -----------------------------------------------------------------
// Поле правки кода с подсветкой
// -----------------------------------------------------------------
/**
 * Прозрачный textarea поверх <pre> с раскрашенным тем же текстом. Tab — четыре пробела.
 * Возвращает { element, textarea, setValue(text) }; onInput вызывается при каждом изменении.
 */
export function codeArea({ value = '', highlight, label, onInput = () => {} }) {
	const element = document.createElement('div');
	element.className = 'function-code';
	const painted = document.createElement('pre');
	painted.className = 'function-highlight';
	painted.setAttribute('aria-hidden', 'true');
	const textarea = document.createElement('textarea');
	textarea.className = 'function-body';
	textarea.value = value;
	textarea.spellcheck = false;
	textarea.wrap = 'off';
	textarea.setAttribute('aria-label', label);
	element.append(painted, textarea);
	const syncScroll = () => {
		painted.scrollTop = textarea.scrollTop;
		painted.scrollLeft = textarea.scrollLeft;
	};
	const paint = () => {
		// Лишняя строка: textarea прокручивается на пустую последнюю строку, <pre> — нет
		painted.replaceChildren(highlight(textarea.value), '\n ');
		syncScroll();
	};
	paint();
	textarea.addEventListener('scroll', syncScroll);
	textarea.addEventListener('input', () => {
		paint();
		onInput();
	});
	textarea.addEventListener('keydown', (event) => {
		if (event.key === 'Tab' && !event.shiftKey) {
			event.preventDefault();
			textarea.setRangeText('    ', textarea.selectionStart, textarea.selectionEnd, 'end');
			paint();
			onInput();
		}
	});
	return {
		element,
		textarea,
		/** Новый текст целиком: курсор и прокрутка — в начало. */
		setValue(text) {
			textarea.value = text;
			textarea.setSelectionRange(0, 0);
			textarea.scrollTop = 0;
			textarea.scrollLeft = 0;
			paint();
		},
	};
}

// -----------------------------------------------------------------
// Окно правки функции действия
// -----------------------------------------------------------------
/**
 * Окно кода функции. Правится тело; заголовок CREATE FUNCTION собирает база из имени, языка
 * и изменчивости. Функции ядра и функции с особыми свойствами — только для чтения.
 * Ctrl+S (⌘S) — сохранить, Tab — отступ.
 */
export function openFunctionEditor(fn, onSaved) {
	const dialog = document.createElement('dialog');
	dialog.className = 'code-view function-editor';
	const header = document.createElement('header');
	const title = document.createElement('h3');
	title.textContent = fn.is_new ? t('New action function') : (fn.function ?? fn.name);
	const note = document.createElement('p');
	header.append(title, note);
	const footer = document.createElement('div');
	footer.className = 'toolbar';
	const spacer = () => Object.assign(document.createElement('span'), { className: 'spacer' });
	const copy = (text) => {
		const element = button(t('Copy'), async () => {
			await navigator.clipboard.writeText(text());
			element.textContent = t('Copied');
		});
		return element;
	};
	dialog.addEventListener('close', () => dialog.remove());

	if (!fn.editable) {
		note.textContent = `${fn.description ?? ''} — ${fn.reason}`;
		const pre = document.createElement('pre');
		const code = document.createElement('code');
		code.append(highlightSql(fn.source));
		pre.append(code);
		const close = button(t('Close'), () => dialog.close());
		close.className = 'primary';
		footer.append(spacer(), copy(() => fn.source), close);
		dialog.append(header, pre, footer);
		document.body.append(dialog);
		dialog.showModal();
		return;
	}

	const state = { ...fn };
	let dirty = false;
	const touch = () => {
		dirty = true;
		status.textContent = '';
		renderSignature();
	};
	note.textContent = fn.is_new
		? t('Template: the function is created in the public schema and becomes the component action.')
		: (fn.description ?? '');

	const name = input(state.name, (v) => { state.name = v.trim(); touch(); });
	name.disabled = !state.is_new;
	name.spellcheck = false;
	const description = input(state.description, (v) => { state.description = v; touch(); });
	const language = selectBox([['plpgsql', 'plpgsql'], ['sql', 'sql']], state.language,
		(v) => { state.language = v; touch(); });
	const volatility = selectBox(['VOLATILE', 'STABLE', 'IMMUTABLE'].map((v) => [v, v]), state.volatility,
		(v) => { state.volatility = v; touch(); });
	const fields = document.createElement('div');
	fields.className = 'function-editor-fields';
	fields.append(field(t('Function and action name'), name), field(t('Description'), description),
		field(t('Language'), language), field(t('Volatility'), volatility));

	const signature = document.createElement('code');
	signature.className = 'function-signature';
	const renderSignature = () => {
		signature.replaceChildren(highlightSql(`CREATE OR REPLACE FUNCTION public.${state.name || '…'}(${state.argument} JSON) `
			+ `RETURNS JSON LANGUAGE ${state.language} ${state.volatility} AS $$`));
	};
	renderSignature();
	const { element: code, textarea: body } = codeArea({
		value: state.body,
		highlight: highlightSql,
		label: t('Function code'),
		onInput: touch,
	});
	const closing = document.createElement('code');
	closing.className = 'function-signature';
	closing.append(highlightSql('$$;'));
	const error = document.createElement('p');
	error.className = 'function-error';
	error.setAttribute('role', 'alert');
	error.hidden = true;

	const status = document.createElement('span');
	status.className = 'function-status';
	status.setAttribute('role', 'status');
	const save = button(t('Save'), async () => {
		save.disabled = true;
		error.hidden = true;
		try {
			const result = await callAction('function_save', {
				is_new: state.is_new,
				name: state.name,
				description: state.description,
				language: state.language,
				volatility: state.volatility,
				body: body.value,
			});
			state.is_new = false;
			name.disabled = true;
			title.textContent = `public.${result.action}(json)`;
			note.textContent = state.description ?? '';
			dirty = false;
			status.textContent = t('Saved');
			await onSaved(result.action);
		}
		catch (e) {
			error.textContent = e.message;
			error.hidden = false;
		}
		finally {
			save.disabled = false;
		}
	}, false, t('Ctrl+S'));
	save.className = 'primary';
	// Несохранённый код — переспросить
	const tryClose = () => {
		if (!dirty || confirm(t('Close without saving? Changes to the code will be lost.'))) {
			dialog.close();
		}
	};
	const close = button(t('Close'), tryClose);
	footer.append(status, spacer(), copy(() => body.value), close, save);

	dialog.addEventListener('keydown', (event) => {
		if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 's') {
			event.preventDefault();
			save.click();
		}
	});
	// Esc — как «Закрыть»
	dialog.addEventListener('cancel', (event) => {
		event.preventDefault();
		tryClose();
	});

	dialog.append(header, fields, signature, code, closing, error, footer);
	document.body.append(dialog);
	dialog.showModal();
	body.focus();
	body.setSelectionRange(0, 0);
}
