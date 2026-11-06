// Тонкий клиент Data-Driven UI: рисует форму по JSON-описанию из БД
// и выполняет инструкции (ui_instructions), которые возвращают PL/pgSQL-функции.

import { language, setLanguage, t } from './i18n.js';
import { forgetMessages, messagesToggle, printMessages } from './messages.js';
import { showReport } from './report-viewer.js';

/** Компоненты формы из options.refresh: одно имя или несколько через запятую. */
function refreshTargets(formElement, refresh) {
	return String(refresh ?? '').split(',').map((name) => formElement.grids.get(name.trim())).filter(Boolean);
}

/** Токен CSRF из cookie XSRF-TOKEN: сервер ждёт его в заголовке X-XSRF-TOKEN каждого POST. */
export function csrfHeaders() {
	const token = document.cookie.split('; ').find((c) => c.startsWith('XSRF-TOKEN='))?.slice('XSRF-TOKEN='.length);
	return token ? { 'X-XSRF-TOKEN': decodeURIComponent(token) } : {};
}

/** Страница входа; после входа — возврат на текущую страницу. */
function goToLogin() {
	forgetMessages();
	location.assign(`login.html?next=${encodeURIComponent(location.pathname + location.search)}`);
}

/** Выход: сессия на сервере закрывается, браузер переходит на страницу входа. */
export async function logout() {
	forgetMessages();
	try {
		await fetch('api/auth/logout', { method: 'POST', headers: csrfHeaders() });
	}
	finally {
		location.assign('login.html');
	}
}

/**
 * Вызов единого диспетчера: POST api/ui/event?action=...
 * Пути — относительно страницы: приложение может работать не в корне сайта (https://host/erp/).
 */
export async function callAction(action, data = {}) {
	const response = await fetch(`api/ui/event?action=${encodeURIComponent(action)}`, {
		method: 'POST',
		// Язык интерфейса — для пользователя без настройки языка (с настройкой база берёт её)
		headers: { 'Content-Type': 'application/json', 'Accept-Language': language(), ...csrfHeaders() },
		body: JSON.stringify(data),
	});
	// Сеанс истёк или пользователь отключён — на страницу входа
	if (response.status === 401) {
		goToLogin();
		throw new Error(t('Session ended — please sign in again'));
	}
	let result;
	try {
		result = await response.json();
	}
	catch {
		result = { status: 'error', message: `HTTP ${response.status}` };
	}
	// Сообщения ui_print («Сообщить») — в панель внизу, и при успехе, и при ошибке
	printMessages(result.messages);
	// 403 не от базы — отклонён токен CSRF: сеанс закрыт (например, выход в другой вкладке)
	if (response.status === 403 && result.status !== 'error') {
		goToLogin();
		throw new Error(t('Session ended — please sign in again'));
	}
	if (!response.ok || result.status === 'error') {
		// Ошибка может нести инструкции UI (ui_error в базе), например очистку полей
		throw Object.assign(new Error(result.message || `HTTP ${response.status}`),
			{ instructions: result.ui_instructions });
	}
	return result;
}

/**
 * Действие формы со значениями всех её полей. Действия одной формы выполняются по очереди:
 * следующее получает значения, уже обновлённые предыдущим, — таймер и горячие клавиши не теряют ходы.
 * Возвращает true, если действие выполнено без ошибки.
 */
function runAction(formElement, action, context) {
	const run = async () => {
		try {
			// Значения всех полей формы уходят в базу как JSON: {"user_name": "..."}
			const result = await callAction(action, Object.fromEntries(new FormData(formElement)));
			await applyInstructions(result.ui_instructions, formElement, context);
			return true;
		}
		catch (error) {
			await showError(error, formElement, context);
			return false;
		}
	};
	formElement.pending = (formElement.pending ?? 0) + 1;
	const done = (formElement.queue ?? Promise.resolve()).then(run).finally(() => {
		formElement.pending--;
	});
	formElement.queue = done;
	return done;
}

/** Ошибка действия: сначала инструкции, пришедшие вместе с ней, затем окно с текстом. */
async function showError(error, formElement, context) {
	try {
		await applyInstructions(error.instructions, formElement, context);
	}
	finally {
		showMessage(error.message, 'error');
	}
}

/**
 * Меню приложения: пункты {title, form, items} с произвольной вложенностью (действие menu_get).
 * Пункт с подпунктами — сворачиваемая группа; пункт с формой — ссылка renderLink(item).
 * Свёрнутые группы запоминаются в браузере; группа, в которой открытая форма activeForm, раскрыта.
 */
export function renderMenu(items, renderLink, activeForm) {
	const STORAGE_KEY = 'erp-closed-menu';
	const closed = new Set(JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]'));
	const hasActive = (item) => item.form === activeForm || item.items.some(hasActive);

	function label(item, depth) {
		if (!item.form) {
			const text = document.createElement('span');
			text.className = 'menu-text';
			text.textContent = item.title;
			return text;
		}
		const link = renderLink(item);
		link.classList.add('menu-link');
		link.classList.toggle('active', item.form === activeForm);
		// Отметка выбранного пункта стоит у края меню на любой глубине
		link.style.setProperty('--menu-depth', String(depth));
		return link;
	}

	function node(item, depth, path) {
		if (item.items.length === 0) {
			return label(item, depth);
		}
		// Ключ группы — путь из названий: id пунктов меняются при каждом сохранении меню
		const key = [...path, item.title].join('\u0001');
		const details = document.createElement('details');
		details.className = 'form-folder menu-group';
		details.open = !closed.has(key) || (activeForm != null && hasActive(item));
		const summary = document.createElement('summary');
		if (item.form) {
			// Группа со своей формой: название — ссылка, выбранная выделяется цветом (без полоски)
			const link = renderLink(item);
			link.className = 'menu-group-link';
			link.classList.toggle('active', item.form === activeForm);
			summary.append(link);
		}
		else {
			summary.append(item.title);
		}
		details.append(summary, list(item.items, depth + 1, [...path, item.title]));
		details.addEventListener('toggle', () => {
			if (details.open) {
				closed.delete(key);
			}
			else {
				closed.add(key);
			}
			localStorage.setItem(STORAGE_KEY, JSON.stringify([...closed]));
		});
		return details;
	}

	function list(items, depth, path) {
		const ul = document.createElement('ul');
		ul.className = 'form-list';
		ul.append(...items.map((item) => {
			const li = document.createElement('li');
			li.append(node(item, depth, path));
			return li;
		}));
		return ul;
	}

	const root = list(items, 0, []);
	root.classList.add('menu-tree');
	return root;
}

/**
 * Список форм по папкам: у каждой папки сворачиваемый заголовок, формы без папки — в конце.
 * renderItem(form) возвращает содержимое пункта списка. Свёрнутые папки запоминаются в браузере.
 */
export function renderFormFolders(forms, renderItem) {
	const STORAGE_KEY = 'erp-closed-folders';
	const closed = new Set(JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '[]'));
	const groups = Map.groupBy(forms, (form) => form.folder ?? '');
	const list = (items) => {
		const ul = document.createElement('ul');
		ul.className = 'form-list';
		ul.append(...items.map((form) => {
			const li = document.createElement('li');
			li.append(renderItem(form));
			return li;
		}));
		return ul;
	};
	return [...groups].map(([folder, items]) => {
		if (!folder) {
			return list(items);
		}
		const details = document.createElement('details');
		details.className = 'form-folder';
		details.open = !closed.has(folder);
		const summary = document.createElement('summary');
		const count = document.createElement('span');
		count.className = 'form-folder-count';
		count.textContent = String(items.length);
		summary.append(folder, count);
		details.append(summary, list(items));
		details.addEventListener('toggle', () => {
			if (details.open) {
				closed.delete(folder);
			}
			else {
				closed.add(folder);
			}
			localStorage.setItem(STORAGE_KEY, JSON.stringify([...closed]));
		});
		return details;
	});
}

/** Модальное окно сообщения. */
export function showMessage(text, kind = 'info') {
	const dialog = document.createElement('dialog');
	dialog.className = `message message-${kind}`;
	const p = document.createElement('p');
	p.textContent = text;
	const form = document.createElement('form');
	form.method = 'dialog';
	const ok = document.createElement('button');
	ok.textContent = 'OK';
	form.append(ok);
	dialog.append(p, form);
	dialog.addEventListener('close', () => dialog.remove());
	document.body.append(dialog);
	dialog.showModal();
}

