-- =====================================================================
-- Пакет «Счета на оплату», выпуск 2: черновик карточки и печать счёта
-- =====================================================================
--  * Черновик: открытие счёта запоминает его снимок (bill_invoice_snapshots); счёт, созданный кнопкой
--    «Добавить строку», помечен снимком без состояния и в списке не виден, пока его не сохранят.
--    «Закрыть», крестик и Escape (bill_invoice_cancel) переспрашивают, если что-то изменено, и удаляют
--    новый счёт со строками или возвращают сохранённый к снимку. «Сохранить», «Выставить», «Оплачен»,
--    «Аннулировать» принимают изменения.
--  * Печать: отчёт PDF bill_invoice (функция данных bill_invoice_print_data), кнопка «Печать» в карточке
--    и в строках списка.
-- Как это собрано — шаги 9 и 10 руководства docs/tutorial-invoices.ru.md.
-- Изменения выпуска:
--   * New table bill_invoice_snapshots
--   * New function bill_invoice_cancel(p_data json)
--   * Changed function bill_invoice_edit_open(p_data json)
--   * Changed function bill_invoice_issue(p_data json)
--   * Changed function bill_invoice_pay(p_data json)
--   * New function bill_invoice_print_data(p_data json)
--   * New function bill_invoice_print(p_data json)
--   * New function bill_invoice_restore(p_id bigint, p_state jsonb)
--   * Changed function bill_invoice_save(p_data json)
--   * Changed function bill_invoices_page(p_data json)
--   * New function bill_invoice_state(p_id bigint)
--   * Changed function bill_invoice_upsert(p_data json)
--   * Changed function bill_invoice_void(p_data json)
--   * Changed view bill_invoices_v
--   * Metadata: actions
--   * Metadata: forms
--   * Metadata: form components
--   * Metadata: table columns and row buttons
--   * Metadata: reports
--   * Translations
-- Выпуск применяется один раз: на базе, где он уже записан (pgerp.solution_releases), он пропускается.
SELECT pgerp.solution_release_apply('billing', 2, 'Draft and print', $release$
-- Solution
INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description)
VALUES ('billing', 'Billing', 'bill_', 'Billing', 'billing', 'Invoices for goods and services: customers, catalogue, invoice with lines')
ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, prefix = EXCLUDED.prefix, menu_folder = EXCLUDED.menu_folder,
    migration_folder = EXCLUDED.migration_folder, description = EXCLUDED.description;
DELETE FROM pgerp.solution_objects WHERE solution = 'billing';
DELETE FROM pgerp.solution_data WHERE solution = 'billing';

-- Views: drop before re-creation
DROP VIEW IF EXISTS bill_invoices_v;

DROP VIEW IF EXISTS bill_customers_v;

DROP VIEW IF EXISTS bill_invoice_lines_v;

DROP VIEW IF EXISTS bill_items_v;

-- Tables
CREATE TABLE IF NOT EXISTS bill_invoice_snapshots (
    invoice_id bigint NOT NULL,
    state jsonb,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bill_invoice_snapshots_pkey PRIMARY KEY (invoice_id)
);

-- Functions
CREATE OR REPLACE FUNCTION bill_invoice_cancel(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$-- «Закрыть», крестик и Escape. Если что-то изменено — сначала вопрос; при согласии счёт, созданный
-- в карточке, удаляется со строками, а сохранённый возвращается к снимку. Шапку берём из формы:
-- её правки могут быть ещё не записаны
DECLARE
    v_id       BIGINT := ui_parse_id(p_data->>'id');
    v_invoice  bill_invoices%ROWTYPE;
    v_snapshot bill_invoice_snapshots%ROWTYPE;
    v_new      BOOLEAN;
    v_close    JSONB := jsonb_build_array(ui_close_form(), ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE));
BEGIN
    -- Счёт ещё не записывался (строк не добавляли): спросить, только если выбран покупатель
    IF v_id IS NULL THEN
        IF NOT ui_confirmed(p_data) AND ui_parse_id(p_data->>'customer_id') IS NOT NULL THEN
            RETURN ui_ok(ui_confirm('Close without saving? The new invoice will not be created.',
                                    'bill_invoice_cancel', jsonb_build_object('confirmed', TRUE),
                                    p_confirm_label => 'Don''t save'));
        END IF;
        RETURN ui_ok(ui_close_form());
    END IF;

    SELECT * INTO v_invoice FROM bill_invoices WHERE id = v_id;
    IF NOT FOUND THEN
        RETURN ui_ok(v_close);   -- уже удалён: отменять нечего
    END IF;
    SELECT * INTO v_snapshot FROM bill_invoice_snapshots WHERE invoice_id = v_id;
    v_new := v_snapshot.invoice_id IS NOT NULL AND v_snapshot.state IS NULL;

    IF NOT ui_confirmed(p_data) THEN
        IF v_new
           OR (v_snapshot.state IS NOT NULL AND v_snapshot.state IS DISTINCT FROM bill_invoice_state(v_id))
           OR (v_invoice.status = 'draft' AND
               jsonb_build_object('invoice_date', v_invoice.invoice_date, 'due_date', v_invoice.due_date,
                                  'customer_id', v_invoice.customer_id, 'notes', v_invoice.notes)
               IS DISTINCT FROM
               jsonb_build_object('invoice_date', ui_parse_date(p_data->>'invoice_date'),
                                  'due_date', ui_parse_date(p_data->>'due_date'),
                                  'customer_id', ui_parse_id(p_data->>'customer_id'), 'notes', ui_text(p_data, 'notes'))) THEN
            RETURN ui_ok(ui_confirm(
                format(CASE WHEN v_new THEN ui_t('Close without saving? Invoice %s with its lines will be deleted.')
                            ELSE ui_t('Close without saving? Changes to invoice %s will be discarded.') END,
                       v_invoice.number),
                'bill_invoice_cancel', jsonb_build_object('id', v_id::TEXT, 'confirmed', TRUE),
                p_confirm_label => 'Don''t save'));
        END IF;
        -- Ничего не изменено: возвращать нечего
        DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;
        RETURN ui_ok(ui_close_form());
    END IF;

    IF v_new THEN
        DELETE FROM bill_invoices WHERE id = v_id;   -- строки и снимок удалятся каскадом
    ELSIF v_snapshot.state IS NOT NULL THEN
        PERFORM bill_invoice_restore(v_id, v_snapshot.state);
        DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;
    END IF;
    RETURN ui_ok(v_close);
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_edit_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_id   BIGINT := ui_parse_id(p_data->>'id');
    v_card JSONB  := bill_invoice_card(v_id);
