// Окно отчёта PDF: инструкция show_report из базы (ui_report) и предпросмотр в редакторе отчётов.
// PDF загружается заранее: ошибка (отчёт устарел, ошибка в шаблоне) показывается сообщением,
// а не страницей с JSON внутри окна. Показывает встроенный просмотрщик PDF браузера.

import { language, t } from './i18n.js';
import { csrfHeaders } from './ui-runtime.js';

/** Ответ с отчётом → Blob PDF; ошибка — Error с текстом для пользователя. */
export async function pdfFromResponse(response) {
	const type = response.headers.get('Content-Type') ?? '';
	if (response.ok && type.startsWith('application/pdf')) {
		return response.blob();
	}
	let message = `HTTP ${response.status}`;
	let kind;
	try {
		const result = await response.json();
		message = result.message || message;
		kind = result.kind;
	}
	catch {
		// не JSON — остаётся код ответа
	}
	throw new Error(kind === 'report' ? t('Report template error: {0}', message) : message);
}

/** Показать отчёт по адресу из инструкции show_report. */
export async function showReport(url, title) {
	// Язык интерфейса — как у остальных запросов: переводы $R{...} и формат чисел
	const response = await fetch(url, { headers: { 'Accept-Language': language(), ...csrfHeaders() } });
	showPdf(await pdfFromResponse(response), title);
}

/** Окно с PDF: встроенный просмотрщик браузера, «Скачать», «Открыть в новой вкладке». */
export function showPdf(blob, title) {
	const url = URL.createObjectURL(blob);
	const dialog = document.createElement('dialog');
	dialog.className = 'code-view report-viewer';
	const header = document.createElement('header');
	const heading = document.createElement('h3');
	heading.textContent = title ?? '';
	header.append(heading);

	const frame = document.createElement('iframe');
	frame.className = 'report-frame';
	frame.src = url;
	frame.title = title ?? t('Report');

	const footer = document.createElement('div');
	footer.className = 'toolbar';
	const spacer = document.createElement('span');
	spacer.className = 'spacer';
	const download = document.createElement('a');
	download.className = 'button';
	download.href = url;
	download.download = `${(title || 'report').replace(/[\\/:*?"<>|]+/g, '_')}.pdf`;
	download.textContent = t('Download');
	const open = document.createElement('a');
	open.className = 'button';
	open.href = url;
	open.target = '_blank';
	open.rel = 'noopener';
	open.textContent = t('Open in a new tab');
	const close = document.createElement('button');
	close.type = 'button';
	close.className = 'primary';
	close.textContent = t('Close');
	close.addEventListener('click', () => dialog.close());
	footer.append(spacer, download, open, close);

	dialog.append(header, frame, footer);
	dialog.addEventListener('close', () => {
		dialog.remove();
		// Вкладка, открытая по ссылке, успевает загрузить PDF
		setTimeout(() => URL.revokeObjectURL(url), 60_000);
	});
	document.body.append(dialog);
	dialog.showModal();
	close.focus();
}