/** Окно подтверждения. Возвращает true, если пользователь подтвердил. */
export function showConfirm(text, confirmLabel = 'OK') {
	return new Promise((resolve) => {
		const dialog = document.createElement('dialog');
		dialog.className = 'message message-confirm';
		const p = document.createElement('p');
		p.textContent = text;
		const form = document.createElement('form');
		form.method = 'dialog';
		const cancel = document.createElement('button');
		cancel.value = 'cancel';
		cancel.textContent = t('Cancel');
		const confirm = document.createElement('button');
		confirm.value = 'confirm';
		confirm.className = 'danger-fill';
		confirm.textContent = confirmLabel;
		form.append(cancel, confirm);
		dialog.append(p, form);
		// Esc и «Отмена» дают returnValue, отличный от 'confirm'
		dialog.addEventListener('close', () => {
			dialog.remove();
			resolve(dialog.returnValue === 'confirm');
		});
		document.body.append(dialog);
		dialog.showModal();
		cancel.focus();
	});
}

/**
 * Выполнение инструкций, пришедших из базы: одна или массив, по порядку.
 * context.onLookup — обработчик выбора, если инструкции пришли от кнопки "..." поля выбора.
 */
export async function applyInstructions(instructions, formElement, context = {}) {
	for (const instruction of [instructions ?? []].flat()) {
		switch (instruction.command) {
			case 'show_message':
				showMessage(instruction.text);
				break;
			case 'clear_form':
				formElement.reset();
				break;
			case 'close_form': {
				// Форма, открытая отдельной страницей, закрывается возвратом назад
				const dialog = formElement.closest('dialog');
				if (dialog) {
					dialog.close();
				}
				else {
					history.back();
				}
				break;
			}
			case 'open_form':
				await openForm(instruction.form, {
					modal: instruction.modal,
					data: instruction.data,
					title: instruction.title,
					// Режим выбора: строка списка возвращается в поле, откуда открыт список
					onSelect: (instruction.select && context.onLookup)
						? (row) => context.onLookup(row, instruction.select)
						: undefined,
				});
				break;
			case 'set_values': {
				// form — имя другой открытой формы (например, карточки документа из формы его строки)
				const target = instruction.form ? findForm(instruction.form) : formElement;
				if (target) {
					fillForm(target, instruction.values);
				}
				break;
			}
			case 'set_title':
				formElement.querySelector(':scope > h2').textContent = instruction.title;
				break;
			case 'refresh_grid': {
				const grid = findGrid(instruction.grid);
				grid?.load(instruction.keep_page ? grid.currentPage() : 1);
				break;
			}
			case 'logout':
				await logout();
				break;
			case 'show_report':
				// Отчёт PDF (ui_report): окно с просмотрщиком; ошибка — сообщением
				try {
					await showReport(instruction.url, instruction.title);
				}
				catch (error) {
					showMessage(error.message, 'error');
				}
				break;
			case 'confirm':
				// База спрашивает подтверждение; при согласии повторно вызывается указанное действие
				if (await showConfirm(instruction.text, instruction.confirm_label)) {
					const result = await callAction(instruction.action, instruction.data ?? {});
					await applyInstructions(result.ui_instructions, formElement, context);
				}
				break;
			default:
				console.warn('Unknown UI command', instruction);
		}
	}
}

/** Переключатель темы в шапке: «Как в системе» и темы из pgerp.themes; выбор сохраняется в настройке пользователя. */
function themeSelect(themes = []) {
	const select = document.createElement('select');
	select.className = 'topbar-select';
	select.setAttribute('aria-label', t('Theme'));
	select.title = t('Theme');
	const current = globalThis.PgErpTheme?.choice() ?? '';
	select.append(new Option(t('System'), '', false, current === ''),
		...themes.map((theme) => new Option(theme.title, theme.code, false, theme.code === current)));
	select.addEventListener('change', async () => {
		const previous = globalThis.PgErpTheme?.choice() ?? '';
		globalThis.PgErpTheme?.set(select.value);
		try {
			await callAction('session_theme_set', { theme: select.value });
		}
		catch (error) {
			globalThis.PgErpTheme?.set(previous);
			select.value = previous;
			showMessage(error.message, 'error');
		}
	});
	return select;
}

/** Переключатель языка в шапке: язык сохраняется в настройке пользователя, страница перезагружается. */
function languageSelect(languages = []) {
	const select = document.createElement('select');
	select.className = 'topbar-select';
	select.setAttribute('aria-label', t('Language'));
	select.append(...languages.map((l) => new Option(l.title, l.code, false, l.code === language())));
	select.hidden = languages.length < 2;
	select.addEventListener('change', async () => {
		try {
			await callAction('session_lang_set', { lang: select.value });
			setLanguage(select.value);
			location.reload();
		}
		catch (error) {
			showMessage(error.message, 'error');
		}
	});
	return select;
}

/**
 * Вошедший пользователь (действие session_get): имя, «Сменить пароль» и «Выйти» в шапке;
 * переключатель в редактор форм — только администратору. Если пароль нужно сменить, сразу
 * открывается окно смены пароля, после него страница перезагружается. При первом входе администратора —
 * окно выбора решений для установки (session_get → setup_required). Возвращает пользователя.
 */
export async function initSession(topbar) {
	const { user, languages, themes } = await callAction('session_get');
	// Тема из настройки пользователя — сразу, без перезагрузки
	if ((user.theme ?? '') !== globalThis.PgErpTheme?.choice()) {
		globalThis.PgErpTheme?.set(user.theme ?? '');
	}
	// Язык из настройки пользователя: тексты модулей вычислены при загрузке, поэтому — перезагрузка
	if (user.lang && user.lang !== language()) {
		setLanguage(user.lang);
		location.reload();
		return new Promise(() => {});
	}
	if (!user.is_admin) {
		topbar.querySelector('.topbar-mode')?.remove();
	}
	const box = document.createElement('div');
	box.className = 'topbar-user';
	const name = document.createElement('span');
	name.className = 'topbar-user-name';
	name.textContent = user.full_name || user.login;
	name.title = t('Login: {0}', user.login);
	const password = document.createElement('button');
	password.type = 'button';
	password.className = 'link';
	password.textContent = t('Change password');
	password.addEventListener('click', () => openForm('password_change', { modal: true })
		.catch((error) => showMessage(error.message, 'error')));
	const exit = document.createElement('button');
	exit.type = 'button';
	exit.className = 'link';
	exit.textContent = t('Sign out');
	exit.addEventListener('click', () => logout());
	box.append(messagesToggle(), themeSelect(themes), languageSelect(languages), name, password, exit);
	topbar.append(box);

	if (user.must_change_password) {
		await openForm('password_change', {
			modal: true,
			title: t('Change your password to continue'),
			onClose: () => location.reload(),
		});
	}
	else if (user.setup_required) {
		// Первый вход администратора: какие решения установить. Модуль — только для администратора
		const { showSolutionPackages } = await import('./solution-packages.js');
		await showSolutionPackages({ setup: true });
		location.reload();
		return new Promise(() => {});
	}
	return user;
}

/**
 * Команды из базы без запроса пользователя: pgerp.ui_push(...) → NOTIFY → сервер → WebSocket /api/ui/ws.
 * Сообщение: {"form": имя формы или null, "ui_instructions": [...]}. Если форма указана, инструкции
 * выполняются, только когда она открыта, и в её контексте.
 * При обрыве соединение восстанавливается с паузой 1, 2, 4… до 30 секунд.
 */
export function connectUiEvents() {
	// Относительно страницы, с той же схемой: https → wss
	const url = new URL('api/ui/ws', location.href);
	url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
	let delay = 1000;

	const connect = () => {
		const socket = new WebSocket(url);
		socket.addEventListener('open', () => {
			delay = 1000;
		});
		socket.addEventListener('message', async (event) => {
			const message = JSON.parse(event.data);
			const formElement = message.form ? findForm(message.form) : undefined;
			if (message.form && !formElement) {
				return;
			}
			try {
				await applyInstructions(message.ui_instructions, formElement);
			}
			catch (error) {
				console.warn('UI command from database failed', message, error);
			}
		});
		socket.addEventListener('close', () => {
			setTimeout(connect, delay);
			delay = Math.min(delay * 2, 30000);
		});
	};
	connect();
}

/** Последняя открытая форма с указанным именем. */
function findForm(name) {
	return [...document.querySelectorAll('form.erp-form')].findLast((form) => form.dataset.form === name);
}

/** Таблица ищется во всех открытых формах: модальная форма обновляет таблицу формы под ней. */
function findGrid(name) {
	for (const form of document.querySelectorAll('form.erp-form')) {
		const grid = form.grids?.get(name);
		if (grid) {
			return grid;
		}
	}
	return undefined;
}

/**
 * Открытие формы по имени: в модальном окне или вместо текущей страницы.
 * data — значения полей по их именам (например, редактируемая запись), title — заголовок вместо заданного в форме,
 * onSelect — режим выбора: в строках таблиц появляется «Выбрать», выбранная строка передаётся в onSelect.
 */
