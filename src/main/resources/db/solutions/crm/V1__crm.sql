-- =====================================================================
-- Пакет решения «CRM», выпуск 1: пример прикладной системы на PgERP — полный цикл продаж
-- =====================================================================
-- Устанавливает администратор (при первом входе или в редакторе: «Решения → Установить»); объекты
-- создаются в схеме решения (по умолчанию crm, выбирается при установке): имена в этом файле — без схемы.
--
--  * Компании и контакты — общий справочник; изменить компанию может её ответственный или руководитель.
--  * Сделки по воронке: стадии с вероятностью, товары и услуги в сделке со скидкой, плановая дата
--    закрытия, «Следующая стадия» / «Выиграна» / «Проиграна» (с причиной), журнал изменений.
--    Сделку можно закрыть без сохранения: при открытии карточки запоминается снимок сделки, а «Отмена»,
--    крестик и Escape переспрашивают «Закрыть без сохранения?» и возвращают сделку к нему.
--  * Задачи, звонки, встречи, письма и заметки по сделке или компании; сроки, просрочка,
--    «Напоминания» — список в панели сообщений (ui_print).
--  * Роли: «Менеджер по продажам» видит свои сделки и задачи, «Руководитель отдела продаж» (и admin) —
--    все, плюс воронку по стадиям и менеджерам. Видимость — в представлениях (crm_can_see).
--  * Уведомления: переданная сделка или задача — окно у нового ответственного (ui_push_to_user),
--    выигранная сделка — руководителям (ui_push_to_role); списки обновляются во всех вкладках (ui_push_to).
--  * Отчёты PDF: коммерческое предложение по сделке и воронка продаж (ui_report).
--
-- Все объекты — с префиксом crm_: функции правятся в редакторе функций, их тексты попадают в форму
-- «Переводы». Демо-пользователи ivanov, petrova (менеджеры) и sidorov (руководитель) создаются без пароля:
-- администратор задаёт его в форме «Пользователи». Даты демо-данных — относительно времени установки.
-- Выпуск применяется один раз: на базе, где он уже записан (pgerp.solution_releases), он пропускается.
SELECT pgerp.solution_release_apply('crm', 1, 'CRM', $release$
-- ---------------------------------------------------------------------
-- Решение
-- ---------------------------------------------------------------------
INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description)
VALUES ('crm', 'CRM', 'crm_', 'CRM', 'crm', 'Companies, contacts, pipeline deals, tasks, reports')
ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, prefix = EXCLUDED.prefix, menu_folder = EXCLUDED.menu_folder,
    migration_folder = EXCLUDED.migration_folder, description = EXCLUDED.description;

-- ---------------------------------------------------------------------
-- Роли и демо-пользователи
-- ---------------------------------------------------------------------
INSERT INTO pgerp.roles (role_name, title) VALUES
    ('crm_manager', 'Sales manager'),
    ('crm_head',    'Head of sales')
ON CONFLICT (role_name) DO NOTHING;

-- Пароль — случайный, никому не известный: войти можно после того, как администратор задаст пароль
INSERT INTO pgerp.users (login, full_name, password_hash, must_change_password) VALUES
    ('ivanov',  'Ivan Ivanov',     pgerp.auth_hash(gen_random_uuid()::TEXT), TRUE),
    ('petrova', 'Maria Petrova',   pgerp.auth_hash(gen_random_uuid()::TEXT), TRUE),
    ('sidorov', 'Alexey Sidorov', pgerp.auth_hash(gen_random_uuid()::TEXT), TRUE)
ON CONFLICT (login) DO NOTHING;

INSERT INTO pgerp.user_roles (user_id, role_id)
SELECT u.id, r.id
FROM (VALUES ('ivanov', 'crm_manager'), ('petrova', 'crm_manager'), ('sidorov', 'crm_head')) AS t(login, role)
JOIN pgerp.users u ON u.login = t.login
JOIN pgerp.roles r ON r.role_name = t.role
ON CONFLICT DO NOTHING;

-- ---------------------------------------------------------------------
-- Таблицы
-- ---------------------------------------------------------------------
CREATE TABLE crm_industries (
    id   BIGSERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL UNIQUE
);

-- Воронка: порядок, вероятность успеха, закрывающие стадии (выиграна / проиграна)
CREATE TABLE crm_stages (
    id          BIGSERIAL PRIMARY KEY,
    code        VARCHAR(20) NOT NULL UNIQUE CHECK (code ~ '^[a-z_]+$'),
    name        VARCHAR(100) NOT NULL,
    sort_order  INT NOT NULL,
    probability INT NOT NULL CHECK (probability BETWEEN 0 AND 100),
    is_closed   BOOLEAN NOT NULL DEFAULT FALSE,
    is_won      BOOLEAN NOT NULL DEFAULT FALSE,
    CHECK (NOT is_won OR is_closed)
);

CREATE TABLE crm_activity_kinds (
    code       VARCHAR(20) PRIMARY KEY CHECK (code ~ '^[a-z_]+$'),
    name       VARCHAR(100) NOT NULL,
    sort_order INT NOT NULL
);

CREATE TABLE crm_companies (
    id          BIGSERIAL PRIMARY KEY,
    name        VARCHAR(200) NOT NULL CHECK (trim(name) <> ''),
    inn         VARCHAR(12) CHECK (inn ~ '^(\d{10}|\d{12})$'),
    industry_id BIGINT REFERENCES crm_industries(id) ON DELETE SET NULL,
    phone       VARCHAR(50),
    email       VARCHAR(200),
    website     VARCHAR(200),
    address     TEXT,
    owner_login VARCHAR(50) NOT NULL REFERENCES pgerp.users(login) ON UPDATE CASCADE,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX crm_companies_name_key ON crm_companies (lower(name));
CREATE INDEX crm_companies_owner_idx ON crm_companies (owner_login);

CREATE TABLE crm_contacts (
    id         BIGSERIAL PRIMARY KEY,
    company_id BIGINT NOT NULL REFERENCES crm_companies(id) ON DELETE CASCADE,
    full_name  VARCHAR(200) NOT NULL CHECK (trim(full_name) <> ''),
    position   VARCHAR(200),
    phone      VARCHAR(50),
    email      VARCHAR(200),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX crm_contacts_company_idx ON crm_contacts (company_id);

-- Группы товаров и услуг: дерево любой глубины
CREATE TABLE crm_product_groups (
    id        BIGSERIAL PRIMARY KEY,
    parent_id BIGINT REFERENCES crm_product_groups(id),
    name      VARCHAR(100) NOT NULL CHECK (trim(name) <> '')
);
CREATE UNIQUE INDEX crm_product_groups_name_idx ON crm_product_groups (COALESCE(parent_id, 0), lower(name));

CREATE TABLE crm_products (
    id       BIGSERIAL PRIMARY KEY,
    group_id BIGINT NOT NULL REFERENCES crm_product_groups(id),
    name     VARCHAR(200) NOT NULL UNIQUE,
    sku      VARCHAR(50) UNIQUE,
    unit     VARCHAR(20) NOT NULL DEFAULT 'pcs',
    price    NUMERIC(12,2) NOT NULL CHECK (price >= 0)
);
CREATE INDEX crm_products_group_idx ON crm_products (group_id);

CREATE TABLE crm_deals (
    id             BIGSERIAL PRIMARY KEY,
    title          VARCHAR(200) NOT NULL CHECK (trim(title) <> ''),
    company_id     BIGINT NOT NULL REFERENCES crm_companies(id),
    contact_id     BIGINT REFERENCES crm_contacts(id) ON DELETE SET NULL,
    stage_id       BIGINT NOT NULL REFERENCES crm_stages(id),
    owner_login    VARCHAR(50) NOT NULL REFERENCES pgerp.users(login) ON UPDATE CASCADE,
    expected_close DATE,
    closed_on      DATE,
    lost_reason    TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX crm_deals_company_idx ON crm_deals (company_id);
CREATE INDEX crm_deals_owner_idx ON crm_deals (owner_login);
CREATE INDEX crm_deals_stage_idx ON crm_deals (stage_id);

CREATE TABLE crm_deal_lines (
    id         BIGSERIAL PRIMARY KEY,
    deal_id    BIGINT NOT NULL REFERENCES crm_deals(id) ON DELETE CASCADE,
    product_id BIGINT NOT NULL REFERENCES crm_products(id),
    quantity   NUMERIC(12,2) NOT NULL CHECK (quantity > 0),
    price      NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    discount   NUMERIC(5,2) NOT NULL DEFAULT 0 CHECK (discount BETWEEN 0 AND 100)
);
CREATE INDEX crm_deal_lines_deal_idx ON crm_deal_lines (deal_id);

-- Задачи, звонки, встречи, письма, заметки: по сделке, по компании или сами по себе
CREATE TABLE crm_activities (
    id          BIGSERIAL PRIMARY KEY,
    kind        VARCHAR(20) NOT NULL REFERENCES crm_activity_kinds(code),
    subject     VARCHAR(300) NOT NULL CHECK (trim(subject) <> ''),
    notes       TEXT,
    due_on      DATE,
    done_at     TIMESTAMPTZ,
    deal_id     BIGINT REFERENCES crm_deals(id) ON DELETE CASCADE,
    company_id  BIGINT REFERENCES crm_companies(id) ON DELETE CASCADE,
    owner_login VARCHAR(50) NOT NULL REFERENCES pgerp.users(login) ON UPDATE CASCADE,
    created_by  VARCHAR(50),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX crm_activities_owner_idx ON crm_activities (owner_login, done_at);
CREATE INDEX crm_activities_deal_idx ON crm_activities (deal_id);
CREATE INDEX crm_activities_company_idx ON crm_activities (company_id);

-- Журнал сделки: создание, смена стадии и ответственного, выполненные задачи
CREATE TABLE crm_deal_events (
    id      BIGSERIAL PRIMARY KEY,
    deal_id BIGINT NOT NULL REFERENCES crm_deals(id) ON DELETE CASCADE,
    at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    login   VARCHAR(50),
    text    TEXT NOT NULL
);
CREATE INDEX crm_deal_events_deal_idx ON crm_deal_events (deal_id, at);

-- Снимок открытой на редактирование сделки; state IS NULL — сделка создана в этой карточке
CREATE TABLE crm_deal_snapshots (
    deal_id    BIGINT PRIMARY KEY REFERENCES crm_deals(id) ON DELETE CASCADE,
    state      JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Видимость и общие функции
-- ---------------------------------------------------------------------
-- Руководитель отдела и администратор видят всё; без пользователя (консоль, миграции) — тоже всё
CREATE FUNCTION crm_is_head()
RETURNS BOOLEAN AS $$
    SELECT ui_user() IS NULL OR ui_has_role('crm_head') OR ui_has_role('admin');
$$ LANGUAGE sql STABLE;

-- Сделку и задачу видит ответственный и руководитель
CREATE FUNCTION crm_can_see(p_owner VARCHAR)
RETURNS BOOLEAN AS $$
    SELECT p_owner = ui_user() OR crm_is_head();
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_user_name(p_login VARCHAR)
RETURNS VARCHAR AS $$
    SELECT COALESCE((SELECT NULLIF(full_name, '') FROM pgerp.users WHERE login = p_login), p_login);
$$ LANGUAGE sql STABLE;

-- Метка для колонки badge: код задаёт цвет, подпись — на языке пользователя
CREATE FUNCTION crm_badge(p_code TEXT, p_label TEXT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('code', p_code, 'label', ui_t(p_label));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_date(p_date DATE)
RETURNS TEXT AS $$
    SELECT to_char(p_date, 'DD.MM.YYYY');
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Представления (видимость — здесь: менеджер получает только свои сделки и задачи)
-- ---------------------------------------------------------------------
-- Ответственные: менеджеры, руководители и сам пользователь (например, администратор)
CREATE VIEW crm_owners_v AS
SELECT u.id, u.login, COALESCE(NULLIF(u.full_name, ''), u.login) AS name
FROM pgerp.users u
WHERE u.is_active
  AND (pgerp.auth_has_role(u.id, 'crm_manager') OR pgerp.auth_has_role(u.id, 'crm_head') OR u.login = ui_user());

CREATE VIEW crm_companies_v AS
SELECT c.id, c.name, c.inn, c.industry_id, i.name AS industry, c.phone, c.email, c.website, c.address,
       c.owner_login, crm_user_name(c.owner_login) AS owner,
       (SELECT count(*) FROM crm_deals d JOIN crm_stages s ON s.id = d.stage_id
        WHERE d.company_id = c.id AND NOT s.is_closed) AS open_deals,
       lower(concat_ws(' ', c.name, c.inn, c.phone, c.email)) AS search_text
FROM crm_companies c
LEFT JOIN crm_industries i ON i.id = c.industry_id;

CREATE VIEW crm_contacts_v AS
SELECT ct.id, ct.company_id, co.name AS company, ct.full_name, ct.position, ct.phone, ct.email,
       lower(concat_ws(' ', ct.full_name, co.name, ct.phone, ct.email)) AS search_text
FROM crm_contacts ct
JOIN crm_companies co ON co.id = ct.company_id;

CREATE VIEW crm_deal_lines_v AS
SELECT l.id, l.deal_id, l.product_id, p.name AS product, p.sku, p.unit, l.quantity, l.price, l.discount,
       round(l.quantity * l.price * (1 - l.discount / 100), 2) AS amount
FROM crm_deal_lines l
JOIN crm_products p ON p.id = l.product_id;

CREATE VIEW crm_deals_v AS
SELECT d.id, d.title, d.company_id, co.name AS company, d.contact_id, ct.full_name AS contact,
       d.stage_id, s.code AS stage_code, s.sort_order AS stage_order, crm_badge(s.code, s.name) AS stage,
       s.probability, s.is_closed, s.is_won,
       d.owner_login, crm_user_name(d.owner_login) AS owner,
       COALESCE(a.amount, 0) AS amount,
       round(COALESCE(a.amount, 0) * s.probability / 100, 2) AS weighted,
       d.expected_close, crm_date(d.expected_close) AS close_date,
       (NOT s.is_closed AND d.expected_close < current_date) AS is_overdue,
       d.closed_on, d.lost_reason, d.created_at,
       lower(concat_ws(' ', d.title, co.name)) AS search_text
FROM crm_deals d
JOIN crm_companies co ON co.id = d.company_id
JOIN crm_stages s ON s.id = d.stage_id
LEFT JOIN crm_contacts ct ON ct.id = d.contact_id
LEFT JOIN (SELECT deal_id, sum(amount) AS amount FROM crm_deal_lines_v GROUP BY deal_id) a ON a.deal_id = d.id
WHERE crm_can_see(d.owner_login);

-- Состояние задачи: выполнена, просрочена, на сегодня, запланирована
CREATE VIEW crm_activities_v AS
SELECT a.id, a.kind, ui_t(k.name) AS kind_name, a.subject, a.notes,
       a.due_on, crm_date(a.due_on) AS due, COALESCE(a.due_on, DATE '9999-12-31') AS due_sort,
       x.state_code, crm_badge(x.state_code, x.state_name) AS state,
       a.done_at IS NOT NULL AS is_done, a.done_at,
       a.deal_id, d.title AS deal,
       COALESCE(a.company_id, d.company_id) AS company_id, co.name AS company,
       COALESCE(d.title, co.name) AS related,
       a.owner_login, crm_user_name(a.owner_login) AS owner,
       lower(concat_ws(' ', a.subject, d.title, co.name)) AS search_text
FROM crm_activities a
JOIN crm_activity_kinds k ON k.code = a.kind
LEFT JOIN crm_deals d ON d.id = a.deal_id
LEFT JOIN crm_companies co ON co.id = COALESCE(a.company_id, d.company_id)
CROSS JOIN LATERAL (
    SELECT CASE WHEN a.done_at IS NOT NULL THEN 'done'
                WHEN a.due_on < current_date THEN 'overdue'
                WHEN a.due_on = current_date THEN 'today'
                ELSE 'open' END AS state_code,
           CASE WHEN a.done_at IS NOT NULL THEN 'Completed'
                WHEN a.due_on < current_date THEN 'Overdue'
                WHEN a.due_on = current_date THEN 'Today'
                ELSE 'Planned' END AS state_name) x
WHERE crm_can_see(a.owner_login);

CREATE VIEW crm_deal_events_v AS
SELECT e.id, e.deal_id, e.at, to_char(e.at, 'DD.MM.YYYY HH24:MI') AS at_text,
       COALESCE(crm_user_name(e.login), ui_t('system')) AS author, ui_t(e.text) AS text
FROM crm_deal_events e;

-- Группы на языке пользователя (названия демо-групп переводятся, свои — как есть) — для дерева
CREATE VIEW crm_product_groups_t AS
SELECT id, parent_id, ui_t(name) AS title FROM crm_product_groups;

-- Группы с путём от корня («Services / Implementation») и id предков — для списков выбора и фильтра товаров
CREATE VIEW crm_product_groups_v AS
WITH RECURSIVE g AS (
    SELECT id, parent_id, name, ui_t(name) AS path, ARRAY[id] AS ids
    FROM crm_product_groups WHERE parent_id IS NULL
    UNION ALL
    SELECT c.id, c.parent_id, c.name, g.path || ' / ' || ui_t(c.name), g.ids || c.id
    FROM crm_product_groups c JOIN g ON c.parent_id = g.id
)
SELECT id, parent_id, name, path, ids FROM g;

CREATE VIEW crm_products_v AS
SELECT p.id, p.group_id, g.path AS group_path, g.ids AS group_ids, p.name, p.sku, p.unit, p.price,
       ui_money_input(p.price) AS price_input, lower(concat_ws(' ', p.name, p.sku)) AS search_text
FROM crm_products p
JOIN crm_product_groups_v g ON g.id = p.group_id;

-- Воронка по стадиям — по видимым сделкам
CREATE VIEW crm_pipeline_v AS
SELECT s.id, s.sort_order, crm_badge(s.code, s.name) AS stage, ui_t(s.name) AS stage_name, s.probability,
       count(d.id) AS deals, COALESCE(sum(d.amount), 0) AS amount, COALESCE(sum(d.weighted), 0) AS weighted
FROM crm_stages s
LEFT JOIN crm_deals_v d ON d.stage_id = s.id
GROUP BY s.id;

CREATE VIEW crm_pipeline_owners_v AS
SELECT u.id, u.login, COALESCE(NULLIF(u.full_name, ''), u.login) AS owner,
       count(d.id) FILTER (WHERE NOT d.is_closed) AS open_deals,
       COALESCE(sum(d.amount) FILTER (WHERE NOT d.is_closed), 0) AS open_amount,
       COALESCE(sum(d.weighted) FILTER (WHERE NOT d.is_closed), 0) AS weighted,
       COALESCE(sum(d.amount) FILTER (WHERE d.is_won AND d.closed_on >= date_trunc('month', current_date)), 0)
           AS won_month,
       (SELECT count(*) FROM crm_activities_v a WHERE a.owner_login = u.login AND a.state_code = 'overdue')
           AS overdue_tasks
FROM pgerp.users u
JOIN crm_deals_v d ON d.owner_login = u.login
GROUP BY u.id;

-- ---------------------------------------------------------------------
-- Списки выбора
-- ---------------------------------------------------------------------
-- Стадии — в порядке воронки, а не по алфавиту
CREATE FUNCTION crm_stages_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'items',
        (SELECT json_agg(json_build_object('id', id, 'label', ui_t(name)) ORDER BY sort_order) FROM crm_stages));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_owners_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('crm_owners_v', 'name', 'login');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_industries_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('crm_industries');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_activity_kinds_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'items',
        (SELECT json_agg(json_build_object('id', code, 'label', ui_t(name)) ORDER BY sort_order)
         FROM crm_activity_kinds));
$$ LANGUAGE sql STABLE;

-- Фильтр списка задач; пустое значение — открытые
CREATE FUNCTION crm_task_filter_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'items', json_build_array(
        json_build_object('id', 'today',   'label', ui_t('Due today')),
        json_build_object('id', 'overdue', 'label', ui_t('Overdue only')),
        json_build_object('id', 'done',    'label', ui_t('Completed only')),
        json_build_object('id', 'all',     'label', ui_t('All, including done'))));
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Компании
-- ---------------------------------------------------------------------
CREATE FUNCTION crm_companies_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_companies_page', p_data, 'crm_companies_v', NULL, 'name', 'asc',
                        p_search_column => 'search_text', p_search => p_data->>'search',
                        p_filters => jsonb_build_object('industry_id', p_data->>'industry_filter'));
$$ LANGUAGE sql;

-- Кнопка «...» у поля «Компания»: список компаний в режиме выбора
CREATE FUNCTION crm_company_select_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_companies',
        p_title  => 'Select a company',
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name')));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_company_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_company',
        p_title => 'New company',
        p_data  => jsonb_build_object('owner_login', ui_user())));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_company_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_company crm_companies%ROWTYPE;
BEGIN
    SELECT * INTO v_company FROM crm_companies WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Company not found — it may have been deleted');

    RETURN ui_ok(ui_open_form('crm_company',
        p_title => v_company.name,
        p_data  => jsonb_build_object(
            'id', v_company.id::TEXT,
            'name', v_company.name,
            'inn', COALESCE(v_company.inn, ''),
            'industry_id', COALESCE(v_company.industry_id::TEXT, ''),
            'phone', COALESCE(v_company.phone, ''),
            'email', COALESCE(v_company.email, ''),
            'website', COALESCE(v_company.website, ''),
            'address', COALESCE(v_company.address, ''),
            'owner_login', v_company.owner_login)));
