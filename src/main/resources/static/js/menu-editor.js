import { applyInstructions, callAction, showMessage } from './ui-runtime.js';
import { t } from './i18n.js';

/**
 * Редактор меню приложения: дерево пунктов с произвольной вложенностью.
 * У пункта — название и форма, которая открывается при переходе к нему; пункт с подпунктами
 * в приложении — раскрывающаяся группа. Меню сохраняется целиком (действие menu_save).
 *
 * root — контейнер редактора; onDirty(value) — сообщает о несохранённых изменениях.
 * Возвращает { open(forms), dirty }: open загружает меню; forms — [{name, title}] для выбора формы.
 */
export function createMenuEditor(root, { onDirty = () => {} } = {}) {
	const NEW_TITLE = t('New item');

	let items = [];      // [{title, form, items: [...]}]
	let forms = [];
	let selected = null; // выбранный пункт (объект из items)
	let dirty = false;

	const canvas = document.createElement('section');
	canvas.className = 'editor-canvas';
	const toolbar = document.createElement('div');
	toolbar.className = 'toolbar';
	const dirtyMark = document.createElement('span');
	dirtyMark.className = 'editor-dirty';
	dirtyMark.title = t('There are unsaved changes');
	dirtyMark.textContent = t('● Not saved');
	dirtyMark.hidden = true;
	const addButton = button(t('+ Item'), () => addItem(false), false, t('New item after the selected one, at the same level'));
	const addChildButton = button(t('+ Subitem'), () => addItem(true), false, t('New item inside the selected one'));
	const saveButton = button(t('Save'), save);
	saveButton.className = 'primary';
	toolbar.append(spacer(), dirtyMark, addButton, addChildButton, saveButton);

	const tree = document.createElement('div');
	tree.className = 'menu-editor-tree';
	tree.tabIndex = 0;
	tree.setAttribute('role', 'tree');
	tree.setAttribute('aria-label', t('Menu items'));
	canvas.append(heading(t('Application menu')), toolbar, tree);

	const props = document.createElement('aside');
	props.className = 'editor-props';
	props.setAttribute('aria-label', t('Item properties'));
	root.replaceChildren(canvas, props);

	// -----------------------------------------------------------------
	// Загрузка и сохранение
	// -----------------------------------------------------------------
	async function open(formList) {
		forms = formList;
		// Исходные тексты пунктов, не перевод: меню сохраняется обратно
		const result = await callAction('menu_get', { source: true });
		items = normalize(result.items);
		selected = null;
		setDirty(false);
		render();
	}

	/** Только то, что хранит меню: id пунктов назначает база при сохранении. */
	function normalize(list) {
		return list.map((item) => ({ title: item.title, form: item.form ?? null, items: normalize(item.items ?? []) }));
	}

	async function save() {
		const path = selected ? pathOf(selected) : null;
		try {
			const result = await callAction('menu_save', { items: normalize(items) });
			await applyInstructions(result.ui_instructions);
			await open(forms);
			// Выбор остаётся на том же месте дерева
			selected = path ? itemAt(path) : null;
			render();
		}
		catch (error) {
			showMessage(error.message, 'error');
		}
	}

	function setDirty(value) {
		dirty = value;
		dirtyMark.hidden = !dirty;
		onDirty(dirty);
	}

	function changed() {
		setDirty(true);
		render();
	}

	// -----------------------------------------------------------------
	// Положение пункта в дереве
	// -----------------------------------------------------------------
	/** Список, в котором лежит пункт, его индекс и пункт-родитель (null — верхний уровень). */
	function locate(target, list = items, parent = null) {
		for (const [index, item] of list.entries()) {
			if (item === target) {
				return { list, index, parent };
			}
			const found = locate(target, item.items, item);
			if (found) {
				return found;
			}
		}
		return null;
	}

	/** Путь к пункту — номера на каждом уровне. */
	function pathOf(target) {
		const place = locate(target);
		return place.parent ? [...pathOf(place.parent), place.index] : [place.index];
	}

	function itemAt(path) {
		let list = items;
		let item = null;
		for (const index of path) {
			item = list[index];
			if (!item) {
				return null;
			}
			list = item.items;
		}
		return item;
	}

	/** Пункты по порядку отображения: [{item, depth}]. */
	function flatten(list = items, depth = 0) {
		return list.flatMap((item) => [{ item, depth }, ...flatten(item.items, depth + 1)]);
	}

	// -----------------------------------------------------------------
	// Изменение дерева
	// -----------------------------------------------------------------
	function addItem(asChild) {
		const item = { title: NEW_TITLE, form: null, items: [] };
		if (asChild && selected) {
			selected.items.push(item);
		}
		else if (selected) {
			const place = locate(selected);
			place.list.splice(place.index + 1, 0, item);
		}
		else {
			items.push(item);
		}
		selected = item;
		changed();
		// Сразу можно вводить название
		const title = props.querySelector('input');
		title?.focus();
		title?.select();
	}

	/** Выше / ниже среди пунктов своего уровня. */
	function move(delta) {
		const { list, index } = locate(selected);
		list.splice(index, 1);
		list.splice(index + delta, 0, selected);
		changed();
	}

	/** Вправо: пункт становится последним подпунктом предыдущего пункта своего уровня. */
	function indent() {
		const { list, index } = locate(selected);
		list.splice(index, 1);
		list[index - 1].items.push(selected);
		changed();
	}

	/** Влево: пункт выходит из группы и встаёт сразу после неё. */
	function outdent() {
		const { list, index, parent } = locate(selected);
		const outer = locate(parent);
		list.splice(index, 1);
		outer.list.splice(outer.index + 1, 0, selected);
		changed();
	}

	function remove() {
		const count = flatten(selected.items).length;
		if (count > 0 && !confirm(t('Delete item “{0}” with its subitems ({1})?', selected.title, count))) {
			return;
		}
		const { list, index, parent } = locate(selected);
		list.splice(index, 1);
		// Выбор переходит к соседу или к родителю
		selected = list[index] ?? list[index - 1] ?? parent;
		changed();
	}

	function formTitle(name) {
		return forms.find((f) => f.name === name)?.title;
	}

	// -----------------------------------------------------------------
	// Отрисовка
	// -----------------------------------------------------------------
	function render() {
		addChildButton.disabled = !selected;
		renderTree();
		renderProps();
	}

	function renderTree() {
		const rows = flatten();
		if (rows.length === 0) {
			const empty = document.createElement('p');
			empty.className = 'editor-empty';
			empty.textContent = t('The menu has no items yet — add them with the “+ Item” button.');
			tree.replaceChildren(empty);
			return;
		}
		tree.replaceChildren(...rows.map(({ item, depth }) => {
			const row = document.createElement('div');
			row.className = 'menu-editor-row';
			row.setAttribute('role', 'treeitem');
			row.setAttribute('aria-level', String(depth + 1));
			row.setAttribute('aria-selected', String(item === selected));
			row.classList.toggle('is-selected', item === selected);
			row.classList.toggle('is-group', item.items.length > 0);
			row.style.setProperty('--depth', String(depth));

			const title = document.createElement('span');
			title.className = 'menu-editor-title';
			title.textContent = item.title;
			const form = document.createElement('span');
			form.className = 'menu-editor-form';
			if (item.form) {
				form.textContent = `${formTitle(item.form) ?? '?'} (${item.form})`;
			}
			else if (item.items.length === 0) {
				form.textContent = t('no form');
				form.classList.add('is-missing');
			}
			row.append(title, form);
			row.addEventListener('click', () => {
				selected = item;
				render();
			});
			return row;
		}));
		tree.querySelector('.is-selected')?.scrollIntoView({ block: 'nearest' });
	}

	function renderProps() {
		if (!selected) {
			props.replaceChildren(
				heading(t('Menu')),
				hint(t('Click an item to edit it. An item with subitems is an expandable group in the application; ')
					+ t('an item with a form opens it when selected.')),
				hint(t('The ← → buttons change nesting: → makes the item a subitem of the previous one, ← moves it out of the group.')),
			);
			return;
		}

		const { list, index, parent } = locate(selected);
		const tools = document.createElement('div');
		tools.className = 'editor-props-tools';
		const removeButton = button(t('Delete'), remove, false, t('Delete item (Delete)'));
		removeButton.className = 'danger';
		tools.append(
			button('↑', () => move(-1), index === 0, t('Up (Alt+↑)')),
			button('↓', () => move(1), index === list.length - 1, t('Down (Alt+↓)')),
			button('←', outdent, !parent, t('Move out of the group (Alt+←)')),
			button('→', indent, index === 0, t('Make a subitem of the previous one (Alt+→)')),
			removeButton,
		);

		const title = document.createElement('input');
		title.value = selected.title;
		title.addEventListener('input', () => {
			selected.title = title.value;
			setDirty(true);
			renderTree();
		});

		const form = document.createElement('select');
		form.add(new Option(t('— no form —'), ''));
		for (const f of forms) {
			form.add(new Option(`${f.title} (${f.name})`, f.name, false, f.name === selected.form));
		}
		form.addEventListener('change', () => {
			// Название по умолчанию заменяется заголовком выбранной формы
			const previous = formTitle(selected.form);
			if (!selected.title.trim() || selected.title === NEW_TITLE || selected.title === previous) {
				selected.title = formTitle(form.value) ?? selected.title;
			}
			selected.form = form.value || null;
			changed();
		});

		const fields = [
			field(t('Title'), title),
			field(t('Form'), form, selected.items.length > 0
				? t('Optional for a group: the group title becomes a link to the form')
				: t('Opens when the item is selected')),
		];
		if (selected.form) {
			const link = document.createElement('a');
			link.href = `./?form=${encodeURIComponent(selected.form)}`;
			link.target = '_blank';
			link.textContent = t('Open form');
			fields.push(link);
		}
		props.replaceChildren(heading(t('Menu item')), tools, ...fields);
	}

	// Клавиши в дереве: ↑ ↓ — выбор, Alt+стрелки — перемещение, Delete — удаление, Escape — снять выбор
	tree.addEventListener('keydown', (event) => {
		const rows = flatten();
		const position = rows.findIndex((row) => row.item === selected);
		if (event.altKey && selected) {
			const { list, index, parent } = locate(selected);
			const moves = {
				ArrowUp: index > 0 && (() => move(-1)),
				ArrowDown: index < list.length - 1 && (() => move(1)),
				ArrowLeft: parent && outdent,
				ArrowRight: index > 0 && indent,
			};
			if (event.key in moves) {
				event.preventDefault();
				moves[event.key]?.();
			}
			return;
		}
		switch (event.key) {
			case 'ArrowDown':
				selected = rows[Math.min(position + 1, rows.length - 1)]?.item ?? null;
				break;
			case 'ArrowUp':
				selected = rows[Math.max(position - 1, 0)]?.item ?? null;
				break;
			case 'Delete':
				if (selected) {
					remove();
				}
				break;
			case 'Escape':
				selected = null;
				break;
			default:
				return;
		}
		event.preventDefault();
		render();
	});

	// -----------------------------------------------------------------
	// Элементы панели
	// -----------------------------------------------------------------
	function heading(text) {
		const element = document.createElement('h3');
		element.textContent = text;
		return element;
	}

	function hint(text) {
		const element = document.createElement('p');
		element.className = 'editor-hint';
		element.textContent = text;
		return element;
	}

	function field(caption, control, help) {
		const wrapper = document.createElement('label');
		wrapper.className = 'erp-field';
		const span = document.createElement('span');
		span.textContent = caption;
		wrapper.append(span, control);
		if (help) {
			wrapper.append(hint(help));
		}
		return wrapper;
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
	};
}