export async function openForm(name, { modal = false, data = {}, title, onSelect, onClose } = {}) {
	if (!modal) {
		location.href = `./?form=${encodeURIComponent(name)}`;
		return;
	}
	const { form } = await callAction('form_get', { form: name });
	if (title) {
		form.title = title;
	}
	const dialog = document.createElement('dialog');
	const formElement = renderForm(form, {
		onSelect: onSelect && ((row) => {
			onSelect(row);
			dialog.close();
		}),
	});
	fillForm(formElement, data);

	// Закрытие окна у формы с действием отмены (form.cancel) — как кнопка "Отмена":
	// база может откатить изменения или переспросить пользователя
	async function cancel() {
		if (!form.cancel) {
			dialog.close();
			return;
		}
		try {
			const result = await callAction(form.cancel, Object.fromEntries(new FormData(formElement)));
			await applyInstructions(result.ui_instructions, formElement);
		}
		catch (error) {
			await showError(error, formElement);
		}
	}

	dialog.className = 'erp-modal';
	const close = document.createElement('button');
	close.type = 'button';
	close.className = 'erp-modal-close';
	close.innerHTML = '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true"><path d="M4 4l8 8M12 4l-8 8" '
		+ 'fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>';
	close.title = t('Close');
	close.setAttribute('aria-label', t('Close'));
	close.addEventListener('click', () => cancel());
	// Escape — так же, как крестик
	dialog.addEventListener('cancel', (event) => {
		event.preventDefault();
		cancel();
	});
	dialog.append(close, formElement);
	dialog.addEventListener('close', () => {
		dialog.remove();
		onClose?.();
	});
	document.body.append(dialog);
	dialog.showModal();
	dialog.querySelector('input:not([type=hidden]):not([tabindex="-1"])')?.focus();
}

/** Заполнение полей формы значениями; заполненные значения становятся исходными для reset(). */
function fillForm(formElement, data) {
	for (const [name, value] of Object.entries(data ?? {})) {
		const field = formElement.elements.namedItem(name);
		if (field instanceof HTMLInputElement) {
			field.value = value ?? '';
			field.defaultValue = field.value;
			field.dispatchEvent(new Event('erp-value'));
		}
		else if (field instanceof HTMLSelectElement) {
			field.setValue(value, true);
		}
	}
}

/**
 * Рендер формы. В режиме предпросмотра (preview) кнопки не вызывают сервер.
 * @returns {HTMLFormElement}
 */
export function renderForm(form, { preview = false, onSelect } = {}) {
	const element = document.createElement('form');
	element.className = 'erp-form';
	element.dataset.form = form.name ?? '';
	element.addEventListener('submit', (event) => event.preventDefault());
	element.grids = new Map();

	const title = document.createElement('h2');
	title.textContent = form.title;
	element.append(title);

	// Компоненты с вкладкой попадают в блок вкладок, который встаёт на место первого из них
	// Колонки (options.column) — так же: блок колонок встаёт на место первого компонента с колонкой
	let tabs = null;
	let columns = null;
	// Дерево — мастер таблицы формы (группы слева, записи справа) — в режиме выбора только фильтр:
	// выбирается строка таблицы, а не узел
	const masters = new Set(form.components.filter((c) => c.type === 'grid' && c.master).map((c) => c.master));
	form.components.forEach((component, index) => {
		const choose = (component.type === 'tree' && masters.has(component.name)) ? undefined : onSelect;
		let child = renderComponent(component, element, preview, choose);
		if (preview) {
			// В редакторе скрытое поле видно, а каждый компонент знает свой номер — по нему выбирается щелчком
			if (component.type === 'hidden' || component.type === 'timer') {
				child = document.createElement('p');
				child.className = 'erp-hidden-preview';
				child.textContent = component.type === 'hidden'
					? t('Hidden field: {0}', component.name || '—')
					: t('Timer: {0} · {1} ms', component.action ?? '—', timerInterval(component));
			}
			child.dataset.componentIndex = String(index);
		}
		const column = Number(component.options?.column) || null;
		const container = column ? (columns ??= renderColumns(element)).panel(column)
			: component.tab ? (tabs ??= renderTabs(element)).panel(component.tab)
				: element;
		place(container, child, component.type === 'button');
	});
	if (!preview) {
		bindHotkeys(element, form.components);
	}
	return element;
}

/**
 * Горячие клавиши кнопок (options.hotkey — event.code или event.key: ArrowLeft, Space, KeyP, Enter).
 * Работают, пока форма на экране и поверх неё нет другого окна; в полях ввода клавиши не перехватываются.
 */
function bindHotkeys(formElement, components) {
	const hotkeys = new Map(components
		.filter((c) => c.type === 'button' && c.action && c.options?.hotkey)
		.map((c) => [c.options.hotkey, c.action]));
	if (hotkeys.size === 0) {
		return;
	}
	let shown = false;
	const onKey = (event) => {
		if (!formElement.isConnected) {
			if (shown) {
				document.removeEventListener('keydown', onKey);
			}
			return;
		}
		shown = true;
		const top = [...document.querySelectorAll('dialog[open]')].at(-1);
		if ((top ? !top.contains(formElement) : formElement.closest('dialog'))
			|| event.target.closest?.('input, select, textarea')) {
			return;
		}
		const action = hotkeys.get(event.code) ?? hotkeys.get(event.key);
		if (action) {
			event.preventDefault();
			runAction(formElement, action);
		}
	};
	document.addEventListener('keydown', onKey);
}

function timerInterval(component) {
	return Math.max(Number(component.options?.interval) || 1000, 100);
}

/** Подряд идущие кнопки выстраиваются в один ряд. */
function place(container, child, isButton) {
	if (!isButton) {
		container.append(child);
		return;
	}
	let row = container.lastElementChild;
	if (!row?.classList.contains('erp-buttons')) {
		row = document.createElement('div');
		row.className = 'erp-buttons';
		container.append(row);
	}
	row.append(child);
}

/**
 * Колонки формы: компоненты с options.column = 1, 2, … стоят друг под другом в своей колонке,
 * колонки — рядом по порядку номеров. panel(n) возвращает колонку, создавая её при первом обращении.
 * Первая колонка уже остальных; на узком экране колонки встают друг под другом.
 */
function renderColumns(formElement) {
	const wrapper = document.createElement('div');
	wrapper.className = 'erp-columns';
	formElement.append(wrapper);
	const panels = new Map();
	return {
		panel(number) {
			let panel = panels.get(number);
			if (!panel) {
				panel = document.createElement('div');
				panel.className = 'erp-column';
				panel.style.order = String(number);
				panels.set(number, panel);
				wrapper.append(panel);
				const rest = panels.size - 1;
				wrapper.style.setProperty('--erp-columns-template',
					rest ? `minmax(240px, 1fr) repeat(${rest}, minmax(0, 2fr))` : '1fr');
			}
			return panel;
		},
	};
}

let tabsCounter = 0;

/**
 * Блок вкладок. panel(title) возвращает панель вкладки, создавая её при первом обращении.
 * На ярлыке показывается число строк в таблицах вкладки (событие grid-loaded).
 */
function renderTabs(formElement) {
	const id = `erp-tabs-${++tabsCounter}`;
	const wrapper = document.createElement('div');
	wrapper.className = 'erp-tabs';
	const tablist = document.createElement('div');
	tablist.className = 'erp-tablist';
	tablist.setAttribute('role', 'tablist');
	wrapper.append(tablist);
	formElement.append(wrapper);

	const tabs = [];

	function select(tab, focus = false) {
		for (const other of tabs) {
			const selected = other === tab;
			other.button.setAttribute('aria-selected', String(selected));
			other.button.tabIndex = selected ? 0 : -1;
			other.panel.hidden = !selected;
		}
		if (focus) {
			tab.button.focus();
		}
	}

	// Клавиатура: стрелки, Home, End
	tablist.addEventListener('keydown', (event) => {
		const index = tabs.findIndex((tab) => tab.button === document.activeElement);
		if (index < 0) {
			return;
		}
		const next = { ArrowRight: index + 1, ArrowLeft: index - 1, Home: 0, End: tabs.length - 1 }[event.key];
		if (next === undefined) {
			return;
		}
		event.preventDefault();
		select(tabs[(next + tabs.length) % tabs.length], true);
	});

	return {
		panel(title) {
			let tab = tabs.find((t) => t.title === title);
			if (tab) {
				return tab.panel;
			}
			const index = tabs.length;
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'erp-tab';
			button.id = `${id}-tab-${index}`;
			button.setAttribute('role', 'tab');
			button.setAttribute('aria-controls', `${id}-panel-${index}`);
			const label = document.createElement('span');
			label.textContent = title;
			const count = document.createElement('span');
			count.className = 'erp-tab-count';
			button.append(label, count);

			const panel = document.createElement('div');
			panel.className = 'erp-tabpanel';
			panel.id = `${id}-panel-${index}`;
			panel.setAttribute('role', 'tabpanel');
			panel.setAttribute('aria-labelledby', button.id);

			const totals = new Map();
			panel.addEventListener('grid-loaded', (event) => {
				totals.set(event.target, event.detail.total);
				const sum = [...totals.values()].reduce((a, b) => a + b, 0);
				count.textContent = String(sum);
			});

			tab = { title, button, panel };
			tabs.push(tab);
			button.addEventListener('click', () => select(tab));
			tablist.append(button);
			wrapper.append(panel);
			select(tabs[0]);
			return panel;
		},
	};
}