END;
$$ LANGUAGE plpgsql;

-- Карточка компании: новая создаётся, существующая меняется ответственным или руководителем; возвращает id
CREATE FUNCTION crm_company_upsert(p_data JSON)
RETURNS BIGINT AS $$
DECLARE
    v_id       BIGINT  := ui_parse_id(p_data->>'id');
    v_name     VARCHAR := ui_text(p_data, 'name');
    v_inn      VARCHAR := ui_text(p_data, 'inn');
    v_email    VARCHAR := ui_text(p_data, 'email');
    v_owner    VARCHAR := COALESCE(ui_text(p_data, 'owner_login'), ui_user());
    v_industry BIGINT  := ui_parse_id(p_data->>'industry_id');
    v_current  crm_companies%ROWTYPE;
BEGIN
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the company name');
    PERFORM ui_require(v_inn IS NULL OR v_inn ~ '^(\d{10}|\d{12})$', 'Tax ID must be 10 or 12 digits');
    PERFORM ui_require(v_email IS NULL OR v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'Invalid email');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_owners_v WHERE login = v_owner), 'Choose an owner');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_companies WHERE lower(name) = lower(v_name) AND id IS DISTINCT FROM v_id),
                       format('Company “%s” already exists', v_name));

    IF ui_is_new(p_data) THEN
        INSERT INTO crm_companies (name, inn, industry_id, phone, email, website, address, owner_login)
        VALUES (v_name, v_inn, v_industry, ui_text(p_data, 'phone'), v_email, ui_text(p_data, 'website'),
                ui_text(p_data, 'address'), v_owner)
        RETURNING id INTO v_id;
        RETURN v_id;
    END IF;

    SELECT * INTO v_current FROM crm_companies WHERE id = v_id FOR UPDATE;
    PERFORM ui_require(FOUND, 'Company not found — it may have been deleted');
    PERFORM ui_require(crm_can_see(v_current.owner_login),
                       'Only the company owner or the head of sales can edit the company');
    UPDATE crm_companies
    SET name = v_name, inn = v_inn, industry_id = v_industry, phone = ui_text(p_data, 'phone'), email = v_email,
        website = ui_text(p_data, 'website'), address = ui_text(p_data, 'address'), owner_login = v_owner
    WHERE id = v_id;

    IF v_owner <> v_current.owner_login AND v_owner <> ui_user() THEN
        PERFORM ui_push_to_user(v_owner, ui_message(format(ui_t('Company “%s” has been assigned to you'), v_name)));
    END IF;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Новая компания сохраняется перед добавлением контакта, сделки или задачи: вкладкам нужен её id
CREATE FUNCTION crm_company_saved(p_is_new BOOLEAN, p_id BIGINT)
RETURNS JSONB AS $$
    SELECT CASE WHEN p_is_new THEN
        jsonb_build_array(
            ui_set_values(jsonb_build_object('id', p_id::TEXT), p_form => 'crm_company'),
            ui_refresh_grid('crm_companies_grid'))
    ELSE
        jsonb_build_array(ui_refresh_grid('crm_companies_grid', p_keep_page => TRUE))
    END;
$$ LANGUAGE sql;

CREATE FUNCTION crm_company_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_company_upsert(p_data);
BEGIN
    RETURN ui_ok(
        ui_close_form(),
        ui_refresh_grid('crm_companies_grid', p_keep_page => NOT ui_is_new(p_data)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_company_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_company crm_companies%ROWTYPE;
BEGIN
    SELECT * INTO v_company FROM crm_companies WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Company not found — it may have been deleted');
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can delete a company');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_deals WHERE company_id = v_company.id),
                       format('Company “%s” has deals and cannot be deleted', v_company.name));

    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(
            format('Delete company “%s” with its contacts and tasks?', v_company.name),
            'crm_company_delete', jsonb_build_object('id', v_company.id, 'confirmed', TRUE),
            p_confirm_label => 'Delete'));
    END IF;

    DELETE FROM crm_companies WHERE id = v_company.id;
    RETURN ui_ok(ui_refresh_grid('crm_companies_grid', p_keep_page => TRUE),
                 ui_message(format('Company “%s” deleted', v_company.name)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_company_contacts_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_company_contacts_page', p_data, 'crm_contacts_v', 'company_id', 'full_name', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION crm_company_deals_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_company_deals_page', p_data, 'crm_deals_v', 'company_id', 'stage', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION crm_company_activities_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_company_activities_page', p_data, 'crm_activities_v', 'company_id', 'due', 'asc');
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Контакты
-- ---------------------------------------------------------------------
-- company_id — фильтр, когда список открыт для выбора контакта компании
CREATE FUNCTION crm_contacts_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_contacts_page', p_data, 'crm_contacts_v', NULL, 'full_name', 'asc',
                        p_search_column => 'search_text', p_search => p_data->>'search',
                        p_filters => jsonb_build_object('company_id', p_data->>'company_id'));
$$ LANGUAGE sql;

-- Кнопка «...» у поля «Контакт» сделки: контакты выбранной компании
CREATE FUNCTION crm_contact_select_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_company crm_companies%ROWTYPE;
BEGIN
    SELECT * INTO v_company FROM crm_companies WHERE id = ui_parse_id(p_data->>'company_id');
    PERFORM ui_require(FOUND, 'Choose a company first');
    RETURN ui_ok(ui_open_form('crm_contacts',
        p_title  => format('Contacts: %s', v_company.name),
        p_data   => jsonb_build_object('company_id', v_company.id::TEXT),
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'full_name')));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_contact_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_contact', p_title => 'New contact'));
END;
$$ LANGUAGE plpgsql;

-- «Добавить контакт» в карточке компании: новая компания сначала сохраняется
CREATE FUNCTION crm_company_contact_new_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_company_upsert(p_data);
BEGIN
    RETURN ui_ok(
        crm_company_saved(ui_is_new(p_data), v_id),
        ui_open_form('crm_contact',
            p_title => 'New contact',
            p_data  => jsonb_build_object('company_id', v_id::TEXT,
                                          'company_id__display', (SELECT name FROM crm_companies WHERE id = v_id))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_contact_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_contact crm_contacts_v%ROWTYPE;
BEGIN
    SELECT * INTO v_contact FROM crm_contacts_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Contact not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('crm_contact',
        p_title => v_contact.full_name,
        p_data  => jsonb_build_object(
            'id', v_contact.id::TEXT,
            'company_id', v_contact.company_id::TEXT,
            'company_id__display', v_contact.company,
            'full_name', v_contact.full_name,
            'position', COALESCE(v_contact.position, ''),
            'phone', COALESCE(v_contact.phone, ''),
            'email', COALESCE(v_contact.email, ''))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_contact_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_company BIGINT  := ui_parse_id(p_data->>'company_id');
    v_name    VARCHAR := ui_text(p_data, 'full_name');
    v_email   VARCHAR := ui_text(p_data, 'email');
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_companies WHERE id = v_company), 'Choose a company');
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the contact name');
    PERFORM ui_require(v_email IS NULL OR v_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$', 'Invalid email');

    IF ui_is_new(p_data) THEN
        INSERT INTO crm_contacts (company_id, full_name, position, phone, email)
        VALUES (v_company, v_name, ui_text(p_data, 'position'), ui_text(p_data, 'phone'), v_email);
    ELSE
        UPDATE crm_contacts
        SET company_id = v_company, full_name = v_name, position = ui_text(p_data, 'position'),
            phone = ui_text(p_data, 'phone'), email = v_email
        WHERE id = ui_parse_id(p_data->>'id');
        PERFORM ui_require(FOUND, 'Contact not found — it may have been deleted');
    END IF;

    RETURN ui_ok(
        ui_close_form(),
        ui_refresh_grid('crm_contacts_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_company_contacts_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_companies_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_contact_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_contact crm_contacts_v%ROWTYPE;
BEGIN
    SELECT * INTO v_contact FROM crm_contacts_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Contact not found — it may have been deleted');

    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Delete contact “%s” (%s)?', v_contact.full_name, v_contact.company),
                                'crm_contact_delete', jsonb_build_object('id', v_contact.id, 'confirmed', TRUE),
                                p_confirm_label => 'Delete'));
    END IF;

    DELETE FROM crm_contacts WHERE id = v_contact.id;
    RETURN ui_ok(ui_refresh_grid('crm_contacts_grid', p_keep_page => TRUE),
                 ui_refresh_grid('crm_company_contacts_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Товары и услуги
-- ---------------------------------------------------------------------
-- Дерево групп: корень «Все товары и услуги» (id all), под ним — группы. Выбранный узел — мастер таблицы товаров
CREATE FUNCTION crm_product_groups_tree(p_data JSON)
RETURNS JSON AS $$
    SELECT CASE COALESCE(p_data->>'parent_id', '')
        WHEN '' THEN json_build_object('status', 'success', 'nodes', json_build_array(json_build_object(
                         'id', 'all', 'label', ui_t('All products and services'),
                         'has_children', EXISTS (SELECT 1 FROM crm_product_groups))))
        WHEN 'all' THEN ui_tree_level('{}', 'crm_product_groups_t', 'title')
        ELSE ui_tree_level(p_data, 'crm_product_groups_t', 'title') END;
$$ LANGUAGE sql STABLE;

-- Группа для списка выбора: путь от корня
CREATE FUNCTION crm_product_groups_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('crm_product_groups_v', 'path');
$$ LANGUAGE sql STABLE;

-- Выбранная группа в дереве (master_id): числовой id; корень «Все» и пусто — без группы
CREATE FUNCTION crm_selected_group(p_value TEXT)
RETURNS BIGINT AS $$
    SELECT CASE WHEN p_value ~ '^[0-9]{1,18}$' THEN p_value::BIGINT END;
$$ LANGUAGE sql IMMUTABLE;

-- Товары выбранной группы и всех её подгрупп; без группы — все
CREATE FUNCTION crm_products_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_products_page', p_data, 'crm_products_v', NULL, 'name', 'asc',
                        p_search_column => 'search_text', p_search => p_data->>'search',
                        p_filters => jsonb_build_object('group_id',
                            (SELECT jsonb_agg(g.id) FROM crm_product_groups_v g
                             WHERE crm_selected_group(p_data->>'master_id') = ANY (g.ids))));
$$ LANGUAGE sql;

CREATE FUNCTION crm_product_group_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    RETURN ui_ok(ui_open_form('crm_product_group', p_title => 'New group',
        p_data => jsonb_build_object('parent_id', COALESCE(crm_selected_group(p_data->>'group_id')::TEXT, ''))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_group_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_group crm_product_groups%ROWTYPE;
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    SELECT * INTO v_group FROM crm_product_groups WHERE id = crm_selected_group(p_data->>'group_id');
    PERFORM ui_require(FOUND, 'Select a group in the tree');
    RETURN ui_ok(ui_open_form('crm_product_group', p_title => v_group.name,
        p_data => jsonb_build_object('id', v_group.id::TEXT, 'name', v_group.name,
                                     'parent_id', COALESCE(v_group.parent_id::TEXT, ''))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_group_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id     BIGINT  := ui_parse_id(p_data->>'id');
    v_name   VARCHAR := ui_text(p_data, 'name');
    v_parent BIGINT  := ui_parse_id(p_data->>'parent_id');
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the name');
    -- Группу нельзя перенести в саму себя или в свою подгруппу
    PERFORM ui_require(v_id IS NULL OR v_parent IS NULL
                       OR NOT EXISTS (SELECT 1 FROM crm_product_groups_v WHERE id = v_parent AND v_id = ANY (ids)),
                       'A group cannot be moved into itself or its subgroup');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_product_groups
                                   WHERE parent_id IS NOT DISTINCT FROM v_parent AND lower(name) = lower(v_name)
                                     AND id IS DISTINCT FROM v_id),
                       'This group already has a subgroup with this name');
    IF ui_is_new(p_data) THEN
        INSERT INTO crm_product_groups (parent_id, name) VALUES (v_parent, v_name);
    ELSE
        UPDATE crm_product_groups SET parent_id = v_parent, name = v_name WHERE id = v_id;
        PERFORM ui_require(FOUND, 'Group not found — it may have been deleted');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('group_id'), ui_refresh_grid('crm_products_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_group_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_group crm_product_groups%ROWTYPE;
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    SELECT * INTO v_group FROM crm_product_groups WHERE id = crm_selected_group(p_data->>'group_id');
    PERFORM ui_require(FOUND, 'Select a group in the tree');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_product_groups WHERE parent_id = v_group.id)
                       AND NOT EXISTS (SELECT 1 FROM crm_products WHERE group_id = v_group.id),
                       format('Group “%s” is not empty: move or delete its subgroups and products first', v_group.name));
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Delete group “%s”?', v_group.name), 'crm_product_group_delete',
                                jsonb_build_object('group_id', v_group.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM crm_product_groups WHERE id = v_group.id;
    -- Дерево перечитывается: удалённый выбранный узел снимается, таблица товаров — тоже
    RETURN ui_ok(ui_refresh_grid('group_id'));
END;
$$ LANGUAGE plpgsql;

-- Кнопка «...» у поля «Товар»: при выборе подставляется и цена
CREATE FUNCTION crm_product_select_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_products',
        p_title  => 'Select a product or service',
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name',
                                       'fill', jsonb_build_object('price', 'price_input'))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    -- Новый товар — в группу, выбранную в дереве
    RETURN ui_ok(ui_open_form('crm_product', p_title => 'New product or service',
                              p_data => jsonb_build_object('unit', 'pcs',
                                  'group_id', COALESCE(crm_selected_group(p_data->>'group_id')::TEXT, ''))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_product crm_products%ROWTYPE;
BEGIN
    SELECT * INTO v_product FROM crm_products WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Product not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('crm_product',
        p_title => v_product.name,
        p_data  => jsonb_build_object('id', v_product.id::TEXT, 'group_id', v_product.group_id::TEXT, 'name', v_product.name,
                                      'sku', COALESCE(v_product.sku, ''), 'unit', v_product.unit,
                                      'price', ui_money_input(v_product.price))));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name  VARCHAR := ui_text(p_data, 'name');
    v_sku   VARCHAR := ui_text(p_data, 'sku');
    v_price NUMERIC := ui_parse_money(p_data->>'price');
    v_group BIGINT  := ui_parse_id(p_data->>'group_id');
BEGIN
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_product_groups WHERE id = v_group), 'Choose a group');
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the name');
    PERFORM ui_require(v_price IS NOT NULL AND v_price >= 0, 'Price must be a number, e.g. 1500 or 99.90');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_products WHERE (lower(name) = lower(v_name) OR sku = v_sku)
                                                              AND id IS DISTINCT FROM ui_parse_id(p_data->>'id')),
                       'A product with this name or SKU already exists');

    IF ui_is_new(p_data) THEN
        INSERT INTO crm_products (group_id, name, sku, unit, price)
        VALUES (v_group, v_name, v_sku, COALESCE(ui_text(p_data, 'unit'), 'pcs'), v_price);
    ELSE
        UPDATE crm_products SET group_id = v_group, name = v_name, sku = v_sku, unit = COALESCE(ui_text(p_data, 'unit'), 'pcs'),
                                price = v_price
        WHERE id = ui_parse_id(p_data->>'id');
        PERFORM ui_require(FOUND, 'Product not found — it may have been deleted');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('crm_products_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_product_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_product crm_products%ROWTYPE;
BEGIN
    SELECT * INTO v_product FROM crm_products WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Product not found — it may have been deleted');
    PERFORM ui_require(crm_is_head(), 'Only the head of sales can change products');
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM crm_deal_lines WHERE product_id = v_product.id),
                       format('“%s” is used in deals and cannot be deleted', v_product.name));
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Delete “%s”?', v_product.name), 'crm_product_delete',
                                jsonb_build_object('id', v_product.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM crm_products WHERE id = v_product.id;
    RETURN ui_ok(ui_refresh_grid('crm_products_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Сделки
-- ---------------------------------------------------------------------
CREATE FUNCTION crm_deals_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_deals_page', p_data, 'crm_deals_v', NULL, 'close_date', 'asc',
                        p_search_column => 'search_text', p_search => p_data->>'search',
                        p_filters => jsonb_build_object('stage_id', p_data->>'stage_filter',
                                                        'owner_login', p_data->>'owner_filter'));
$$ LANGUAGE sql;

CREATE FUNCTION crm_my_deals_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_my_deals_page', p_data, 'crm_deals_v', NULL, 'close_date', 'asc',
                        p_filters => jsonb_build_object('owner_login', ui_user(), 'is_closed', FALSE));
$$ LANGUAGE sql;

-- Значения карточки сделки для формы
CREATE FUNCTION crm_deal_values(p_id BIGINT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'id', d.id::TEXT,
        'title', d.title,
        'company_id', d.company_id::TEXT,
        'company_id__display', d.company,
        'contact_id', COALESCE(d.contact_id::TEXT, ''),
        'contact_id__display', COALESCE(d.contact, ''),
        'stage_id', d.stage_id::TEXT,
        'owner_login', d.owner_login,
        'expected_close', COALESCE(to_char(d.expected_close, 'YYYY-MM-DD'), ''),
        'amount', ui_format_money(d.amount)
                  || CASE WHEN d.is_closed THEN '' ELSE format(' (%s%%)', d.probability) END)
    FROM crm_deals_v d
    WHERE d.id = p_id;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_deal_title(p_id BIGINT)
RETURNS TEXT AS $$
    SELECT format(ui_t('Deal #%s: %s'), id, title) FROM crm_deals WHERE id = p_id;
$$ LANGUAGE sql STABLE;

-- После изменения сделки: значения открытой карточки и все таблицы со сделками
CREATE FUNCTION crm_deal_changed(p_id BIGINT)
RETURNS JSONB AS $$
    SELECT jsonb_build_array(
        ui_set_values(crm_deal_values(p_id), p_form => 'crm_deal'),
        ui_refresh_grid('crm_deals_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_my_deals_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_company_deals_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_deal_events_grid', p_keep_page => TRUE));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_deal_defaults(p_company_id BIGINT DEFAULT NULL)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'stage_id', (SELECT id FROM crm_stages WHERE NOT is_closed ORDER BY sort_order LIMIT 1)::TEXT,
        'owner_login', ui_user(),
        'expected_close', to_char(current_date + 30, 'YYYY-MM-DD'),
        'amount', ui_format_money(0))
        || CASE WHEN p_company_id IS NULL THEN '{}'::JSONB ELSE jsonb_build_object(
               'company_id', p_company_id::TEXT,
               'company_id__display', (SELECT name FROM crm_companies WHERE id = p_company_id)) END;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_deal_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_deal', p_title => 'New deal', p_data => crm_deal_defaults()));
END;
$$ LANGUAGE plpgsql;

-- «Новая сделка» в карточке компании: новая компания сначала сохраняется
CREATE FUNCTION crm_company_deal_new_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_company_upsert(p_data);
BEGIN
    RETURN ui_ok(crm_company_saved(ui_is_new(p_data), v_id),
                 ui_open_form('crm_deal', p_title => 'New deal', p_data => crm_deal_defaults(v_id)));
END;
$$ LANGUAGE plpgsql;

-- Сделка целиком: шапка, товары, задачи и журнал
CREATE FUNCTION crm_deal_state(p_id BIGINT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'deal', to_jsonb(d) - 'created_at',
        'lines', COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.id)
                           FROM crm_deal_lines l WHERE l.deal_id = d.id), '[]'::JSONB),
        'activities', COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.id)
                                FROM crm_activities a WHERE a.deal_id = d.id), '[]'::JSONB),
        'events', COALESCE((SELECT jsonb_agg(to_jsonb(e) ORDER BY e.id)
                            FROM crm_deal_events e WHERE e.deal_id = d.id), '[]'::JSONB))
    FROM crm_deals d
    WHERE d.id = p_id;
$$ LANGUAGE sql STABLE;

-- Вернуть сделку к снимку
CREATE FUNCTION crm_deal_restore(p_id BIGINT, p_state JSONB)
RETURNS VOID AS $$
BEGIN
    -- Шапка; контакт мог быть удалён — тогда остаётся пустым
    UPDATE crm_deals d
    SET title = s.title, company_id = s.company_id,
        contact_id = CASE WHEN EXISTS (SELECT 1 FROM crm_contacts c WHERE c.id = s.contact_id) THEN s.contact_id END,
        stage_id = s.stage_id, owner_login = s.owner_login, expected_close = s.expected_close
    FROM jsonb_populate_record(NULL::crm_deals, p_state->'deal') s
    WHERE d.id = p_id;
    -- Отдельно от стадии: триггер crm_deals_before ставит их при смене стадии
    UPDATE crm_deals d
    SET closed_on = s.closed_on, lost_reason = s.lost_reason
    FROM jsonb_populate_record(NULL::crm_deals, p_state->'deal') s
    WHERE d.id = p_id;

    DELETE FROM crm_deal_lines WHERE deal_id = p_id;
    INSERT INTO crm_deal_lines
    SELECT * FROM jsonb_populate_recordset(NULL::crm_deal_lines, p_state->'lines');

    DELETE FROM crm_activities
    WHERE deal_id = p_id
       OR id IN (SELECT id FROM jsonb_populate_recordset(NULL::crm_activities, p_state->'activities'));
    INSERT INTO crm_activities
    SELECT * FROM jsonb_populate_recordset(NULL::crm_activities, p_state->'activities');

    -- Журнал — последним: восстановление шапки само пишет в него смену стадии и ответственного
    DELETE FROM crm_deal_events WHERE deal_id = p_id;
    INSERT INTO crm_deal_events
    SELECT * FROM jsonb_populate_recordset(NULL::crm_deal_events, p_state->'events');