BEGIN
    PERFORM ui_require(v_card IS NOT NULL, 'Invoice not found — it may have been deleted');
    -- Запомнить сохранённую версию: закрытие без «Сохранить» вернёт к ней. Снимок перезаписывается —
    -- оставшийся от окна, закрытого вместе с вкладкой браузера, вернул бы счёт в прошлое
    INSERT INTO bill_invoice_snapshots (invoice_id, state) VALUES (v_id, bill_invoice_state(v_id))
    ON CONFLICT (invoice_id) DO UPDATE SET state = EXCLUDED.state, created_at = now();
    RETURN ui_ok(ui_open_form('bill_invoice', p_title => format(ui_t('Invoice %s'), v_card->>'number'), p_data => v_card));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_issue(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_id BIGINT := bill_invoice_upsert(p_data);
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM bill_invoice_lines WHERE invoice_id = v_id),
                       'Add at least one line before issuing the invoice');
    UPDATE bill_invoices SET status = 'issued' WHERE id = v_id;
    DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;
    PERFORM ui_print(format(ui_t('Invoice %s issued'), (SELECT number FROM bill_invoices WHERE id = v_id)));
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_pay(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    UPDATE bill_invoices SET status = 'paid' WHERE id = v_id AND status = 'issued';
    PERFORM ui_require(FOUND, 'Only an issued invoice can be marked as paid');
    DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_print_data(p_data json)
 RETURNS json
 LANGUAGE plpgsql
 STABLE
AS $function$-- Данные отчёта bill_invoice: ключи верхнего уровня — параметры $P{...}, rows — строки $F{...}
DECLARE
    v_invoice  bill_invoices_v%ROWTYPE;
    v_customer bill_customers%ROWTYPE;
BEGIN
    SELECT * INTO v_invoice FROM bill_invoices_v WHERE id = ui_parse_id(p_data->>'invoice_id');
    PERFORM ui_require(FOUND, 'Invoice not found — it may have been deleted');
    SELECT * INTO v_customer FROM bill_customers WHERE id = v_invoice.customer_id;
    RETURN json_build_object(
        'title', format(ui_t('Invoice %s'), v_invoice.number),
        'invoice_date', v_invoice.invoice_date,
        'due_date', v_invoice.due_date,
        'status', v_invoice.status_badge->>'label',
        'customer', v_customer.name,
        'customer_details', concat_ws(' · ', CASE WHEN v_customer.tax_id IS NOT NULL THEN format(ui_t('Tax ID %s'), v_customer.tax_id) END,
                                      v_customer.address, v_customer.email),
        'notes', v_invoice.notes,
        'amount', v_invoice.amount, 'vat', v_invoice.vat, 'total', v_invoice.total,
        'rows', COALESCE((
            SELECT json_agg(json_build_object(
                       'line_no', n, 'item', item, 'unit', unit, 'quantity', quantity, 'price', price,
                       'amount', amount, 'vat_rate', vat_rate, 'total', total) ORDER BY n)
            FROM (SELECT row_number() OVER (ORDER BY id) AS n, * FROM bill_invoice_lines_v
                  WHERE invoice_id = v_invoice.id) l), '[]'));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_print(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$-- «Печать»: из карточки сначала записывается шапка черновика, из строки списка приходит только id
DECLARE
    v_id     BIGINT := ui_parse_id(p_data->>'id');
    v_number TEXT;
BEGIN
    IF p_data->>'invoice_date' IS NOT NULL
       AND (v_id IS NULL OR (SELECT status FROM bill_invoices WHERE id = v_id) = 'draft') THEN
        v_id := bill_invoice_upsert(p_data);
    END IF;
    SELECT number INTO v_number FROM bill_invoices WHERE id = v_id;
    PERFORM ui_require(FOUND, 'Invoice not found — it may have been deleted');
    PERFORM ui_require(EXISTS (SELECT 1 FROM bill_invoice_lines WHERE invoice_id = v_id),
                       'Add at least one line before printing the invoice');
    RETURN ui_ok(ui_report('bill_invoice', jsonb_build_object('invoice_id', v_id), format(ui_t('Invoice %s'), v_number)));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_restore(p_id bigint, p_state jsonb)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
BEGIN
    UPDATE bill_invoices i
    SET invoice_date = s.invoice_date, due_date = s.due_date, customer_id = s.customer_id,
        status = s.status, notes = s.notes
    FROM jsonb_populate_record(NULL::bill_invoices, p_state->'invoice') s
    WHERE i.id = p_id;
    DELETE FROM bill_invoice_lines WHERE invoice_id = p_id;
    INSERT INTO bill_invoice_lines
    SELECT * FROM jsonb_populate_recordset(NULL::bill_invoice_lines, p_state->'lines');
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_save(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_id BIGINT := bill_invoice_upsert(p_data);
BEGIN
    DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;   -- изменения приняты
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE),
                 ui_message(format(ui_t('Invoice %s saved'), (SELECT number FROM bill_invoices WHERE id = v_id))));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoices_page(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$SELECT ui_grid_page('bill_invoices_page', p_data, 'bill_invoices_v', NULL, 'date_text', 'desc',
                    p_search_column => 'search_text', p_search => lower(p_data->>'search'),
                    p_filters => jsonb_build_object('status', p_data->>'status_filter', 'is_new', 'false'));
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_state(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'invoice', to_jsonb(i) - 'created_at',
        'lines', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id)
                           FROM bill_invoice_lines l WHERE l.invoice_id = i.id), '[]'::JSONB))
    FROM bill_invoices i WHERE i.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_upsert(p_data json)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id       BIGINT := ui_parse_id(p_data->>'id');
    v_date     DATE   := ui_parse_date(p_data->>'invoice_date');
    v_due      DATE   := ui_parse_date(p_data->>'due_date');
    v_customer BIGINT := ui_parse_id(p_data->>'customer_id');
    v_notes    TEXT   := ui_text(p_data, 'notes');