function renderComponent(component, formElement, preview, onSelect) {
	switch (component.type) {
		case 'label': {
			const p = document.createElement('p');
			p.className = 'erp-label';
			p.textContent = component.label ?? '';
			return p;
		}
		case 'input': {
			const wrapper = document.createElement('label');
			wrapper.className = 'erp-field';
			const caption = document.createElement('span');
			caption.textContent = component.label ?? component.name;
			const input = document.createElement('input');
			input.name = component.name;
			input.autocomplete = 'off';
			// options.type = "password" — скрытый ввод
			if (component.options?.type === 'password') {
				input.type = 'password';
				input.autocomplete = 'new-password';
			}
			// Поле-фильтр: options.refresh — имена таблиц (деревьев) через запятую, перечитываются при вводе
			const refresh = component.options?.refresh;
			if (refresh && !preview) {
				input.type = 'search';
				let timeout;
				input.addEventListener('input', () => {
					clearTimeout(timeout);
					timeout = setTimeout(() => refreshTargets(formElement, refresh).forEach((grid) => grid.load(1)),
						FILTER_DELAY);
				});
			}
			wrapper.append(caption, input);
			return wrapper;
		}
		case 'date': {
			// Дата с календарём браузера; значение в формате ГГГГ-ММ-ДД
			const wrapper = document.createElement('label');
			wrapper.className = 'erp-field erp-date';
			const caption = document.createElement('span');
			caption.textContent = component.label ?? component.name;
			const input = document.createElement('input');
			input.type = 'date';
			input.name = component.name;
			wrapper.append(caption, input);
			return wrapper;
		}
		case 'display': {
			// Значение только для чтения; задаётся базой (data в open_form, set_values)
			const wrapper = document.createElement('label');
			wrapper.className = 'erp-field erp-display';
			const caption = document.createElement('span');
			caption.textContent = component.label ?? component.name;
			const output = document.createElement('input');
			output.name = component.name;
			output.readOnly = true;
			output.tabIndex = -1;
			wrapper.append(caption, output);
			return wrapper;
		}
		case 'hidden': {
			const input = document.createElement('input');
			input.type = 'hidden';
			input.name = component.name;
			return input;
		}
		case 'lookup':
			return renderLookup(component, formElement, preview);
		case 'combobox': {
			// Список перечитывается той же инструкцией refresh_grid и полем-фильтром (options.refresh)
			const combobox = renderCombobox(component, formElement, preview);
			formElement.grids.set(component.name, combobox);
			return combobox.element;
		}
		case 'button': {
			const button = document.createElement('button');
			button.type = 'submit';
			button.textContent = component.label ?? component.name;
			button.addEventListener('click', async (event) => {
				event.preventDefault();
				if (preview || !component.action) {
					return;
				}
				button.disabled = true;
				try {
					await runAction(formElement, component.action);
				}
				finally {
					button.disabled = false;
				}
			});
			return button;
		}
		case 'timer': {
			// Таймер: пока значение поля не пустое, вызывает действие каждые options.interval мс.
			// Включает и выключает его база: set_values {"<имя>": "1"} / {"<имя>": ""}
			const input = document.createElement('input');
			input.type = 'hidden';
			input.name = component.name;
			if (!preview && component.action) {
				let shown = false;
				const id = setInterval(async () => {
					if (!formElement.isConnected) {
						if (shown) {
							clearInterval(id);
						}
						return;
					}
					shown = true;
					// Пропуск такта, если предыдущее действие формы ещё выполняется или вкладка скрыта
					if (!input.value || formElement.pending || document.hidden) {
						return;
					}
					if (!await runAction(formElement, component.action)) {
						input.value = '';  // после ошибки таймер останавливается
					}
				}, timerInterval(component));
			}
			return input;
		}
		case 'board':
			return renderBoard(component);
		case 'chart': {
			// График перечитывается той же инструкцией refresh_grid, что и таблица
			const chart = renderChart(component, formElement, preview);
			formElement.grids.set(component.name, chart);
			return chart.element;
		}
		case 'grid': {
			const grid = renderGrid(component, formElement, preview, onSelect);
			formElement.grids.set(component.name, grid);
			return grid.element;
		}
		case 'tree': {
			// Дерево перечитывается той же инструкцией refresh_grid
			const tree = renderTree(component, formElement, preview, onSelect);
			formElement.grids.set(component.name, tree);
			return tree.element;
		}
		default: {
			const unknown = document.createElement('p');
			unknown.textContent = t('Unknown component: {0}', component.type);
			return unknown;
		}
	}
}

/**
 * Поле выбора: значение (id) хранится в скрытом поле с именем компонента,
 * отображаемый текст — в поле <имя>__display. Кнопка "..." вызывает действие,
 * которое открывает форму-список в режиме выбора.
 */
function renderLookup(component, formElement, preview) {
	const wrapper = document.createElement('div');
	wrapper.className = 'erp-field erp-lookup';
	const caption = document.createElement('span');
	caption.textContent = component.label ?? component.name;
	const value = document.createElement('input');
	value.type = 'hidden';
	value.name = component.name;
	const display = document.createElement('input');
	display.name = `${component.name}__display`;
	display.readOnly = true;
	display.placeholder = t('Not selected');
	display.setAttribute('aria-label', caption.textContent);
	const button = document.createElement('button');
	button.type = 'button';
	button.className = 'lookup-button';
	button.textContent = '...';
	button.title = t('Select');
	// Очистка выбора — видна, пока значение выбрано
	const clear = document.createElement('button');
	clear.type = 'button';
	clear.className = 'lookup-button lookup-clear';
	clear.textContent = '✕';
	clear.title = t('Clear');
	const updateClear = () => {
		clear.hidden = preview || !value.value;
	};
	clear.addEventListener('click', () => {
		value.value = '';
		display.value = '';
		updateClear();
	});
	value.addEventListener('erp-value', updateClear);
	updateClear();

	const choose = (row, select) => {
		value.value = row[select.value_field ?? 'id'] ?? '';
		display.value = row[select.display_field ?? 'name'] ?? '';
		// Заполнение соседних полей формы из выбранной строки: {"поле формы": "поле строки"}
		for (const [field, source] of Object.entries(select.fill ?? {})) {
			const target = formElement.elements.namedItem(field);
			if (target instanceof HTMLInputElement) {
				target.value = row[source] ?? '';
			}
			else if (target instanceof HTMLSelectElement) {
				target.setValue(row[source]);
			}
		}
		updateClear();
	};

	button.addEventListener('click', async () => {
		if (preview || !component.action) {
			return;
		}
		button.disabled = true;
		try {
			await runAction(formElement, component.action, { onLookup: choose });
		}
		finally {
			button.disabled = false;
		}
	});
	display.addEventListener('dblclick', () => button.click());

	const row = document.createElement('div');
	row.className = 'lookup-row';
	row.append(display, clear, button);
	wrapper.append(caption, value, row);
	return wrapper;
}

/**
 * Выпадающий список. Элементы возвращает действие component.action: получает значения полей формы
 * и отвечает {items: [{id, label}]}. Значение компонента — id выбранного элемента; первый пункт —
 * пустой (options.placeholder, по умолчанию «Не выбрано»). При выборе перечитываются таблицы
 * с master = имя списка и компонент options.refresh — так строятся фильтры и зависимые списки.
 * Значение, заданное до загрузки элементов (data в open_form, set_values), ставится после загрузки.
 */
