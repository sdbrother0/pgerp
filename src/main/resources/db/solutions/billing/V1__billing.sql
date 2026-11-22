-- =====================================================================
-- Пакет решения «Счета на оплату»: счета на товары и услуги — документ со строками (master-detail)
-- =====================================================================
--  * Справочники: товары и услуги (вид, единица, цена, ставка НДС), покупатели.
--  * Счёт — мастер: номер из id, дата, срок оплаты, покупатель, состояние (черновик, выставлен,
--    оплачен, аннулирован; просроченный — по сроку оплаты), итог с НДС.
--  * Строки счёта — детали: таблица в карточке со свойством «Мастер», строка — отдельная форма
--    с выбором товара, который подставляет цену и НДС; сохранение строки обновляет итог карточки.
--  * Менять и удалять можно только черновик. Роль bill_accountant, меню «Billing», русские переводы.
--
-- Готовый вариант решения из руководства docs/tutorial-invoices.ru.md — с другими именами
-- (billing, префикс bill_ вместо invoices, inv_), чтобы пакет и решение по руководству не мешали друг другу.
-- Устанавливает администратор (при первом входе или в редакторе: «Решения → Установить»); объекты
-- создаются в схеме решения (по умолчанию billing, выбирается при установке).
-- Выпуск применяется один раз: на базе, где он уже записан (pgerp.solution_releases), он пропускается.
SELECT pgerp.solution_release_apply('billing', 1, 'Billing', $release$
-- Solution
INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description)
VALUES ('billing', 'Billing', 'bill_', 'Billing', 'billing', 'Invoices for goods and services: customers, catalogue, invoice with lines')
ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, prefix = EXCLUDED.prefix, menu_folder = EXCLUDED.menu_folder,
    migration_folder = EXCLUDED.migration_folder, description = EXCLUDED.description;
DELETE FROM pgerp.solution_objects WHERE solution = 'billing';
DELETE FROM pgerp.solution_data WHERE solution = 'billing';

-- Tables
CREATE TABLE IF NOT EXISTS bill_customers (
    id bigserial,
    name character varying(200) NOT NULL,
    tax_id character varying(20),
    address text,
    email character varying(200),
    CONSTRAINT bill_customers_pkey PRIMARY KEY (id),
    CONSTRAINT bill_customers_name_key UNIQUE (name),
    CONSTRAINT bill_customers_name_check CHECK ((TRIM(BOTH FROM name) <> ''::text))
);

CREATE TABLE IF NOT EXISTS bill_invoice_lines (
    id bigserial,
    invoice_id bigint NOT NULL,
    item_id bigint NOT NULL,
    quantity numeric(14,3) DEFAULT 1 NOT NULL,
    price numeric(14,2) NOT NULL,
    vat_rate numeric(5,2) NOT NULL,
    CONSTRAINT bill_invoice_lines_pkey PRIMARY KEY (id),
    CONSTRAINT bill_invoice_lines_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT bill_invoice_lines_quantity_check CHECK ((quantity > (0)::numeric)),
    CONSTRAINT bill_invoice_lines_vat_rate_check CHECK (((vat_rate >= (0)::numeric) AND (vat_rate <= (100)::numeric)))
);

CREATE TABLE IF NOT EXISTS bill_invoices (
    id bigserial,
    number character varying(30) NOT NULL,
    invoice_date date DEFAULT CURRENT_DATE NOT NULL,
    due_date date,
    customer_id bigint NOT NULL,
    status character varying(10) DEFAULT 'draft'::character varying NOT NULL,
    notes text,
    created_by character varying(50) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT bill_invoices_pkey PRIMARY KEY (id),
    CONSTRAINT bill_invoices_check CHECK (((due_date IS NULL) OR (due_date >= invoice_date))),
    CONSTRAINT bill_invoices_number_key UNIQUE (number),
    CONSTRAINT bill_invoices_status_check CHECK (((status)::text = ANY ((ARRAY['draft'::character varying, 'issued'::character varying, 'paid'::character varying, 'cancelled'::character varying])::text[])))
);