BEGIN
    PERFORM ui_require(v_date IS NOT NULL, 'Enter the invoice date');
    PERFORM ui_require(EXISTS (SELECT 1 FROM bill_customers WHERE id = v_customer), 'Choose a customer');
    PERFORM ui_require(v_due IS NULL OR v_due >= v_date, 'The payment date cannot be earlier than the invoice date');
    IF ui_is_new(p_data) THEN
        -- Номер — из id счёта: INV-2026-00001
        v_id := nextval(pg_get_serial_sequence('bill_invoices', 'id'));
        INSERT INTO bill_invoices (id, number, invoice_date, due_date, customer_id, notes, created_by)
        VALUES (v_id, format('INV-%s-%s', to_char(v_date, 'YYYY'), lpad(v_id::TEXT, 5, '0')),
                v_date, v_due, v_customer, v_notes, ui_user());
        -- Счёт создан в карточке: снимок без состояния — закрытие без «Сохранить» его удалит
        INSERT INTO bill_invoice_snapshots (invoice_id, state) VALUES (v_id, NULL);
    ELSE
        PERFORM bill_invoice_require_draft(v_id);
        UPDATE bill_invoices SET invoice_date = v_date, due_date = v_due, customer_id = v_customer, notes = v_notes
        WHERE id = v_id;
    END IF;
    RETURN v_id;
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_void(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    PERFORM ui_require(v_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM bill_invoice_snapshots
                                                        WHERE invoice_id = v_id AND state IS NULL),
                       'The invoice is not saved yet — just close it');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm('Cancel this invoice? It cannot be changed afterwards.', 'bill_invoice_void',
                                jsonb_build_object('id', v_id, 'confirmed', TRUE), p_confirm_label => 'Cancel invoice'));
    END IF;
    UPDATE bill_invoices SET status = 'cancelled' WHERE id = v_id AND status IN ('draft', 'issued');
    PERFORM ui_require(FOUND, 'Only a draft or an issued invoice can be cancelled');
    DELETE FROM bill_invoice_snapshots WHERE invoice_id = v_id;
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

-- Views
CREATE OR REPLACE VIEW bill_customers_v AS
 SELECT id,
    name,
    tax_id,
    address,
    email,
    lower(concat_ws(' '::text, name, tax_id, email)) AS search_text
   FROM bill_customers c;

CREATE OR REPLACE VIEW bill_invoice_lines_v AS
 SELECT l.id,
    l.invoice_id,
    l.item_id,
    i.name AS item,
    i.unit,
    l.quantity,
    l.price,
    l.vat_rate,
    a.amount,
    a.vat,
    a.amount + a.vat AS total
   FROM bill_invoice_lines l
     JOIN bill_items i ON i.id = l.item_id
     CROSS JOIN LATERAL ( SELECT round(l.quantity * l.price, 2) AS amount,
            round(round(l.quantity * l.price, 2) * l.vat_rate / 100::numeric, 2) AS vat) a;

CREATE OR REPLACE VIEW bill_items_v AS
 SELECT id,
    name,
    kind,
    unit,
    price,
    vat_rate,
        CASE kind
            WHEN 'service'::text THEN ui_badge('Service'::text, 'accent'::text)
            ELSE ui_badge('Goods'::text, 'done'::text)
        END AS kind_badge,
    ui_money_input(price) AS price_input,
    trim_scale(vat_rate)::text AS vat_input,
    lower(name::text) AS search_text
   FROM bill_items i;

CREATE OR REPLACE VIEW bill_invoices_v AS
 SELECT v.id,
    v.number,
    v.invoice_date,
    to_char(v.invoice_date::timestamp with time zone, 'DD.MM.YYYY'::text) AS date_text,
    v.due_date,
    to_char(v.due_date::timestamp with time zone, 'DD.MM.YYYY'::text) AS due_text,
    v.customer_id,
    c.name AS customer,
    v.status,
    v.notes,
        CASE v.status
            WHEN 'draft'::text THEN ui_badge('Draft'::text, 'neutral'::text)
            WHEN 'issued'::text THEN
            CASE
                WHEN v.due_date < CURRENT_DATE THEN ui_badge('Overdue'::text, 'danger'::text)
                ELSE ui_badge('Issued'::text, 'accent'::text)
            END
            WHEN 'paid'::text THEN ui_badge('Paid'::text, 'success'::text)
            WHEN 'cancelled'::text THEN ui_badge('Cancelled'::text, 'done'::text)
            ELSE NULL::jsonb
        END AS status_badge,
    COALESCE(t.lines, 0::bigint) AS lines,
    COALESCE(t.amount, 0::numeric) AS amount,
    COALESCE(t.vat, 0::numeric) AS vat,
    COALESCE(t.total, 0::numeric) AS total,
    lower(concat_ws(' '::text, v.number, c.name)) AS search_text,
    (EXISTS ( SELECT 1
           FROM bill_invoice_snapshots s
          WHERE s.invoice_id = v.id AND s.state IS NULL)) AS is_new
   FROM bill_invoices v
     JOIN bill_customers c ON c.id = v.customer_id
     LEFT JOIN ( SELECT bill_invoice_lines_v.invoice_id,
            count(*) AS lines,
            sum(bill_invoice_lines_v.amount) AS amount,
            sum(bill_invoice_lines_v.vat) AS vat,
            sum(bill_invoice_lines_v.total) AS total
           FROM bill_invoice_lines_v
          GROUP BY bill_invoice_lines_v.invoice_id) t ON t.invoice_id = v.id;

-- Foreign keys
DO $c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'bill_invoice_snapshots'::regclass AND conname = 'bill_invoice_snapshots_invoice_id_fkey') THEN
        ALTER TABLE bill_invoice_snapshots ADD CONSTRAINT bill_invoice_snapshots_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES bill_invoices(id) ON DELETE CASCADE;
    END IF;