function renderCombobox(component, formElement, preview) {
	const element = document.createElement('label');
	element.className = 'erp-field erp-combobox';
	const caption = document.createElement('span');
	caption.textContent = component.label ?? component.name;
	const select = document.createElement('select');
	select.name = component.name;
	const empty = new Option(component.options?.placeholder ?? t('Not selected'), '');
	select.append(empty);
	element.append(caption, select);

	if (preview) {
		empty.textContent = t('Data: {0}', component.action ?? '—');
		select.setValue = () => {};
		return { element, load() {}, currentPage: () => 1 };
	}

	let loaded = false;
	let request = 0;  // ответ устаревшего запроса не перезаписывает список

	// Перечитать зависимые компоненты: таблицы-детали и options.refresh
	function changed() {
		const targets = new Set([...formElement.grids.values()].filter((grid) => grid.master === component.name));
		for (const target of refreshTargets(formElement, component.options?.refresh)) {
			targets.add(target);
		}
		for (const target of targets) {
			target.load(1);
		}
	}

	// Значение от базы. asDefault — становится исходным для reset(), как у fillForm.
	// Пока элементы не загружены, значение держит временный пункт: оно сразу уходит в действия и источники.
	select.setValue = (value, asDefault = false) => {
		value = String(value ?? '');
		const before = select.value;
		let option = [...select.options].find((o) => o.value === value);
		if (!option && !loaded) {
			option = new Option('…', value);
			select.append(option);
		}
		option ??= empty;
		option.selected = true;
		if (asDefault) {
			for (const other of select.options) {
				other.defaultSelected = other === option;
			}
		}
		if (select.value !== before && select.isConnected) {
			changed();
		}
	};

	select.addEventListener('change', changed);

	async function load() {
		const current = ++request;
		try {
			const result = await callAction(component.action, Object.fromEntries(new FormData(formElement)));
			if (current !== request) {
				return;
			}
			const value = select.value;
			const defaultValue = [...select.options].find((o) => o.defaultSelected)?.value ?? '';
			select.replaceChildren(empty, ...(result.items ?? []).map((item) => {
				const id = String(item.id ?? '');
				return new Option(item.label ?? id, id, id === defaultValue);
			}));
			loaded = true;
			([...select.options].find((o) => o.value === value) ?? empty).selected = true;
			// Выбранный элемент исчез из списка — значение сброшено, зависимые компоненты перечитываются
			if (select.value !== value && select.isConnected) {
				changed();
			}
		}
		catch (error) {
			if (current === request) {
				empty.textContent = error.message;
			}
		}
	}

	queueMicrotask(load);
	return { element, load, currentPage: () => 1 };
}

/**
 * Поле из клеток. Значение — строки через «/»: «#» — занятая клетка, «@» — активная, остальное — пустая.
 * Пока значения нет, рисуется пустое поле options.rows × options.cols.
 */
function renderBoard(component) {
	const wrapper = document.createElement('div');
	wrapper.className = 'erp-board';
	if (component.label) {
		const caption = document.createElement('span');
		caption.className = 'erp-board-caption';
		caption.textContent = component.label;
		wrapper.append(caption);
	}
	const input = document.createElement('input');
	input.type = 'hidden';
	input.name = component.name;
	const grid = document.createElement('div');
	grid.className = 'erp-board-grid';
	grid.setAttribute('role', 'img');

	const draw = () => {
		const empty = '.'.repeat(Number(component.options?.cols) || 8);
		const rows = input.value
			? input.value.split('/')
			: Array(Number(component.options?.rows) || 12).fill(empty);
		const cols = Math.max(...rows.map((row) => row.length), 1);
		grid.style.gridTemplateColumns = `repeat(${cols}, var(--erp-cell-size))`;
		grid.replaceChildren(...rows.flatMap((row) => [...row.padEnd(cols, '.')].map((char) => {
			const cell = document.createElement('span');
			cell.className = char === '#' ? 'erp-cell is-filled' : char === '@' ? 'erp-cell is-active' : 'erp-cell';
			return cell;
		})));
		grid.setAttribute('aria-label', component.label || t('Field'));
	};
	input.addEventListener('erp-value', draw);
	draw();
	wrapper.append(input, grid);
	return wrapper;
}

/**
 * График: данные — от действия-источника {labels, series: [{name, values}], format}, источник получает
 * значения полей формы. Вид — options.chart: bar (гистограмма), line (тренд), area, pie; options.stacked —
 * ряды столбцов и областей друг на друге; options.height — высота, px. Рисуется SVG по ширине контейнера,
 * при наведении — подсказка со значениями точки. Обновляется инструкцией refresh_grid.
 */
function renderChart(component, formElement, preview) {
	const element = document.createElement('section');
	element.className = 'erp-chart';
	if (component.label) {
		const caption = document.createElement('h3');
		caption.textContent = component.label;
		element.append(caption);
	}
	const body = document.createElement('div');
	body.className = 'erp-chart-body';
	const legend = document.createElement('div');
	legend.className = 'erp-chart-legend';
	const tooltip = document.createElement('div');
	tooltip.className = 'erp-chart-tooltip';
	tooltip.hidden = true;
	element.append(body, legend, tooltip);

	const options = component.options ?? {};
	const kind = ['bar', 'line', 'area', 'pie'].includes(options.chart) ? options.chart : 'bar';
	const height = Math.min(Math.max(Number(options.height) || 260, 120), 800);
	const stacked = options.stacked === true || options.stacked === 'true' || Number(options.stacked) === 1;
	let data = null;

	function draw() {
		const width = body.clientWidth;
		if (!data || width === 0) {
			return;
		}
		const series = (data.series ?? []).map((s) => ({ name: s.name, values: (s.values ?? []).map((v) => Number(v) || 0) }));
		const labels = (data.labels ?? []).map((label) => String(label ?? ''));
		if (!labels.length || !series.length) {
			body.textContent = t('No data');
			legend.replaceChildren();
			return;
		}
		const type = ['bar', 'line', 'area', 'pie'].includes(data.type) ? data.type : kind;
		const format = chartFormatter(data.format);
		const svg = svgNode('svg', { viewBox: `0 0 ${width} ${height}`, width, height, role: 'img' });
		svg.setAttribute('aria-label', component.label || t('Chart'));
		const show = (index, x, y) => {
			const rows = type === 'pie'
				? [[0, series[0].name, series[0].values[index]]]
				: series.map((s, i) => [i, s.name, s.values[index]]);
			tooltip.replaceChildren(Object.assign(document.createElement('strong'), { textContent: labels[index] }),
				...rows.map(([i, name, value]) => {
					const row = document.createElement('div');
					const mark = document.createElement('i');
					mark.className = `erp-chart-c${(type === 'pie' ? index : i) % CHART_COLORS}`;
					row.append(mark, `${name}: ${format.full(value)}`);
					return row;
				}));
			tooltip.hidden = false;
			const box = element.getBoundingClientRect();
			const left = Math.min(Math.max(x - box.left + 12, 0), box.width - tooltip.offsetWidth);
			tooltip.style.left = `${left}px`;
			tooltip.style.top = `${y - box.top + 12}px`;
		};
		svg.addEventListener('mouseleave', () => {
			tooltip.hidden = true;
			svg.querySelectorAll('.is-hover').forEach((node) => node.classList.remove('is-hover'));
		});
		if (type === 'pie') {
			drawPie(svg, width, height, labels, series[0].values, show);
			legend.replaceChildren(...labels.map((label, i) => legendItem(label, i)));
		}
		else {
			drawAxes(svg, width, height, labels, series, type, stacked, format, show);
			legend.replaceChildren(...(series.length > 1 ? series.map((s, i) => legendItem(s.name, i)) : []));
		}
		body.replaceChildren(svg);
	}

	async function load() {
		if (preview) {
			data = { labels: ['A', 'B', 'C', 'D', 'E'], series: [{ name: t('Value'), values: [4, 7, 5, 9, 6] }] };
			draw();
			return;
		}
		try {
			data = await callAction(component.action, Object.fromEntries(new FormData(formElement)));
			draw();
		}
		catch (error) {
			body.textContent = error.message;
		}
	}

	// Ширина известна только на экране — перерисовка при каждом её изменении (окно, колонки, вкладки)
	let lastWidth = 0;
	new ResizeObserver(() => {
		if (body.clientWidth !== lastWidth) {
			lastWidth = body.clientWidth;
			draw();
		}
	}).observe(body);
	body.style.minHeight = `${height}px`;
	queueMicrotask(load);
	return { element, load, currentPage: () => 1 };
}

// Данные таблиц и деревьев в редакторе: холст перерисовывается при каждой правке —
// один и тот же запрос к источнику не чаще раза в 15 с
const previewCache = new Map();

function previewPage(action, data) {
	const key = `${action} ${JSON.stringify(data)}`;
	const cached = previewCache.get(key);
	if (cached && Date.now() - cached.time < 15000) {
		return cached.promise;
	}
	const promise = callAction(action, data);
	previewCache.set(key, { time: Date.now(), promise });
	promise.catch(() => previewCache.delete(key));
	return promise;
}

// Число цветов рядов: .erp-chart-c0 … — в css/app.css (светлая и тёмная темы)
const CHART_COLORS = 6;

function svgNode(tag, attributes = {}) {
	const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
	for (const [name, value] of Object.entries(attributes)) {
		node.setAttribute(name, String(value));
	}
	return node;
}

function legendItem(text, index) {
	const item = document.createElement('span');
	const mark = document.createElement('i');
	mark.className = `erp-chart-c${index % CHART_COLORS}`;
	item.append(mark, text);
	return item;
}

/** Подписи значений: short — на оси (1,2 тыс.), full — в подсказке. */
function chartFormatter(format) {
	const short = new Intl.NumberFormat(language(), { notation: 'compact', maximumFractionDigits: 1 });
	const full = format === 'money' ? moneyFormat : numberFormat;
	const suffix = format === 'percent' ? ' %' : '';
	return { short: (v) => short.format(v) + suffix, full: (v) => full.format(v) + suffix };
}

