// Тема оформления: ставит data-theme у <html> до отрисовки страницы, поэтому подключается обычным
// (не модульным) <script> в <head> — без мигания. Выбор хранится в localStorage: нет записи — светлая
// тема по умолчанию, 'system' — как в системе; настройку в базе синхронизирует initSession (ui-runtime.js).
(function () {
	const STORAGE_KEY = 'erp-theme';
	const DEFAULT = 'light';
	const SYSTEM = 'system';
	const system = window.matchMedia('(prefers-color-scheme: dark)');

	/** Код темы или '' — как в системе. */
	function choice() {
		let stored = null;
		try {
			stored = localStorage.getItem(STORAGE_KEY);
		}
		catch {
			// без localStorage — тема по умолчанию
		}
		if (stored === SYSTEM) {
			return '';
		}
		return stored || DEFAULT;
	}

	function apply() {
		document.documentElement.dataset.theme = choice() || (system.matches ? 'dark' : 'light');
	}

	// «Как в системе» следует за сменой темы ОС; выбор в другой вкладке применяется и здесь
	system.addEventListener('change', apply);
	window.addEventListener('storage', (event) => {
		if (event.key === STORAGE_KEY) {
			apply();
		}
	});
	apply();

	window.PgErpTheme = {
		/** Выбранная тема: код из pgerp.themes (по умолчанию light) или '' — как в системе. */
		choice,
		/** Сменить тему сразу, без перезагрузки: оформление темы — CSS-переменные. */
		set(theme) {
			try {
				localStorage.setItem(STORAGE_KEY, theme || SYSTEM);
			}
			catch {
				// без localStorage тема действует до перезагрузки
			}
			apply();
		},
	};
})();