END;
$c$;

-- Comments
COMMENT ON TABLE bill_invoice_snapshots IS 'Saved state of an invoice open in its card; state NULL — created in the card';

COMMENT ON COLUMN bill_invoice_snapshots.invoice_id IS 'Invoice';

COMMENT ON COLUMN bill_invoice_snapshots.state IS 'Header and lines when the card was opened; NULL — a new invoice';

-- Metadata
INSERT INTO pgerp.ui_actions (action_name, function_name, description, everyone) VALUES
    ('bill_customer_edit_open', 'bill_customer_edit_open', 'Invoices: open customer', 'false'),
    ('bill_customer_new_open', 'bill_customer_new_open', 'Invoices: new customer', 'false'),
    ('bill_customer_save', 'bill_customer_save', 'Invoices: save customer', 'false'),
    ('bill_customer_select_open', 'bill_customer_select_open', 'Invoices: choose a customer', 'false'),
    ('bill_customers_page', 'bill_customers_page', 'Invoices: customers list', 'false'),
    ('bill_invoice_cancel', 'bill_invoice_cancel', 'Invoices: close the invoice card', 'false'),
    ('bill_invoice_delete', 'bill_invoice_delete', 'Invoices: delete a draft invoice', 'false'),
    ('bill_invoice_edit_open', 'bill_invoice_edit_open', 'Invoices: open invoice', 'false'),
    ('bill_invoice_issue', 'bill_invoice_issue', 'Invoices: issue invoice', 'false'),
    ('bill_invoice_new_open', 'bill_invoice_new_open', 'Invoices: new invoice', 'false'),
    ('bill_invoice_pay', 'bill_invoice_pay', 'Invoices: mark invoice as paid', 'false'),
    ('bill_invoice_print', 'bill_invoice_print', 'Invoices: print invoice (PDF)', 'false'),
    ('bill_invoice_print_data', 'bill_invoice_print_data', 'Invoices: invoice report data', 'false'),
    ('bill_invoice_save', 'bill_invoice_save', 'Invoices: save invoice', 'false'),
    ('bill_invoices_page', 'bill_invoices_page', 'Invoices: invoice list', 'false'),
    ('bill_invoice_void', 'bill_invoice_void', 'Invoices: cancel invoice', 'false'),
    ('bill_item_delete', 'bill_item_delete', 'Invoices: delete goods or service', 'false'),
    ('bill_item_edit_open', 'bill_item_edit_open', 'Invoices: open goods or service', 'false'),
    ('bill_item_new_open', 'bill_item_new_open', 'Invoices: new goods or service', 'false'),
    ('bill_item_save', 'bill_item_save', 'Invoices: save goods or service', 'false'),
    ('bill_item_select_open', 'bill_item_select_open', 'Invoices: choose goods or service', 'false'),
    ('bill_items_page', 'bill_items_page', 'Invoices: goods and services list', 'false'),
    ('bill_kinds_combo', 'bill_kinds_combo', 'Invoices: goods or service', 'false'),
    ('bill_line_delete', 'bill_line_delete', 'Invoices: delete a line', 'false'),
    ('bill_line_edit_open', 'bill_line_edit_open', 'Invoices: open a line', 'false'),
    ('bill_line_new_open', 'bill_line_new_open', 'Invoices: add a line', 'false'),
    ('bill_line_save', 'bill_line_save', 'Invoices: save a line', 'false'),
    ('bill_lines_page', 'bill_lines_page', 'Invoices: invoice lines', 'false'),
    ('bill_statuses_combo', 'bill_statuses_combo', 'Invoices: invoice statuses', 'false')
ON CONFLICT (action_name) DO UPDATE SET function_name = EXCLUDED.function_name, description = EXCLUDED.description,
    everyone = EXCLUDED.everyone, is_system = FALSE;

INSERT INTO pgerp.forms (form_name, title, cancel_action, folder) VALUES
    ('bill_customer', 'Customer', NULL, 'Billing'),
    ('bill_customers', 'Customers', NULL, 'Billing'),
    ('bill_invoice', 'Invoice', 'bill_invoice_cancel', 'Billing'),
    ('bill_invoices', 'Invoices', NULL, 'Billing'),
    ('bill_item', 'Goods or service', NULL, 'Billing'),
    ('bill_items', 'Goods and services', NULL, 'Billing'),
    ('bill_line', 'Invoice line', NULL, 'Billing')
ON CONFLICT (form_name) DO UPDATE SET title = EXCLUDED.title, cancel_action = EXCLUDED.cancel_action,
    folder = EXCLUDED.folder, updated_at = now();