/** «Круглый» шаг шкалы: 1, 2, 2.5, 5 × 10ⁿ — около count делений. */
function niceStep(range, count) {
	const raw = range / count;
	const power = 10 ** Math.floor(Math.log10(raw));
	return [1, 2, 2.5, 5, 10].map((m) => m * power).find((step) => step >= raw) ?? raw;
}

/** Столбцы, линии и области: оси, сетка, подписи; show(index, x, y) — подсказка по точке. */
function drawAxes(svg, width, height, labels, series, type, stacked, format, show) {
	const stackable = stacked && type !== 'line';
	const totals = labels.map((_, i) => series.reduce((sum, s) => sum + Math.max(s.values[i] ?? 0, 0), 0));
	const values = series.flatMap((s) => s.values);
	let max = Math.max(0, ...(stackable ? totals : values));
	let min = Math.min(0, ...values);
	if (max === min) {
		max = min + 1;
	}
	const step = niceStep(max - min, 4);
	min = Math.floor(min / step) * step;
	max = Math.ceil(max / step) * step;

	const ticks = [];
	for (let v = min; v <= max + step / 2; v += step) {
		ticks.push(Math.round(v / step) * step);
	}
	const left = Math.max(...ticks.map((v) => format.short(v).length)) * 7 + 12;
	const plot = { left, right: width - 8, top: 10, bottom: height - 26 };
	const y = (v) => plot.bottom - (v - min) / (max - min) * (plot.bottom - plot.top);
	const band = (plot.right - plot.left) / labels.length;
	const x = (i) => plot.left + band * (i + 0.5);

	for (const v of ticks) {
		svg.append(svgNode('line', { class: v === 0 ? 'erp-chart-zero' : 'erp-chart-grid', x1: plot.left, x2: plot.right, y1: y(v), y2: y(v) }));
		const text = svgNode('text', { class: 'erp-chart-axis', x: plot.left - 6, y: y(v) + 4, 'text-anchor': 'end' });
		text.textContent = format.short(v);
		svg.append(text);
	}
	// Подписи оси X: на узком графике — через одну (две, …), длинные укорачиваются
	const every = Math.max(1, Math.ceil(labels.length * 64 / (plot.right - plot.left)));
	const maxChars = Math.max(3, Math.floor(band * every / 7));
	labels.forEach((label, i) => {
		if (i % every !== 0) {
			return;
		}
		const text = svgNode('text', { class: 'erp-chart-axis', x: x(i), y: plot.bottom + 17, 'text-anchor': 'middle' });
		text.textContent = label.length > maxChars ? `${label.slice(0, maxChars - 1)}…` : label;
		svg.append(text);
	});

	// Подсветка точки под курсором — полоса во всю высоту
	const hovers = labels.map((_, i) => svgNode('rect', { class: 'erp-chart-band', x: plot.left + band * i, y: plot.top,
		width: band, height: plot.bottom - plot.top }));
	svg.prepend(...hovers);

	if (type === 'bar') {
		const inner = band * 0.72;
		const barWidth = stackable ? inner : inner / series.length;
		const base = labels.map(() => 0);
		series.forEach((s, si) => {
			s.values.forEach((v, i) => {
				let from = 0;
				let to = v;
				if (stackable) {
					from = base[i];
					to = from + Math.max(v, 0);
					base[i] = to;
				}
				const x0 = x(i) - inner / 2 + (stackable ? 0 : barWidth * si);
				const top = y(Math.max(from, to));
				const h = Math.max(Math.abs(y(from) - y(to)), v ? 1 : 0);
				svg.append(svgNode('rect', { class: `erp-chart-bar erp-chart-c${si % CHART_COLORS}`,
					x: x0 + 1, y: top, width: Math.max(barWidth - 2, 1), height: h, rx: Math.min(3, barWidth / 4) }));
			});
		});
	}
	else {
		const base = labels.map(() => 0);
		series.forEach((s, si) => {
			const points = s.values.map((v, i) => {
				const from = stackable ? base[i] : 0;
				const to = from + (stackable ? Math.max(v, 0) : v);
				if (stackable) {
					base[i] = to;
				}
				return [x(i), y(to), y(from)];
			});
			const line = points.map(([px, py], i) => `${i ? 'L' : 'M'}${px.toFixed(1)},${py.toFixed(1)}`).join('');
			if (type === 'area') {
				const back = points.slice().reverse().map(([px, , py0]) => `L${px.toFixed(1)},${py0.toFixed(1)}`).join('');
				svg.append(svgNode('path', { class: `erp-chart-area erp-chart-c${si % CHART_COLORS}`, d: `${line}${back}Z` }));
			}
			svg.append(svgNode('path', { class: `erp-chart-line erp-chart-c${si % CHART_COLORS}`, d: line }));
			if (labels.length <= 40) {
				points.forEach(([px, py]) => svg.append(svgNode('circle', { class: `erp-chart-dot erp-chart-c${si % CHART_COLORS}`,
					cx: px, cy: py, r: 3 })));
			}
		});
	}

	svg.addEventListener('mousemove', (event) => {
		const box = svg.getBoundingClientRect();
		const i = Math.floor((event.clientX - box.left - plot.left) / band);
		hovers.forEach((node, n) => node.classList.toggle('is-hover', n === i));
		if (i >= 0 && i < labels.length) {
			show(i, event.clientX, event.clientY);
		}
	});
}

/** Круговая диаграмма (кольцо) по первому ряду; отрицательные значения не рисуются. */
function drawPie(svg, width, height, labels, values, show) {
	const total = values.reduce((sum, v) => sum + Math.max(v, 0), 0);
	const radius = Math.min(width, height) / 2 - 8;
	const cx = width / 2;
	const cy = height / 2;
	if (total <= 0) {
		return;
	}
	let angle = -Math.PI / 2;
	values.forEach((v, i) => {
		if (v <= 0) {
			return;
		}
		const sweep = v / total * Math.PI * 2;
		const end = angle + Math.min(sweep, Math.PI * 2 - 0.0001);
		const point = (a, r) => `${(cx + r * Math.cos(a)).toFixed(2)},${(cy + r * Math.sin(a)).toFixed(2)}`;
		const inner = radius * 0.58;
		const large = sweep > Math.PI ? 1 : 0;
		const slice = svgNode('path', { class: `erp-chart-slice erp-chart-c${i % CHART_COLORS}`,
			d: `M${point(angle, radius)}A${radius},${radius} 0 ${large} 1 ${point(end, radius)}`
				+ `L${point(end, inner)}A${inner},${inner} 0 ${large} 0 ${point(angle, inner)}Z` });
		slice.addEventListener('mousemove', (event) => show(i, event.clientX, event.clientY));
		svg.append(slice);
		angle += sweep;
	});
}

const PAGE_SIZE = 10;
// Пауза после ввода в поле-фильтр перед запросом, мс
const FILTER_DELAY = 300;

