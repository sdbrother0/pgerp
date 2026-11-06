import { callAction, showConfirm, showMessage } from './ui-runtime.js';
import { button, copyButton, el, field, formatTime, hint, input, section, select, spacer, table } from './editor-kit.js';
import { t } from './i18n.js';

/**
 * Раздел «Доступ MCP» (editor.html?mcp): адрес MCP-сервера, токены доступа и готовые настройки клиентов.
 * Токен показывается один раз — при выдаче; в базе хранится только его хеш.
 * Агент работает с правами владельца токена: разработка решений доступна только администратору.
 */
export function createMcpAccess(root) {
	let tokens = [];
	let users = [];
	let issued = null;   // {token, login}
	const draft = { title: '', login: '', days: '' };

	const canvas = el('section', { className: 'editor-canvas dev-canvas' });
	root.replaceChildren(canvas);

	/** Адрес /mcp относительно страницы редактора: приложение может работать не в корне сайта. */
	function endpoint() {
		return new URL('mcp', location.href).href.replace(/\?.*$/, '');
	}

	async function open() {
		const result = await callAction('mcp_tokens_list');
		tokens = result.tokens;
		users = result.users;
		draft.login ||= users.find((u) => u.is_admin)?.login ?? '';
		render();
	}

	function snippets(token) {
		const url = endpoint();
		const claudeCode = `claude mcp add --transport http pgerp ${url} --header "Authorization: Bearer ${token}"`;
		const json = JSON.stringify({ mcpServers: { pgerp: { type: 'http', url, headers: { Authorization: `Bearer ${token}` } } } }, null, 2);
		return { claudeCode, json };
	}

	function render() {
		const placeholder = '<token>';
		const sample = snippets(issued?.token ?? placeholder);
		const parts = [
			el('div', { className: 'toolbar' }, el('h3', { className: 'report-heading', textContent: t('MCP access') })),
			hint(t('The MCP server gives an AI agent (Claude Code, Claude Desktop and other MCP clients) tools for the full development cycle: solutions, data schema, functions, forms, menu, roles, translations, reports, action tests and releases.')),
			section(t('Server address'),
				el('div', { className: 'toolbar dev-inline' }, el('code', { textContent: endpoint() }), copyButton(endpoint())),
				hint(t('Streamable HTTP transport, sign-in with a token in the header Authorization: Bearer <token>.'))),
		];

		if (issued) {
			parts.push(section(t('New token'),
				el('div', { className: 'dev-token' }, el('code', { textContent: issued.token }), copyButton(issued.token)),
				hint(t('Copy the token now: it will not be shown again.')),
				issued.is_admin ? null : hint(t('The token owner is not an administrator: development tools are not available to them.')),
				el('h5', { textContent: t('Claude Code') }),
				el('div', { className: 'toolbar dev-inline' }, el('code', { className: 'dev-snippet', textContent: sample.claudeCode }), copyButton(sample.claudeCode)),
				el('h5', { textContent: t('Client settings (JSON)') }),
				el('pre', { className: 'dev-sql dev-json', textContent: sample.json }),
				el('div', { className: 'toolbar dev-inline' }, copyButton(sample.json)),
				el('div', { className: 'toolbar dev-inline' }, spacer(), button(t('Done'), () => { issued = null; render(); }, { className: 'primary' }))));
		}
		else {
			parts.push(section(t('Issue token'),
				el('div', { className: 'report-fields dev-fields' },
					field(t('Purpose'), input(draft.title, (v) => { draft.title = v; }, { placeholder: t('Claude Code on my laptop') })),
					field(t('User'), select(users.map((u) => [u.login, u.is_admin ? `${u.name} (${u.login}, ${t('administrator')})` : `${u.name} (${u.login})`]),
						draft.login, (v) => { draft.login = v; }), t('The agent works with this user\'s permissions')),
					field(t('Valid for, days'), input(draft.days, (v) => { draft.days = v.trim(); }, { type: 'number', min: 1, max: 3650, placeholder: t('no expiry') })),
					el('div', { className: 'toolbar dev-inline' }, spacer(), button(t('Issue token'), create, { className: 'primary' }))),
				hint(t('Connecting Claude Code after issuing: {0}', sample.claudeCode))));
		}

		parts.push(section(t('Tokens'), tokens.length
			? table([t('Purpose'), t('User'), t('Token'), t('Issued'), t('Last used'), t('Valid until'), ''],
				tokens.map((tk) => [tk.title, tk.login, el('code', { textContent: tk.hint }), formatTime(tk.created_at),
					tk.last_used_at ? formatTime(tk.last_used_at) : t('never used'),
					tk.expires_at ? `${formatTime(tk.expires_at)}${tk.expired ? ` (${t('expired')})` : ''}` : t('no expiry'),
					button(t('Revoke'), () => revoke(tk), { className: 'danger' })]))
			: hint(t('No tokens.'))));
		canvas.replaceChildren(...parts);
	}

	async function create() {
		try {
			issued = await callAction('mcp_token_create', draft);
			draft.title = '';
			draft.days = '';
			await open();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	async function revoke(token) {
		if (!await showConfirm(t('Revoke token “{0}”? Clients using it will lose access.', token.title), t('Revoke'))) {
			return;
		}
		try {
			await callAction('mcp_token_revoke', { id: token.id });
			await open();
		}
		catch (e) {
			showMessage(e.message, 'error');
		}
	}

	return { open };
}