CREATE TABLE IF NOT EXISTS bill_items (
    id bigserial,
    name character varying(200) NOT NULL,
    kind character varying(10) DEFAULT 'goods'::character varying NOT NULL,
    unit character varying(20) DEFAULT 'pcs'::character varying NOT NULL,
    price numeric(14,2) DEFAULT 0 NOT NULL,
    vat_rate numeric(5,2) DEFAULT 20 NOT NULL,
    CONSTRAINT bill_items_pkey PRIMARY KEY (id),
    CONSTRAINT bill_items_name_key UNIQUE (name),
    CONSTRAINT bill_items_kind_check CHECK (((kind)::text = ANY ((ARRAY['goods'::character varying, 'service'::character varying])::text[]))),
    CONSTRAINT bill_items_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT bill_items_vat_rate_check CHECK (((vat_rate >= (0)::numeric) AND (vat_rate <= (100)::numeric)))
);

-- Functions
CREATE OR REPLACE FUNCTION bill_customer_edit_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_customer bill_customers%ROWTYPE;
BEGIN
    SELECT * INTO v_customer FROM bill_customers WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Customer not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('bill_customer', p_title => v_customer.name,
        p_data => jsonb_build_object('id', v_customer.id::TEXT, 'name', v_customer.name,
                                     'tax_id', COALESCE(v_customer.tax_id, ''), 'email', COALESCE(v_customer.email, ''),
                                     'address', COALESCE(v_customer.address, ''))));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_customer_new_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN ui_ok(ui_open_form('bill_customer', p_title => 'New customer'));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_customer_save(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id   BIGINT := ui_parse_id(p_data->>'id');
    v_name TEXT   := ui_text(p_data, 'name');
BEGIN
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the customer name');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM bill_customers WHERE name = v_name AND id IS DISTINCT FROM v_id),
                       'There is already a customer with this name');
    IF ui_is_new(p_data) THEN
        INSERT INTO bill_customers (name, tax_id, email, address)
        VALUES (v_name, ui_text(p_data, 'tax_id'), ui_text(p_data, 'email'), ui_text(p_data, 'address'));
    ELSE
        UPDATE bill_customers SET name = v_name, tax_id = ui_text(p_data, 'tax_id'), email = ui_text(p_data, 'email'),
                                 address = ui_text(p_data, 'address')
        WHERE id = v_id;
        PERFORM ui_require(FOUND, 'Customer not found — it may have been deleted');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('bill_customers_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_customer_select_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN ui_ok(ui_open_form('bill_customers', p_title => 'Choose a customer',
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name')));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_customers_page(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT ui_grid_page('bill_customers_page', p_data, 'bill_customers_v', NULL, 'name', 'asc',
                    p_search_column => 'search_text', p_search => lower(p_data->>'search'));
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_card(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object(
        'id',                   v.id::TEXT,
        'number',               v.number,
        'status_text',          v.status_badge->>'label',
        'invoice_date',         to_char(v.invoice_date, 'YYYY-MM-DD'),
        'due_date',             COALESCE(to_char(v.due_date, 'YYYY-MM-DD'), ''),
        'customer_id',          v.customer_id::TEXT,
        'customer_id__display', v.customer,
        'notes',                COALESCE(v.notes, '')) || bill_invoice_totals(p_id)
    FROM bill_invoices_v v WHERE v.id = p_id;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_changed(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_array(ui_set_values(bill_invoice_card(p_id), p_form => 'bill_invoice'),
                             ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE));
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_delete(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_invoice bill_invoices%ROWTYPE;
BEGIN
    SELECT * INTO v_invoice FROM bill_invoices WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Invoice not found — it may have been deleted');
    PERFORM ui_require(v_invoice.status = 'draft', 'Only a draft can be deleted; cancel an issued invoice instead');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format(ui_t('Delete invoice %s?'), v_invoice.number), 'bill_invoice_delete',
                                jsonb_build_object('id', v_invoice.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM bill_invoices WHERE id = v_invoice.id;   -- строки удалятся каскадом
    RETURN ui_ok(ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_edit_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_card JSONB := bill_invoice_card(ui_parse_id(p_data->>'id'));
BEGIN
    PERFORM ui_require(v_card IS NOT NULL, 'Invoice not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('bill_invoice', p_title => format(ui_t('Invoice %s'), v_card->>'number'), p_data => v_card));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_issue(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT := bill_invoice_upsert(p_data);
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM bill_invoice_lines WHERE invoice_id = v_id),
                       'Add at least one line before issuing the invoice');
    UPDATE bill_invoices SET status = 'issued' WHERE id = v_id;
    PERFORM ui_print(format(ui_t('Invoice %s issued'), (SELECT number FROM bill_invoices WHERE id = v_id)));
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_new_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN ui_ok(ui_open_form('bill_invoice', p_title => 'New invoice',
        p_data => jsonb_build_object('invoice_date', to_char(current_date, 'YYYY-MM-DD'),
                                     'due_date',     to_char(current_date + 10, 'YYYY-MM-DD'),
                                     'status_text',  ui_t('Draft'))));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_pay(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    UPDATE bill_invoices SET status = 'paid' WHERE id = v_id AND status = 'issued';
    PERFORM ui_require(FOUND, 'Only an issued invoice can be marked as paid');
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_require_draft(p_id bigint)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
AS $function$
DECLARE
    v_status TEXT;
BEGIN
    SELECT status INTO v_status FROM bill_invoices WHERE id = p_id;
    PERFORM ui_require(FOUND, 'Invoice not found — it may have been deleted');
    PERFORM ui_require(v_status = 'draft', 'Only a draft invoice can be changed');
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_save(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id BIGINT := bill_invoice_upsert(p_data);
BEGIN
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE),
                 ui_message(format(ui_t('Invoice %s saved'), (SELECT number FROM bill_invoices WHERE id = v_id))));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_invoices_page(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT ui_grid_page('bill_invoices_page', p_data, 'bill_invoices_v', NULL, 'date_text', 'desc',
                    p_search_column => 'search_text', p_search => lower(p_data->>'search'),
                    p_filters => jsonb_build_object('status', p_data->>'status_filter'));
$function$;

CREATE OR REPLACE FUNCTION bill_invoice_totals(p_id bigint)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
AS $function$
    SELECT jsonb_build_object('totals', format(ui_t('%s (without VAT %s, VAT %s)'),
                              ui_format_money(v.total), ui_format_money(v.amount), ui_format_money(v.vat)))
    FROM bill_invoices_v v WHERE v.id = p_id;
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
AS $function$
DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    PERFORM ui_require(v_id IS NOT NULL, 'The invoice is not saved yet — just close it');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm('Cancel this invoice? It cannot be changed afterwards.', 'bill_invoice_void',
                                jsonb_build_object('id', v_id, 'confirmed', TRUE), p_confirm_label => 'Cancel invoice'));
    END IF;
    UPDATE bill_invoices SET status = 'cancelled' WHERE id = v_id AND status IN ('draft', 'issued');
    PERFORM ui_require(FOUND, 'Only a draft or an issued invoice can be cancelled');
    RETURN ui_ok(bill_invoice_changed(v_id));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_item_delete(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_item bill_items%ROWTYPE;
BEGIN
    SELECT * INTO v_item FROM bill_items WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Not found — it may have been deleted');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM bill_invoice_lines WHERE item_id = v_item.id),
                       'It is used in invoices and cannot be deleted');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format(ui_t('Delete “%s”?'), v_item.name), 'bill_item_delete',
                                jsonb_build_object('id', v_item.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM bill_items WHERE id = v_item.id;
    RETURN ui_ok(ui_refresh_grid('bill_items_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_item_edit_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_item bill_items_v%ROWTYPE;
BEGIN
    SELECT * INTO v_item FROM bill_items_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('bill_item', p_title => v_item.name,
        p_data => jsonb_build_object('id', v_item.id::TEXT, 'name', v_item.name, 'kind', v_item.kind,
                                     'unit', v_item.unit, 'price', v_item.price_input, 'vat_rate', v_item.vat_input)));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_item_new_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    RETURN ui_ok(ui_open_form('bill_item', p_title => 'New goods or service',
        p_data => jsonb_build_object('kind', 'goods', 'unit', 'pcs', 'price', '0', 'vat_rate', '20')));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_item_save(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_id    BIGINT  := ui_parse_id(p_data->>'id');
    v_name  TEXT    := ui_text(p_data, 'name');
    v_kind  TEXT    := COALESCE(ui_text(p_data, 'kind'), 'goods');
    v_unit  TEXT    := COALESCE(ui_text(p_data, 'unit'), 'pcs');
    v_price NUMERIC := ui_parse_money(p_data->>'price');
    v_vat   NUMERIC := ui_parse_money(p_data->>'vat_rate');
BEGIN
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the name');
    PERFORM ui_require(v_price IS NOT NULL, 'Price must be a number, e.g. 1500 or 99.90');
    PERFORM ui_require(v_vat IS NOT NULL AND v_vat <= 100, 'VAT must be from 0 to 100 %');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM bill_items WHERE name = v_name AND id IS DISTINCT FROM v_id),
                       'There is already an item with this name');
    IF ui_is_new(p_data) THEN
        INSERT INTO bill_items (name, kind, unit, price, vat_rate) VALUES (v_name, v_kind, v_unit, v_price, v_vat);
    ELSE
        UPDATE bill_items SET name = v_name, kind = v_kind, unit = v_unit, price = v_price, vat_rate = v_vat
        WHERE id = v_id;
        PERFORM ui_require(FOUND, 'Not found — it may have been deleted');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('bill_items_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_item_select_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- Выбранная строка заполняет и цену, и ставку НДС: {"поле формы": "поле строки списка"}
    RETURN ui_ok(ui_open_form('bill_items', p_title => 'Choose goods or service',
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name',
                                       'fill', jsonb_build_object('price', 'price_input', 'vat_rate', 'vat_input'))));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_items_page(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT ui_grid_page('bill_items_page', p_data, 'bill_items_v', NULL, 'name', 'asc',
                    p_search_column => 'search_text', p_search => lower(p_data->>'search'));
$function$;

CREATE OR REPLACE FUNCTION bill_kinds_combo(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT json_build_object('status', 'success', 'items', json_build_array(
    json_build_object('id', 'goods',   'label', ui_t('Goods')),
    json_build_object('id', 'service', 'label', ui_t('Service'))));
$function$;

CREATE OR REPLACE FUNCTION bill_line_delete(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_line bill_invoice_lines_v%ROWTYPE;
BEGIN
    SELECT * INTO v_line FROM bill_invoice_lines_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Line not found — it may have been deleted');
    PERFORM bill_invoice_require_draft(v_line.invoice_id);
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format(ui_t('Remove “%s” from the invoice?'), v_line.item), 'bill_line_delete',
                                jsonb_build_object('id', v_line.id, 'confirmed', TRUE), p_confirm_label => 'Remove'));
    END IF;
    DELETE FROM bill_invoice_lines WHERE id = v_line.id;
    RETURN ui_ok(ui_refresh_grid('bill_lines_grid', p_keep_page => TRUE),
                 ui_set_values(bill_invoice_totals(v_line.invoice_id), p_form => 'bill_invoice'),
                 ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_line_edit_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_line bill_invoice_lines_v%ROWTYPE;
BEGIN
    SELECT * INTO v_line FROM bill_invoice_lines_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Line not found — it may have been deleted');
    PERFORM bill_invoice_require_draft(v_line.invoice_id);
    RETURN ui_ok(ui_open_form('bill_line', p_title => v_line.item,
        p_data => jsonb_build_object('id', v_line.id::TEXT, 'invoice_id', v_line.invoice_id::TEXT,
                                     'item_id', v_line.item_id::TEXT, 'item_id__display', v_line.item,
                                     'quantity', trim_scale(v_line.quantity)::TEXT,
                                     'price', ui_money_input(v_line.price),
                                     'vat_rate', trim_scale(v_line.vat_rate)::TEXT)));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_line_new_open(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    -- Новый счёт сначала сохраняется: строке нужен id счёта
    v_id BIGINT := bill_invoice_upsert(p_data);
BEGIN
    PERFORM bill_invoice_require_draft(v_id);
    RETURN ui_ok(ui_set_values(bill_invoice_card(v_id)),
                 ui_set_title(format(ui_t('Invoice %s'), (SELECT number FROM bill_invoices WHERE id = v_id))),
                 ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE),
                 ui_open_form('bill_line', p_title => 'Invoice line',
                              p_data => jsonb_build_object('invoice_id', v_id::TEXT, 'quantity', '1')));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_line_save(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_invoice  BIGINT  := ui_parse_id(p_data->>'invoice_id');
    v_item     BIGINT  := ui_parse_id(p_data->>'item_id');
    v_quantity NUMERIC := ui_parse_money(p_data->>'quantity');
    v_price    NUMERIC := ui_parse_money(p_data->>'price');
    v_vat      NUMERIC := ui_parse_money(p_data->>'vat_rate');
BEGIN
    PERFORM bill_invoice_require_draft(v_invoice);
    PERFORM ui_require(EXISTS (SELECT 1 FROM bill_items WHERE id = v_item), 'Choose goods or a service');
    PERFORM ui_require(v_quantity > 0, 'Quantity must be a number greater than zero');
    PERFORM ui_require(v_price IS NOT NULL, 'Price must be a number, e.g. 1500 or 99.90');
    PERFORM ui_require(v_vat IS NOT NULL AND v_vat <= 100, 'VAT must be from 0 to 100 %');
    IF ui_is_new(p_data) THEN
        INSERT INTO bill_invoice_lines (invoice_id, item_id, quantity, price, vat_rate)
        VALUES (v_invoice, v_item, v_quantity, v_price, v_vat);
    ELSE
        UPDATE bill_invoice_lines SET item_id = v_item, quantity = v_quantity, price = v_price, vat_rate = v_vat
        WHERE id = ui_parse_id(p_data->>'id') AND invoice_id = v_invoice;
        PERFORM ui_require(FOUND, 'Line not found — it may have been deleted');
    END IF;
    -- Закрыть строку, перечитать строки и обновить итоги в карточке счёта (другая открытая форма)
    RETURN ui_ok(ui_close_form(),
                 ui_refresh_grid('bill_lines_grid', p_keep_page => TRUE),
                 ui_set_values(bill_invoice_totals(v_invoice), p_form => 'bill_invoice'),
                 ui_refresh_grid('bill_invoices_grid', p_keep_page => TRUE));
END;
$function$;

CREATE OR REPLACE FUNCTION bill_lines_page(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT ui_grid_page('bill_lines_page', p_data, 'bill_invoice_lines_v', 'invoice_id', 'id', 'asc');
$function$;

CREATE OR REPLACE FUNCTION bill_statuses_combo(p_data json)
 RETURNS json
 LANGUAGE sql
 STABLE
AS $function$
SELECT json_build_object('status', 'success', 'items', json_build_array(
    json_build_object('id', 'draft',     'label', ui_t('Draft')),
    json_build_object('id', 'issued',    'label', ui_t('Issued')),
    json_build_object('id', 'paid',      'label', ui_t('Paid')),
    json_build_object('id', 'cancelled', 'label', ui_t('Cancelled'))));
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
    lower(concat_ws(' '::text, v.number, c.name)) AS search_text
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
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'bill_invoice_lines'::regclass AND conname = 'bill_invoice_lines_invoice_id_fkey') THEN
        ALTER TABLE bill_invoice_lines ADD CONSTRAINT bill_invoice_lines_invoice_id_fkey FOREIGN KEY (invoice_id) REFERENCES bill_invoices(id) ON DELETE CASCADE;
    END IF;
END;
$c$;

DO $c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'bill_invoice_lines'::regclass AND conname = 'bill_invoice_lines_item_id_fkey') THEN
        ALTER TABLE bill_invoice_lines ADD CONSTRAINT bill_invoice_lines_item_id_fkey FOREIGN KEY (item_id) REFERENCES bill_items(id) ON DELETE RESTRICT;
    END IF;
END;
$c$;

DO $c$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'bill_invoices'::regclass AND conname = 'bill_invoices_customer_id_fkey') THEN
        ALTER TABLE bill_invoices ADD CONSTRAINT bill_invoices_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES bill_customers(id) ON DELETE RESTRICT;
    END IF;
END;
$c$;

-- Indexes
CREATE INDEX IF NOT EXISTS bill_invoice_lines_invoice_id_idx ON bill_invoice_lines USING btree (invoice_id);

CREATE INDEX IF NOT EXISTS bill_invoice_lines_item_id_idx ON bill_invoice_lines USING btree (item_id);

CREATE INDEX IF NOT EXISTS bill_invoices_customer_id_idx ON bill_invoices USING btree (customer_id);

CREATE INDEX IF NOT EXISTS bill_invoices_invoice_date_idx ON bill_invoices USING btree (invoice_date);

-- Comments
COMMENT ON TABLE bill_customers IS 'Customers (payers)';

COMMENT ON COLUMN bill_customers.name IS 'Name';

COMMENT ON COLUMN bill_customers.tax_id IS 'Tax ID';

COMMENT ON COLUMN bill_customers.address IS 'Address';

COMMENT ON COLUMN bill_customers.email IS 'E-mail';

COMMENT ON TABLE bill_invoice_lines IS 'Invoice lines (details)';

COMMENT ON COLUMN bill_invoice_lines.invoice_id IS 'Invoice';

COMMENT ON COLUMN bill_invoice_lines.item_id IS 'Goods or service';

COMMENT ON COLUMN bill_invoice_lines.quantity IS 'Quantity';

COMMENT ON COLUMN bill_invoice_lines.price IS 'Price without VAT';

COMMENT ON COLUMN bill_invoice_lines.vat_rate IS 'VAT, %';

COMMENT ON TABLE bill_invoices IS 'Invoices (master)';

COMMENT ON COLUMN bill_invoices.number IS 'Invoice number';

COMMENT ON COLUMN bill_invoices.invoice_date IS 'Invoice date';

COMMENT ON COLUMN bill_invoices.due_date IS 'Pay by';

COMMENT ON COLUMN bill_invoices.customer_id IS 'Customer';

COMMENT ON COLUMN bill_invoices.status IS 'draft, issued, paid, cancelled';

COMMENT ON COLUMN bill_invoices.notes IS 'Notes';

COMMENT ON COLUMN bill_invoices.created_by IS 'Author login';

COMMENT ON TABLE bill_items IS 'Goods and services';

COMMENT ON COLUMN bill_items.name IS 'Name';

COMMENT ON COLUMN bill_items.kind IS 'goods or service';

COMMENT ON COLUMN bill_items.unit IS 'Unit of measure';

COMMENT ON COLUMN bill_items.price IS 'Price without VAT';

COMMENT ON COLUMN bill_items.vat_rate IS 'VAT, %';

-- Metadata
INSERT INTO pgerp.ui_actions (action_name, function_name, description, everyone) VALUES
    ('bill_customer_edit_open', 'bill_customer_edit_open', 'Invoices: open customer', 'false'),
    ('bill_customer_new_open', 'bill_customer_new_open', 'Invoices: new customer', 'false'),
    ('bill_customer_save', 'bill_customer_save', 'Invoices: save customer', 'false'),
    ('bill_customer_select_open', 'bill_customer_select_open', 'Invoices: choose a customer', 'false'),
    ('bill_customers_page', 'bill_customers_page', 'Invoices: customers list', 'false'),
    ('bill_invoice_delete', 'bill_invoice_delete', 'Invoices: delete a draft invoice', 'false'),
    ('bill_invoice_edit_open', 'bill_invoice_edit_open', 'Invoices: open invoice', 'false'),
    ('bill_invoice_issue', 'bill_invoice_issue', 'Invoices: issue invoice', 'false'),
    ('bill_invoice_new_open', 'bill_invoice_new_open', 'Invoices: new invoice', 'false'),
    ('bill_invoice_pay', 'bill_invoice_pay', 'Invoices: mark invoice as paid', 'false'),
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
    ('bill_invoice', 'Invoice', NULL, 'Billing'),
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
    ('bill_invoice', '15', 'button', 'btn_close', 'Close', 'form_close', NULL, NULL, NULL),
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

DELETE FROM pgerp.grid_columns WHERE action_name IN ('bill_customer_edit_open', 'bill_customer_new_open', 'bill_customer_save', 'bill_customer_select_open', 'bill_customers_page', 'bill_invoice_delete', 'bill_invoice_edit_open', 'bill_invoice_issue', 'bill_invoice_new_open', 'bill_invoice_pay', 'bill_invoice_save', 'bill_invoices_page', 'bill_invoice_void', 'bill_item_delete', 'bill_item_edit_open', 'bill_item_new_open', 'bill_item_save', 'bill_item_select_open', 'bill_items_page', 'bill_kinds_combo', 'bill_line_delete', 'bill_line_edit_open', 'bill_line_new_open', 'bill_line_save', 'bill_lines_page', 'bill_statuses_combo');
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
DELETE FROM pgerp.grid_row_actions WHERE source_action IN ('bill_customer_edit_open', 'bill_customer_new_open', 'bill_customer_save', 'bill_customer_select_open', 'bill_customers_page', 'bill_invoice_delete', 'bill_invoice_edit_open', 'bill_invoice_issue', 'bill_invoice_new_open', 'bill_invoice_pay', 'bill_invoice_save', 'bill_invoices_page', 'bill_invoice_void', 'bill_item_delete', 'bill_item_edit_open', 'bill_item_new_open', 'bill_item_save', 'bill_item_select_open', 'bill_items_page', 'bill_kinds_combo', 'bill_line_delete', 'bill_line_edit_open', 'bill_line_new_open', 'bill_line_save', 'bill_lines_page', 'bill_statuses_combo');
INSERT INTO pgerp.grid_row_actions (source_action, sort_order, row_action, label, style) VALUES
    ('bill_customers_page', '1', 'bill_customer_edit_open', 'Edit', 'default'),
    ('bill_invoices_page', '1', 'bill_invoice_edit_open', 'Open', 'default'),
    ('bill_invoices_page', '2', 'bill_invoice_delete', 'Delete', 'danger'),
    ('bill_items_page', '1', 'bill_item_edit_open', 'Edit', 'default'),
    ('bill_items_page', '2', 'bill_item_delete', 'Delete', 'danger'),
    ('bill_lines_page', '1', 'bill_line_edit_open', 'Edit', 'default'),
    ('bill_lines_page', '2', 'bill_line_delete', 'Remove', 'danger');

INSERT INTO pgerp.roles (role_name, title) VALUES
    ('bill_accountant', 'Billing: accountant')
ON CONFLICT (role_name) DO UPDATE SET title = EXCLUDED.title;
DELETE FROM pgerp.role_forms WHERE role_id IN (SELECT id FROM pgerp.roles WHERE role_name IN ('bill_accountant'));
INSERT INTO pgerp.role_forms (role_id, form_name)
SELECT r.id, v.form_name FROM (VALUES
    ('bill_accountant', 'bill_customers'),
    ('bill_accountant', 'bill_invoices'),
    ('bill_accountant', 'bill_items')
) AS v(role_name, form_name)
JOIN pgerp.roles r ON r.role_name = v.role_name
WHERE EXISTS (SELECT 1 FROM pgerp.forms f WHERE f.form_name = v.form_name);

SELECT pgerp.solution_menu_apply('Billing', '[
    {
        "form": "bill_invoices",
        "title": "Invoices"
    },
    {
        "form": "bill_customers",
        "title": "Customers"
    },
    {
        "form": "bill_items",
        "title": "Goods and services"
    }
]');

-- Dropped functions and types, translations
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Add', 'Добавить'),
    ('ru', 'Add at least one line before issuing the invoice', 'Добавьте в счёт хотя бы одну строку'),
    ('ru', 'Add line', 'Добавить строку'),
    ('ru', 'Address', 'Адрес'),
    ('ru', 'All', 'Все'),
    ('ru', 'Amount', 'Сумма'),
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
    ('ru', 'Customer', 'Покупатель'),
    ('ru', 'Customer not found — it may have been deleted', 'Покупатель не найден — возможно, его удалили'),
    ('ru', 'Customers', 'Покупатели'),
    ('ru', 'Date', 'Дата'),
    ('ru', 'Delete', 'Удалить'),
    ('ru', 'Delete invoice %s?', 'Удалить счёт %s?'),
    ('ru', 'Delete “%s”?', 'Удалить «%s»?'),
    ('ru', 'Draft', 'Черновик'),
    ('ru', 'Edit', 'Изменить'),
    ('ru', 'E-mail', 'Эл. почта'),
    ('ru', 'Enter the customer name', 'Укажите название покупателя'),
    ('ru', 'Enter the invoice date', 'Укажите дату счёта'),
    ('ru', 'Enter the name', 'Укажите название'),
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
    ('ru', 'Paid', 'Оплачен'),
    ('ru', 'Pay by', 'Оплатить до'),
    ('ru', 'Price', 'Цена'),
    ('ru', 'Price must be a number, e.g. 1500 or 99.90', 'Цена — число, например 1500 или 99,90'),
    ('ru', 'Price without VAT', 'Цена без НДС'),
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
    ('ru', 'The invoice is not saved yet — just close it', 'Счёт ещё не сохранён — просто закройте его'),
    ('ru', 'The payment date cannot be earlier than the invoice date', 'Срок оплаты не может быть раньше даты счёта'),
    ('ru', 'There is already a customer with this name', 'Покупатель с таким названием уже есть'),
    ('ru', 'There is already an item with this name', 'Товар или услуга с таким названием уже есть'),
    ('ru', 'Total', 'Итого'),
    ('ru', 'Unit', 'Ед. изм.'),
    ('ru', 'VAT', 'НДС'),
    ('ru', 'VAT, %', 'НДС, %'),
    ('ru', 'VAT must be from 0 to 100 %', 'НДС — от 0 до 100 %')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;
$release$);