DELETE FROM pgerp.form_components WHERE form_name IN ('bill_customer', 'bill_customers', 'bill_invoice', 'bill_invoices', 'bill_item', 'bill_items', 'bill_line');
INSERT INTO pgerp.form_components (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options) VALUES
    ('bill_customer', '1', 'hidden', 'id', NULL, NULL, NULL, NULL, NULL),
    ('bill_customer', '2', 'input', 'name', 'Name', NULL, NULL, NULL, NULL),
    ('bill_customer', '3', 'input', 'tax_id', 'Tax ID', NULL, NULL, NULL, NULL),
    ('bill_customer', '4', 'input', 'email', 'E-mail', NULL, NULL, NULL, NULL),
    ('bill_customer', '5', 'input', 'address', 'Address', NULL, NULL, NULL, NULL),
    ('bill_customer', '6', 'button', 'btn_save', 'Save', 'bill_customer_save', NULL, NULL, NULL),
    ('bill_customer', '7', 'button', 'btn_cancel', 'Cancel', 'form_close', NULL, NULL, NULL),
    ('bill_customers', '1', 'input', 'search', 'Search', NULL, NULL, NULL, '{"refresh": "bill_customers_grid"}'),
    ('bill_customers', '2', 'grid', 'bill_customers_grid', NULL, 'bill_customers_page', NULL, NULL, NULL),
    ('bill_customers', '3', 'button', 'btn_new', 'New customer', 'bill_customer_new_open', NULL, NULL, NULL),
    ('bill_invoice', '1', 'hidden', 'id', NULL, NULL, NULL, NULL, NULL),
    ('bill_invoice', '10', 'display', 'totals', 'Total', NULL, NULL, 'Lines', NULL),
    ('bill_invoice', '11', 'button', 'btn_save', 'Save', 'bill_invoice_save', NULL, NULL, NULL),
    ('bill_invoice', '12', 'button', 'btn_issue', 'Issue', 'bill_invoice_issue', NULL, NULL, NULL),
    ('bill_invoice', '13', 'button', 'btn_pay', 'Paid', 'bill_invoice_pay', NULL, NULL, NULL),
    ('bill_invoice', '14', 'button', 'btn_void', 'Cancel invoice', 'bill_invoice_void', NULL, NULL, NULL),
    ('bill_invoice', '15', 'button', 'btn_print', 'Print', 'bill_invoice_print', NULL, NULL, NULL),
    ('bill_invoice', '16', 'button', 'btn_close', 'Close', 'bill_invoice_cancel', NULL, NULL, NULL),
    ('bill_invoice', '2', 'display', 'number', 'Number', NULL, NULL, NULL, '{"column": 1}'),
    ('bill_invoice', '3', 'date', 'invoice_date', 'Date', NULL, NULL, NULL, '{"column": 1}'),
    ('bill_invoice', '4', 'lookup', 'customer_id', 'Customer', 'bill_customer_select_open', NULL, NULL, '{"column": 1}'),
    ('bill_invoice', '5', 'display', 'status_text', 'Status', NULL, NULL, NULL, '{"column": 2}'),
    ('bill_invoice', '6', 'date', 'due_date', 'Pay by', NULL, NULL, NULL, '{"column": 2}'),
    ('bill_invoice', '7', 'input', 'notes', 'Notes', NULL, NULL, NULL, '{"column": 2}'),
    ('bill_invoice', '8', 'button', 'btn_add_line', 'Add line', 'bill_line_new_open', NULL, 'Lines', NULL),
    ('bill_invoice', '9', 'grid', 'bill_lines_grid', NULL, 'bill_lines_page', 'id', 'Lines', NULL),
    ('bill_invoices', '1', 'input', 'search', 'Search', NULL, NULL, NULL, '{"column": 1, "refresh": "bill_invoices_grid"}'),
    ('bill_invoices', '2', 'combobox', 'status_filter', 'Status', 'bill_statuses_combo', NULL, NULL, '{"column": 2, "refresh": "bill_invoices_grid", "placeholder": "All"}'),
    ('bill_invoices', '3', 'grid', 'bill_invoices_grid', NULL, 'bill_invoices_page', NULL, NULL, NULL),
    ('bill_invoices', '4', 'button', 'btn_new', 'New invoice', 'bill_invoice_new_open', NULL, NULL, NULL),
    ('bill_item', '1', 'hidden', 'id', NULL, NULL, NULL, NULL, NULL),
    ('bill_item', '2', 'input', 'name', 'Name', NULL, NULL, NULL, NULL),
    ('bill_item', '3', 'combobox', 'kind', 'Kind', 'bill_kinds_combo', NULL, NULL, NULL),
    ('bill_item', '4', 'input', 'unit', 'Unit', NULL, NULL, NULL, NULL),
    ('bill_item', '5', 'input', 'price', 'Price without VAT', NULL, NULL, NULL, NULL),
    ('bill_item', '6', 'input', 'vat_rate', 'VAT, %', NULL, NULL, NULL, NULL),
    ('bill_item', '7', 'button', 'btn_save', 'Save', 'bill_item_save', NULL, NULL, NULL),
    ('bill_item', '8', 'button', 'btn_cancel', 'Cancel', 'form_close', NULL, NULL, NULL),
    ('bill_items', '1', 'input', 'search', 'Search', NULL, NULL, NULL, '{"refresh": "bill_items_grid"}'),
    ('bill_items', '2', 'grid', 'bill_items_grid', NULL, 'bill_items_page', NULL, NULL, NULL),
    ('bill_items', '3', 'button', 'btn_new', 'Add', 'bill_item_new_open', NULL, NULL, NULL),
    ('bill_line', '1', 'hidden', 'id', NULL, NULL, NULL, NULL, NULL),
    ('bill_line', '2', 'hidden', 'invoice_id', NULL, NULL, NULL, NULL, NULL),
    ('bill_line', '3', 'lookup', 'item_id', 'Goods or service', 'bill_item_select_open', NULL, NULL, NULL),
    ('bill_line', '4', 'input', 'quantity', 'Quantity', NULL, NULL, NULL, NULL),
    ('bill_line', '5', 'input', 'price', 'Price without VAT', NULL, NULL, NULL, NULL),
    ('bill_line', '6', 'input', 'vat_rate', 'VAT, %', NULL, NULL, NULL, NULL),
    ('bill_line', '7', 'button', 'btn_save', 'Save', 'bill_line_save', NULL, NULL, NULL),
    ('bill_line', '8', 'button', 'btn_cancel', 'Cancel', 'form_close', NULL, NULL, NULL);