END;
$$ LANGUAGE plpgsql;

-- Открытие сделки запоминает её сохранённую версию. Снимок перезаписывается: оставшийся от окна,
-- закрытого без «Отмены» (например, вместе с вкладкой браузера), иначе вернул бы сделку в прошлое
CREATE FUNCTION crm_deal_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_deals_v WHERE id = v_id),
                       'Deal not found or not available — another manager owns it');
    INSERT INTO crm_deal_snapshots (deal_id, state)
    VALUES (v_id, crm_deal_state(v_id))
    ON CONFLICT (deal_id) DO UPDATE SET state = EXCLUDED.state, created_at = now();
    RETURN ui_ok(ui_open_form('crm_deal', p_title => crm_deal_title(v_id), p_data => crm_deal_values(v_id)));
END;
$$ LANGUAGE plpgsql;

-- Шапка сделки; возвращает id. Закрытые стадии — только кнопками «Выиграна» / «Проиграна» или с причиной.
-- Новая сделка помечается снимком без состояния: «Отмена» её удалит
CREATE FUNCTION crm_deal_upsert(p_data JSON)
RETURNS BIGINT AS $$
DECLARE
    v_id      BIGINT  := ui_parse_id(p_data->>'id');
    v_title   VARCHAR := ui_text(p_data, 'title');
    v_company BIGINT  := ui_parse_id(p_data->>'company_id');
    v_contact BIGINT  := ui_parse_id(p_data->>'contact_id');
    v_stage   crm_stages%ROWTYPE;
    v_owner   VARCHAR := COALESCE(ui_text(p_data, 'owner_login'), ui_user());
    v_close   DATE    := ui_parse_date(p_data->>'expected_close');
    v_current crm_deals%ROWTYPE;
BEGIN
    SELECT * INTO v_stage FROM crm_stages WHERE id = ui_parse_id(p_data->>'stage_id');
    PERFORM ui_require(v_title IS NOT NULL, 'Enter the deal title');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_companies WHERE id = v_company), 'Choose a company');
    PERFORM ui_require(v_contact IS NULL OR EXISTS (SELECT 1 FROM crm_contacts WHERE id = v_contact AND company_id = v_company),
                       'The contact is not from the selected company — choose it again');
    PERFORM ui_require(v_stage.id IS NOT NULL, 'Choose a stage');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_owners_v WHERE login = v_owner), 'Choose an owner');
    PERFORM ui_require(NULLIF(trim(p_data->>'expected_close'), '') IS NULL OR v_close IS NOT NULL,
                       'Invalid expected close date');

    IF ui_is_new(p_data) THEN
        PERFORM ui_require(NOT v_stage.is_closed, 'A new deal cannot be closed right away — save it first');
        INSERT INTO crm_deals (title, company_id, contact_id, stage_id, owner_login, expected_close)
        VALUES (v_title, v_company, v_contact, v_stage.id, v_owner, v_close)
        RETURNING id INTO v_id;
        INSERT INTO crm_deal_snapshots (deal_id, state) VALUES (v_id, NULL);
    ELSE
        SELECT * INTO v_current FROM crm_deals WHERE id = v_id FOR UPDATE;
        PERFORM ui_require(FOUND AND crm_can_see(v_current.owner_login),
                           'Deal not found or not available — another manager owns it');
        IF v_stage.id <> v_current.stage_id AND v_stage.is_closed THEN
            PERFORM ui_require(v_stage.is_won, 'To close the deal as lost, click “Lost” and give a reason');
            PERFORM ui_require((SELECT amount FROM crm_deals_v WHERE id = v_id) > 0,
                               'Add products or services to the deal');
        END IF;
        UPDATE crm_deals
        SET title = v_title, company_id = v_company, contact_id = v_contact, stage_id = v_stage.id,
            owner_login = v_owner, expected_close = v_close
        WHERE id = v_id;
    END IF;

    IF v_owner <> ui_user() AND v_owner IS DISTINCT FROM v_current.owner_login THEN
        PERFORM ui_push_to_user(v_owner, ui_message(format(ui_t('Deal “%s” has been assigned to you'), v_title)));
    END IF;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

-- Новая сделка сохраняется перед добавлением товара или задачи: вкладкам нужен её id
CREATE FUNCTION crm_deal_saved(p_is_new BOOLEAN, p_id BIGINT)
RETURNS JSONB AS $$
    SELECT CASE WHEN p_is_new
        THEN jsonb_build_array(ui_set_title(crm_deal_title(p_id))) || crm_deal_changed(p_id)
        ELSE crm_deal_changed(p_id) END;
$$ LANGUAGE sql STABLE;

-- «Сохранить»: снимок больше не нужен
CREATE FUNCTION crm_deal_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_deal_upsert(p_data);
BEGIN
    DELETE FROM crm_deal_snapshots WHERE deal_id = v_id;
    RETURN ui_ok(ui_close_form(), crm_deal_changed(v_id));
END;
$$ LANGUAGE plpgsql;

-- «Отмена» (и крестик, и Escape): если что-то изменено — сначала переспрашивает.
-- Сделка, созданная в этой карточке, удаляется; сохранённая возвращается к снимку.
-- Шапка берётся из формы: её изменения могут быть ещё не записаны в базу
CREATE FUNCTION crm_deal_cancel(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id       BIGINT := ui_parse_id(p_data->>'id');
    v_deal     crm_deals%ROWTYPE;
    v_snapshot crm_deal_snapshots%ROWTYPE;
    v_changed  BOOLEAN;
    v_close    JSONB := jsonb_build_array(
        ui_close_form(),
        ui_refresh_grid('crm_deals_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_my_deals_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_company_deals_grid', p_keep_page => TRUE)) || crm_activity_refresh();
BEGIN
    -- Новая сделка ещё не записывалась: спросить, только если введено название
    -- (компания, стадия и прочее заполняются по умолчанию)
    IF v_id IS NULL THEN
        IF NOT ui_confirmed(p_data) AND ui_text(p_data, 'title') IS NOT NULL THEN
            RETURN ui_ok(ui_confirm('Close without saving? The new deal will not be created.',
                                    'crm_deal_cancel', jsonb_build_object('confirmed', TRUE),
                                    p_confirm_label => 'Don''t save'));
        END IF;
        RETURN ui_ok(ui_close_form());
    END IF;

    SELECT * INTO v_deal FROM crm_deals WHERE id = v_id;
    IF NOT FOUND OR NOT crm_can_see(v_deal.owner_login) THEN
        -- Сделка уже удалена или передана — отменять нечего
        RETURN ui_ok(v_close);
    END IF;
    SELECT * INTO v_snapshot FROM crm_deal_snapshots WHERE deal_id = v_id;

    IF NOT ui_confirmed(p_data) THEN
        v_changed := CASE
            WHEN v_snapshot.deal_id IS NOT NULL AND v_snapshot.state IS NULL THEN TRUE
            ELSE (v_snapshot.state IS NOT NULL AND v_snapshot.state IS DISTINCT FROM crm_deal_state(v_id))
                 OR jsonb_build_object(
                        'title', v_deal.title, 'company_id', v_deal.company_id, 'contact_id', v_deal.contact_id,
                        'stage_id', v_deal.stage_id, 'owner_login', v_deal.owner_login,
                        'expected_close', v_deal.expected_close)
                    IS DISTINCT FROM jsonb_build_object(
                        'title', ui_text(p_data, 'title'), 'company_id', ui_parse_id(p_data->>'company_id'),
                        'contact_id', ui_parse_id(p_data->>'contact_id'), 'stage_id', ui_parse_id(p_data->>'stage_id'),
                        'owner_login', COALESCE(ui_text(p_data, 'owner_login'), ui_user()),
                        'expected_close', ui_parse_date(p_data->>'expected_close'))
        END;

        IF v_changed THEN
            RETURN ui_ok(ui_confirm(
                CASE WHEN v_snapshot.deal_id IS NOT NULL AND v_snapshot.state IS NULL
                    THEN format('Close without saving? Deal "%s" with its products and tasks will be deleted.', v_deal.title)
                    ELSE format('Close without saving? Changes to deal "%s" will be discarded.', v_deal.title)
                END,
                'crm_deal_cancel',
                jsonb_build_object('id', v_id::TEXT, 'confirmed', TRUE),
                p_confirm_label => 'Don''t save'));
        END IF;
        -- Ничего не изменено: возвращать нечего
        DELETE FROM crm_deal_snapshots WHERE deal_id = v_id;
        RETURN ui_ok(ui_close_form());
    END IF;

    IF v_snapshot.deal_id IS NOT NULL AND v_snapshot.state IS NULL THEN
        DELETE FROM crm_deals WHERE id = v_id;  -- товары, задачи, журнал и снимок — каскадно
    ELSIF v_snapshot.state IS NOT NULL THEN
        PERFORM crm_deal_restore(v_id, v_snapshot.state);
        DELETE FROM crm_deal_snapshots WHERE deal_id = v_id;
    END IF;

    RETURN ui_ok(v_close);
END;
$$ LANGUAGE plpgsql;

-- «Следующая стадия»: изменения в карточке сохраняются, сделка переходит дальше по воронке
CREATE FUNCTION crm_deal_advance(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id   BIGINT := crm_deal_upsert(p_data);
    v_from crm_stages%ROWTYPE;
    v_to   crm_stages%ROWTYPE;
BEGIN
    SELECT s.* INTO v_from FROM crm_stages s JOIN crm_deals d ON d.stage_id = s.id WHERE d.id = v_id;
    PERFORM ui_require(NOT v_from.is_closed, 'The deal is closed');
    SELECT * INTO v_to FROM crm_stages WHERE NOT is_closed AND sort_order > v_from.sort_order ORDER BY sort_order LIMIT 1;
    PERFORM ui_require(FOUND, 'This is the last stage: was the deal won or lost?');

    UPDATE crm_deals SET stage_id = v_to.id WHERE id = v_id;
    PERFORM ui_print(format(ui_t('%s: %s → %s'), crm_deal_title(v_id), ui_t(v_from.name), ui_t(v_to.name)));
    RETURN ui_ok(crm_deal_saved(ui_is_new(p_data), v_id));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_win(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id   BIGINT := crm_deal_upsert(p_data);
    v_deal crm_deals_v%ROWTYPE;
BEGIN
    SELECT * INTO v_deal FROM crm_deals_v WHERE id = v_id;
    PERFORM ui_require(NOT v_deal.is_closed, 'The deal is already closed');
    PERFORM ui_require(v_deal.amount > 0, 'Add products or services to the deal');

    UPDATE crm_deals SET stage_id = (SELECT id FROM crm_stages WHERE is_won LIMIT 1) WHERE id = v_id;
    PERFORM ui_print(format(ui_t('Deal “%s” won: %s'), v_deal.title, ui_format_money(v_deal.amount)));
    PERFORM ui_push_to_role('crm_head', ui_message(format(ui_t('%s won the deal “%s” for %s'),
                                                          crm_user_name(ui_user()), v_deal.title,
                                                          ui_format_money(v_deal.amount))));
    RETURN ui_ok(crm_deal_saved(ui_is_new(p_data), v_id),
                 ui_message(format('Deal “%s” won', v_deal.title)));
END;
$$ LANGUAGE plpgsql;

-- «Проиграна»: окно с причиной
CREATE FUNCTION crm_deal_lose_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_deal_upsert(p_data);
BEGIN
    PERFORM ui_require(NOT (SELECT is_closed FROM crm_deals_v WHERE id = v_id), 'The deal is already closed');
    RETURN ui_ok(crm_deal_saved(ui_is_new(p_data), v_id),
                 ui_open_form('crm_deal_lost', p_data => jsonb_build_object('deal_id', v_id::TEXT)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_lose_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id     BIGINT := ui_parse_id(p_data->>'deal_id');
    v_reason TEXT   := ui_text(p_data, 'lost_reason');
    v_deal   crm_deals_v%ROWTYPE;
BEGIN
    SELECT * INTO v_deal FROM crm_deals_v WHERE id = v_id;
    PERFORM ui_require(FOUND, 'Deal not found or not available — another manager owns it');
    PERFORM ui_require(NOT v_deal.is_closed, 'The deal is already closed');
    PERFORM ui_require(v_reason IS NOT NULL, 'Enter a reason');

    UPDATE crm_deals
    SET stage_id = (SELECT id FROM crm_stages WHERE is_closed AND NOT is_won LIMIT 1), lost_reason = v_reason
    WHERE id = v_id;
    INSERT INTO crm_deal_events (deal_id, login, text) VALUES (v_id, ui_user(), format('Loss reason: %s', v_reason));
    PERFORM ui_print(format(ui_t('Deal “%s” lost: %s'), v_deal.title, v_reason), 'warning');
    RETURN ui_ok(ui_close_form(), crm_deal_changed(v_id));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_deal crm_deals_v%ROWTYPE;
BEGIN
    SELECT * INTO v_deal FROM crm_deals_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Deal not found or not available — another manager owns it');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(
            format('Delete deal “%s” (%s, %s) with its items, tasks and history?',
                   v_deal.title, v_deal.company, ui_format_money(v_deal.amount)),
            'crm_deal_delete', jsonb_build_object('id', v_deal.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM crm_deals WHERE id = v_deal.id;
    RETURN ui_ok(ui_refresh_grid('crm_deals_grid', p_keep_page => TRUE),
                 ui_refresh_grid('crm_my_deals_grid', p_keep_page => TRUE),
                 ui_refresh_grid('crm_company_deals_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

-- «Коммерческое предложение»: отчёт PDF по сохранённой сделке
CREATE FUNCTION crm_deal_print(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := ui_parse_id(p_data->>'id');
BEGIN
    -- Из карточки — сначала сохранить изменения; из строки списка — только id
    IF p_data->>'title' IS NOT NULL THEN
        v_id := crm_deal_upsert(p_data);
    END IF;
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_deals_v WHERE id = v_id AND amount > 0),
                       'Add products or services to the deal');
    RETURN ui_ok(
        CASE WHEN p_data->>'title' IS NOT NULL THEN crm_deal_saved(ui_is_new(p_data), v_id) END,
        ui_report('crm_offer', jsonb_build_object('deal_id', v_id), format('Offer for deal #%s', v_id)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_events_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_deal_events_page', p_data, 'crm_deal_events_v', 'deal_id', 'at_text', 'desc');
$$ LANGUAGE sql;

-- ---------------------------------------------------------------------
-- Товары в сделке
-- ---------------------------------------------------------------------
CREATE FUNCTION crm_deal_lines_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_deal_lines_page', p_data, 'crm_deal_lines_v', 'deal_id', 'id', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION crm_deal_line_new_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_deal_upsert(p_data);
BEGIN
    PERFORM ui_require(NOT (SELECT is_closed FROM crm_deals_v WHERE id = v_id), 'The deal is closed — its items cannot change');
    RETURN ui_ok(crm_deal_saved(ui_is_new(p_data), v_id),
                 ui_open_form('crm_deal_line', p_title => 'Product or service in a deal',
                              p_data => jsonb_build_object('deal_id', v_id::TEXT, 'quantity', '1', 'discount', '0')));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_line_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_line crm_deal_lines_v%ROWTYPE;
BEGIN
    SELECT * INTO v_line FROM crm_deal_lines_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Item not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('crm_deal_line',
        p_title => v_line.product,
        p_data  => jsonb_build_object(
            'id', v_line.id::TEXT, 'deal_id', v_line.deal_id::TEXT,
            'product_id', v_line.product_id::TEXT, 'product_id__display', v_line.product,
            'quantity', trim_scale(v_line.quantity)::TEXT, 'price', ui_money_input(v_line.price),
            'discount', trim_scale(v_line.discount)::TEXT)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_line_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_deal     BIGINT  := ui_parse_id(p_data->>'deal_id');
    v_product  BIGINT  := ui_parse_id(p_data->>'product_id');
    v_quantity NUMERIC := ui_parse_money(p_data->>'quantity');
    v_price    NUMERIC := ui_parse_money(p_data->>'price');
    v_discount NUMERIC := COALESCE(ui_parse_money(NULLIF(trim(p_data->>'discount'), '')), 0);
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_deals_v WHERE id = v_deal AND NOT is_closed),
                       'The deal is closed or not available — its items cannot change');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_products WHERE id = v_product), 'Choose a product or service');
    PERFORM ui_require(v_quantity > 0, 'Quantity must be a number greater than zero');
    PERFORM ui_require(v_price IS NOT NULL AND v_price >= 0, 'Price must be a number, e.g. 1500 or 99.90');
    PERFORM ui_require(v_discount BETWEEN 0 AND 100, 'Discount must be from 0 to 100 %');

    IF ui_is_new(p_data) THEN
        INSERT INTO crm_deal_lines (deal_id, product_id, quantity, price, discount)
        VALUES (v_deal, v_product, v_quantity, v_price, v_discount);
    ELSE
        UPDATE crm_deal_lines SET product_id = v_product, quantity = v_quantity, price = v_price, discount = v_discount
        WHERE id = ui_parse_id(p_data->>'id') AND deal_id = v_deal;
        PERFORM ui_require(FOUND, 'Item not found — it may have been deleted');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('crm_deal_lines_grid', p_keep_page => TRUE), crm_deal_changed(v_deal));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_line_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_line crm_deal_lines_v%ROWTYPE;
BEGIN
    SELECT * INTO v_line FROM crm_deal_lines_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Item not found — it may have been deleted');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_deals_v WHERE id = v_line.deal_id AND NOT is_closed),
                       'The deal is closed or not available — its items cannot change');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Remove “%s” from the deal?', v_line.product), 'crm_deal_line_delete',
                                jsonb_build_object('id', v_line.id, 'confirmed', TRUE), p_confirm_label => 'Remove'));
    END IF;
    DELETE FROM crm_deal_lines WHERE id = v_line.id;
    RETURN ui_ok(ui_refresh_grid('crm_deal_lines_grid', p_keep_page => TRUE), crm_deal_changed(v_line.deal_id));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Задачи, звонки, встречи
-- ---------------------------------------------------------------------
CREATE FUNCTION crm_activity_refresh()
RETURNS JSONB AS $$
    SELECT jsonb_build_array(
        ui_refresh_grid('crm_tasks_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_my_tasks_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_deal_activities_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_company_activities_grid', p_keep_page => TRUE),
        ui_refresh_grid('crm_deal_events_grid', p_keep_page => TRUE));
$$ LANGUAGE sql IMMUTABLE;

-- Пустое значение фильтра — открытые задачи
CREATE FUNCTION crm_tasks_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_tasks_page', p_data, 'crm_activities_v', NULL, 'due', 'asc',
                        p_search_column => 'search_text', p_search => p_data->>'search',
                        p_filters => jsonb_build_object('owner_login', p_data->>'owner_filter')
                                     || CASE COALESCE(p_data->>'task_filter', '')
                                            WHEN 'today'   THEN jsonb_build_object('state_code', 'today')
                                            WHEN 'overdue' THEN jsonb_build_object('state_code', 'overdue')
                                            WHEN 'done'    THEN jsonb_build_object('is_done', TRUE)
                                            WHEN 'all'     THEN '{}'::JSONB
                                            ELSE jsonb_build_object('is_done', FALSE) END);
$$ LANGUAGE sql;

CREATE FUNCTION crm_my_tasks_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_my_tasks_page', p_data, 'crm_activities_v', NULL, 'due', 'asc',
                        p_filters => jsonb_build_object('owner_login', ui_user(), 'is_done', FALSE));
$$ LANGUAGE sql;

