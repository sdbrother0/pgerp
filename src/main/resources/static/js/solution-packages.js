import { callAction, csrfHeaders, showConfirm, showMessage } from './ui-runtime.js';
import { button, checkbox, el, hint, input, spacer, table } from './editor-kit.js';
import { language, t } from './i18n.js';

/**
 * Пакеты прикладных решений (db/solutions/<папка> в приложении): окно установки.
 * <ul>
 * <li>setup — первый вход администратора: отметить решения, «Установить выбранные» или «Пропустить»;
 * после этого окно больше не показывается (действие solutions_setup_done), страница перезагружается.</li>
 * <li>иначе — редактор («Решения → Установить решения»): установка и обновление любого пакета.</li>
 * </ul>
 * Новое решение ставится в свою схему базы: по умолчанию — из пакета (обычно имя решения).
 * «Удалить схему» — чистая установка: решение, его схема со всеми данными и метаданные (формы, меню, роли…)
 * удаляются перед установкой; только после подтверждения.
 * Возвращает Promise: true — что-то установлено.
 */
export function showSolutionPackages({ setup = false } = {}) {
	return new Promise((resolve) => {
		let packages = [];
		const selected = new Set();
		const resets = new Set();
		const schemas = {};
		let busy = false;
		let installed = false;

		const dialog = el('dialog', { className: 'code-view packages-dialog' });
		const body = el('div', { className: 'packages-body' });
		const footer = el('div', { className: 'toolbar' });
		dialog.append(el('header', {},
			el('h3', { textContent: setup ? t('Which solutions to install?') : t('Solution installation') }),
			el('p', { textContent: setup
				? t('The platform is installed. Choose application solutions — you can also install them later: “Editor → Solutions → Install solutions”.')
				: t('Solution packages shipped with the application. Each solution goes into its own database schema; installed solutions are updated to the latest release of the package.') })),
		body, footer);

		function close() {
			dialog.close();
		}
		dialog.addEventListener('cancel', (e) => {
			if (busy) {
				e.preventDefault();
			}
		});
		dialog.addEventListener('close', () => {
			dialog.remove();
			resolve(installed);
		});

		async function load() {
			const response = await fetch('api/dev/solutions', { headers: { 'Accept-Language': language() } });
			const result = await response.json().catch(() => ({ status: 'error', message: `HTTP ${response.status}` }));
			if (!response.ok || result.status === 'error') {
				throw new Error(result.message);
			}
			packages = result.packages;
			for (const p of packages) {
				schemas[p.name] ??= p.schema;
				if (setup && p.installed_version === null && p.version > 0) {
					selected.add(p.name);
				}
			}
			render();
		}

		function state(p) {
			if (p.installed_version === null) {
				return t('not installed');
			}
			return p.installed_version < p.version
				? t('release {0} installed, package has {1}', p.installed_version, p.version)
				: t('installed, release {0}', p.installed_version);
		}

		function render() {
			const rows = packages.map((p) => {
				const isNew = p.installed_version === null;
				const schema = isNew
					? input(schemas[p.name], (v) => { schemas[p.name] = v.trim(); }, { spellcheck: false, disabled: busy, placeholder: p.schema })
					: el('code', { textContent: p.db_schema });
				const about = el('div', { className: 'packages-about' },
					el('strong', { textContent: localized(p.title) || p.name }), ' ', el('code', { textContent: p.name }),
					localized(p.description) ? el('p', { textContent: localized(p.description) }) : null);
				const reset = checkbox(resets.has(p.name), (v) => {
					(v ? resets.add(p.name) : resets.delete(p.name));
					render();
				}, { disabled: busy, title: t('Delete the solution schema with all its data before installing') });
				const cells = [about, schema, state(p), (setup && !isNew) ? '' : el('label', { className: 'packages-reset' }, reset, ' ', t('Drop schema'))];
				if (setup) {
					cells.unshift(isNew ? checkbox(selected.has(p.name), (v) => { (v ? selected.add(p.name) : selected.delete(p.name)); },
						{ disabled: busy }) : '');
				}
				else {
					const action = resets.has(p.name) ? (isNew ? t('Install') : t('Reinstall'))
						: isNew ? t('Install') : (p.installed_version < p.version ? t('Update') : null);
					const className = resets.has(p.name) ? 'danger' : (isNew ? 'primary' : '');
					cells.push(action ? button(action, () => install([p.name]), { className, disabled: busy }) : '');
				}
				return cells;
			});
			const columns = [t('Solution'), t('Database schema'), t('Status'), t('Clean installation')];
			body.replaceChildren(packages.length
				? table(setup ? ['', ...columns] : [...columns, ''], rows, 'packages-table')
				: hint(t('The application has no solution packages.')),
			...(busy ? [hint(t('Installing… This may take up to a minute.'))] : []));
			footer.replaceChildren(spacer(), ...(setup
				? [button(t('Skip'), finishSetup, { disabled: busy }),
					button(t('Install selected'), () => install([...selected]), { className: 'primary', disabled: busy || !selected.size })]
				: [button(t('Close'), close, { className: 'primary', disabled: busy })]));
		}

		/** Схема, которую удалит чистая установка: своя у установленного решения, иначе — указанная. */
		function targetSchema(name) {
			const p = packages.find((x) => x.name === name);
			return (p?.installed_version !== null && p?.db_schema) ? p.db_schema : (schemas[name] || p?.schema || name);
		}

		async function install(names) {
			const dropped = names.filter((name) => resets.has(name));
			if (dropped.length) {
				const list = dropped.map((name) => t('“{0}” — schema {1}', name, targetSchema(name))).join('; ');
				const ok = await showConfirm(t('Delete before installing: {0}? All tables and data of these schemas, the forms, menu, '
					+ 'roles and reports of the solutions will be deleted permanently.', list), t('Delete and install'));
				if (!ok) {
					return;
				}
			}
			busy = true;
			render();
			try {
				for (const name of names) {
					const response = await fetch('api/dev/solutions/install', {
						method: 'POST',
						headers: { 'Content-Type': 'application/json', 'Accept-Language': language(), ...csrfHeaders() },
						body: JSON.stringify(resets.has(name)
							? { name, schema: targetSchema(name), reset: true }
							: { name, schema: schemas[name] || null }),
					});
					const result = await response.json().catch(() => ({ status: 'error', message: `HTTP ${response.status}` }));
					if (!response.ok || result.status === 'error') {
						throw new Error(t('Solution “{0}” was not installed: {1}', name, result.message));
					}
					installed = true;
					resets.delete(name);
					const title = localized(packages.find((p) => p.name === name)?.title) || result.solution.title;
					showMessage(t('Solution “{0}” installed into schema {1}, release {2}', title, result.solution.db_schema, result.solution.version));
				}
				if (setup) {
					await finishSetup();
					return;
				}
			}
			catch (e) {
				showMessage(e.message, 'error');
			}
			busy = false;
			await load().catch((e) => showMessage(e.message, 'error'));
		}

		async function finishSetup() {
			try {
				await callAction('solutions_setup_done');
				close();
			}
			catch (e) {
				showMessage(e.message, 'error');
			}
		}

		document.body.append(dialog);
		dialog.showModal();
		body.append(hint(t('Loading…')));
		load().catch((e) => {
			showMessage(e.message, 'error');
			busy = false;
			render();
		});
	});
}

/** Текст пакета на языке интерфейса: строка или {"ru": …, "en": …}. */
function localized(value) {
	if (value === null || value === undefined || typeof value === 'string') {
		return value ?? '';
	}
	return value[language()] ?? value.en ?? value.ru ?? Object.values(value)[0] ?? '';
}