DELETE FROM pgerp.grid_columns WHERE action_name IN ('bill_customer_edit_open', 'bill_customer_new_open', 'bill_customer_save', 'bill_customer_select_open', 'bill_customers_page', 'bill_invoice_cancel', 'bill_invoice_delete', 'bill_invoice_edit_open', 'bill_invoice_issue', 'bill_invoice_new_open', 'bill_invoice_pay', 'bill_invoice_print', 'bill_invoice_print_data', 'bill_invoice_save', 'bill_invoices_page', 'bill_invoice_void', 'bill_item_delete', 'bill_item_edit_open', 'bill_item_new_open', 'bill_item_save', 'bill_item_select_open', 'bill_items_page', 'bill_kinds_combo', 'bill_line_delete', 'bill_line_edit_open', 'bill_line_new_open', 'bill_line_save', 'bill_lines_page', 'bill_statuses_combo');
INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column) VALUES
    ('bill_customers_page', '1', 'name', 'Name', 'text', 'name'),
    ('bill_customers_page', '2', 'tax_id', 'Tax ID', 'text', NULL),
    ('bill_customers_page', '3', 'email', 'E-mail', 'text', NULL),
    ('bill_invoices_page', '1', 'number', 'Number', 'text', 'number'),
    ('bill_invoices_page', '2', 'date_text', 'Date', 'text', 'invoice_date'),
    ('bill_invoices_page', '3', 'customer', 'Customer', 'text', 'customer'),
    ('bill_invoices_page', '4', 'total', 'Total', 'money', 'total'),
    ('bill_invoices_page', '5', 'due_text', 'Pay by', 'text', 'due_date'),
    ('bill_invoices_page', '6', 'status_badge', 'Status', 'badge', 'status'),
    ('bill_items_page', '1', 'name', 'Name', 'text', 'name'),
    ('bill_items_page', '2', 'kind_badge', 'Kind', 'badge', 'kind'),
    ('bill_items_page', '3', 'unit', 'Unit', 'text', NULL),
    ('bill_items_page', '4', 'price', 'Price', 'money', 'price'),
    ('bill_items_page', '5', 'vat_rate', 'VAT, %', 'number', NULL),
    ('bill_lines_page', '1', 'item', 'Goods or service', 'text', NULL),
    ('bill_lines_page', '2', 'unit', 'Unit', 'text', NULL),
    ('bill_lines_page', '3', 'quantity', 'Qty', 'number', NULL),
    ('bill_lines_page', '4', 'price', 'Price', 'money', NULL),
    ('bill_lines_page', '5', 'amount', 'Amount', 'money', NULL),
    ('bill_lines_page', '6', 'vat_rate', 'VAT, %', 'number', NULL),
    ('bill_lines_page', '7', 'total', 'Total', 'money', NULL);
DELETE FROM pgerp.grid_row_actions WHERE source_action IN ('bill_customer_edit_open', 'bill_customer_new_open', 'bill_customer_save', 'bill_customer_select_open', 'bill_customers_page', 'bill_invoice_cancel', 'bill_invoice_delete', 'bill_invoice_edit_open', 'bill_invoice_issue', 'bill_invoice_new_open', 'bill_invoice_pay', 'bill_invoice_print', 'bill_invoice_print_data', 'bill_invoice_save', 'bill_invoices_page', 'bill_invoice_void', 'bill_item_delete', 'bill_item_edit_open', 'bill_item_new_open', 'bill_item_save', 'bill_item_select_open', 'bill_items_page', 'bill_kinds_combo', 'bill_line_delete', 'bill_line_edit_open', 'bill_line_new_open', 'bill_line_save', 'bill_lines_page', 'bill_statuses_combo');
INSERT INTO pgerp.grid_row_actions (source_action, sort_order, row_action, label, style) VALUES
    ('bill_customers_page', '1', 'bill_customer_edit_open', 'Edit', 'default'),
    ('bill_invoices_page', '1', 'bill_invoice_edit_open', 'Open', 'default'),
    ('bill_invoices_page', '2', 'bill_invoice_print', 'Print', 'default'),
    ('bill_invoices_page', '3', 'bill_invoice_delete', 'Delete', 'danger'),
    ('bill_items_page', '1', 'bill_item_edit_open', 'Edit', 'default'),
    ('bill_items_page', '2', 'bill_item_delete', 'Delete', 'danger'),
    ('bill_lines_page', '1', 'bill_line_edit_open', 'Edit', 'default'),
    ('bill_lines_page', '2', 'bill_line_delete', 'Remove', 'danger');