CREATE FUNCTION crm_deal_activities_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_deal_activities_page', p_data, 'crm_activities_v', 'deal_id', 'due', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION crm_activity_defaults(p_deal_id BIGINT, p_company_id BIGINT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'kind', 'call',
        'due_on', to_char(current_date + 1, 'YYYY-MM-DD'),
        'owner_login', ui_user(),
        'deal_id', COALESCE(p_deal_id::TEXT, ''),
        'company_id', COALESCE(p_company_id::TEXT, ''),
        'related', COALESCE((SELECT title FROM crm_deals WHERE id = p_deal_id),
                            (SELECT name FROM crm_companies WHERE id = p_company_id), ''));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION crm_activity_new_open(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_open_form('crm_activity', p_title => 'New task', p_data => crm_activity_defaults(NULL, NULL)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deal_activity_new_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_deal_upsert(p_data);
BEGIN
    RETURN ui_ok(crm_deal_saved(ui_is_new(p_data), v_id),
                 ui_open_form('crm_activity', p_title => 'New task', p_data => crm_activity_defaults(v_id, NULL)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_company_activity_new_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_company_upsert(p_data);
BEGIN
    RETURN ui_ok(crm_company_saved(ui_is_new(p_data), v_id),
                 ui_open_form('crm_activity', p_title => 'New task', p_data => crm_activity_defaults(NULL, v_id)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_activity_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_activity crm_activities_v%ROWTYPE;
BEGIN
    SELECT * INTO v_activity FROM crm_activities_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Task not found or not available');
    RETURN ui_ok(ui_open_form('crm_activity',
        p_title => format('%s: %s', v_activity.kind_name, v_activity.subject),
        p_data  => jsonb_build_object(
            'id', v_activity.id::TEXT,
            'kind', v_activity.kind,
            'subject', v_activity.subject,
            'notes', COALESCE(v_activity.notes, ''),
            'due_on', COALESCE(to_char(v_activity.due_on, 'YYYY-MM-DD'), ''),
            'owner_login', v_activity.owner_login,
            'deal_id', COALESCE(v_activity.deal_id::TEXT, ''),
            'company_id', COALESCE(v_activity.company_id::TEXT, ''),
            'related', COALESCE(v_activity.related, ''),
            'state', v_activity.state->>'label')));
END;
$$ LANGUAGE plpgsql;

-- Задача из карточки; возвращает id. Переданная другому — уведомление ему
CREATE FUNCTION crm_activity_upsert(p_data JSON)
RETURNS BIGINT AS $$
DECLARE
    v_id      BIGINT  := ui_parse_id(p_data->>'id');
    v_kind    VARCHAR := ui_text(p_data, 'kind');
    v_subject VARCHAR := ui_text(p_data, 'subject');
    v_due     DATE    := ui_parse_date(p_data->>'due_on');
    v_owner   VARCHAR := COALESCE(ui_text(p_data, 'owner_login'), ui_user());
    v_deal    BIGINT  := ui_parse_id(p_data->>'deal_id');
    v_company BIGINT  := ui_parse_id(p_data->>'company_id');
    v_current crm_activities%ROWTYPE;
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_activity_kinds WHERE code = v_kind), 'Choose a type');
    PERFORM ui_require(v_subject IS NOT NULL, 'Enter a subject');
    PERFORM ui_require(NULLIF(trim(p_data->>'due_on'), '') IS NULL OR v_due IS NOT NULL, 'Invalid due date');
    PERFORM ui_require(EXISTS (SELECT 1 FROM crm_owners_v WHERE login = v_owner), 'Choose an owner');
    PERFORM ui_require(v_deal IS NULL OR EXISTS (SELECT 1 FROM crm_deals_v WHERE id = v_deal),
                       'Deal not found or not available — another manager owns it');

    IF ui_is_new(p_data) THEN
        INSERT INTO crm_activities (kind, subject, notes, due_on, deal_id, company_id, owner_login, created_by)
        VALUES (v_kind, v_subject, ui_text(p_data, 'notes'), v_due, v_deal,
                CASE WHEN v_deal IS NULL THEN v_company END, v_owner, ui_user())
        RETURNING id INTO v_id;
    ELSE
        SELECT * INTO v_current FROM crm_activities WHERE id = v_id FOR UPDATE;
        PERFORM ui_require(FOUND AND crm_can_see(v_current.owner_login), 'Task not found or not available');
        UPDATE crm_activities
        SET kind = v_kind, subject = v_subject, notes = ui_text(p_data, 'notes'), due_on = v_due, owner_login = v_owner
        WHERE id = v_id;
    END IF;

    IF v_owner <> ui_user() AND v_owner IS DISTINCT FROM v_current.owner_login THEN
        PERFORM ui_push_to_user(v_owner,
            ui_message(format(ui_t('%s assigned to you: %s, due %s'), crm_user_name(ui_user()), v_subject,
                              COALESCE(crm_date(v_due), ui_t('no due date')))));
    END IF;
    RETURN v_id;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_activity_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id BIGINT := crm_activity_upsert(p_data);
BEGIN
    RETURN ui_ok(ui_close_form(), crm_activity_refresh());
END;
$$ LANGUAGE plpgsql;

-- «Выполнено»: из карточки (изменения сохраняются, новая задача записывается сразу выполненной —
-- например, состоявшийся звонок) или из строки списка (только id). Выполненная задача по сделке — в журнал
CREATE FUNCTION crm_activity_done(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id       BIGINT := ui_parse_id(p_data->>'id');
    v_activity crm_activities%ROWTYPE;
BEGIN
    IF p_data->>'subject' IS NOT NULL THEN
        v_id := crm_activity_upsert(p_data);
    END IF;
    SELECT * INTO v_activity FROM crm_activities WHERE id = v_id FOR UPDATE;
    PERFORM ui_require(FOUND AND crm_can_see(v_activity.owner_login), 'Task not found or not available');
    PERFORM ui_require(v_activity.done_at IS NULL, 'The task is already done');

    UPDATE crm_activities SET done_at = now() WHERE id = v_id;
    IF v_activity.deal_id IS NOT NULL THEN
        INSERT INTO crm_deal_events (deal_id, login, text)
        VALUES (v_activity.deal_id, ui_user(), format('Done: %s', v_activity.subject));
    END IF;
    PERFORM ui_print(format(ui_t('Done: %s'), v_activity.subject));
    RETURN ui_ok(CASE WHEN p_data->>'subject' IS NOT NULL THEN ui_close_form() END, crm_activity_refresh());
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_activity_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_activity crm_activities_v%ROWTYPE;
BEGIN
    SELECT * INTO v_activity FROM crm_activities_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Task not found or not available');
    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Delete “%s”?', v_activity.subject), 'crm_activity_delete',
                                jsonb_build_object('id', v_activity.id, 'confirmed', TRUE), p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM crm_activities WHERE id = v_activity.id;
    RETURN ui_ok(crm_activity_refresh());
END;
$$ LANGUAGE plpgsql;

-- «Напоминания»: просроченные и сегодняшние задачи пользователя — в панель сообщений
CREATE FUNCTION crm_reminders(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_task  RECORD;
    v_count INT := 0;
BEGIN
    FOR v_task IN
        SELECT * FROM crm_activities_v
        WHERE owner_login = ui_user() AND state_code IN ('overdue', 'today')
        ORDER BY due_on, id
    LOOP
        v_count := v_count + 1;
        PERFORM ui_print(
            format(CASE v_task.state_code WHEN 'overdue' THEN ui_t('Overdue since %s: %s — %s') ELSE ui_t('Today (%s): %s — %s') END,
                   v_task.due, v_task.subject, COALESCE(v_task.related, ui_t('unlinked'))),
            CASE v_task.state_code WHEN 'overdue' THEN 'error' ELSE 'warning' END);
    END LOOP;
    IF v_count = 0 THEN
        PERFORM ui_print('No overdue tasks and nothing due today');
    END IF;
    RETURN ui_ok();
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Воронка продаж
-- ---------------------------------------------------------------------
CREATE FUNCTION crm_pipeline_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_pipeline_page', p_data, 'crm_pipeline_v', NULL, 'stage', 'asc');
$$ LANGUAGE sql;

-- Гистограмма воронки: сумма и сумма с учётом вероятности по стадиям, в порядке воронки
CREATE FUNCTION crm_pipeline_chart(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_chart('crm_pipeline_v', 'stage_name', ARRAY['amount', 'weighted'], ARRAY['Amount', 'Weighted'],
                    p_order_column => 'sort_order', p_format => 'money');
$$ LANGUAGE sql;

CREATE FUNCTION crm_pipeline_owners_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('crm_pipeline_owners_page', p_data, 'crm_pipeline_owners_v', NULL, 'open_amount', 'desc');
$$ LANGUAGE sql;

CREATE FUNCTION crm_pipeline_print(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_report('crm_pipeline', '{}', format('Sales pipeline as of %s', crm_date(current_date))));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Данные отчётов PDF
-- ---------------------------------------------------------------------
-- Коммерческое предложение: {"deal_id"}
CREATE FUNCTION crm_offer_data(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_deal    crm_deals_v%ROWTYPE;
    v_company crm_companies_v%ROWTYPE;
BEGIN
    SELECT * INTO v_deal FROM crm_deals_v WHERE id = ui_parse_id(p_data->>'deal_id');
    PERFORM ui_require(FOUND, 'Deal not found or not available — another manager owns it');
    SELECT * INTO v_company FROM crm_companies_v WHERE id = v_deal.company_id;

    RETURN json_build_object(
        'title', format(ui_t('Commercial offer #%s'), v_deal.id),
        'offer_date', current_date,
        'valid_until', current_date + 14,
        'deal', v_deal.title,
        'company', v_company.name,
        'company_details', concat_ws(' · ', CASE WHEN v_company.inn IS NOT NULL THEN format(ui_t('Tax ID %s'), v_company.inn) END,
                                     v_company.address, v_company.phone),
        'contact', v_deal.contact,
        'manager', v_deal.owner,
        'total', v_deal.amount,
        'discount_total', (SELECT COALESCE(sum(quantity * price) - sum(amount), 0) FROM crm_deal_lines_v WHERE deal_id = v_deal.id),
        'rows', COALESCE((
            SELECT json_agg(json_build_object(
                       'line_no', n, 'product', product, 'sku', sku, 'unit', unit, 'quantity', quantity,
                       'price', price, 'discount', discount, 'amount', amount) ORDER BY n)
            FROM (SELECT row_number() OVER (ORDER BY id) AS n, * FROM crm_deal_lines_v WHERE deal_id = v_deal.id) l), '[]'));
END;
$$ LANGUAGE plpgsql STABLE;

-- Воронка продаж по видимым пользователю сделкам
CREATE FUNCTION crm_pipeline_data(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object(
        'title', ui_t('Sales pipeline'),
        'as_of', current_date,
        'scope', CASE WHEN crm_is_head() THEN ui_t('All managers') ELSE crm_user_name(ui_user()) END,
        'printed_by', crm_user_name(ui_user()),
        'open_count', (SELECT count(*) FROM crm_deals_v WHERE NOT is_closed),
        'open_amount', (SELECT COALESCE(sum(amount), 0) FROM crm_deals_v WHERE NOT is_closed),
        'weighted', (SELECT COALESCE(sum(weighted), 0) FROM crm_deals_v WHERE NOT is_closed),
        'won_month', (SELECT COALESCE(sum(amount), 0) FROM crm_deals_v
                      WHERE is_won AND closed_on >= date_trunc('month', current_date)),
        'rows', (SELECT json_agg(json_build_object('stage', stage_name, 'probability', probability, 'deals', deals,
                                                   'amount', amount, 'weighted', weighted) ORDER BY sort_order)
                 FROM crm_pipeline_v));
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Справочники
-- ---------------------------------------------------------------------
INSERT INTO crm_stages (id, code, name, sort_order, probability, is_closed, is_won) VALUES
    (1, 'new',         'New',        1, 10,  FALSE, FALSE),
    (2, 'qualified',   'Qualification', 2, 25,  FALSE, FALSE),
    (3, 'proposal',    'Proposal',  3, 50,  FALSE, FALSE),
    (4, 'negotiation', 'Negotiation',   4, 75,  FALSE, FALSE),
    (5, 'won',         'Won',     5, 100, TRUE,  TRUE),
    (6, 'lost',        'Lost',    6, 0,   TRUE,  FALSE);

INSERT INTO crm_activity_kinds (code, name, sort_order) VALUES
    ('call',    'Call',  1),
    ('meeting', 'Meeting', 2),
    ('task',    'Task',  3),
    ('email',   'Email message',  4),
    ('note',    'Note', 5);

INSERT INTO crm_industries (id, name) VALUES
    (1, 'Retail'), (2, 'Manufacturing'), (3, 'IT and telecom'),
    (4, 'Logistics'), (5, 'Construction'), (6, 'Finance');

INSERT INTO crm_product_groups (id, parent_id, name) VALUES
    (1, NULL, 'Software'),
    (2, NULL, 'Services'),
    (3, 2,    'Implementation'),
    (4, 2,    'Training and consulting'),
    (5, 2,    'Support'),
    (6, NULL, 'Hardware');

INSERT INTO crm_products (id, group_id, name, sku, unit, price) VALUES
    (1,  1, 'CRM user license (1 year)',     'LIC-USR',  'pcs', 18000),
    (2,  3, 'CRM implementation',            'SRV-IMPL', 'h',   3500),
    (3,  4, 'Staff training',                'SRV-EDU',  'day', 45000),
    (4,  3, 'Accounting system integration', 'SRV-INT',  'pcs', 120000),
    (5,  3, 'Data migration',                'SRV-MIG',  'pcs', 60000),
    (6,  5, 'Technical support (1 year)',    'SUP-YEAR', 'pcs', 96000),
    (7,  1, 'Mobile app for sales reps',     'APP-MOB',  'pcs', 150000),
    (8,  6, 'Application server',            'HW-SRV',   'pcs', 420000),
    (9,  4, 'Sales process audit',           'SRV-AUD',  'pcs', 80000),
    (10, 3, 'Report setup',                  'SRV-REP',  'h',   3000);

-- ---------------------------------------------------------------------
-- Демо-данные (даты — относительно дня установки)
-- ---------------------------------------------------------------------
INSERT INTO crm_companies (id, name, inn, industry_id, phone, email, website, address, owner_login, created_at) VALUES
    (1,  'North Wind LLC',     '7701234567', 1, '+7 495 100-10-10', 'info@sever-veter.ru', 'sever-veter.ru', '12 Tverskaya St, Moscow',      'ivanov',  now() - interval '120 days'),
    (2,  'Uralmash Service JSC',      '6601234568', 2, '+7 343 200-20-20', 'office@uralmash-s.ru', 'uralmash-s.ru', '18 Kosmonavtov Ave, Yekaterinburg', 'petrova', now() - interval '110 days'),
    (3,  'Cloud Solutions LLC',   '7801234569', 3, '+7 812 300-30-30', 'hello@cloudsol.ru',  'cloudsol.ru',    '28 Nevsky Ave, Saint Petersburg', 'ivanov',  now() - interval '100 days'),
    (4,  'TransLogistic LLC',      '5401234570', 4, '+7 383 400-40-40', 'sales@translog.ru',  'translog.ru',    '5 Lenina St, Novosibirsk',     'petrova', now() - interval '95 days'),
    (5,  'StroyGrad LLC',          '1601234571', 5, '+7 843 500-50-50', 'info@stroygrad.ru',  'stroygrad.ru',   '40 Baumana St, Kazan',        'ivanov',  now() - interval '90 days'),
    (6,  'Capital Invest JSC',      '7701234572', 6, '+7 495 600-60-60', 'ir@kapinvest.ru',    'kapinvest.ru',   '10 Presnenskaya Emb, Moscow',   'sidorov', now() - interval '85 days'),
    (7,  'Farm Yard LLC',    '3601234573', 1, '+7 473 700-70-70', 'zakaz@fermdvor.ru',  'fermdvor.ru',    '3 Koltsovskaya St, Voronezh',    'petrova', now() - interval '70 days'),
    (8,  'Technosphere LLC',         '7701234574', 3, '+7 495 800-80-80', 'info@technosfera.ru', 'technosfera.ru', '65 Profsoyuznaya St, Moscow',   'ivanov',  now() - interval '60 days'),
    (9,  'Volga Plast LLC',        '6301234575', 2, '+7 846 900-90-90', 'office@volgaplast.ru', 'volgaplast.ru', '4 Moskovskoye Hwy, Samara',       'petrova', now() - interval '45 days'),
    (10, 'Fast Delivery LLC',   '2301234576', 4, '+7 861 111-11-11', 'hello@fastdel.ru',   'fastdel.ru',     '100 Krasnaya St, Krasnodar',    'ivanov',  now() - interval '30 days'),
    (11, 'Severstal Repair JSC',   '3501234577', 2, '+7 820 222-22-22', 'remont@ss-r.ru',     'ss-r.ru',        '30 Mira St, Cherepovets',        'sidorov', now() - interval '20 days'),
    (12, 'Corner Coffee LLC',    '7701234578', 1, '+7 495 333-33-33', 'coffee@corner.ru',   NULL,             '7 Arbat St, Moscow',           'petrova', now() - interval '10 days');

INSERT INTO crm_contacts (id, company_id, full_name, position, phone, email) VALUES
    (1,  1,  'Olga Smirnova',     'Chief Commercial Officer',      '+7 916 101-01-01', 'smirnova@sever-veter.ru'),
    (2,  1,  'Pavel Kuznetsov',     'Head of IT',            '+7 916 101-01-02', 'kuznetsov@sever-veter.ru'),
    (3,  2,  'Sergey Volkov',      'Chief Engineer',            '+7 912 202-02-01', 'volkov@uralmash-s.ru'),
    (4,  2,  'Elena Morozova',     'Head of Procurement',   '+7 912 202-02-02', 'morozova@uralmash-s.ru'),
    (5,  3,  'Dmitry Lebedev',    'CEO',       '+7 921 303-03-01', 'lebedev@cloudsol.ru'),
    (6,  4,  'Anna Novikova',      'Business Development Director',       '+7 913 404-04-01', 'novikova@translog.ru'),
    (7,  4,  'Igor Fedorov',      'CFO',        '+7 913 404-04-02', 'fedorov@translog.ru'),
    (8,  5,  'Ruslan Galiev',      'Director',                   '+7 917 505-05-01', 'galiev@stroygrad.ru'),
    (9,  6,  'Victoria Belova',    'Director of Operations',      '+7 903 606-06-01', 'belova@kapinvest.ru'),
    (10, 6,  'Artem Sokolov',      'Head of Sales',        '+7 903 606-06-02', 'sokolov@kapinvest.ru'),
    (11, 7,  'Nikolay Popov',      'Owner',                   '+7 910 707-07-01', 'popov@fermdvor.ru'),
    (12, 8,  'Tatiana Orlova',     'Project Manager',      '+7 925 808-08-01', 'orlova@technosfera.ru'),
    (13, 8,  'Maxim Egorov',      'CTO',       '+7 925 808-08-02', 'egorov@technosfera.ru'),
    (14, 9,  'Svetlana Kozlova',   'Chief Commercial Officer',      '+7 927 909-09-01', 'kozlova@volgaplast.ru'),
    (15, 10, 'Andrey Pavlov',      'COO',      '+7 918 111-11-01', 'pavlov@fastdel.ru'),
    (16, 11, 'Yulia Stepanova',     'Head of Repair Service',   '+7 921 222-22-01', 'stepanova@ss-r.ru'),
    (17, 12, 'Kirill Zakharov',     'Manager',                '+7 926 333-33-01', 'zakharov@corner.ru');

INSERT INTO crm_deals (id, title, company_id, contact_id, stage_id, owner_login, expected_close, closed_on, lost_reason, created_at) VALUES
    (1,  'CRM for the sales department',             1,  1,  4, 'ivanov',  current_date + 7,   NULL,              NULL, now() - interval '60 days'),
    (2,  'Support for year 2',              1,  2,  5, 'ivanov',  current_date - 20,  current_date - 5,  NULL, now() - interval '50 days'),
    (3,  'Service desk automation',    2,  3,  3, 'petrova', current_date + 21,  NULL,              NULL, now() - interval '40 days'),
    (4,  'ERP integration',                  2,  4,  2, 'petrova', current_date + 45,  NULL,              NULL, now() - interval '25 days'),
    (5,  'Partner program',             3,  5,  1, 'ivanov',  current_date + 60,  NULL,              NULL, now() - interval '5 days'),
    (6,  'CRM for the dispatch center',             4,  6,  4, 'petrova', current_date - 3,   NULL,              NULL, now() - interval '55 days'),
    (7,  'Mobile sales reps',               4,  7,  6, 'petrova', current_date - 30,  current_date - 25, 'Chose a competitor: 20% cheaper', now() - interval '80 days'),
    (8,  'Sites and foremen tracking',          5,  8,  3, 'ivanov',  current_date + 14,  NULL,              NULL, now() - interval '35 days'),
    (9,  'Customer portal',                 6,  9,  2, 'sidorov', current_date + 30,  NULL,              NULL, now() - interval '20 days'),
    (10, 'CRM for investment advisors', 6,  10, 5, 'sidorov', current_date - 40,  current_date - 35, NULL, now() - interval '90 days'),
    (11, 'Website orders',                    7,  11, 1, 'petrova', current_date + 30,  NULL,              NULL, now() - interval '3 days'),
    (12, 'CRM rollout for 50 seats',          8,  12, 4, 'ivanov',  current_date + 3,   NULL,              NULL, now() - interval '45 days'),
    (13, 'New staff training',        8,  13, 5, 'ivanov',  current_date - 10,  current_date - 2,  NULL, now() - interval '30 days'),
    (14, 'Sales audit',                      9,  14, 3, 'petrova', current_date + 10,  NULL,              NULL, now() - interval '15 days'),
    (15, 'Courier tracking',                     10, 15, 2, 'ivanov',  current_date + 25,  NULL,              NULL, now() - interval '12 days'),
    (16, 'Repair requests',                  11, 16, 1, 'sidorov', current_date + 40,  NULL,              NULL, now() - interval '8 days'),
    (17, 'Loyalty program',              12, 17, 6, 'petrova', current_date - 12,  current_date - 9,  'Project postponed until next year', now() - interval '35 days'),
    (18, 'Management reporting',        3,  5,  4, 'ivanov',  current_date - 1,   NULL,              NULL, now() - interval '28 days');

INSERT INTO crm_deal_lines (deal_id, product_id, quantity, price, discount) VALUES
    (1, 1, 15, 18000, 10), (1, 2, 40, 3500, 0), (1, 3, 2, 45000, 0),
    (2, 6, 1, 96000, 5),
    (3, 1, 8, 18000, 0), (3, 2, 60, 3500, 0), (3, 7, 1, 150000, 15),
    (4, 4, 1, 120000, 0), (4, 5, 1, 60000, 0),
    (5, 1, 3, 18000, 0),
    (6, 1, 25, 18000, 12), (6, 2, 80, 3500, 5), (6, 6, 1, 96000, 0),
    (7, 7, 1, 150000, 0), (7, 1, 10, 18000, 0),
    (8, 1, 12, 18000, 5), (8, 7, 1, 150000, 10),
    (9, 4, 1, 120000, 0), (9, 2, 30, 3500, 0),
    (10, 1, 20, 18000, 10), (10, 3, 3, 45000, 0), (10, 6, 1, 96000, 0),
    (11, 1, 2, 18000, 0),
    (12, 1, 50, 18000, 15), (12, 2, 120, 3500, 10), (12, 8, 1, 420000, 5), (12, 6, 1, 96000, 0),
    (13, 3, 4, 45000, 0),
    (14, 9, 1, 80000, 0), (14, 10, 16, 3000, 0),
    (15, 1, 6, 18000, 0), (15, 7, 1, 150000, 0),
    (17, 1, 4, 18000, 0),
    (18, 10, 40, 3000, 0), (18, 1, 5, 18000, 0);

INSERT INTO crm_activities (kind, subject, notes, due_on, done_at, deal_id, company_id, owner_login, created_by, created_at) VALUES
    ('call',    'Agree on the final discount',          NULL,                                  current_date,      NULL,                       1,    NULL, 'ivanov',  'ivanov',  now() - interval '3 days'),
    ('meeting', 'Demo for the IT department',            'Show the integration and roles',          current_date - 12, now() - interval '12 days', 1,    NULL, 'ivanov',  'ivanov',  now() - interval '20 days'),
    ('email',   'Send the contract for approval',     NULL,                                  current_date + 2,  NULL,                       1,    NULL, 'ivanov',  'sidorov', now() - interval '1 day'),
    ('call',    'Clarify mobile version requirements', NULL,                                 current_date - 2,  NULL,                       3,    NULL, 'petrova', 'petrova', now() - interval '7 days'),
    ('meeting', 'Meeting at the customer''s site',         'Yekaterinburg, workshop #2',                current_date + 5,  NULL,                       3,    NULL, 'petrova', 'petrova', now() - interval '4 days'),
    ('task',    'Prepare the integration spec',          NULL,                                  current_date + 10, NULL,                       4,    NULL, 'petrova', 'petrova', now() - interval '6 days'),
    ('call',    'First call: needs',            NULL,                                  current_date + 1,  NULL,                       5,    NULL, 'ivanov',  'ivanov',  now() - interval '2 days'),
    ('call',    'Remind about the signing deadline',          'The planned date has passed',                current_date - 1,  NULL,                       6,    NULL, 'petrova', 'sidorov', now() - interval '2 days'),
    ('note',    'A competitor offered a 20% discount',        NULL,                                  NULL,              now() - interval '26 days', 7,    NULL, 'petrova', 'petrova', now() - interval '26 days'),
    ('meeting', 'Presentation for the chief engineer',     NULL,                                  current_date + 3,  NULL,                       8,    NULL, 'ivanov',  'ivanov',  now() - interval '5 days'),
    ('task',    'Customer portal scenarios',          NULL,                                  current_date + 7,  NULL,                       9,    NULL, 'sidorov', 'sidorov', now() - interval '3 days'),
    ('call',    'Clarify website order volume',        NULL,                                  current_date + 2,  NULL,                       11,   NULL, 'petrova', 'petrova', now() - interval '1 day'),
    ('meeting', 'Project pitch to the CEO',         'Needs a presentation with an ROI calculation', current_date,  NULL,                       12,   NULL, 'ivanov',  'ivanov',  now() - interval '6 days'),
    ('email',   'Send a commercial proposal',      NULL,                                  current_date - 4,  NULL,                       12,   NULL, 'ivanov',  'ivanov',  now() - interval '8 days'),
    ('call',    'Training feedback',            NULL,                                  current_date - 1,  now() - interval '1 day',   13,   NULL, 'ivanov',  'ivanov',  now() - interval '4 days'),
    ('task',    'Sales process questionnaire',          NULL,                                  current_date + 4,  NULL,                       14,   NULL, 'petrova', 'petrova', now() - interval '3 days'),
    ('call',    'Demo for the COO',      NULL,                                  current_date - 3,  NULL,                       15,   NULL, 'ivanov',  'ivanov',  now() - interval '9 days'),
    ('call',    'Meet the repair service',         NULL,                                  current_date + 6,  NULL,                       16,   NULL, 'sidorov', 'sidorov', now() - interval '2 days'),
    ('task',    'Prepare a sample report for the board',  NULL,                                  current_date,      NULL,                       18,   NULL, 'ivanov',  'ivanov',  now() - interval '2 days'),
    ('call',    'Congratulate on the company anniversary',         NULL,                                  current_date + 12, NULL,                       NULL, 2,    'petrova', 'petrova', now() - interval '1 day'),
    ('meeting', 'Quarterly customer meeting',        NULL,                                  current_date + 20, NULL,                       NULL, 6,    'sidorov', 'sidorov', now() - interval '1 day'),
    ('task',    'Update the contract details',         NULL,                                  current_date - 6,  NULL,                       NULL, 10,   'ivanov',  'ivanov',  now() - interval '10 days'),
    ('task',    'Weekly report to the head',       NULL,                                  current_date + 2,  NULL,                       NULL, NULL, 'petrova', 'sidorov', now() - interval '1 day');

INSERT INTO crm_deal_events (deal_id, at, login, text)
SELECT id, created_at, owner_login, 'Deal created' FROM crm_deals;
INSERT INTO crm_deal_events (deal_id, at, login, text) VALUES
    (1,  now() - interval '30 days', 'ivanov',  'Stage: Proposal → Negotiation'),
    (2,  (current_date - 5)::TIMESTAMPTZ + interval '15 hours', 'ivanov', 'Stage: Negotiation → Won'),
    (6,  now() - interval '10 days', 'petrova', 'Stage: Proposal → Negotiation'),
    (7,  (current_date - 25)::TIMESTAMPTZ + interval '11 hours', 'petrova', 'Stage: Negotiation → Lost'),
    (7,  (current_date - 25)::TIMESTAMPTZ + interval '11 hours', 'petrova', 'Loss reason: Chose a competitor: 20% cheaper'),
    (10, (current_date - 35)::TIMESTAMPTZ + interval '16 hours', 'sidorov', 'Stage: Negotiation → Won'),
    (12, now() - interval '7 days',  'ivanov',  'Stage: Proposal → Negotiation'),
    (13, (current_date - 2)::TIMESTAMPTZ + interval '12 hours', 'ivanov', 'Stage: Proposal → Won'),
    (17, (current_date - 9)::TIMESTAMPTZ + interval '10 hours', 'petrova', 'Stage: Proposal → Lost'),
    (17, (current_date - 9)::TIMESTAMPTZ + interval '10 hours', 'petrova', 'Loss reason: Project postponed until next year');

SELECT setval(pg_get_serial_sequence('crm_stages', 'id'), (SELECT max(id) FROM crm_stages));
SELECT setval(pg_get_serial_sequence('crm_industries', 'id'), (SELECT max(id) FROM crm_industries));
SELECT setval(pg_get_serial_sequence('crm_product_groups', 'id'), (SELECT max(id) FROM crm_product_groups));
SELECT setval(pg_get_serial_sequence('crm_products', 'id'), (SELECT max(id) FROM crm_products));
SELECT setval(pg_get_serial_sequence('crm_companies', 'id'), (SELECT max(id) FROM crm_companies));
SELECT setval(pg_get_serial_sequence('crm_contacts', 'id'), (SELECT max(id) FROM crm_contacts));
SELECT setval(pg_get_serial_sequence('crm_deals', 'id'), (SELECT max(id) FROM crm_deals));

-- ---------------------------------------------------------------------
-- Триггеры (после демо-данных): журнал сделки, дата закрытия, обновление списков во всех вкладках
-- ---------------------------------------------------------------------
-- Закрывающая стадия ставит дату закрытия, открытая — снимает её и причину проигрыша
CREATE FUNCTION crm_deals_before()
RETURNS TRIGGER AS $$
DECLARE
    v_stage crm_stages%ROWTYPE;
BEGIN
    SELECT * INTO v_stage FROM crm_stages WHERE id = NEW.stage_id;
    IF v_stage.is_closed THEN
        IF TG_OP = 'INSERT' OR NEW.stage_id IS DISTINCT FROM OLD.stage_id THEN
            NEW.closed_on := current_date;
        END IF;
    ELSE
        NEW.closed_on := NULL;
        NEW.lost_reason := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_deals_log()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO crm_deal_events (deal_id, login, text) VALUES (NEW.id, ui_user(), 'Deal created');
        RETURN NULL;
    END IF;
    IF NEW.stage_id IS DISTINCT FROM OLD.stage_id THEN
        INSERT INTO crm_deal_events (deal_id, login, text)
        SELECT NEW.id, ui_user(), format('Stage: %s → %s', f.name, t.name)
        FROM crm_stages f, crm_stages t WHERE f.id = OLD.stage_id AND t.id = NEW.stage_id;
    END IF;
    IF NEW.owner_login IS DISTINCT FROM OLD.owner_login THEN
        INSERT INTO crm_deal_events (deal_id, login, text)
        VALUES (NEW.id, ui_user(), format('Owner: %s → %s',
                                          crm_user_name(OLD.owner_login), crm_user_name(NEW.owner_login)));
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Списки сделок и задач обновляются во всех вкладках, где они открыты (каждая перечитывает свою видимость)
CREATE FUNCTION crm_deals_push()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM ui_push_to('crm_deals', ui_refresh_grid('crm_deals_grid', p_keep_page => TRUE));
    PERFORM ui_push_to('crm_dashboard', ui_refresh_grid('crm_my_deals_grid', p_keep_page => TRUE));
    PERFORM ui_push_to('crm_pipeline', ui_refresh_grid('crm_pipeline_chart'),
                                       ui_refresh_grid('crm_pipeline_grid', p_keep_page => TRUE),
                                       ui_refresh_grid('crm_pipeline_owners_grid', p_keep_page => TRUE));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION crm_activities_push()
RETURNS TRIGGER AS $$
BEGIN
    PERFORM ui_push_to('crm_tasks', ui_refresh_grid('crm_tasks_grid', p_keep_page => TRUE));
    PERFORM ui_push_to('crm_dashboard', ui_refresh_grid('crm_my_tasks_grid', p_keep_page => TRUE));
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER crm_deals_before BEFORE INSERT OR UPDATE OF stage_id ON crm_deals
    FOR EACH ROW EXECUTE FUNCTION crm_deals_before();
CREATE TRIGGER crm_deals_log AFTER INSERT OR UPDATE OF stage_id, owner_login ON crm_deals
    FOR EACH ROW EXECUTE FUNCTION crm_deals_log();
CREATE TRIGGER crm_deals_push AFTER INSERT OR UPDATE OR DELETE ON crm_deals
    FOR EACH STATEMENT EXECUTE FUNCTION crm_deals_push();
CREATE TRIGGER crm_deal_lines_push AFTER INSERT OR UPDATE OR DELETE ON crm_deal_lines
    FOR EACH STATEMENT EXECUTE FUNCTION crm_deals_push();
CREATE TRIGGER crm_activities_push AFTER INSERT OR UPDATE OR DELETE ON crm_activities
    FOR EACH STATEMENT EXECUTE FUNCTION crm_activities_push();

-- ---------------------------------------------------------------------
-- Действия
-- ---------------------------------------------------------------------
INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('crm_stages_combo',              'crm_stages_combo',              'CRM: pipeline stages list',                        FALSE, FALSE),
    ('crm_owners_combo',              'crm_owners_combo',              'CRM: owners list',                         FALSE, FALSE),
    ('crm_industries_combo',          'crm_industries_combo',          'CRM: industries list',                              FALSE, FALSE),
    ('crm_activity_kinds_combo',      'crm_activity_kinds_combo',      'CRM: task types',                                   FALSE, FALSE),
    ('crm_task_filter_combo',         'crm_task_filter_combo',         'CRM: task list filter',                          FALSE, FALSE),
    ('crm_companies_page',            'crm_companies_page',            'CRM: companies table',                             FALSE, FALSE),
    ('crm_company_select_open',       'crm_company_select_open',       'CRM: select a company',                               FALSE, FALSE),
    ('crm_company_new_open',          'crm_company_new_open',          'CRM: new company',                               FALSE, FALSE),
    ('crm_company_edit_open',         'crm_company_edit_open',         'CRM: open a company',                             FALSE, FALSE),
    ('crm_company_save',              'crm_company_save',              'CRM: save a company',                           FALSE, FALSE),
    ('crm_company_delete',            'crm_company_delete',            'CRM: delete a company',                             FALSE, FALSE),
    ('crm_company_contacts_page',     'crm_company_contacts_page',     'CRM: company contacts',                            FALSE, FALSE),
    ('crm_company_deals_page',        'crm_company_deals_page',        'CRM: company deals',                              FALSE, FALSE),
    ('crm_company_activities_page',   'crm_company_activities_page',   'CRM: company tasks',                           FALSE, FALSE),
    ('crm_company_contact_new_open',  'crm_company_contact_new_open',  'CRM: new company contact',                       FALSE, FALSE),
    ('crm_company_deal_new_open',     'crm_company_deal_new_open',     'CRM: new company deal',                        FALSE, FALSE),
    ('crm_company_activity_new_open', 'crm_company_activity_new_open', 'CRM: new company task',                     FALSE, FALSE),
    ('crm_contacts_page',             'crm_contacts_page',             'CRM: contacts table',                            FALSE, FALSE),
    ('crm_contact_select_open',       'crm_contact_select_open',       'CRM: select a company contact',                      FALSE, FALSE),
    ('crm_contact_new_open',          'crm_contact_new_open',          'CRM: new contact',                                FALSE, FALSE),
    ('crm_contact_edit_open',         'crm_contact_edit_open',         'CRM: open a contact',                              FALSE, FALSE),
    ('crm_contact_save',              'crm_contact_save',              'CRM: save a contact',                            FALSE, FALSE),
    ('crm_contact_delete',            'crm_contact_delete',            'CRM: delete a contact',                              FALSE, FALSE),
    ('crm_products_page',             'crm_products_page',             'CRM: products and services table',                      FALSE, FALSE),
    ('crm_product_select_open',       'crm_product_select_open',       'CRM: select a product with its price',             FALSE, FALSE),
    ('crm_product_new_open',          'crm_product_new_open',          'CRM: new product',                                  FALSE, FALSE),
    ('crm_product_edit_open',         'crm_product_edit_open',         'CRM: open a product',                                FALSE, FALSE),
    ('crm_product_save',              'crm_product_save',              'CRM: save a product',                              FALSE, FALSE),
    ('crm_product_delete',            'crm_product_delete',            'CRM: delete a product',                                FALSE, FALSE),
    ('crm_product_groups_tree',       'crm_product_groups_tree',       'CRM: product group tree',                            FALSE, FALSE),
    ('crm_product_groups_combo',      'crm_product_groups_combo',      'CRM: product groups list',                           FALSE, FALSE),
    ('crm_product_group_new_open',    'crm_product_group_new_open',    'CRM: new product group',                             FALSE, FALSE),
    ('crm_product_group_edit_open',   'crm_product_group_edit_open',   'CRM: open a product group',                          FALSE, FALSE),
    ('crm_product_group_save',        'crm_product_group_save',        'CRM: save a product group',                          FALSE, FALSE),
    ('crm_product_group_delete',      'crm_product_group_delete',      'CRM: delete a product group',                        FALSE, FALSE),
    ('crm_deals_page',                'crm_deals_page',                'CRM: deals table with filters',                   FALSE, FALSE),
    ('crm_my_deals_page',             'crm_my_deals_page',             'CRM: my open deals',                          FALSE, FALSE),
    ('crm_deal_new_open',             'crm_deal_new_open',             'CRM: new deal',                                 FALSE, FALSE),
    ('crm_deal_edit_open',            'crm_deal_edit_open',            'CRM: open a deal',                               FALSE, FALSE),
    ('crm_deal_save',                 'crm_deal_save',                 'CRM: save a deal',                             FALSE, FALSE),
    ('crm_deal_advance',              'crm_deal_advance',              'CRM: move the deal to the next stage',                      FALSE, FALSE),
    ('crm_deal_win',                  'crm_deal_win',                  'CRM: deal won',                              FALSE, FALSE),
    ('crm_deal_lose_open',            'crm_deal_lose_open',            'CRM: deal lost — reason',                   FALSE, FALSE),
    ('crm_deal_lose_save',            'crm_deal_lose_save',            'CRM: close the deal as lost',               FALSE, FALSE),
    ('crm_deal_delete',               'crm_deal_delete',               'CRM: delete a deal',                               FALSE, FALSE),
    ('crm_deal_cancel',               'crm_deal_cancel',               'CRM: close deal without saving',                FALSE, FALSE),
    ('crm_deal_print',                'crm_deal_print',                'CRM: commercial offer (PDF)',               FALSE, FALSE),
    ('crm_deal_events_page',          'crm_deal_events_page',          'CRM: deal history',                                FALSE, FALSE),
    ('crm_deal_lines_page',           'crm_deal_lines_page',           'CRM: deal items',                              FALSE, FALSE),
    ('crm_deal_line_new_open',        'crm_deal_line_new_open',        'CRM: add an item to the deal',                      FALSE, FALSE),
    ('crm_deal_line_edit_open',       'crm_deal_line_edit_open',       'CRM: open a deal item',                       FALSE, FALSE),
    ('crm_deal_line_save',            'crm_deal_line_save',            'CRM: save a deal item',                     FALSE, FALSE),
    ('crm_deal_line_delete',          'crm_deal_line_delete',          'CRM: remove an item from the deal',                       FALSE, FALSE),
    ('crm_tasks_page',                'crm_tasks_page',                'CRM: tasks table with filters',                    FALSE, FALSE),
    ('crm_my_tasks_page',             'crm_my_tasks_page',             'CRM: my open tasks',                          FALSE, FALSE),
    ('crm_deal_activities_page',      'crm_deal_activities_page',      'CRM: deal tasks',                             FALSE, FALSE),
    ('crm_activity_new_open',         'crm_activity_new_open',         'CRM: new task',                                 FALSE, FALSE),
    ('crm_deal_activity_new_open',    'crm_deal_activity_new_open',    'CRM: new deal task',                       FALSE, FALSE),
    ('crm_activity_edit_open',        'crm_activity_edit_open',        'CRM: open a task',                               FALSE, FALSE),
    ('crm_activity_save',             'crm_activity_save',             'CRM: save a task',                             FALSE, FALSE),
    ('crm_activity_done',             'crm_activity_done',             'CRM: task done',                             FALSE, FALSE),
    ('crm_activity_delete',           'crm_activity_delete',           'CRM: delete a task',                               FALSE, FALSE),
    ('crm_reminders',                 'crm_reminders',                 'CRM: reminders to the message panel',               FALSE, FALSE),
    ('crm_pipeline_page',             'crm_pipeline_page',             'CRM: pipeline by stage',                           FALSE, FALSE),
    ('crm_pipeline_owners_page',      'crm_pipeline_owners_page',      'CRM: pipeline by manager',                        FALSE, FALSE),
    ('crm_pipeline_chart',            'crm_pipeline_chart',            'CRM: pipeline chart by stage',                     FALSE, FALSE),
    ('crm_pipeline_print',            'crm_pipeline_print',            'CRM: “Sales pipeline” report (PDF)',                 FALSE, FALSE),
    ('crm_offer_data',                'crm_offer_data',                'CRM: commercial offer data',             FALSE, FALSE),
    ('crm_pipeline_data',             'crm_pipeline_data',             'CRM: “Sales pipeline” report data',               FALSE, FALSE);

-- ---------------------------------------------------------------------
-- Формы
-- ---------------------------------------------------------------------
INSERT INTO pgerp.forms (form_name, title, cancel_action, folder) VALUES
    ('crm_dashboard',  'Dashboard',          NULL, 'CRM'),
    ('crm_deals',      'Deals',                NULL, 'CRM'),
    ('crm_deal',       'Deal',                'crm_deal_cancel', 'CRM'),
    ('crm_deal_line',  'Deal item',        NULL, 'CRM'),
    ('crm_deal_lost',  'Deal lost',      NULL, 'CRM'),
    ('crm_companies',  'Companies',              NULL, 'CRM'),
    ('crm_company',    'Company',              NULL, 'CRM'),
    ('crm_contacts',   'Contacts',              NULL, 'CRM'),
    ('crm_contact',    'Contact',               NULL, 'CRM'),
    ('crm_tasks',      'Tasks',                NULL, 'CRM'),
    ('crm_activity',   'Task',                NULL, 'CRM'),
    ('crm_products',   'Products and services',       NULL, 'CRM'),
    ('crm_product',    'Product or service',      NULL, 'CRM'),
    ('crm_product_group', 'Product group',        NULL, 'CRM'),
    ('crm_pipeline',   'Sales pipeline',        NULL, 'CRM');

INSERT INTO pgerp.form_components (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options) VALUES
    ('crm_dashboard', 1,  'button',   'btn_new_task',          'New task',             'crm_activity_new_open',         NULL, NULL, NULL),
    ('crm_dashboard', 2,  'button',   'btn_new_deal',          'New deal',             'crm_deal_new_open',             NULL, NULL, NULL),
    ('crm_dashboard', 3,  'button',   'btn_reminders',         'Reminders',              'crm_reminders',                 NULL, NULL, NULL),
    ('crm_dashboard', 4,  'grid',     'crm_my_tasks_grid',     'My tasks',               'crm_my_tasks_page',             NULL, NULL, NULL),
    ('crm_dashboard', 5,  'grid',     'crm_my_deals_grid',     'My open deals',      'crm_my_deals_page',             NULL, NULL, NULL),

    ('crm_deals', 1, 'combobox', 'stage_filter',   'Stage',        'crm_stages_combo', NULL, NULL, '{"refresh": "crm_deals_grid", "placeholder": "All stages", "column": 1}'),
    ('crm_deals', 2, 'combobox', 'owner_filter',   'Owner', 'crm_owners_combo', NULL, NULL, '{"refresh": "crm_deals_grid", "placeholder": "All", "column": 2}'),
    ('crm_deals', 3, 'input',    'search',         'Search',         NULL,               NULL, NULL, '{"refresh": "crm_deals_grid", "column": 3}'),
    ('crm_deals', 4, 'button',   'btn_new',        'New deal',  'crm_deal_new_open', NULL, NULL, NULL),
    ('crm_deals', 5, 'grid',     'crm_deals_grid', 'Deals',        'crm_deals_page',   NULL, NULL, NULL),

    ('crm_deal', 1,  'hidden',   'id',                       NULL,                        NULL,                         NULL, NULL,       NULL),
    ('crm_deal', 2,  'input',    'title',                    'Title',                  NULL,                         NULL, NULL,       '{"column": 1}'),
    ('crm_deal', 3,  'lookup',   'company_id',               'Company',                  'crm_company_select_open',    NULL, NULL,       '{"column": 1}'),
    ('crm_deal', 4,  'lookup',   'contact_id',               'Contact',                   'crm_contact_select_open',    NULL, NULL,       '{"column": 1}'),
    ('crm_deal', 5,  'combobox', 'stage_id',                 'Stage',                    'crm_stages_combo',           NULL, NULL,       '{"column": 2}'),
    ('crm_deal', 6,  'combobox', 'owner_login',              'Owner',             'crm_owners_combo',           NULL, NULL,       '{"column": 2}'),
    ('crm_deal', 7,  'date',     'expected_close',           'Expected close date',    NULL,                         NULL, NULL,       '{"column": 2}'),
    ('crm_deal', 8,  'display',  'amount',                   'Amount (probability)',       NULL,                         NULL, NULL,       NULL),
    ('crm_deal', 9,  'button',   'btn_add_line',             'Add product or service', 'crm_deal_line_new_open',     NULL, 'Products',   NULL),
    ('crm_deal', 10, 'grid',     'crm_deal_lines_grid',      NULL,                        'crm_deal_lines_page',        'id', 'Products',   NULL),
    ('crm_deal', 11, 'button',   'btn_add_activity',         'Add task',           'crm_deal_activity_new_open', NULL, 'Tasks',   NULL),
    ('crm_deal', 12, 'grid',     'crm_deal_activities_grid', NULL,                        'crm_deal_activities_page',   'id', 'Tasks',   NULL),
    ('crm_deal', 13, 'grid',     'crm_deal_events_grid',     NULL,                        'crm_deal_events_page',       'id', 'History',   NULL),
    ('crm_deal', 14, 'button',   'btn_save',                 'Save',                 'crm_deal_save',              NULL, NULL,       NULL),
    ('crm_deal', 15, 'button',   'btn_advance',              'Next stage',          'crm_deal_advance',           NULL, NULL,       NULL),
    ('crm_deal', 16, 'button',   'btn_win',                  'Won',                  'crm_deal_win',               NULL, NULL,       NULL),
    ('crm_deal', 17, 'button',   'btn_lose',                 'Lost',                 'crm_deal_lose_open',         NULL, NULL,       NULL),
    ('crm_deal', 18, 'button',   'btn_print',                'Commercial offer',  'crm_deal_print',             NULL, NULL,       NULL),
    ('crm_deal', 19, 'button',   'btn_close',                'Cancel',                    'crm_deal_cancel',            NULL, NULL,       NULL),

    ('crm_deal_line', 1, 'hidden', 'id',         NULL,               NULL,                      NULL, NULL, NULL),
    ('crm_deal_line', 2, 'hidden', 'deal_id',    NULL,               NULL,                      NULL, NULL, NULL),
    ('crm_deal_line', 3, 'lookup', 'product_id', 'Product or service', 'crm_product_select_open', NULL, NULL, NULL),
    ('crm_deal_line', 4, 'input',  'quantity',   'Quantity',       NULL,                      NULL, NULL, NULL),
    ('crm_deal_line', 5, 'input',  'price',      'Price',             NULL,                      NULL, NULL, NULL),
    ('crm_deal_line', 6, 'input',  'discount',   'Discount, %',        NULL,                      NULL, NULL, NULL),
    ('crm_deal_line', 7, 'button', 'btn_save',   'Save',        'crm_deal_line_save',      NULL, NULL, NULL),
    ('crm_deal_line', 8, 'button', 'btn_cancel', 'Cancel',           'form_close',              NULL, NULL, NULL),

    ('crm_deal_lost', 1, 'hidden', 'deal_id',     NULL,                   NULL,                 NULL, NULL, NULL),
    ('crm_deal_lost', 2, 'input',  'lost_reason', 'Reason',              NULL,                 NULL, NULL, NULL),
    ('crm_deal_lost', 3, 'button', 'btn_save',    'Mark as lost', 'crm_deal_lose_save', NULL, NULL, NULL),
    ('crm_deal_lost', 4, 'button', 'btn_cancel',  'Cancel',               'form_close',         NULL, NULL, NULL),

    ('crm_companies', 1, 'input',    'search',             'Search',          NULL,                   NULL, NULL, '{"refresh": "crm_companies_grid", "column": 1}'),
    ('crm_companies', 2, 'combobox', 'industry_filter',    'Industry',        'crm_industries_combo', NULL, NULL, '{"refresh": "crm_companies_grid", "placeholder": "All industries", "column": 2}'),
    ('crm_companies', 3, 'button',   'btn_new',            'New company', 'crm_company_new_open', NULL, NULL, NULL),
    ('crm_companies', 4, 'grid',     'crm_companies_grid', 'Companies',       'crm_companies_page',   NULL, NULL, NULL),

    ('crm_company', 1,  'hidden',   'id',                          NULL,              NULL,                            NULL, NULL,       NULL),
    ('crm_company', 2,  'input',    'name',                        'Name',    NULL,                            NULL, NULL,       '{"column": 1}'),
    ('crm_company', 3,  'input',    'inn',                         'Tax ID',             NULL,                            NULL, NULL,       '{"column": 1}'),
    ('crm_company', 4,  'combobox', 'industry_id',                 'Industry',         'crm_industries_combo',          NULL, NULL,       '{"column": 1}'),
    ('crm_company', 5,  'combobox', 'owner_login',                 'Owner',   'crm_owners_combo',              NULL, NULL,       '{"column": 1}'),
    ('crm_company', 6,  'input',    'phone',                       'Phone',         NULL,                            NULL, NULL,       '{"column": 2}'),
    ('crm_company', 7,  'input',    'email',                       'Email',       NULL,                            NULL, NULL,       '{"column": 2}'),
    ('crm_company', 8,  'input',    'website',                     'Website',            NULL,                            NULL, NULL,       '{"column": 2}'),
    ('crm_company', 9,  'input',    'address',                     'Address',           NULL,                            NULL, NULL,       '{"column": 2}'),
    ('crm_company', 10, 'button',   'btn_add_contact',             'Add contact', 'crm_company_contact_new_open', NULL, 'Contacts', NULL),
    ('crm_company', 11, 'grid',     'crm_company_contacts_grid',   NULL,              'crm_company_contacts_page',     'id', 'Contacts', NULL),
    ('crm_company', 12, 'button',   'btn_add_deal',                'New deal',    'crm_company_deal_new_open',     NULL, 'Deals',   NULL),
    ('crm_company', 13, 'grid',     'crm_company_deals_grid',      NULL,              'crm_company_deals_page',        'id', 'Deals',   NULL),
    ('crm_company', 14, 'button',   'btn_add_activity',            'Add task', 'crm_company_activity_new_open', NULL, 'Tasks',   NULL),
    ('crm_company', 15, 'grid',     'crm_company_activities_grid', NULL,              'crm_company_activities_page',   'id', 'Tasks',   NULL),
    ('crm_company', 16, 'button',   'btn_save',                    'Save',       'crm_company_save',              NULL, NULL,       NULL),
    ('crm_company', 17, 'button',   'btn_close',                   'Close',         'form_close',                    NULL, NULL,       NULL),

    ('crm_contacts', 1, 'hidden', 'company_id',        NULL,            NULL,                   NULL, NULL, NULL),
    ('crm_contacts', 2, 'input',  'search',            'Search',         NULL,                   NULL, NULL, '{"refresh": "crm_contacts_grid"}'),
    ('crm_contacts', 3, 'button', 'btn_new',           'New contact', 'crm_contact_new_open', NULL, NULL, NULL),
    ('crm_contacts', 4, 'grid',   'crm_contacts_grid', 'Contacts',      'crm_contacts_page',    NULL, NULL, NULL),

    ('crm_contact', 1, 'hidden', 'id',         NULL,        NULL,                      NULL, NULL, NULL),
    ('crm_contact', 2, 'lookup', 'company_id', 'Company',  'crm_company_select_open', NULL, NULL, NULL),
    ('crm_contact', 3, 'input',  'full_name',  'Full name',       NULL,                      NULL, NULL, NULL),
    ('crm_contact', 4, 'input',  'position',   'Position', NULL,                      NULL, NULL, NULL),
    ('crm_contact', 5, 'input',  'phone',      'Phone',   NULL,                      NULL, NULL, NULL),
    ('crm_contact', 6, 'input',  'email',      'Email', NULL,                      NULL, NULL, NULL),
    ('crm_contact', 7, 'button', 'btn_save',   'Save', 'crm_contact_save',        NULL, NULL, NULL),
    ('crm_contact', 8, 'button', 'btn_cancel', 'Cancel',    'form_close',              NULL, NULL, NULL),

    ('crm_tasks', 1, 'combobox', 'task_filter',    'Show',      'crm_task_filter_combo', NULL, NULL, '{"refresh": "crm_tasks_grid", "placeholder": "Open only", "column": 1}'),
    ('crm_tasks', 2, 'combobox', 'owner_filter',   'Owner', 'crm_owners_combo',      NULL, NULL, '{"refresh": "crm_tasks_grid", "placeholder": "All", "column": 2}'),
    ('crm_tasks', 3, 'input',    'search',         'Search',         NULL,                    NULL, NULL, '{"refresh": "crm_tasks_grid", "column": 3}'),
    ('crm_tasks', 4, 'button',   'btn_new',        'New task',  'crm_activity_new_open', NULL, NULL, NULL),
    ('crm_tasks', 5, 'button',   'btn_reminders',  'Reminders',   'crm_reminders',         NULL, NULL, NULL),
    ('crm_tasks', 6, 'grid',     'crm_tasks_grid', 'Tasks',        'crm_tasks_page',        NULL, NULL, NULL),

    ('crm_activity', 1,  'hidden',   'id',          NULL,            NULL,                       NULL, NULL, NULL),
    ('crm_activity', 2,  'hidden',   'deal_id',     NULL,            NULL,                       NULL, NULL, NULL),
    ('crm_activity', 3,  'hidden',   'company_id',  NULL,            NULL,                       NULL, NULL, NULL),
    ('crm_activity', 4,  'display',  'related',     'Related to',   NULL,                       NULL, NULL, NULL),
    ('crm_activity', 5,  'combobox', 'kind',        'Type',           'crm_activity_kinds_combo', NULL, NULL, NULL),
    ('crm_activity', 6,  'input',    'subject',     'Subject',          NULL,                       NULL, NULL, NULL),
    ('crm_activity', 7,  'date',     'due_on',      'Due',          NULL,                       NULL, NULL, NULL),
    ('crm_activity', 8,  'combobox', 'owner_login', 'Owner', 'crm_owners_combo',         NULL, NULL, NULL),
    ('crm_activity', 9,  'input',    'notes',       'Comment',   NULL,                       NULL, NULL, NULL),
    ('crm_activity', 10, 'button',   'btn_save',    'Save',     'crm_activity_save',        NULL, NULL, NULL),
    ('crm_activity', 11, 'button',   'btn_done',    'Mark done',     'crm_activity_done',        NULL, NULL, NULL),
    ('crm_activity', 12, 'button',   'btn_cancel',  'Cancel',        'form_close',               NULL, NULL, NULL),

    ('crm_products', 1, 'button', 'btn_group_new',     'New group',              'crm_product_group_new_open',  NULL, NULL, '{"column": 1}'),
    ('crm_products', 2, 'button', 'btn_group_edit',    'Edit',                   'crm_product_group_edit_open', NULL, NULL, '{"column": 1}'),
    ('crm_products', 3, 'button', 'btn_group_delete',  'Delete',                 'crm_product_group_delete',    NULL, NULL, '{"column": 1}'),
    ('crm_products', 4, 'tree',   'group_id',          'Groups',                 'crm_product_groups_tree',     NULL, NULL, '{"column": 1}'),
    ('crm_products', 5, 'button', 'btn_new',           'New product or service', 'crm_product_new_open', NULL, NULL, '{"column": 2}'),
    ('crm_products', 6, 'input',  'search',            'Search',                 NULL,                   NULL, NULL, '{"refresh": "crm_products_grid", "column": 2}'),
    ('crm_products', 7, 'grid',   'crm_products_grid', 'Products and services',  'crm_products_page',    'group_id', NULL, '{"column": 2}'),

    ('crm_product_group', 1, 'hidden',   'id',         NULL,           NULL,                       NULL, NULL, NULL),
    ('crm_product_group', 2, 'input',    'name',       'Name',         NULL,                       NULL, NULL, NULL),
    ('crm_product_group', 3, 'combobox', 'parent_id',  'Parent group', 'crm_product_groups_combo', NULL, NULL, '{"placeholder": "Top level"}'),
    ('crm_product_group', 4, 'button',   'btn_save',   'Save',         'crm_product_group_save',   NULL, NULL, NULL),
    ('crm_product_group', 5, 'button',   'btn_cancel', 'Cancel',       'form_close',               NULL, NULL, NULL),

    ('crm_product', 1, 'hidden',   'id',         NULL,              NULL,                       NULL, NULL, NULL),
    ('crm_product', 2, 'combobox', 'group_id',   'Group',           'crm_product_groups_combo', NULL, NULL, '{"placeholder": "Choose a group"}'),
    ('crm_product', 3, 'input',    'name',       'Name',            NULL,                       NULL, NULL, NULL),
    ('crm_product', 4, 'input',    'sku',        'SKU',             NULL,                       NULL, NULL, NULL),
    ('crm_product', 5, 'input',    'unit',       'Unit of measure', NULL,                       NULL, NULL, NULL),
    ('crm_product', 6, 'input',    'price',      'Price',           NULL,                       NULL, NULL, NULL),
    ('crm_product', 7, 'button',   'btn_save',   'Save',            'crm_product_save',         NULL, NULL, NULL),
    ('crm_product', 8, 'button',   'btn_cancel', 'Cancel',          'form_close',               NULL, NULL, NULL),

    ('crm_pipeline', 1, 'button', 'btn_print',                'PDF report',      'crm_pipeline_print',       NULL, NULL, NULL),
    ('crm_pipeline', 2, 'chart',  'crm_pipeline_chart',       'Amount by stage', 'crm_pipeline_chart',    NULL, NULL, '{"chart": "bar", "height": 240}'),
    ('crm_pipeline', 3, 'grid',   'crm_pipeline_grid',        'By stage',     'crm_pipeline_page',        NULL, NULL, NULL),
    ('crm_pipeline', 4, 'grid',   'crm_pipeline_owners_grid', 'By manager',  'crm_pipeline_owners_page', NULL, NULL, NULL);

INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column) VALUES
    ('crm_my_tasks_page', 1, 'due',      'Due',        'text',  'due_sort'),
    ('crm_my_tasks_page', 2, 'state',    'Status',   'badge', 'due_sort'),
    ('crm_my_tasks_page', 3, 'kind_name', 'Type',        'text',  'kind'),
    ('crm_my_tasks_page', 4, 'subject',  'Subject',        'text',  'subject'),
    ('crm_my_tasks_page', 5, 'related',  'Related to', 'text',  'related'),

    ('crm_my_deals_page', 1, 'title',      'Deal',   'text',  'title'),
    ('crm_my_deals_page', 2, 'stage',      'Stage',   'badge', 'stage_order'),
    ('crm_my_deals_page', 3, 'amount',     'Amount',    'money', 'amount'),
    ('crm_my_deals_page', 4, 'close_date', 'Close date', 'text',  'expected_close'),

    ('crm_deals_page', 1, 'id',         'No.',           'number', 'id'),
    ('crm_deals_page', 2, 'title',      'Deal',        'text',   'title'),
    ('crm_deals_page', 3, 'company',    'Company',      'text',   'company'),
    ('crm_deals_page', 4, 'stage',      'Stage',        'badge',  'stage_order'),
    ('crm_deals_page', 5, 'amount',     'Amount',         'money',  'amount'),
    ('crm_deals_page', 6, 'close_date', 'Close date',      'text',   'expected_close'),
    ('crm_deals_page', 7, 'owner',      'Owner', 'text',   'owner'),

    ('crm_company_deals_page', 1, 'title',      'Deal',        'text',  'title'),
    ('crm_company_deals_page', 2, 'stage',      'Stage',        'badge', 'stage_order'),
    ('crm_company_deals_page', 3, 'amount',     'Amount',         'money', 'amount'),
    ('crm_company_deals_page', 4, 'owner',      'Owner', 'text',  'owner'),

    ('crm_deal_lines_page', 1, 'product',  'Product or service', 'text',   'product'),
    ('crm_deal_lines_page', 2, 'quantity', 'Qty',           'number', 'quantity'),
    ('crm_deal_lines_page', 3, 'unit',     'Unit',              'text',   NULL),
    ('crm_deal_lines_page', 4, 'price',    'Price',             'money',  'price'),
    ('crm_deal_lines_page', 5, 'discount', 'Discount, %',        'number', 'discount'),
    ('crm_deal_lines_page', 6, 'amount',   'Amount',            'money',  'amount'),

    ('crm_deal_activities_page', 1, 'due',       'Due',          'text',  'due_sort'),
    ('crm_deal_activities_page', 2, 'state',     'Status',     'badge', 'due_sort'),
    ('crm_deal_activities_page', 3, 'kind_name', 'Type',           'text',  'kind'),
    ('crm_deal_activities_page', 4, 'subject',   'Subject',          'text',  'subject'),
    ('crm_deal_activities_page', 5, 'owner',     'Owner', 'text',  'owner'),

    ('crm_company_activities_page', 1, 'due',       'Due',          'text',  'due_sort'),
    ('crm_company_activities_page', 2, 'state',     'Status',     'badge', 'due_sort'),
    ('crm_company_activities_page', 3, 'kind_name', 'Type',           'text',  'kind'),
    ('crm_company_activities_page', 4, 'subject',   'Subject',          'text',  'subject'),
    ('crm_company_activities_page', 5, 'deal',      'Deal',        'text',  'deal'),

    ('crm_deal_events_page', 1, 'at_text', 'When', 'text', 'at'),
    ('crm_deal_events_page', 2, 'author',  'Who',   'text', NULL),
    ('crm_deal_events_page', 3, 'text',    'What',   'text', NULL),

    ('crm_companies_page', 1, 'name',       'Company',       'text',   'name'),
    ('crm_companies_page', 2, 'industry',   'Industry',        'text',   'industry'),
    ('crm_companies_page', 3, 'phone',      'Phone',        'text',   NULL),
    ('crm_companies_page', 4, 'open_deals', 'Open deals', 'number', 'open_deals'),
    ('crm_companies_page', 5, 'owner',      'Owner',  'text',   'owner'),

    ('crm_company_contacts_page', 1, 'full_name', 'Full name',       'text', 'full_name'),
    ('crm_company_contacts_page', 2, 'position',  'Position', 'text', 'position'),
    ('crm_company_contacts_page', 3, 'phone',     'Phone',   'text', NULL),
    ('crm_company_contacts_page', 4, 'email',     'Email', 'text', NULL),

    ('crm_contacts_page', 1, 'full_name', 'Full name',       'text', 'full_name'),
    ('crm_contacts_page', 2, 'company',   'Company',  'text', 'company'),
    ('crm_contacts_page', 3, 'position',  'Position', 'text', 'position'),
    ('crm_contacts_page', 4, 'phone',     'Phone',   'text', NULL),
    ('crm_contacts_page', 5, 'email',     'Email', 'text', NULL),

    ('crm_tasks_page', 1, 'due',       'Due',          'text',  'due_sort'),
    ('crm_tasks_page', 2, 'state',     'Status',     'badge', 'due_sort'),
    ('crm_tasks_page', 3, 'kind_name', 'Type',           'text',  'kind'),
    ('crm_tasks_page', 4, 'subject',   'Subject',          'text',  'subject'),
    ('crm_tasks_page', 5, 'related',   'Related to',   'text',  'related'),
    ('crm_tasks_page', 6, 'owner',     'Owner', 'text',  'owner'),

    ('crm_products_page', 1, 'name',       'Name',  'text',  'name'),
    ('crm_products_page', 2, 'group_path', 'Group', 'text',  'group_path'),
    ('crm_products_page', 3, 'sku',        'SKU',   'text',  'sku'),
    ('crm_products_page', 4, 'unit',       'Unit',  'text',  NULL),
    ('crm_products_page', 5, 'price',      'Price', 'money', 'price'),

    ('crm_pipeline_page', 1, 'stage',       'Stage',             'badge',  'sort_order'),
    ('crm_pipeline_page', 2, 'probability', 'Probability, %',     'number', 'probability'),
    ('crm_pipeline_page', 3, 'deals',       'Deal count',             'number', 'deals'),
    ('crm_pipeline_page', 4, 'amount',      'Amount',              'money',  'amount'),
    ('crm_pipeline_page', 5, 'weighted',    'Weighted', 'money', 'weighted'),

    ('crm_pipeline_owners_page', 1, 'owner',         'Manager',             'text',   'owner'),
    ('crm_pipeline_owners_page', 2, 'open_deals',    'Open deals',      'number', 'open_deals'),
    ('crm_pipeline_owners_page', 3, 'open_amount',   'In progress',             'money',  'open_amount'),
    ('crm_pipeline_owners_page', 4, 'weighted',      'Weighted', 'money',  'weighted'),
    ('crm_pipeline_owners_page', 5, 'won_month',     'Won this month', 'money', 'won_month'),
    ('crm_pipeline_owners_page', 6, 'overdue_tasks', 'Overdue tasks',   'number', 'overdue_tasks');

INSERT INTO pgerp.grid_row_actions (source_action, sort_order, row_action, label, style) VALUES
    ('crm_my_tasks_page',           1, 'crm_activity_done',       'Mark done', 'default'),
    ('crm_my_tasks_page',           2, 'crm_activity_edit_open',  'Open',   'default'),
    ('crm_my_deals_page',           1, 'crm_deal_edit_open',      'Open',   'default'),
    ('crm_deals_page',              1, 'crm_deal_edit_open',      'Open',   'default'),
    ('crm_deals_page',              2, 'crm_deal_print',          'Offer',        'default'),
    ('crm_deals_page',              3, 'crm_deal_delete',         'Delete',   'danger'),
    ('crm_company_deals_page',      1, 'crm_deal_edit_open',      'Open',   'default'),
    ('crm_deal_lines_page',         1, 'crm_deal_line_edit_open', 'Edit',  'default'),
    ('crm_deal_lines_page',         2, 'crm_deal_line_delete',    'Remove',    'danger'),
    ('crm_deal_activities_page',    1, 'crm_activity_done',       'Mark done', 'default'),
    ('crm_deal_activities_page',    2, 'crm_activity_edit_open',  'Open',   'default'),
    ('crm_company_activities_page', 1, 'crm_activity_done',       'Mark done', 'default'),
    ('crm_company_activities_page', 2, 'crm_activity_edit_open',  'Open',   'default'),
    ('crm_companies_page',          1, 'crm_company_edit_open',   'Open',   'default'),
    ('crm_companies_page',          2, 'crm_company_delete',      'Delete',   'danger'),
    ('crm_company_contacts_page',   1, 'crm_contact_edit_open',   'Edit',  'default'),
    ('crm_company_contacts_page',   2, 'crm_contact_delete',      'Delete',   'danger'),
    ('crm_contacts_page',           1, 'crm_contact_edit_open',   'Edit',  'default'),
    ('crm_contacts_page',           2, 'crm_contact_delete',      'Delete',   'danger'),
    ('crm_tasks_page',              1, 'crm_activity_done',       'Mark done', 'default'),
    ('crm_tasks_page',              2, 'crm_activity_edit_open',  'Open',   'default'),
    ('crm_tasks_page',              3, 'crm_activity_delete',     'Delete',   'danger'),
    ('crm_products_page',           1, 'crm_product_edit_open',   'Edit',  'default'),
    ('crm_products_page',           2, 'crm_product_delete',      'Delete',   'danger');

-- Роли: менеджеру — работа с клиентами и сделками, руководителю — ещё воронка. Карточки (сделка,
-- компания, задача…) выдаются через действия, которые их открывают
INSERT INTO pgerp.role_forms (role_id, form_name)
SELECT r.id, f.form_name
FROM pgerp.roles r
CROSS JOIN (VALUES ('crm_dashboard'), ('crm_deals'), ('crm_companies'), ('crm_contacts'), ('crm_tasks'),
                   ('crm_products')) AS f(form_name)
WHERE r.role_name IN ('crm_manager', 'crm_head')
UNION ALL
SELECT r.id, 'crm_pipeline' FROM pgerp.roles r WHERE r.role_name = 'crm_head';

-- Меню: папка CRM — первой
UPDATE pgerp.menu_items SET sort_order = sort_order + 1 WHERE parent_id IS NULL;
WITH root AS (
    INSERT INTO pgerp.menu_items (parent_id, sort_order, title, form_name) VALUES (NULL, 1, 'CRM', NULL)
    RETURNING id
)
INSERT INTO pgerp.menu_items (parent_id, sort_order, title, form_name)
SELECT root.id, n, title, form_name
FROM root
CROSS JOIN (VALUES (1, 'Dashboard',    'crm_dashboard'),
                   (2, 'Deals',          'crm_deals'),
                   (3, 'Companies',        'crm_companies'),
                   (4, 'Contacts',        'crm_contacts'),
                   (5, 'Tasks',          'crm_tasks'),
                   (6, 'Sales pipeline',  'crm_pipeline'),
                   (7, 'Products and services', 'crm_products')) AS t(n, title, form_name);

-- ---------------------------------------------------------------------
-- Отчёты PDF
-- ---------------------------------------------------------------------
INSERT INTO pgerp.reports (name, title, data_action, sample_params, jrxml) VALUES
('crm_offer', 'Commercial offer', 'crm_offer_data', '{"deal_id": 12}', $jrxml$<jasperReport name="crm_offer" pageWidth="595" pageHeight="842" columnWidth="515" leftMargin="40" rightMargin="40" topMargin="40" bottomMargin="30">
	<!-- Commercial proposal for a deal: parameters come from crm_offer_data, rows are the deal products and services -->
	<parameter name="title" class="java.lang.String"/>
	<parameter name="offer_date" class="java.util.Date"/>
	<parameter name="valid_until" class="java.util.Date"/>
	<parameter name="deal" class="java.lang.String"/>
	<parameter name="company" class="java.lang.String"/>
	<parameter name="company_details" class="java.lang.String"/>
	<parameter name="contact" class="java.lang.String"/>
	<parameter name="manager" class="java.lang.String"/>
	<parameter name="total" class="java.math.BigDecimal"/>
	<parameter name="discount_total" class="java.math.BigDecimal"/>
	<field name="line_no" class="java.lang.Integer"/>
	<field name="product" class="java.lang.String"/>
	<field name="sku" class="java.lang.String"/>
	<field name="unit" class="java.lang.String"/>
	<field name="quantity" class="java.math.BigDecimal"/>
	<field name="price" class="java.math.BigDecimal"/>
	<field name="discount" class="java.math.BigDecimal"/>
	<field name="amount" class="java.math.BigDecimal"/>
	<title height="150">
		<element kind="rectangle" x="0" y="0" width="515" height="4" mode="Opaque" backcolor="#0969DA">
			<pen lineWidth="0.0"/>
		</element>
		<element kind="textField" x="0" y="14" width="515" height="30" fontSize="20.0" bold="true">
			<expression><![CDATA[$P{title}]]></expression>
		</element>
		<element kind="textField" x="0" y="44" width="515" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{dated} + " " + new java.text.SimpleDateFormat("dd.MM.yyyy").format($P{offer_date}) + " · " + $R{valid until} + " " + new java.text.SimpleDateFormat("dd.MM.yyyy").format($P{valid_until})]]></expression>
		</element>
		<element kind="textField" x="0" y="72" width="90" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{Customer}]]></expression>
		</element>
		<element kind="textField" x="90" y="72" width="425" height="18" bold="true">
			<expression><![CDATA[$P{company}]]></expression>
		</element>
		<element kind="textField" x="90" y="90" width="425" height="16" fontSize="8.0" forecolor="#59636E" textAdjust="StretchHeight">
			<expression><![CDATA[$P{company_details}]]></expression>
		</element>
		<element kind="textField" x="0" y="108" width="90" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{Contact}]]></expression>
		</element>
		<element kind="textField" x="90" y="108" width="200" height="18">
			<expression><![CDATA[$P{contact} == null ? "—" : $P{contact}]]></expression>
		</element>
		<element kind="textField" x="290" y="108" width="225" height="18" hTextAlign="Right">
			<expression><![CDATA[$R{Manager} + ": " + $P{manager}]]></expression>
		</element>
		<element kind="textField" x="0" y="126" width="515" height="18" fontSize="9.0" forecolor="#59636E">
			<expression><![CDATA[$R{Project} + ": " + $P{deal}]]></expression>
		</element>
	</title>
	<columnHeader height="24">
		<element kind="frame" x="0" y="0" width="515" height="22" mode="Opaque" backcolor="#F6F8FA">
			<element kind="textField" x="4" y="0" width="24" height="22" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA["№"]]></expression>
			</element>
			<element kind="textField" x="28" y="0" width="207" height="22" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Product or service}]]></expression>
			</element>
			<element kind="textField" x="235" y="0" width="60" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Qty}]]></expression>
			</element>
			<element kind="textField" x="295" y="0" width="75" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Price}]]></expression>
			</element>
			<element kind="textField" x="370" y="0" width="50" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Discount}]]></expression>
			</element>
			<element kind="textField" x="420" y="0" width="91" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
				<expression><![CDATA[$R{Amount}]]></expression>
			</element>
		</element>
	</columnHeader>
	<detail>
		<band height="30">
			<element kind="textField" x="4" y="0" width="24" height="18" fontSize="9.0">
				<expression><![CDATA[$F{line_no}]]></expression>
			</element>
			<element kind="textField" x="28" y="0" width="207" height="18" fontSize="9.0" textAdjust="StretchHeight">
				<expression><![CDATA[$F{product}]]></expression>
			</element>
			<element kind="textField" x="28" y="16" width="207" height="12" fontSize="7.0" forecolor="#59636E">
				<expression><![CDATA[$F{sku}]]></expression>
			</element>
			<element kind="textField" x="235" y="0" width="60" height="18" hTextAlign="Right" fontSize="9.0">
				<expression><![CDATA[new java.text.DecimalFormat("#,##0.##").format($F{quantity}) + " " + $F{unit}]]></expression>
			</element>
			<element kind="textField" x="295" y="0" width="75" height="18" hTextAlign="Right" fontSize="9.0" pattern="#,##0.00">
				<expression><![CDATA[$F{price}]]></expression>
			</element>
			<element kind="textField" x="370" y="0" width="50" height="18" hTextAlign="Right" fontSize="9.0">
				<expression><![CDATA[$F{discount}.signum() == 0 ? "—" : new java.text.DecimalFormat("#,##0.##").format($F{discount}) + "%"]]></expression>
			</element>
			<element kind="textField" x="420" y="0" width="91" height="18" hTextAlign="Right" fontSize="9.0" pattern="#,##0.00">
				<expression><![CDATA[$F{amount}]]></expression>
			</element>
			<element kind="line" x="0" y="29" width="515" height="1" forecolor="#EFF2F5"/>
		</band>
	</detail>
	<pageFooter height="20">
		<element kind="textField" x="0" y="0" width="315" height="20" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$R{Commercial offer} + " · " + $P{company}]]></expression>
		</element>
		<element kind="textField" x="315" y="0" width="200" height="20" hTextAlign="Right" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$R{Page} + " " + $V{PAGE_NUMBER}]]></expression>
		</element>
	</pageFooter>
	<summary height="110">
		<element kind="textField" x="195" y="10" width="195" height="18" hTextAlign="Right">
			<expression><![CDATA[$R{Total discount}]]></expression>
		</element>
		<element kind="textField" x="395" y="10" width="116" height="18" hTextAlign="Right" pattern="#,##0.00">
			<expression><![CDATA[$P{discount_total}]]></expression>
		</element>
		<element kind="textField" x="195" y="30" width="195" height="22" hTextAlign="Right" bold="true" fontSize="12.0">
			<expression><![CDATA[$R{Total due}]]></expression>
		</element>
		<element kind="textField" x="395" y="30" width="116" height="22" hTextAlign="Right" bold="true" fontSize="12.0" pattern="#,##0.00">
			<expression><![CDATA[$P{total}]]></expression>
		</element>
		<element kind="textField" x="0" y="66" width="515" height="40" fontSize="9.0" forecolor="#59636E" textAdjust="StretchHeight">
			<expression><![CDATA[$R{Prices are in roubles. Implementation dates are agreed after the contract is signed. We will be happy to answer your questions.}]]></expression>
		</element>
	</summary>
