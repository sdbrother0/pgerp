// Панель сообщений внизу экрана: строки ui_print из ответов действий.
// Функции базы пишут в неё через ui_print(текст[, 'info' | 'warning' | 'error']):
// шлюз добавляет к ответу массив messages: [{text, kind}], даже если действие завершилось ошибкой.
// Новое сообщение открывает панель сам; кнопка «Сообщения» в шапке показывает и скрывает её.
// Сообщения и открытость панели хранятся в sessionStorage: переход к другой форме их не теряет.

import { language, t } from './i18n.js';

/** Не больше стольких строк: старые уходят, чтобы панель не разрасталась бесконечно. */
const LIMIT = 500;

const STORAGE_KEY = 'pgerp.messages';

const OPEN_KEY = 'pgerp.messages.open';

const timeFormat = new Intl.DateTimeFormat(language(), { hour: '2-digit', minute: '2-digit', second: '2-digit' });

/** Сообщения вкладки: [{time, text, kind}]. */
let entries = load();

let panel = null;
let list = null;
let counter = null;

/** Кнопки «Сообщения» в шапке: счётчик и признак открытой панели. */
const toggles = new Set();

function load() {
	try {
		const saved = JSON.parse(sessionStorage.getItem(STORAGE_KEY));
		return Array.isArray(saved) ? saved : [];
	}
	catch {
		return [];
	}
}

function save() {
	try {
		sessionStorage.setItem(STORAGE_KEY, JSON.stringify(entries));
	}
	catch {
		// Хранилище переполнено или недоступно — сообщения остаются только на этой странице
	}
}

function createPanel() {
	panel = document.createElement('section');
	panel.className = 'messages-panel';
	panel.id = 'messages-panel';
	panel.hidden = true;
	panel.setAttribute('aria-label', t('Messages'));

	const header = document.createElement('header');
	const title = document.createElement('h3');
	title.textContent = t('Messages');
	counter = document.createElement('span');
	counter.className = 'messages-count';
	title.append(' ', counter);
	const spacer = document.createElement('span');
	spacer.className = 'spacer';
	const clear = document.createElement('button');
	clear.type = 'button';
	clear.className = 'link';
	clear.textContent = t('Clear');
	clear.addEventListener('click', () => {
		entries = [];
		save();
		render();
	});
	const close = document.createElement('button');
	close.type = 'button';
	close.className = 'messages-close';
	close.textContent = '×';
	close.title = t('Close');
	close.setAttribute('aria-label', t('Close'));
	close.addEventListener('click', hideMessages);
	header.append(title, spacer, clear, close);

	list = document.createElement('ol');
	list.className = 'messages-list';
	list.setAttribute('role', 'log');
	list.setAttribute('aria-live', 'polite');
	panel.append(header, list);
	document.body.append(panel);
	// Содержимое страницы не уходит под панель
	new ResizeObserver(updatePadding).observe(panel);
}

function renderEntry({ time, text, kind }) {
	const item = document.createElement('li');
	item.className = `messages-item messages-${['warning', 'error'].includes(kind) ? kind : 'info'}`;
	const stamp = document.createElement('time');
	stamp.textContent = time;
	const body = document.createElement('span');
	body.textContent = text;
	item.append(stamp, body);
	return item;
}

/** Список, счётчик и кнопки в шапке — по текущим сообщениям. */
function render() {
	if (entries.length === 0) {
		const empty = document.createElement('li');
		empty.className = 'messages-empty';
		empty.textContent = t('No messages');
		list.replaceChildren(empty);
	}
	else {
		list.replaceChildren(...entries.map(renderEntry));
	}
	counter.textContent = entries.length > 0 ? String(entries.length) : '';
	syncToggles();
}

function syncToggles() {
	const open = Boolean(panel && !panel.hidden);
	for (const { button, badge } of toggles) {
		button.setAttribute('aria-expanded', String(open));
		button.classList.toggle('active', open);
		badge.textContent = entries.length > 0 ? String(entries.length) : '';
		badge.hidden = entries.length === 0;
	}
}

function updatePadding() {
	const docked = !panel.hidden && panel.parentElement === document.body;
	document.body.style.paddingBottom = docked ? `${panel.offsetHeight}px` : '';
}

function hideMessages() {
	if (!panel) {
		return;
	}
	panel.hidden = true;
	sessionStorage.removeItem(OPEN_KEY);
	updatePadding();
	syncToggles();
}

/**
 * Показывает панель. Открыта модальная форма — внизу внутри неё:
 * всё вне модального окна браузер делает недоступным, а поверх формы панель закрыла бы её кнопки.
 * После закрытия формы панель с накопленными сообщениями возвращается вниз страницы.
 */
export function showMessages() {
	if (!panel) {
		createPanel();
		render();
	}
	const modal = [...document.querySelectorAll('dialog.erp-modal[open]')].filter((d) => d.matches(':modal')).at(-1);
	const host = modal ?? document.body;
	if (panel.parentElement !== host) {
		host.append(panel);
		modal?.addEventListener('close', () => {
			document.body.append(panel);
			panel.classList.remove('messages-inline');
			updatePadding();
		}, { once: true });
	}
	panel.classList.toggle('messages-inline', Boolean(modal));
	panel.hidden = false;
	sessionStorage.setItem(OPEN_KEY, '1');
	updatePadding();
	syncToggles();
	list.lastElementChild?.scrollIntoView({ block: 'nearest' });
}

/** Добавляет сообщения и открывает панель: внизу страницы или внутри открытой модальной формы. */
export function printMessages(messages) {
	if (!Array.isArray(messages) || messages.length === 0) {
		return;
	}
	const time = timeFormat.format(new Date());
	entries.push(...messages.map(({ text, kind }) => ({ time, text: String(text ?? ''), kind })));
	entries = entries.slice(-LIMIT);
	save();
	if (panel) {
		render();
	}
	showMessages();
}

/** Забыть сообщения вкладки — при выходе: следующий пользователь их не увидит. */
export function forgetMessages() {
	sessionStorage.removeItem(STORAGE_KEY);
	sessionStorage.removeItem(OPEN_KEY);
}

/** Кнопка «Сообщения» для шапки: показать или скрыть панель; рядом — число сообщений. */
export function messagesToggle() {
	const button = document.createElement('button');
	button.type = 'button';
	button.className = 'link topbar-messages';
	button.setAttribute('aria-controls', 'messages-panel');
	const badge = document.createElement('span');
	badge.className = 'topbar-badge';
	button.append(t('Messages'), badge);
	button.addEventListener('click', () => {
		if (panel && !panel.hidden) {
			hideMessages();
		}
		else {
			showMessages();
		}
	});
	toggles.add({ button, badge });
	syncToggles();
	return button;
}

// Панель была открыта на прошлой странице этой вкладки — открыть и здесь
if (sessionStorage.getItem(OPEN_KEY) && entries.length > 0) {
	queueMicrotask(() => document.readyState === 'loading'
		? document.addEventListener('DOMContentLoaded', showMessages, { once: true })
		: showMessages());
}