INSERT INTO pgerp.reports (name, title, data_action, sample_params, jrxml) VALUES
    ('bill_invoice', 'Invoice', 'bill_invoice_print_data', '{"invoice_id": 1}', '<jasperReport name="bill_invoice" pageWidth="595" pageHeight="842" columnWidth="515" leftMargin="40" rightMargin="40" topMargin="40" bottomMargin="30">
	<!-- Invoice: parameters come from bill_invoice_print_data, rows are the invoice lines -->
	<parameter name="title" class="java.lang.String"/>
	<parameter name="invoice_date" class="java.util.Date"/>
	<parameter name="due_date" class="java.util.Date"/>
	<parameter name="status" class="java.lang.String"/>
	<parameter name="customer" class="java.lang.String"/>
	<parameter name="customer_details" class="java.lang.String"/>
	<parameter name="notes" class="java.lang.String"/>
	<parameter name="amount" class="java.math.BigDecimal"/>
	<parameter name="vat" class="java.math.BigDecimal"/>
	<parameter name="total" class="java.math.BigDecimal"/>
	<field name="line_no" class="java.lang.Integer"/>
	<field name="item" class="java.lang.String"/>
	<field name="unit" class="java.lang.String"/>
	<field name="quantity" class="java.math.BigDecimal"/>
	<field name="price" class="java.math.BigDecimal"/>
	<field name="amount" class="java.math.BigDecimal"/>
	<field name="vat_rate" class="java.math.BigDecimal"/>
	<field name="total" class="java.math.BigDecimal"/>
	<title height="120">
		<element kind="rectangle" x="0" y="0" width="515" height="4" mode="Opaque" backcolor="#0969DA">
			<pen lineWidth="0.0"/>
		</element>
		<element kind="textField" x="0" y="14" width="380" height="30" fontSize="20.0" bold="true">
			<expression><![CDATA[$P{title}]]></expression>
		</element>
		<element kind="textField" x="380" y="20" width="135" height="20" hTextAlign="Right" forecolor="#59636E">
			<expression><![CDATA[$P{status}]]></expression>
		</element>
		<element kind="textField" x="0" y="44" width="515" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{dated} + " " + new java.text.SimpleDateFormat("dd.MM.yyyy").format($P{invoice_date})
				+ ($P{due_date} == null ? "" : " · " + $R{Pay by} + " " + new java.text.SimpleDateFormat("dd.MM.yyyy").format($P{due_date}))]]></expression>
		</element>
		<element kind="textField" x="0" y="72" width="90" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{Customer}]]></expression>
		</element>
		<element kind="textField" x="90" y="72" width="425" height="18" bold="true">
			<expression><![CDATA[$P{customer}]]></expression>
		</element>
		<element kind="textField" x="90" y="90" width="425" height="16" fontSize="8.0" forecolor="#59636E" textAdjust="StretchHeight">
			<expression><![CDATA[$P{customer_details}]]></expression>
		</element>
	</title>
	<columnHeader height="24">
		<element kind="frame" x="0" y="0" width="515" height="22" mode="Opaque" backcolor="#F6F8FA">
			<element kind="textField" x="4" y="0" width="24" height="22" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA["№"]]></expression>
			</element>
			<element kind="textField" x="28" y="0" width="165" height="22" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Goods or service}]]></expression>
			</element>
			<element kind="textField" x="193" y="0" width="65" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Qty}]]></expression>
			</element>
			<element kind="textField" x="258" y="0" width="70" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Price}]]></expression>
			</element>
			<element kind="textField" x="328" y="0" width="75" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Amount}]]></expression>
			</element>
			<element kind="textField" x="403" y="0" width="45" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{VAT, %}]]></expression>
			</element>
			<element kind="textField" x="448" y="0" width="63" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Total}]]></expression>
			</element>
		</element>
	</columnHeader>
	<detail>
		<band height="22">
			<element kind="textField" x="4" y="2" width="24" height="18" fontSize="9.0">
				<expression><![CDATA[$F{line_no}]]></expression>
			</element>
			<element kind="textField" x="28" y="2" width="165" height="18" fontSize="9.0" textAdjust="StretchHeight">
				<expression><![CDATA[$F{item}]]></expression>
			</element>
			<element kind="textField" x="193" y="2" width="65" height="18" hTextAlign="Right" fontSize="9.0">
				<expression><![CDATA[new java.text.DecimalFormat("#,##0.###", java.text.DecimalFormatSymbols.getInstance($P{REPORT_LOCALE})).format($F{quantity}) + " " + $F{unit}]]></expression>
			</element>
			<element kind="textField" x="258" y="2" width="70" height="18" hTextAlign="Right" fontSize="9.0" pattern="#,##0.00">
				<expression><![CDATA[$F{price}]]></expression>
			</element>
			<element kind="textField" x="328" y="2" width="75" height="18" hTextAlign="Right" fontSize="9.0" pattern="#,##0.00">
				<expression><![CDATA[$F{amount}]]></expression>
			</element>
			<element kind="textField" x="403" y="2" width="45" height="18" hTextAlign="Right" fontSize="9.0">
				<expression><![CDATA[new java.text.DecimalFormat("#,##0.##", java.text.DecimalFormatSymbols.getInstance($P{REPORT_LOCALE})).format($F{vat_rate})]]></expression>
			</element>
			<element kind="textField" x="448" y="2" width="63" height="18" hTextAlign="Right" fontSize="9.0" pattern="#,##0.00">
				<expression><![CDATA[$F{total}]]></expression>
			</element>
			<element kind="line" x="0" y="21" width="515" height="1" forecolor="#EFF2F5"/>
		</band>
	</detail>
	<pageFooter height="20">
		<element kind="textField" x="0" y="0" width="315" height="20" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$P{title} + " · " + $P{customer}]]></expression>
		</element>
		<element kind="textField" x="315" y="0" width="200" height="20" hTextAlign="Right" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$R{Page} + " " + $V{PAGE_NUMBER}]]></expression>
		</element>
	</pageFooter>
	<summary height="110">
		<element kind="textField" x="195" y="10" width="195" height="18" hTextAlign="Right">
			<expression><![CDATA[$R{Amount without VAT}]]></expression>
		</element>
		<element kind="textField" x="395" y="10" width="116" height="18" hTextAlign="Right" pattern="#,##0.00">
			<expression><![CDATA[$P{amount}]]></expression>
		</element>
		<element kind="textField" x="195" y="28" width="195" height="18" hTextAlign="Right">
			<expression><![CDATA[$R{VAT}]]></expression>
		</element>
		<element kind="textField" x="395" y="28" width="116" height="18" hTextAlign="Right" pattern="#,##0.00">
			<expression><![CDATA[$P{vat}]]></expression>
		</element>
		<element kind="textField" x="195" y="48" width="195" height="22" hTextAlign="Right" bold="true" fontSize="12.0">
			<expression><![CDATA[$R{Total due}]]></expression>
		</element>
		<element kind="textField" x="395" y="48" width="116" height="22" hTextAlign="Right" bold="true" fontSize="12.0" pattern="#,##0.00">
			<expression><![CDATA[$P{total}]]></expression>
		</element>
		<element kind="textField" x="0" y="80" width="515" height="26" fontSize="9.0" forecolor="#59636E" textAdjust="StretchHeight">
			<expression><![CDATA[$P{notes} == null ? "" : $R{Notes} + ": " + $P{notes}]]></expression>
		</element>
	</summary>
</jasperReport>
')
ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, data_action = EXCLUDED.data_action,
    sample_params = EXCLUDED.sample_params, jrxml = EXCLUDED.jrxml, updated_at = now();