// Числа — по правилам языка интерфейса
/** Тоны меток (колонки badge); neutral — без цвета. Цвета — в css/app.css (.badge-tone-*). */
const BADGE_TONES = new Set(['accent', 'attention', 'success', 'done', 'danger']);
const moneyFormat = new Intl.NumberFormat(language(), { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const numberFormat = new Intl.NumberFormat(language());

/**
 * Таблица с постраничным просмотром. Данные, колонки и пагинацию
 * возвращает действие-источник: {meta, columns, rows}.
 * Источник получает значения полей формы — по ним он может фильтровать строки.
 * Таблица-детали (component.master) передаёт источнику master_id — значение поля формы-мастера.
 * В режиме выбора (onSelect) в строках есть «Выбрать», двойной щелчок по строке тоже выбирает её.
 */
function renderGrid(component, formElement, preview, onSelect) {
	const element = document.createElement('section');
	element.className = 'erp-grid';

	if (component.label) {
		const caption = document.createElement('h3');
		caption.textContent = component.label;
		element.append(caption);
	}
	const body = document.createElement('div');
	body.className = 'erp-grid-body';
	const pager = document.createElement('div');
	pager.className = 'erp-pager';
	element.append(body, pager);

	// Строк на странице — options.page_size (1–100, больше база не отдаёт), по умолчанию PAGE_SIZE
	const pageSize = Math.min(Math.max(Math.trunc(Number(component.options?.page_size)) || PAGE_SIZE, 1), 100);

	if (preview) {
		// Редактор: первая страница настоящих данных источника — только для просмотра (щелчок выбирает компонент)
		element.classList.add('is-preview');
		const source = t('Data: {0}', component.action ?? '—')
			+ (component.master ? t(' · master: {0}', component.master) : '');
		body.textContent = source;
		if (component.action) {
			previewPage(component.action, { page: 1, limit: pageSize }).then((result) => {
				body.replaceChildren(renderTable(result.columns, result.rows, result.row_actions ?? [], formElement,
					result.meta.sort ?? null, () => {}));
				pager.textContent = t('Page {0} of {1} · {2} total', 1, result.meta.total_pages, result.meta.total_rows);
			}).catch((error) => {
				body.textContent = `${source} — ${error.message}`;
			});
		}
		return { element, master: component.master, load() {}, currentPage: () => 1 };
	}

	let currentPage = 1;
	// Пока не выбрано пользователем, сортировку по умолчанию определяет база
	let sort = null;

	async function load(page) {
		try {
			// Источник получает значения полей формы (фильтры) и параметры страницы
			const params = { ...Object.fromEntries(new FormData(formElement)), page, limit: pageSize };
			delete params.sort_field;
			delete params.sort_dir;
			delete params.master_id;
			if (component.master) {
				params.master_id = formElement.elements.namedItem(component.master)?.value ?? '';
			}
			if (sort) {
				params.sort_field = sort.field;
				params.sort_dir = sort.dir;
			}
			const result = await callAction(component.action, params);
			currentPage = result.meta.current_page;
			sort = result.meta.sort ?? sort;
			const rowActions = result.row_actions ?? [];
			if (onSelect) {
				rowActions.unshift({ label: t('Select'), style: 'primary', select: true });
			}
			body.replaceChildren(renderTable(result.columns, result.rows, rowActions, formElement,
				sort, sortBy, onSelect));
			renderPager(result.meta);
			element.dispatchEvent(new CustomEvent('grid-loaded', { bubbles: true, detail: { total: result.meta.total_rows } }));
		}
		catch (error) {
			body.textContent = error.message;
		}
	}

	function renderPager(meta) {
		const pageButton = (icon, label, page, disabled) => {
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'erp-pager-button';
			button.innerHTML = PAGER_ICONS[icon];
			button.title = label;
			button.setAttribute('aria-label', label);
			button.disabled = disabled;
			button.addEventListener('click', () => load(page));
			return button;
		};
		const first = meta.current_page <= 1;
		const last = meta.current_page >= meta.total_pages;
		const info = document.createElement('span');
		info.textContent = t('Page {0} of {1} · {2} total', meta.current_page, meta.total_pages, meta.total_rows);
		pager.replaceChildren(
			pageButton('first', t('First page'), 1, first),
			pageButton('previous', t('Previous page'), meta.current_page - 1, first),
			info,
			pageButton('next', t('Next page'), meta.current_page + 1, last),
			pageButton('last', t('Last page'), meta.total_pages, last),
		);
	}

	// Повторный щелчок по той же колонке меняет направление
	function sortBy(field) {
		sort = { field, dir: (sort?.field === field && sort.dir === 'asc') ? 'desc' : 'asc' };
		load(1);
	}

	// Первая загрузка — после того как форма заполнена данными (fillForm идёт сразу за renderForm),
	// иначе таблица-детали не увидит значение поля-мастера
	queueMicrotask(() => load(1));
	return { element, master: component.master, load, currentPage: () => currentPage };
}

// Значки узлов дерева, 16×16 (статическая разметка, цвет — из CSS через currentColor)
const TREE_ICONS = {
	folder: '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M1.5 3.25c0-.69.56-1.25 1.25-1.25h3.1c.4 0 .78.19 1.01.51l.84 1.12c.1.13.24.2.4.2h5.15c.69 0 1.25.56 1.25 1.25v7.67c0 .69-.56 1.25-1.25 1.25H2.75c-.69 0-1.25-.56-1.25-1.25z"/></svg>',
	folderOpen: '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="currentColor" d="M1.5 3.25c0-.69.56-1.25 1.25-1.25h3.1c.4 0 .78.19 1.01.51l.84 1.12c.1.13.24.2.4.2h5.15c.69 0 1.25.56 1.25 1.25V6.5H4.6c-.6 0-1.13.38-1.32.95L1.5 12.8z"/><path fill="currentColor" d="M4.13 7.6a.75.75 0 0 1 .71-.5h10.08c.5 0 .86.48.72.96l-1.43 4.88c-.16.53-.65.9-1.2.9H2.25a.5.5 0 0 1-.47-.66z"/></svg>',
	file: '<svg viewBox="0 0 16 16" width="16" height="16"><path fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" d="M3.65 2.15h5.2l3.5 3.5v8.2a.5.5 0 0 1-.5.5h-8.2a.5.5 0 0 1-.5-.5V2.65a.5.5 0 0 1 .5-.5z"/><path fill="none" stroke="currentColor" stroke-width="1.3" stroke-linejoin="round" d="M8.65 2.25v3.6h3.6"/></svg>',
};

/**
 * Дерево. Источник данных — действие component.action: получает значения полей формы и parent_id
 * (пусто — корни) и возвращает уровень {nodes: [{id, label, has_children, ...}]}; дети запрашиваются
 * при раскрытии. Значение компонента — id выбранного узла (скрытое поле с именем компонента);
 * таблицы с master = имя дерева перечитываются при выборе. load() перечитывает дерево,
 * сохраняя раскрытые узлы и выбор. В режиме выбора (onSelect) узел выбирается двойным щелчком,
 * Enter или кнопкой «Выбрать».
 */
function renderTree(component, formElement, preview, onSelect) {
	const element = document.createElement('section');
	element.className = 'erp-tree';
	if (component.label) {
		const caption = document.createElement('h3');
		caption.textContent = component.label;
		element.append(caption);
	}
	const input = document.createElement('input');
	input.type = 'hidden';
	input.name = component.name;
	const root = document.createElement('ul');
	root.className = 'erp-tree-level';
	root.setAttribute('role', 'tree');
	root.setAttribute('aria-label', component.label || component.name);
	element.append(input, root);

	// Редактор: корневые узлы источника — только для просмотра (щелчок выбирает компонент), данные кешируются (previewPage)
	const source = t('Data: {0}', component.action ?? '—');
	if (preview) {
		element.classList.add('is-preview');
		root.textContent = source;
		if (!component.action) {
			return { element, load() {}, currentPage: () => 1 };
		}
	}

	const expanded = new Set();  // id раскрытых узлов
	const items = new Map();     // id → {node, li, children}
	let selectedId = '';         // прежний выбор: set_values меняет поле раньше, чем вызывается select

	async function fetchLevel(parentId) {
		if (preview) {
			return (await previewPage(component.action, { parent_id: parentId ?? '' })).nodes ?? [];
		}
		const data = { ...Object.fromEntries(new FormData(formElement)), parent_id: parentId ?? '' };
		return (await callAction(component.action, data)).nodes ?? [];
	}

	async function renderLevel(container, parentId, depth = 0) {
		const nodes = await fetchLevel(parentId);
		container.replaceChildren(...nodes.map((node) => renderNode(node, depth)));
		if (nodes.length === 0 && parentId === null) {
			const empty = document.createElement('li');
			empty.className = 'erp-tree-empty';
			empty.textContent = t('Empty');
			container.append(empty);
		}
		// Раскрытые до перечитывания узлы раскрываются снова
		await Promise.all(nodes.filter((n) => n.has_children && expanded.has(String(n.id)))
			.map((n) => expand(String(n.id))));
	}

	// depth — уровень вложенности: строки во всю ширину дерева, отступ и направляющие — внутри строки
	function renderNode(node, depth) {
		const id = String(node.id);
		const li = document.createElement('li');
		li.setAttribute('role', 'treeitem');
		li.dataset.id = id;
		const row = document.createElement('div');
		row.className = 'erp-tree-row';
		row.tabIndex = -1;
		const toggle = document.createElement('span');
		toggle.className = 'erp-tree-toggle';
		toggle.setAttribute('aria-hidden', 'true');
		// Значок: папка (открытая — когда узел раскрыт); "icon": "file" в узле — конечный элемент, не группа
		const icon = document.createElement('span');
		icon.className = 'erp-tree-icon';
		icon.setAttribute('aria-hidden', 'true');
		const isFile = node.icon === 'file' && !node.has_children;
		icon.classList.toggle('is-file', isFile);
		icon.innerHTML = isFile ? TREE_ICONS.file : TREE_ICONS.folder;
		const label = document.createElement('span');
		label.className = 'erp-tree-label';
		label.textContent = node.label ?? id;
		row.append(toggle, icon, label);
		const children = document.createElement('ul');
		children.className = 'erp-tree-level';
		children.setAttribute('role', 'group');
		children.hidden = true;
		li.append(row, children);
		if (node.has_children) {
			li.setAttribute('aria-expanded', 'false');
		}
		li.setAttribute('aria-selected', String(input.value === id));

		toggle.addEventListener('click', (event) => {
			event.stopPropagation();
			toggleNode(id);
		});
		// Щелчок сам ставит фокус на строку; программный фокус — только для клавиатуры, иначе видна рамка фокуса
		row.addEventListener('click', () => select(id, { focus: false }));
		row.addEventListener('dblclick', () => (onSelect ? onSelect(node) : toggleNode(id)));
		// Уровень — на элементе списка: по нему строка считает отступ, а соединительные линии — своё место
		li.style.setProperty('--depth', depth);
		items.set(id, { node, li, children, depth });
		return li;
	}

	async function expand(id) {
		const item = items.get(id);
		if (!item?.node.has_children) {
			return;
		}
		expanded.add(id);
		item.li.setAttribute('aria-expanded', 'true');
		item.li.querySelector(':scope > .erp-tree-row .erp-tree-icon').innerHTML = TREE_ICONS.folderOpen;
		item.children.hidden = false;
		// Индикатор загрузки на месте стрелки, пока база отдаёт детей
		item.li.classList.add('is-loading');
		try {
			await renderLevel(item.children, id, item.depth + 1);
		}
		finally {
			item.li.classList.remove('is-loading');
		}
	}

	function collapse(id) {
		const item = items.get(id);
		if (!item?.node.has_children) {
			return;
		}
		expanded.delete(id);
		item.li.setAttribute('aria-expanded', 'false');
		item.li.querySelector(':scope > .erp-tree-row .erp-tree-icon').innerHTML = TREE_ICONS.folder;
		item.children.hidden = true;
	}

	function toggleNode(id) {
		return expanded.has(id) ? collapse(id) : expand(id).catch((error) => showMessage(error.message, 'error'));
	}

	// Выбор узла: значение компонента, подсветка, таблицы-детали
	function select(id, { focus = true } = {}) {
		const changed = selectedId !== id;
		selectedId = id;
		input.value = id;
		markSelection(focus);
		if (changed) {
			for (const grid of formElement.grids.values()) {
				if (grid.master === component.name) {
					grid.load(1);
				}
			}
		}
	}

	function markSelection(focus = false) {
		// Без выбора в дерево по Tab попадают на первый узел
		const first = items.has(input.value) ? null : items.keys().next().value;
		for (const [id, item] of items) {
			const selected = id === input.value;
			item.li.setAttribute('aria-selected', String(selected));
			const row = item.li.querySelector(':scope > .erp-tree-row');
			row.tabIndex = (selected || id === first) ? 0 : -1;
			row.querySelector('.erp-tree-choose')?.remove();
			if (selected && onSelect) {
				const choose = document.createElement('button');
				choose.type = 'button';
				choose.className = 'erp-tree-choose';
				choose.textContent = t('Select');
				choose.addEventListener('click', (event) => {
					event.stopPropagation();
					onSelect(item.node);
				});
				row.append(choose);
			}
			if (selected && focus) {
				row.focus();
			}
		}
	}

	// Значение, заданное базой (set_values), — тоже выбор
	input.addEventListener('erp-value', () => select(input.value, { focus: false }));

	// Клавиатура: ↑ ↓ — соседние видимые узлы, → — раскрыть, ← — свернуть или к родителю, Enter — выбрать
	root.addEventListener('keydown', (event) => {
		const current = items.get(input.value);
		const visible = [...root.querySelectorAll('[role=treeitem]')].filter((li) => !li.closest('[hidden]'));
		const index = current ? visible.indexOf(current.li) : -1;
		const go = (li) => li && select(li.dataset.id);
		switch (event.key) {
			case 'ArrowDown':
				go(index < 0 ? visible[0] : visible[Math.min(index + 1, visible.length - 1)]);
				break;
			case 'ArrowUp':
				go(index < 0 ? visible[0] : visible[Math.max(index - 1, 0)]);
				break;
			case 'ArrowRight':
				if (current?.node.has_children && !expanded.has(input.value)) {
					toggleNode(input.value);
				}
				else {
					go(current?.children.querySelector('[role=treeitem]'));
				}
				break;
			case 'ArrowLeft':
				if (current && expanded.has(input.value)) {
					collapse(input.value);
				}
				else {
					go(current?.li.parentElement.closest('[role=treeitem]'));
				}
				break;
			case 'Enter':
				if (current && onSelect) {
					onSelect(current.node);
				}
				else if (current) {
					toggleNode(input.value);
				}
				break;
			default:
				return;
		}
		event.preventDefault();
	});

	// Перечитать дерево; выбранный узел раскрывается — после добавления подгруппы её видно сразу
	async function load() {
		try {
			if (input.value) {
				expanded.add(input.value);
			}
			items.clear();
			await renderLevel(root, null);
			if (input.value && !items.has(input.value)) {
				select('', { focus: false });  // выбранный узел удалён
			}
			markSelection();
		}
		catch (error) {
			root.textContent = preview ? `${source} — ${error.message}` : error.message;
		}
	}

	queueMicrotask(load);
	return { element, load, currentPage: () => 1 };
}

function renderTable(columns, rows, rowActions, formElement, sort, onSort, onSelect) {
	// Если колонки не описаны в метаданных, берём поля первой строки
	if (columns.length === 0 && rows.length > 0) {
		columns = Object.keys(rows[0]).map((field) => ({ field, title: field, type: 'text' }));
	}
	const table = document.createElement('table');
	const head = table.createTHead().insertRow();
	for (const column of columns) {
		const th = document.createElement('th');
		th.className = `cell-${column.type}`;
		if (column.sortable) {
			const sorted = sort?.field === column.field;
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'sort-header';
			button.textContent = column.title;
			const arrow = document.createElement('span');
			arrow.className = 'sort-arrow';
			arrow.textContent = sorted ? (sort.dir === 'asc' ? '▲' : '▼') : '';
			button.append(arrow);
			button.addEventListener('click', () => onSort(column.field));
			th.ariaSort = sorted ? (sort.dir === 'asc' ? 'ascending' : 'descending') : 'none';
			th.append(button);
		}
		else {
			th.textContent = column.title;
		}
		head.append(th);
	}
	if (rowActions.length > 0) {
		head.append(document.createElement('th'));
	}
	const tbody = table.createTBody();
	for (const row of rows) {
		const tr = tbody.insertRow();
		if (onSelect) {
			tr.classList.add('selectable');
			tr.addEventListener('dblclick', () => onSelect(row));
		}
		for (const column of columns) {
			const td = tr.insertCell();
			td.className = `cell-${column.type}`;
			td.append(formatCell(row[column.field], column.type));
		}
		if (rowActions.length > 0) {
			const td = tr.insertCell();
			td.className = 'cell-actions';
			for (const rowAction of rowActions) {
				td.append(renderRowAction(rowAction, row, formElement, onSelect));
			}
		}
	}
	if (rows.length === 0) {
		const td = tbody.insertRow().insertCell();
		td.colSpan = (columns.length || 1) + (rowActions.length > 0 ? 1 : 0);
		td.textContent = t('No data');
	}
	return table;
}

/** Кнопка в строке таблицы: вызывает действие с {"id": <id строки>} или выбирает строку. */
function renderRowAction(rowAction, row, formElement, onSelect) {
	const button = document.createElement('button');
	button.type = 'button';
	button.className = `row-action row-action-${rowAction.style}`;
	button.textContent = rowAction.label;
	button.addEventListener('click', async () => {
		if (rowAction.select) {
			onSelect(row);
			return;
		}
		button.disabled = true;
		try {
			const result = await callAction(rowAction.action, { id: row.id });
			await applyInstructions(result.ui_instructions, formElement);
		}
		catch (error) {
			await showError(error, formElement);
		}
		finally {
			button.disabled = false;
		}
	});
	return button;
}

function formatCell(value, type) {
	if (value === null || value === undefined) {
		return '';
	}
	switch (type) {
		case 'money':
			return moneyFormat.format(value);
		case 'number':
			return numberFormat.format(value);
		case 'badge': {
			// Значение — текст или {label, tone} (pgerp.ui_badge): цвет задают данные, подпись переведена базой.
			// Неизвестный тон — без цвета (neutral)
			const badge = document.createElement('span');
			badge.className = 'badge';
			if (typeof value === 'object') {
				if (BADGE_TONES.has(value.tone)) {
					badge.classList.add(`badge-tone-${value.tone}`);
				}
				badge.textContent = value.label ?? '';
			}
			else {
				badge.textContent = value;
			}
			return badge;
		}
		default:
			return String(value);
	}
}

/** Значки постраничной навигации таблиц: шевроны 16×16, цвет — currentColor. */
const PAGER_ICONS = Object.fromEntries(Object.entries({
	first: 'M4 3.5v9M11.5 4 7.5 8l4 4',
	previous: 'M10 4 6 8l4 4',
	next: 'M6 4l4 4-4 4',
	last: 'M12 3.5v9M4.5 4l4 4-4 4',
}).map(([name, path]) => [name, '<svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">'
	+ `<path d="${path}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg>`]));