</jasperReport>
$jrxml$),
('crm_pipeline', 'Sales pipeline', 'crm_pipeline_data', '{}', $jrxml$<jasperReport name="crm_pipeline" pageWidth="595" pageHeight="842" columnWidth="515" leftMargin="40" rightMargin="40" topMargin="40" bottomMargin="30">
	<!-- Sales pipeline: stages with deal count, amount and probability-weighted amount; totals are in parameters -->
	<parameter name="title" class="java.lang.String"/>
	<parameter name="as_of" class="java.util.Date"/>
	<parameter name="scope" class="java.lang.String"/>
	<parameter name="printed_by" class="java.lang.String"/>
	<parameter name="open_count" class="java.lang.Integer"/>
	<parameter name="open_amount" class="java.math.BigDecimal"/>
	<parameter name="weighted" class="java.math.BigDecimal"/>
	<parameter name="won_month" class="java.math.BigDecimal"/>
	<field name="stage" class="java.lang.String"/>
	<field name="probability" class="java.lang.Integer"/>
	<field name="deals" class="java.lang.Integer"/>
	<field name="amount" class="java.math.BigDecimal"/>
	<field name="weighted" class="java.math.BigDecimal"/>
	<title height="150">
		<element kind="rectangle" x="0" y="0" width="515" height="4" mode="Opaque" backcolor="#0969DA">
			<pen lineWidth="0.0"/>
		</element>
		<element kind="textField" x="0" y="14" width="515" height="30" fontSize="20.0" bold="true">
			<expression><![CDATA[$P{title}]]></expression>
		</element>
		<element kind="textField" x="0" y="44" width="515" height="18" forecolor="#59636E">
			<expression><![CDATA[$R{as of} + " " + new java.text.SimpleDateFormat("dd.MM.yyyy").format($P{as_of}) + " · " + $P{scope}]]></expression>
		</element>
		<element kind="frame" x="0" y="74" width="515" height="62" mode="Opaque" backcolor="#F6F8FA">
			<element kind="textField" x="12" y="8" width="115" height="14" fontSize="8.0" forecolor="#59636E">
				<expression><![CDATA[$R{Open deals}]]></expression>
			</element>
			<element kind="textField" x="12" y="24" width="115" height="26" fontSize="18.0" bold="true">
				<expression><![CDATA[$P{open_count}]]></expression>
			</element>
			<element kind="textField" x="139" y="8" width="115" height="14" fontSize="8.0" forecolor="#59636E">
				<expression><![CDATA[$R{In progress}]]></expression>
			</element>
			<element kind="textField" x="139" y="24" width="115" height="26" fontSize="14.0" bold="true" pattern="#,##0">
				<expression><![CDATA[$P{open_amount}]]></expression>
			</element>
			<element kind="textField" x="266" y="8" width="115" height="14" fontSize="8.0" forecolor="#59636E">
				<expression><![CDATA[$R{Weighted}]]></expression>
			</element>
			<element kind="textField" x="266" y="24" width="115" height="26" fontSize="14.0" bold="true" pattern="#,##0">
				<expression><![CDATA[$P{weighted}]]></expression>
			</element>
			<element kind="textField" x="393" y="8" width="115" height="14" fontSize="8.0" forecolor="#59636E">
				<expression><![CDATA[$R{Won this month}]]></expression>
			</element>
			<element kind="textField" x="393" y="24" width="115" height="26" fontSize="14.0" bold="true" pattern="#,##0" forecolor="#1A7F37">
				<expression><![CDATA[$P{won_month}]]></expression>
			</element>
		</element>
	</title>
	<columnHeader height="24">
		<element kind="textField" x="0" y="0" width="150" height="22" vTextAlign="Middle" bold="true" fontSize="9.0">
			<expression><![CDATA[$R{Stage}]]></expression>
		</element>
		<element kind="textField" x="150" y="0" width="45" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
			<expression><![CDATA["%"]]></expression>
		</element>
		<element kind="textField" x="195" y="0" width="50" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
			<expression><![CDATA[$R{Deal count}]]></expression>
		</element>
		<element kind="textField" x="255" y="0" width="120" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
			<expression><![CDATA[$R{Amount}]]></expression>
		</element>
		<element kind="textField" x="375" y="0" width="140" height="22" hTextAlign="Right" vTextAlign="Middle" bold="true" fontSize="9.0">
			<expression><![CDATA[$R{Weighted}]]></expression>
		</element>
		<element kind="line" x="0" y="23" width="515" height="1" forecolor="#D1D9E0"/>
	</columnHeader>
	<detail>
		<band height="26">
			<element kind="textField" x="0" y="0" width="150" height="24" vTextAlign="Middle">
				<expression><![CDATA[$F{stage}]]></expression>
			</element>
			<element kind="textField" x="150" y="0" width="45" height="24" hTextAlign="Right" vTextAlign="Middle" forecolor="#59636E">
				<expression><![CDATA[$F{probability}]]></expression>
			</element>
			<element kind="textField" x="195" y="0" width="50" height="24" hTextAlign="Right" vTextAlign="Middle">
				<expression><![CDATA[$F{deals}]]></expression>
			</element>
			<element kind="textField" x="255" y="0" width="120" height="24" hTextAlign="Right" vTextAlign="Middle" pattern="#,##0">
				<expression><![CDATA[$F{amount}]]></expression>
			</element>
			<element kind="textField" x="375" y="0" width="140" height="24" hTextAlign="Right" vTextAlign="Middle" pattern="#,##0">
				<expression><![CDATA[$F{weighted}]]></expression>
			</element>
			<element kind="line" x="0" y="25" width="515" height="1" forecolor="#EFF2F5"/>
		</band>
	</detail>
	<pageFooter height="20">
		<element kind="textField" x="0" y="0" width="315" height="20" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$R{Printed by} + ": " + $P{printed_by} + ", " + new java.text.SimpleDateFormat("dd.MM.yyyy HH:mm").format(new java.util.Date())]]></expression>
		</element>
		<element kind="textField" x="315" y="0" width="200" height="20" hTextAlign="Right" forecolor="#59636E" fontSize="8.0">
			<expression><![CDATA[$R{Page} + " " + $V{PAGE_NUMBER}]]></expression>
		</element>
	</pageFooter>