-- Dropped functions and types, translations
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Add', 'Добавить'),
    ('ru', 'Add at least one line before issuing the invoice', 'Добавьте в счёт хотя бы одну строку'),
    ('ru', 'Add at least one line before printing the invoice', 'Добавьте в счёт хотя бы одну строку, чтобы его напечатать'),
    ('ru', 'Add line', 'Добавить строку'),
    ('ru', 'Address', 'Адрес'),
    ('ru', 'All', 'Все'),
    ('ru', 'Amount', 'Сумма'),
    ('ru', 'Amount without VAT', 'Сумма без НДС'),
    ('ru', 'Billing', 'Счета на оплату'),
    ('ru', 'Billing: accountant', 'Счета на оплату: бухгалтер'),
    ('ru', 'Cancel', 'Отмена'),
    ('ru', 'Cancel invoice', 'Аннулировать'),
    ('ru', 'Cancelled', 'Аннулирован'),
    ('ru', 'Cancel this invoice? It cannot be changed afterwards.', 'Аннулировать счёт? После этого его нельзя изменить.'),
    ('ru', 'Choose a customer', 'Выберите покупателя'),
    ('ru', 'Choose goods or a service', 'Выберите товар или услугу'),
    ('ru', 'Choose goods or service', 'Выберите товар или услугу'),
    ('ru', 'Close', 'Закрыть'),
    ('ru', 'Close without saving? Changes to invoice %s will be discarded.', 'Закрыть без сохранения? Изменения счёта %s будут отменены.'),
    ('ru', 'Close without saving? Invoice %s with its lines will be deleted.', 'Закрыть без сохранения? Счёт %s со строками будет удалён.'),
    ('ru', 'Close without saving? The new invoice will not be created.', 'Закрыть без сохранения? Новый счёт не будет создан.'),
    ('ru', 'Customer', 'Покупатель'),
    ('ru', 'Customer not found — it may have been deleted', 'Покупатель не найден — возможно, его удалили'),
    ('ru', 'Customers', 'Покупатели'),
    ('ru', 'Date', 'Дата'),
    ('ru', 'dated', 'от'),
    ('ru', 'Delete', 'Удалить'),
    ('ru', 'Delete invoice %s?', 'Удалить счёт %s?'),
    ('ru', 'Delete “%s”?', 'Удалить «%s»?'),
    ('ru', 'Draft', 'Черновик'),
    ('ru', 'Edit', 'Изменить'),
    ('ru', 'E-mail', 'Эл. почта'),
    ('ru', 'Enter the customer name', 'Укажите название покупателя'),
    ('ru', 'Enter the invoice date', 'Укажите дату счёта'),
    ('ru', 'Enter the name', 'Укажите название'),
    ('ru', 'Form', 'Форма'),
    ('ru', 'Goods', 'Товар'),
    ('ru', 'Goods and services', 'Товары и услуги'),
    ('ru', 'Goods or service', 'Товар или услуга'),
    ('ru', 'Invoice', 'Счёт'),
    ('ru', 'Invoice line', 'Строка счёта'),
    ('ru', 'Invoice not found — it may have been deleted', 'Счёт не найден — возможно, его удалили'),
    ('ru', 'Invoice %s', 'Счёт %s'),
    ('ru', 'Invoices', 'Счета'),
    ('ru', 'Invoice %s issued', 'Счёт %s выставлен'),
    ('ru', 'Invoice %s saved', 'Счёт %s сохранён'),
    ('ru', 'Issue', 'Выставить'),
    ('ru', 'Issued', 'Выставлен'),
    ('ru', 'It is used in invoices and cannot be deleted', 'Используется в счетах — удалить нельзя'),
    ('ru', 'Kind', 'Вид'),
    ('ru', 'Line not found — it may have been deleted', 'Строка не найдена — возможно, её удалили'),
    ('ru', 'Lines', 'Строки'),
    ('ru', 'Name', 'Название'),
    ('ru', 'New customer', 'Новый покупатель'),
    ('ru', 'New goods or service', 'Новый товар или услуга'),
    ('ru', 'New invoice', 'Новый счёт'),
    ('ru', 'Notes', 'Примечание'),
    ('ru', 'Not found — it may have been deleted', 'Не найдено — возможно, удалено'),
    ('ru', 'Number', 'Номер'),
    ('ru', 'Only a draft can be deleted; cancel an issued invoice instead', 'Удалить можно только черновик; выставленный счёт аннулируйте'),
    ('ru', 'Only a draft invoice can be changed', 'Изменить можно только черновик счёта'),
    ('ru', 'Only a draft or an issued invoice can be cancelled', 'Аннулировать можно только черновик или выставленный счёт'),
    ('ru', 'Only an issued invoice can be marked as paid', 'Оплаченным можно отметить только выставленный счёт'),
    ('ru', 'Open', 'Открыть'),
    ('ru', 'Overdue', 'Просрочен'),
    ('ru', 'Page', 'Страница'),
    ('ru', 'Paid', 'Оплачен'),
    ('ru', 'Pay by', 'Оплатить до'),
    ('ru', 'Price', 'Цена'),
    ('ru', 'Price must be a number, e.g. 1500 or 99.90', 'Цена — число, например 1500 или 99,90'),
    ('ru', 'Price without VAT', 'Цена без НДС'),
    ('ru', 'Print', 'Печать'),
    ('ru', 'Qty', 'Кол-во'),
    ('ru', 'Quantity', 'Количество'),
    ('ru', 'Quantity must be a number greater than zero', 'Количество — число больше нуля'),
    ('ru', 'Remove', 'Убрать'),
    ('ru', 'Remove “%s” from the invoice?', 'Убрать «%s» из счёта?'),
    ('ru', 'Save', 'Сохранить'),
    ('ru', 'Search', 'Поиск'),
    ('ru', 'Service', 'Услуга'),
    ('ru', 'Status', 'Состояние'),
    ('ru', '%s (without VAT %s, VAT %s)', '%s (без НДС %s, НДС %s)'),
    ('ru', 'Tax ID', 'ИНН'),
    ('ru', 'Tax ID %s', 'ИНН %s'),
    ('ru', 'The invoice is not saved yet — just close it', 'Счёт ещё не сохранён — просто закройте его'),
    ('ru', 'The payment date cannot be earlier than the invoice date', 'Срок оплаты не может быть раньше даты счёта'),
    ('ru', 'There is already a customer with this name', 'Покупатель с таким названием уже есть'),
    ('ru', 'There is already an item with this name', 'Товар или услуга с таким названием уже есть'),
    ('ru', 'Total', 'Итого'),
    ('ru', 'Total due', 'Итого к оплате'),
    ('ru', 'Unit', 'Ед. изм.'),
    ('ru', 'VAT', 'НДС'),
    ('ru', 'VAT, %', 'НДС, %'),
    ('ru', 'VAT must be from 0 to 100 %', 'НДС — от 0 до 100 %')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;
$release$);