</jasperReport>
$jrxml$);

-- ---------------------------------------------------------------------
-- Переводы
-- ---------------------------------------------------------------------
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Companies, contacts, pipeline deals, tasks, reports', 'Компании, контакты, сделки по воронке, задачи, отчёты'),
    ('ru', 'No.', '№'),
    ('ru', 'Name', 'Наименование'),
    ('ru', 'Quantity', 'Количество'),
    ('ru', 'Phone', 'Телефон'),
    ('ru', 'CRM', 'CRM'),
    ('ru', 'Sales manager', 'Менеджер по продажам'),
    ('ru', 'Head of sales', 'Руководитель отдела продаж'),
    -- стадии, типы задач, состояния
    ('ru', 'New', 'Новая'),
    ('ru', 'Qualification', 'Квалификация'),
    ('ru', 'Proposal', 'Предложение'),
    ('ru', 'Negotiation', 'Переговоры'),
    ('ru', 'Won', 'Выиграна'),
    ('ru', 'Lost', 'Проиграна'),
    ('ru', 'Call', 'Звонок'),
    ('ru', 'Meeting', 'Встреча'),
    ('ru', 'Task', 'Задача'),
    ('ru', 'Email message', 'Письмо'),
    ('ru', 'Note', 'Заметка'),
    ('ru', 'Completed', 'Выполнена'),
    ('ru', 'Overdue', 'Просрочена'),
    ('ru', 'Today', 'Сегодня'),
    ('ru', 'Planned', 'Запланирована'),
    ('ru', 'system', 'система'),
    ('ru', 'Due today', 'На сегодня'),
    ('ru', 'Overdue only', 'Просроченные'),
    ('ru', 'Completed only', 'Выполненные'),
    ('ru', 'All, including done', 'Все, включая выполненные'),
    -- формы, меню, подписи
    ('ru', 'Dashboard', 'Рабочий стол'),
    ('ru', 'Deals', 'Сделки'),
    ('ru', 'Deal', 'Сделка'),
    ('ru', 'Deal item', 'Товар в сделке'),
    ('ru', 'Product or service in a deal', 'Товар или услуга в сделке'),
    ('ru', 'pcs', 'шт.'),
    ('ru', 'Deal lost', 'Сделка проиграна'),
    ('ru', 'Companies', 'Компании'),
    ('ru', 'Company', 'Компания'),
    ('ru', 'Contacts', 'Контакты'),
    ('ru', 'Contact', 'Контакт'),
    ('ru', 'Tasks', 'Задачи'),
    ('ru', 'Products and services', 'Товары и услуги'),
    ('ru', 'Product or service', 'Товар или услуга'),
    ('ru', 'Sales pipeline', 'Воронка продаж'),
    ('ru', 'New task', 'Новая задача'),
    ('ru', 'New deal', 'Новая сделка'),
    ('ru', 'Reminders', 'Напоминания'),
    ('ru', 'My tasks', 'Мои задачи'),
    ('ru', 'My open deals', 'Мои открытые сделки'),
    ('ru', 'Stage', 'Стадия'),
    ('ru', 'Owner', 'Ответственный'),
    ('ru', 'Search', 'Поиск'),
    ('ru', 'All stages', 'Все стадии'),
    ('ru', 'All', 'Все'),
    ('ru', 'Title', 'Название'),
    ('ru', 'Expected close date', 'Плановая дата закрытия'),
    ('ru', 'Amount (probability)', 'Сумма (вероятность)'),
    ('ru', 'Add product or service', 'Добавить товар или услугу'),
    ('ru', 'Add task', 'Добавить задачу'),
    ('ru', 'History', 'Журнал'),
    ('ru', 'Products', 'Товары'),
    ('ru', 'Next stage', 'Следующая стадия'),
    ('ru', 'Commercial offer', 'Коммерческое предложение'),
    ('ru', 'Close', 'Закрыть'),
    ('ru', 'Discount, %', 'Скидка, %'),
    ('ru', 'Reason', 'Причина'),
    ('ru', 'Mark as lost', 'Отметить проигранной'),
    ('ru', 'Industry', 'Отрасль'),
    ('ru', 'All industries', 'Все отрасли'),
    ('ru', 'New company', 'Новая компания'),
    ('ru', 'Tax ID', 'ИНН'),
    ('ru', 'Email', 'Эл. почта'),
    ('ru', 'Website', 'Сайт'),
    ('ru', 'Address', 'Адрес'),
    ('ru', 'Add contact', 'Добавить контакт'),
    ('ru', 'New contact', 'Новый контакт'),
    ('ru', 'Full name', 'ФИО'),
    ('ru', 'Position', 'Должность'),
    ('ru', 'Show', 'Показать'),
    ('ru', 'Open only', 'Открытые'),
    ('ru', 'Related to', 'Относится к'),
    ('ru', 'Type', 'Тип'),
    ('ru', 'Subject', 'Тема'),
    ('ru', 'Due', 'Срок'),
    ('ru', 'Comment', 'Комментарий'),
    ('ru', 'Mark done', 'Выполнено'),
    ('ru', 'New product or service', 'Новый товар или услуга'),
    ('ru', 'SKU', 'Артикул'),
    ('ru', 'Unit of measure', 'Ед. изм.'),
    ('ru', 'PDF report', 'Отчёт PDF'),
    ('ru', 'By stage', 'По стадиям'),
    ('ru', 'Amount by stage', 'Сумма по стадиям'),
    ('ru', 'CRM: pipeline chart by stage', 'CRM: график воронки по стадиям'),
    ('ru', 'By manager', 'По менеджерам'),
    -- колонки и кнопки строк
    ('ru', 'Status', 'Состояние'),
    ('ru', 'Close date', 'Закрытие'),
    ('ru', 'Unit', 'Ед.'),
    ('ru', 'When', 'Когда'),
    ('ru', 'Who', 'Кто'),
    ('ru', 'What', 'Что'),
    ('ru', 'Open deals', 'Открытых сделок'),
    ('ru', 'Probability, %', 'Вероятность, %'),
    ('ru', 'Deal count', 'Сделок'),
    ('ru', 'Weighted', 'С учётом вероятности'),
    ('ru', 'Manager', 'Менеджер'),
    ('ru', 'In progress', 'В работе'),
    ('ru', 'Won this month', 'Выиграно в этом месяце'),
    ('ru', 'Overdue tasks', 'Просроченных задач'),
    ('ru', 'Open', 'Открыть'),
    ('ru', 'Offer', 'КП'),
    ('ru', 'Remove', 'Убрать'),
    -- сообщения
    ('ru', 'Select a company', 'Выбор компании'),
    ('ru', 'Company not found — it may have been deleted', 'Компания не найдена — возможно, она удалена'),
    ('ru', 'Enter the company name', 'Укажите наименование компании'),
    ('ru', 'Tax ID must be 10 or 12 digits', 'ИНН — 10 или 12 цифр'),
    ('ru', 'Invalid email', 'Эл. почта указана неверно'),
    ('ru', 'Choose an owner', 'Выберите ответственного'),
    ('ru', 'Company “%s” already exists', 'Компания «%s» уже есть'),
    ('ru', 'Only the company owner or the head of sales can edit the company', 'Изменить компанию может её ответственный или руководитель отдела продаж'),
    ('ru', 'Company “%s” has been assigned to you', 'Вам передана компания «%s»'),
    ('ru', 'Only the head of sales can delete a company', 'Удалить компанию может руководитель отдела продаж'),
    ('ru', 'Company “%s” has deals and cannot be deleted', 'У компании «%s» есть сделки — удалить её нельзя'),
    ('ru', 'Delete company “%s” with its contacts and tasks?', 'Удалить компанию «%s» вместе с контактами и задачами?'),
    ('ru', 'Company “%s” deleted', 'Компания «%s» удалена'),
    ('ru', 'Choose a company first', 'Сначала выберите компанию'),
    ('ru', 'Contacts: %s', 'Контакты: %s'),
    ('ru', 'Contact not found — it may have been deleted', 'Контакт не найден — возможно, он удалён'),
    ('ru', 'Choose a company', 'Выберите компанию'),
    ('ru', 'Enter the contact name', 'Укажите ФИО контакта'),
    ('ru', 'Delete contact “%s” (%s)?', 'Удалить контакт «%s» (%s)?'),
    ('ru', 'Select a product or service', 'Выбор товара или услуги'),
    ('ru', 'Only the head of sales can change products', 'Справочник товаров меняет руководитель отдела продаж'),
    ('ru', 'Product not found — it may have been deleted', 'Товар не найден — возможно, он удалён'),
    ('ru', 'Enter the name', 'Укажите наименование'),
    ('ru', 'A product with this name or SKU already exists', 'Товар с таким наименованием или артикулом уже есть'),
    ('ru', '“%s” is used in deals and cannot be deleted', '«%s» есть в сделках — удалить нельзя'),
    ('ru', 'Delete “%s”?', 'Удалить «%s»?'),
    ('ru', 'Deal #%s: %s', 'Сделка №%s: %s'),
    ('ru', 'Deal not found or not available — another manager owns it', 'Сделка не найдена или недоступна — её ведёт другой менеджер'),
    ('ru', 'Enter the deal title', 'Укажите название сделки'),
    ('ru', 'The contact is not from the selected company — choose it again', 'Контакт не из выбранной компании — выберите его заново'),
    ('ru', 'Choose a stage', 'Выберите стадию'),
    ('ru', 'Invalid expected close date', 'Плановая дата закрытия указана неверно'),
    ('ru', 'A new deal cannot be closed right away — save it first', 'Новая сделка не может быть сразу закрыта — сначала сохраните её'),
    ('ru', 'To close the deal as lost, click “Lost” and give a reason', 'Чтобы закрыть сделку как проигранную, нажмите «Проиграна» и укажите причину'),
    ('ru', 'Add products or services to the deal', 'Добавьте в сделку товары или услуги'),
    ('ru', 'Deal “%s” has been assigned to you', 'Вам передана сделка «%s»'),
    ('ru', 'The deal is closed', 'Сделка закрыта'),
    ('ru', 'This is the last stage: was the deal won or lost?', 'Это последняя стадия: сделка выиграна или проиграна?'),
    ('ru', '%s: %s → %s', '%s: %s → %s'),
    ('ru', 'The deal is already closed', 'Сделка уже закрыта'),
    ('ru', 'Deal “%s” won: %s', 'Сделка «%s» выиграна: %s'),
    ('ru', '%s won the deal “%s” for %s', '%s выиграл(а) сделку «%s» на %s'),
    ('ru', 'Deal “%s” won', 'Сделка «%s» выиграна'),
    ('ru', 'Enter a reason', 'Укажите причину'),
    ('ru', 'Deal “%s” lost: %s', 'Сделка «%s» проиграна: %s'),
    ('ru', 'Delete deal “%s” (%s, %s) with its items, tasks and history?', 'Удалить сделку «%s» (%s, %s) вместе с товарами, задачами и журналом?'),
    ('ru', 'Offer for deal #%s', 'КП по сделке №%s'),
    ('ru', 'The deal is closed — its items cannot change', 'Сделка закрыта — состав не меняется'),
    ('ru', 'The deal is closed or not available — its items cannot change', 'Сделка закрыта или недоступна — состав не меняется'),
    ('ru', 'Item not found — it may have been deleted', 'Позиция не найдена — возможно, она удалена'),
    ('ru', 'Choose a product or service', 'Выберите товар или услугу'),
    ('ru', 'Quantity must be a number greater than zero', 'Количество — число больше нуля'),
    ('ru', 'Price must be a number, e.g. 1500 or 99.90', 'Цена — число, например 1500 или 99,90'),
    ('ru', 'Discount must be from 0 to 100 %', 'Скидка — от 0 до 100 %'),
    ('ru', 'Remove “%s” from the deal?', 'Убрать «%s» из сделки?'),
    ('ru', 'Task not found or not available', 'Задача не найдена или недоступна'),
    ('ru', 'Choose a type', 'Выберите тип'),
    ('ru', 'Enter a subject', 'Укажите тему'),
    ('ru', 'Invalid due date', 'Срок указан неверно'),
    ('ru', '%s assigned to you: %s, due %s', '%s поручил(а) вам: %s, срок %s'),
    ('ru', 'no due date', 'без срока'),
    ('ru', 'The task is already done', 'Задача уже выполнена'),
    ('ru', 'Done: %s', 'Выполнено: %s'),
    ('ru', 'Overdue since %s: %s — %s', 'Просрочено с %s: %s — %s'),
    ('ru', 'Today (%s): %s — %s', 'Сегодня (%s): %s — %s'),
    ('ru', 'unlinked', 'без привязки'),
    ('ru', 'No overdue tasks and nothing due today', 'Просроченных задач и задач на сегодня нет'),
    ('ru', 'Sales pipeline as of %s', 'Воронка продаж на %s'),
    ('ru', 'Commercial offer #%s', 'Коммерческое предложение №%s'),
    ('ru', 'Tax ID %s', 'ИНН %s'),
    ('ru', 'All managers', 'Все менеджеры'),
    ('ru', 'Deal created', 'Сделка создана'),
    ('ru', 'Stage: %s → %s', 'Стадия: %s → %s'),
    ('ru', 'Owner: %s → %s', 'Ответственный: %s → %s'),
    ('ru', 'Loss reason: %s', 'Причина проигрыша: %s'),
    -- тексты отчётов $R{...}
    ('ru', 'dated', 'от'),
    ('ru', 'valid until', 'действительно до'),
    ('ru', 'Customer', 'Клиент'),
    ('ru', 'Project', 'Проект'),
    ('ru', 'Qty', 'Кол-во'),
    ('ru', 'Price', 'Цена'),
    ('ru', 'Discount', 'Скидка'),
    ('ru', 'Amount', 'Сумма'),
    ('ru', 'Total discount', 'Скидка по предложению'),
    ('ru', 'Total due', 'Итого к оплате'),
    ('ru', 'Prices are in roubles. Implementation dates are agreed after the contract is signed. We will be happy to answer your questions.',
           'Цены указаны в рублях. Сроки внедрения согласуются после подписания договора. Будем рады ответить на вопросы.'),
    ('ru', 'Page', 'Страница'),
    ('ru', 'as of', 'на'),
    ('ru', 'Printed by', 'Напечатал'),
    -- описания действий
    ('ru', 'CRM: pipeline stages list', 'CRM: список стадий воронки'),
    ('ru', 'CRM: owners list', 'CRM: список ответственных'),
    ('ru', 'CRM: industries list', 'CRM: список отраслей'),
    ('ru', 'CRM: task types', 'CRM: типы задач'),
    ('ru', 'CRM: task list filter', 'CRM: фильтр списка задач'),
    ('ru', 'CRM: companies table', 'CRM: таблица компаний'),
    ('ru', 'CRM: select a company', 'CRM: выбор компании'),
    ('ru', 'CRM: new company', 'CRM: новая компания'),
    ('ru', 'CRM: open a company', 'CRM: открыть компанию'),
    ('ru', 'CRM: save a company', 'CRM: сохранить компанию'),
    ('ru', 'CRM: delete a company', 'CRM: удалить компанию'),
    ('ru', 'CRM: company contacts', 'CRM: контакты компании'),
    ('ru', 'CRM: company deals', 'CRM: сделки компании'),
    ('ru', 'CRM: company tasks', 'CRM: задачи по компании'),
    ('ru', 'CRM: new company contact', 'CRM: новый контакт компании'),
    ('ru', 'CRM: new company deal', 'CRM: новая сделка компании'),
    ('ru', 'CRM: new company task', 'CRM: новая задача по компании'),
    ('ru', 'CRM: contacts table', 'CRM: таблица контактов'),
    ('ru', 'CRM: select a company contact', 'CRM: выбор контакта компании'),
    ('ru', 'CRM: new contact', 'CRM: новый контакт'),
    ('ru', 'CRM: open a contact', 'CRM: открыть контакт'),
    ('ru', 'CRM: save a contact', 'CRM: сохранить контакт'),
    ('ru', 'CRM: delete a contact', 'CRM: удалить контакт'),
    ('ru', 'CRM: products and services table', 'CRM: таблица товаров и услуг'),
    ('ru', 'CRM: select a product with its price', 'CRM: выбор товара с подстановкой цены'),
    ('ru', 'CRM: new product', 'CRM: новый товар'),
    ('ru', 'CRM: open a product', 'CRM: открыть товар'),
    ('ru', 'CRM: save a product', 'CRM: сохранить товар'),
    ('ru', 'CRM: delete a product', 'CRM: удалить товар'),
    ('ru', 'CRM: product group tree', 'CRM: дерево групп товаров'),
    ('ru', 'CRM: product groups list', 'CRM: список групп товаров'),
    ('ru', 'CRM: new product group', 'CRM: новая группа товаров'),
    ('ru', 'CRM: open a product group', 'CRM: открыть группу товаров'),
    ('ru', 'CRM: save a product group', 'CRM: сохранить группу товаров'),
    ('ru', 'CRM: delete a product group', 'CRM: удалить группу товаров'),
    ('ru', 'All products and services', 'Все товары и услуги'),
    ('ru', 'Groups', 'Группы'),
    ('ru', 'Group', 'Группа'),
    ('ru', 'New group', 'Новая группа'),
    ('ru', 'Product group', 'Группа товаров'),
    ('ru', 'Parent group', 'Родительская группа'),
    ('ru', 'Top level', 'Верхний уровень'),
    ('ru', 'Choose a group', 'Выберите группу'),
    ('ru', 'Select a group in the tree', 'Выберите группу в дереве'),
    ('ru', 'A group cannot be moved into itself or its subgroup', 'Группу нельзя перенести в неё саму или в её подгруппу'),
    ('ru', 'This group already has a subgroup with this name', 'В этой группе уже есть подгруппа с таким названием'),
    ('ru', 'Group not found — it may have been deleted', 'Группа не найдена — возможно, её удалили'),
    ('ru', 'Group “%s” is not empty: move or delete its subgroups and products first', 'Группа «%s» не пуста: сначала перенесите или удалите её подгруппы и товары'),
    ('ru', 'Delete group “%s”?', 'Удалить группу «%s»?'),
    ('ru', 'Software', 'Программное обеспечение'),
    ('ru', 'Services', 'Услуги'),
    ('ru', 'Implementation', 'Внедрение'),
    ('ru', 'Training and consulting', 'Обучение и консалтинг'),
    ('ru', 'Support', 'Сопровождение'),
    ('ru', 'Hardware', 'Оборудование'),
    ('ru', 'CRM: deals table with filters', 'CRM: таблица сделок с фильтрами'),
    ('ru', 'CRM: my open deals', 'CRM: мои открытые сделки'),
    ('ru', 'CRM: new deal', 'CRM: новая сделка'),
    ('ru', 'CRM: open a deal', 'CRM: открыть сделку'),
    ('ru', 'CRM: save a deal', 'CRM: сохранить сделку'),
    ('ru', 'CRM: move the deal to the next stage', 'CRM: следующая стадия сделки'),
    ('ru', 'CRM: deal won', 'CRM: сделка выиграна'),
    ('ru', 'CRM: deal lost — reason', 'CRM: сделка проиграна — причина'),
    ('ru', 'CRM: close the deal as lost', 'CRM: закрыть сделку как проигранную'),
    ('ru', 'CRM: delete a deal', 'CRM: удалить сделку'),
    ('ru', 'CRM: commercial offer (PDF)', 'CRM: коммерческое предложение (PDF)'),
    ('ru', 'CRM: deal history', 'CRM: журнал сделки'),
    ('ru', 'CRM: deal items', 'CRM: товары в сделке'),
    ('ru', 'CRM: add an item to the deal', 'CRM: добавить товар в сделку'),
    ('ru', 'CRM: open a deal item', 'CRM: открыть товар в сделке'),
    ('ru', 'CRM: save a deal item', 'CRM: сохранить товар в сделке'),
    ('ru', 'CRM: remove an item from the deal', 'CRM: убрать товар из сделки'),
    ('ru', 'CRM: tasks table with filters', 'CRM: таблица задач с фильтрами'),
    ('ru', 'CRM: my open tasks', 'CRM: мои открытые задачи'),
    ('ru', 'CRM: deal tasks', 'CRM: задачи по сделке'),
    ('ru', 'CRM: new task', 'CRM: новая задача'),
    ('ru', 'CRM: new deal task', 'CRM: новая задача по сделке'),
    ('ru', 'CRM: open a task', 'CRM: открыть задачу'),
    ('ru', 'CRM: save a task', 'CRM: сохранить задачу'),
    ('ru', 'CRM: task done', 'CRM: задача выполнена'),
    ('ru', 'CRM: delete a task', 'CRM: удалить задачу'),
    ('ru', 'CRM: reminders to the message panel', 'CRM: напоминания в панель сообщений'),
    ('ru', 'CRM: pipeline by stage', 'CRM: воронка по стадиям'),
    ('ru', 'CRM: pipeline by manager', 'CRM: воронка по менеджерам'),
    ('ru', 'CRM: “Sales pipeline” report (PDF)', 'CRM: отчёт «Воронка продаж» (PDF)'),
    ('ru', 'CRM: commercial offer data', 'CRM: данные коммерческого предложения'),
    ('ru', 'Close without saving? The new deal will not be created.', 'Закрыть без сохранения? Новая сделка не будет создана.'),
    ('ru', 'Close without saving? Deal "%s" with its products and tasks will be deleted.', 'Закрыть без сохранения? Сделка «%s» с товарами и задачами будет удалена.'),
    ('ru', 'Close without saving? Changes to deal "%s" will be discarded.', 'Закрыть без сохранения? Изменения в сделке «%s» будут отменены.'),
    ('ru', 'Don''t save', 'Не сохранять'),
    ('ru', 'Cancel', 'Отмена'),
    ('ru', 'CRM: close deal without saving', 'CRM: закрыть сделку без сохранения'),
    ('ru', 'CRM: “Sales pipeline” report data', 'CRM: данные отчёта «Воронка продаж»')
ON CONFLICT (lang, source) DO NOTHING;

-- Справочники, строки которых переносят выпуски решения
INSERT INTO pgerp.solution_data (table_name, solution) VALUES
    ('crm_activity_kinds', 'crm'),
    ('crm_industries', 'crm'),
    ('crm_stages', 'crm')
ON CONFLICT (table_name) DO UPDATE SET solution = EXCLUDED.solution;
$release$);
