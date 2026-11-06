-- =====================================================================
-- PgERP — ядро платформы: единственная миграция Flyway.
--
-- Схема pgerp: маршрутизатор действий, помощники ui_*, метаданные форм, меню, таблиц и деревьев,
-- пользователи, роли и права, языки и переводы, темы; редактор функций, окно сообщений, отчёты PDF,
-- колонки и фильтры таблиц; разработка решений (решения, схема данных, SQL-консоль, выпуски, установка
-- пакетов) и MCP-сервер. Формы администрирования и переводы текстов ядра. Первый вход — admin / admin,
-- пароль нужно сменить; администратор при первом входе выбирает, какие решения установить.
--
-- Ядро не знает о прикладных решениях. Решения — не миграции Flyway, а пакеты db/solutions/<папка>/:
-- их устанавливает администратор, каждое — в свою схему базы (или в public).
-- Описание платформы — ARCHITECTURE.md.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE SCHEMA pgerp;

-- Прикладной код вызывает помощники ядра без схемы: ui_ok(...). public — первой: объекты ядра
-- создаются и указываются со схемой pgerp
DO $$
BEGIN
    EXECUTE format('ALTER DATABASE %I SET search_path = public, pgerp', current_database());
END;
$$;
SET search_path = public, pgerp;
-- Функции ссылаются на функции и таблицы, объявленные ниже в этом же файле
SET LOCAL check_function_bodies = off;

-- ---------------------------------------------------------------------
-- Таблицы
-- ---------------------------------------------------------------------
-- Реестр действий: какое действие UI какой PL/pgSQL-функцией обрабатывается.
-- Функция-обработчик имеет сигнатуру: fn(p_data JSON) RETURNS JSON.
CREATE TABLE pgerp.ui_actions (
    action_name   VARCHAR(100) PRIMARY KEY,
    function_name REGPROC NOT NULL,
    description   VARCHAR(255),
    is_system     BOOLEAN NOT NULL DEFAULT FALSE,
    everyone      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE pgerp.forms (
    form_name     VARCHAR(50) PRIMARY KEY,
    title         VARCHAR(200) NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    cancel_action VARCHAR(100) REFERENCES pgerp.ui_actions(action_name),
    folder        VARCHAR(100)
);

CREATE TABLE pgerp.form_components (
    id             SERIAL PRIMARY KEY,
    form_name      VARCHAR(50) NOT NULL REFERENCES pgerp.forms(form_name) ON DELETE CASCADE,
    sort_order     INT NOT NULL,
    component_type VARCHAR(20) NOT NULL,
    component_name VARCHAR(50) NOT NULL,
    label          VARCHAR(200),
    action_event   VARCHAR(100) REFERENCES pgerp.ui_actions(action_name),
    master_field   VARCHAR(50),
    tab            VARCHAR(100),
    options        JSONB,
    UNIQUE (form_name, component_name)
);

-- Колонки таблиц. Привязаны к действию-источнику данных: любая таблица,
-- использующая это действие, получает одинаковый набор колонок.
CREATE TABLE pgerp.grid_columns (
    action_name   VARCHAR(100) NOT NULL REFERENCES pgerp.ui_actions(action_name) ON DELETE CASCADE,
    display_order INT NOT NULL,
    field_name    VARCHAR(50) NOT NULL,
    column_title  VARCHAR(100) NOT NULL,
    cell_type     VARCHAR(20) NOT NULL DEFAULT 'text',
    sort_column   VARCHAR(63),
    PRIMARY KEY (action_name, field_name),
    CHECK (cell_type IN ('text', 'datetime', 'number', 'money', 'badge'))
);

-- Кнопки в строках таблицы. Привязаны к действию-источнику данных, как и колонки.
-- При нажатии вызывается row_action с {"id": <id строки>}.
CREATE TABLE pgerp.grid_row_actions (
    source_action VARCHAR(100) NOT NULL REFERENCES pgerp.ui_actions(action_name) ON DELETE CASCADE,
    sort_order    INT NOT NULL,
    row_action    VARCHAR(100) NOT NULL REFERENCES pgerp.ui_actions(action_name),
    label         VARCHAR(50) NOT NULL,
    style         VARCHAR(20) NOT NULL DEFAULT 'default',
    PRIMARY KEY (source_action, row_action),
    CHECK (style IN ('default', 'danger'))
);

CREATE TABLE pgerp.menu_items (
    id         BIGSERIAL PRIMARY KEY,
    parent_id  BIGINT REFERENCES pgerp.menu_items(id) ON DELETE CASCADE,
    sort_order INT NOT NULL,
    title      VARCHAR(200) NOT NULL,
    form_name  VARCHAR(50) REFERENCES pgerp.forms(form_name) ON UPDATE CASCADE ON DELETE SET NULL,
    CHECK (trim(title) <> '')
);
CREATE INDEX menu_items_parent_id_sort_order_idx ON pgerp.menu_items USING btree (parent_id, sort_order);
CREATE INDEX menu_items_form_name_idx ON pgerp.menu_items USING btree (form_name);

CREATE TABLE pgerp.languages (
    code       VARCHAR(10) PRIMARY KEY,
    title      VARCHAR(100) NOT NULL,
    is_source  BOOLEAN NOT NULL DEFAULT FALSE,
    -- Язык по умолчанию: его видит каждый, кто сам не выбрал другой. Исходный язык текстов (на нём написаны
    -- метаданные и сообщения в коде) — is_source. Оба — английский; переводы — с английского на другие языки
    is_default BOOLEAN NOT NULL DEFAULT FALSE,
    sort_order INT NOT NULL DEFAULT 0,
    CHECK (code ~ '^[a-z]{2,3}$')
);
CREATE UNIQUE INDEX languages_source_key ON pgerp.languages USING btree (is_source) WHERE is_source;
CREATE UNIQUE INDEX languages_default_key ON pgerp.languages USING btree (is_default) WHERE is_default;

CREATE TABLE pgerp.themes (
    code       VARCHAR(20) PRIMARY KEY,
    title      VARCHAR(100) NOT NULL,
    sort_order INT NOT NULL DEFAULT 0,
    CHECK (code ~ '^[a-z][a-z0-9-]*$')
);

CREATE TABLE pgerp.users (
    id                   BIGSERIAL PRIMARY KEY,
    login                VARCHAR(50) NOT NULL UNIQUE,
    full_name            VARCHAR(200),
    password_hash        TEXT NOT NULL,
    is_active            BOOLEAN NOT NULL DEFAULT TRUE,
    must_change_password BOOLEAN NOT NULL DEFAULT TRUE,
    failed_attempts      INT NOT NULL DEFAULT 0,
    locked_until         TIMESTAMPTZ,
    last_login_at        TIMESTAMPTZ,
    created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
    lang                 VARCHAR(10) REFERENCES pgerp.languages(code) ON UPDATE CASCADE ON DELETE SET NULL,
    -- Тема пользователя: по умолчанию светлая; NULL — «Как в системе» (выбор в переключателе)
    theme                VARCHAR(20) DEFAULT 'light' REFERENCES pgerp.themes(code) ON UPDATE CASCADE ON DELETE SET NULL,
    CHECK (login ~ '^[a-z0-9][a-z0-9_.@-]*$')
);

CREATE TABLE pgerp.roles (
    id        BIGSERIAL PRIMARY KEY,
    role_name VARCHAR(50) NOT NULL UNIQUE,
    title     VARCHAR(200) NOT NULL,
    CHECK (role_name ~ '^[a-z_][a-z0-9_]*$'),
    CHECK (trim(title) <> '')
);

CREATE TABLE pgerp.user_roles (
    id      BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES pgerp.users(id) ON DELETE CASCADE,
    role_id BIGINT NOT NULL REFERENCES pgerp.roles(id) ON DELETE CASCADE,
    UNIQUE (user_id, role_id)
);
CREATE INDEX user_roles_role_id_idx ON pgerp.user_roles USING btree (role_id);

CREATE TABLE pgerp.role_forms (
    id        BIGSERIAL PRIMARY KEY,
    role_id   BIGINT NOT NULL REFERENCES pgerp.roles(id) ON DELETE CASCADE,
    form_name VARCHAR(50) NOT NULL REFERENCES pgerp.forms(form_name) ON UPDATE CASCADE ON DELETE CASCADE,
    UNIQUE (role_id, form_name)
);
CREATE INDEX role_forms_form_name_idx ON pgerp.role_forms USING btree (form_name);

CREATE TABLE pgerp.translations (
    id          BIGSERIAL PRIMARY KEY,
    lang        VARCHAR(10) NOT NULL REFERENCES pgerp.languages(code) ON UPDATE CASCADE ON DELETE CASCADE,
    source      TEXT NOT NULL,
    translation TEXT NOT NULL,
    is_template BOOLEAN GENERATED ALWAYS AS ((source ~ '%'::text)) STORED,
    UNIQUE (lang, source),
    CHECK (source <> ''),
    CHECK (translation <> '')
);
CREATE INDEX translations_lang_idx ON pgerp.translations USING btree (lang) WHERE is_template;

-- ---------------------------------------------------------------------
-- Функции
-- ---------------------------------------------------------------------
SET LOCAL check_function_bodies = off;  -- функции ссылаются друг на друга и на представления ниже

-- Параметры пагинации из запроса таблицы: {"page": 1, "limit": 10}
CREATE FUNCTION pgerp.ui_page_param(p_data JSON, p_key VARCHAR, p_default INT, p_max INT)
RETURNS INT AS $$
    SELECT CASE
               WHEN p_data->>p_key ~ '^\d{1,6}$' THEN LEAST(GREATEST((p_data->>p_key)::INT, 1), p_max)
               ELSE p_default
           END;
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_format_money(p_value NUMERIC)
RETURNS TEXT AS $$
    -- Фиксированные разделители в шаблоне, затем замена на русские
    SELECT translate(to_char(p_value, 'FM999,999,999,999,990.00'), ',.', ' ,');
$$ LANGUAGE sql IMMUTABLE;

-- Идентификатор из текста или NULL
CREATE FUNCTION pgerp.ui_parse_id(p_text TEXT)
RETURNS BIGINT AS $$
    SELECT CASE WHEN trim(p_text) ~ '^\d{1,18}$' THEN trim(p_text)::BIGINT END;
$$ LANGUAGE sql IMMUTABLE;

-- Денежная сумма из текста ("1 500,50", "99.9") или NULL
CREATE FUNCTION pgerp.ui_parse_money(p_text TEXT)
RETURNS NUMERIC AS $$
    SELECT CASE WHEN v ~ '^\d{1,10}(\.\d{1,2})?$' THEN v::NUMERIC END
    FROM (SELECT replace(replace(trim(p_text), ' ', ''), ',', '.') AS v) t;
$$ LANGUAGE sql IMMUTABLE;

-- Денежная сумма для поля ввода: "1500,50"
CREATE FUNCTION pgerp.ui_money_input(p_value NUMERIC)
RETURNS TEXT AS $$
    SELECT translate(p_value::TEXT, '.', ',');
$$ LANGUAGE sql IMMUTABLE;

-- Метки (колонки таблиц типа badge): цвет задают данные, а не CSS по коду значения.
-- Значение колонки badge — {label, tone}. Тоны (цвета для светлой и тёмной темы — в css/app.css):
--   neutral   — без цвета (по умолчанию)
--   accent    — синий: новое, в работе
--   attention — жёлтый: требует внимания
--   success   — зелёный: успешно завершено
--   done      — фиолетовый: продвинулось дальше
--   danger    — красный: ошибка, просрочено, проиграно
-- Тон хранят прикладные данные (например, колонка tone справочника) или вычисляет представление.

CREATE FUNCTION pgerp.ui_badge_tones()
RETURNS TEXT[] AS $$
    SELECT ARRAY['neutral', 'accent', 'attention', 'success', 'done', 'danger'];
$$ LANGUAGE sql IMMUTABLE;

-- Значение метки: подпись на языке пользователя и тон; неизвестный тон — neutral
CREATE FUNCTION pgerp.ui_badge(p_label TEXT, p_tone TEXT DEFAULT 'neutral')
RETURNS JSONB AS $$
    SELECT jsonb_build_object('label', pgerp.ui_t(p_label),
                              'tone', CASE WHEN p_tone = ANY (pgerp.ui_badge_tones()) THEN p_tone ELSE 'neutral' END);
$$ LANGUAGE sql STABLE;

-- Инструкция: команда и её параметры; параметры со значением NULL не передаются
CREATE FUNCTION pgerp.ui_instruction(p_command TEXT, p_params JSONB DEFAULT '{}')
RETURNS JSONB AS $$
    SELECT jsonb_build_object('command', p_command)
           || COALESCE((SELECT jsonb_object_agg(key, value)
                        FROM jsonb_each(p_params)
                        WHERE value <> 'null'::jsonb), '{}'::jsonb);
$$ LANGUAGE sql IMMUTABLE;

-- Успешный ответ с инструкциями. Инструкции выполняются по порядку;
-- NULL пропускается, массив инструкций разворачивается (удобно для условных групп).
CREATE FUNCTION pgerp.ui_ok(VARIADIC p_instructions JSONB[] DEFAULT '{}')
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'status', 'success',
        'ui_instructions', COALESCE(jsonb_agg(e.value ORDER BY i.n, e.n), '[]'::jsonb))
    FROM unnest(p_instructions) WITH ORDINALITY AS i(value, n)
    CROSS JOIN LATERAL jsonb_array_elements(
        CASE WHEN jsonb_typeof(i.value) = 'array' THEN i.value ELSE jsonb_build_array(i.value) END
    ) WITH ORDINALITY AS e(value, n)
    WHERE i.value IS NOT NULL;
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_message(p_text TEXT)
RETURNS JSONB AS $$
    SELECT ui_instruction('show_message', jsonb_build_object('text', p_text));
$$ LANGUAGE sql IMMUTABLE;

-- Подтверждение: при согласии вызывается p_action с p_data
CREATE FUNCTION pgerp.ui_confirm(p_text TEXT, p_action VARCHAR, p_data JSONB, p_confirm_label TEXT DEFAULT NULL)
RETURNS JSONB AS $$
    SELECT ui_instruction('confirm', jsonb_build_object(
        'text', p_text, 'action', p_action, 'data', p_data, 'confirm_label', p_confirm_label));
$$ LANGUAGE sql IMMUTABLE;

-- Открыть форму; p_select — режим выбора из списка ({value_field, display_field, fill})
CREATE FUNCTION pgerp.ui_open_form(p_form VARCHAR, p_data JSONB DEFAULT NULL, p_title TEXT DEFAULT NULL,
                             p_select JSONB DEFAULT NULL, p_modal BOOLEAN DEFAULT TRUE)
RETURNS JSONB AS $$
    SELECT ui_instruction('open_form', jsonb_build_object(
        'form', p_form, 'modal', p_modal, 'title', p_title, 'data', p_data, 'select', p_select));
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_close_form()
RETURNS JSONB AS $$
    SELECT ui_instruction('close_form');
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_clear_form()
RETURNS JSONB AS $$
    SELECT ui_instruction('clear_form');
$$ LANGUAGE sql IMMUTABLE;

-- Заполнить поля этой формы или другой открытой формы p_form
CREATE FUNCTION pgerp.ui_set_values(p_values JSONB, p_form VARCHAR DEFAULT NULL)
RETURNS JSONB AS $$
    SELECT ui_instruction('set_values', jsonb_build_object('values', p_values, 'form', p_form));
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_set_title(p_title TEXT)
RETURNS JSONB AS $$
    SELECT ui_instruction('set_title', jsonb_build_object('title', p_title));
$$ LANGUAGE sql IMMUTABLE;

-- Перечитать таблицу; p_keep_page — остаться на текущей странице
CREATE FUNCTION pgerp.ui_refresh_grid(p_grid VARCHAR, p_keep_page BOOLEAN DEFAULT FALSE)
RETURNS JSONB AS $$
    SELECT ui_instruction('refresh_grid', jsonb_build_object('grid', p_grid, 'keep_page', p_keep_page));
$$ LANGUAGE sql IMMUTABLE;

-- Универсальное действие "Отмена/Закрыть" для кнопок модальных форм.
CREATE FUNCTION pgerp.ui_form_close(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN ui_ok(ui_close_form());
END;
$$ LANGUAGE plpgsql;

-- Очистить поля этой формы (или другой открытой формы — через ui_set_values)
CREATE FUNCTION pgerp.ui_clear_fields(VARIADIC p_fields TEXT[])
RETURNS JSONB AS $$
    SELECT ui_set_values(jsonb_object_agg(f, '')) FROM unnest(p_fields) AS f;
$$ LANGUAGE sql IMMUTABLE;

-- Ошибка для пользователя; инструкции выполняются клиентом перед показом текста
CREATE FUNCTION pgerp.ui_error(p_message TEXT, VARIADIC p_instructions JSONB[] DEFAULT '{}')
RETURNS VOID AS $$
BEGIN
    RAISE EXCEPTION USING
        MESSAGE = p_message,
        ERRCODE = 'U0001',
        DETAIL  = (ui_ok(VARIADIC p_instructions)->'ui_instructions')::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Дата из поля формы: ГГГГ-ММ-ДД (поле с календарём) или ДД.ММ.ГГГГ; иначе NULL
CREATE FUNCTION pgerp.ui_parse_date(p_text TEXT)
RETURNS DATE AS $$
DECLARE
    v_text TEXT := trim(p_text);
BEGIN
    IF v_text ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN to_date(v_text, 'YYYY-MM-DD');
    ELSIF v_text ~ '^\d{2}\.\d{2}\.\d{4}$' THEN
        RETURN to_date(v_text, 'DD.MM.YYYY');
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;  -- несуществующая дата, например 31.02.2026
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Текст поля формы без пробелов по краям; пустое поле — NULL
CREATE FUNCTION pgerp.ui_text(p_data JSON, p_field TEXT)
RETURNS TEXT AS $$
    SELECT NULLIF(trim(p_data->>p_field), '');
$$ LANGUAGE sql IMMUTABLE;

-- Запись ещё не сохранялась: в форме нет id
CREATE FUNCTION pgerp.ui_is_new(p_data JSON)
RETURNS BOOLEAN AS $$
    SELECT ui_text(p_data, 'id') IS NULL;
$$ LANGUAGE sql IMMUTABLE;

-- Пользователь уже согласился в окне подтверждения (см. ui_confirm)
CREATE FUNCTION pgerp.ui_confirmed(p_data JSON)
RETURNS BOOLEAN AS $$
    SELECT COALESCE(p_data->>'confirmed' = 'true', FALSE);
$$ LANGUAGE sql IMMUTABLE;

-- Проверка ввода: если условие ложно или NULL — ошибка для пользователя (RAISE EXCEPTION).
-- NULL считается нарушением, поэтому v_text ~ '...' заодно проверяет, что поле заполнено.
CREATE FUNCTION pgerp.ui_require(p_ok BOOLEAN, p_message TEXT)
RETURNS VOID AS $$
BEGIN
    IF p_ok IS NOT TRUE THEN
        RAISE EXCEPTION '%', p_message;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Формы без папки — в конце списка
CREATE FUNCTION pgerp.ui_form_list(p_data JSON)
RETURNS JSON AS $$
BEGIN
    RETURN json_build_object(
        'status', 'success',
        'forms', COALESCE((
            SELECT json_agg(json_build_object('name', form_name, 'title', title, 'folder', folder,
                                              'solution', pgerp.solution_of('form', form_name))
                            ORDER BY folder NULLS LAST, title)
            FROM pgerp.forms), '[]'::json),
        'actions', COALESCE((
            SELECT json_agg(json_build_object('name', action_name, 'description', description,
                                              'solution', pgerp.solution_of('action', action_name))
                            ORDER BY action_name)
            FROM pgerp.ui_actions
            WHERE NOT is_system), '[]'::json));
END;
$$ LANGUAGE plpgsql;

-- Структура формы: {"form": {"name", "title", "components": [...]}}
CREATE FUNCTION pgerp.ui_form_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_form_name VARCHAR := p_data->>'form';
    v_form      JSON;
BEGIN
    SELECT json_build_object(
               'name', f.form_name,
               'title', f.title,
               'folder', f.folder,
               'cancel', f.cancel_action,
               'components', COALESCE((
                   SELECT json_agg(json_build_object(
                              'type', c.component_type,
                              'name', c.component_name,
                              'label', c.label,
                              'action', c.action_event,
                              'master', c.master_field,
                              'tab', c.tab,
                              'options', c.options)
                          ORDER BY c.sort_order)
                   FROM pgerp.form_components c
                   WHERE c.form_name = f.form_name), '[]'::json))
    INTO v_form
    FROM pgerp.forms f
    WHERE f.form_name = v_form_name;

    IF v_form IS NULL THEN
        RAISE EXCEPTION 'Form "%" not found', v_form_name;
    END IF;

    RETURN json_build_object('status', 'success', 'form', v_form);
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.ui_form_delete(p_data JSON)
RETURNS JSON AS $$
BEGIN
    DELETE FROM pgerp.forms WHERE form_name = p_data->>'form';
    PERFORM ui_require(FOUND, format('Form "%s" not found', p_data->>'form'));

    RETURN ui_ok();
END;
$$ LANGUAGE plpgsql;

-- {"action": "my_app_item_save"} -> {"action", "function", "description", "source"}
-- Отдаётся код только зарегистрированных в erp.ui_actions функций.
CREATE FUNCTION pgerp.ui_action_source(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_action pgerp.ui_actions%ROWTYPE;
BEGIN
    SELECT * INTO v_action
    FROM pgerp.ui_actions
    WHERE action_name = p_data->>'action';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Action "%" is not registered', p_data->>'action';
    END IF;

    RETURN json_build_object(
        'status', 'success',
        'action', v_action.action_name,
        'function', v_action.function_name::REGPROCEDURE::TEXT,
        'description', v_action.description,
        'source', pg_get_functiondef(v_action.function_name));
END;
$$ LANGUAGE plpgsql;

-- Колонки теперь сообщают клиенту, можно ли по ним сортировать.
CREATE FUNCTION pgerp.ui_grid_columns(p_action VARCHAR)
RETURNS JSON AS $$
    SELECT COALESCE(json_agg(json_build_object(
               'field', field_name,
               'title', column_title,
               'type', cell_type,
               'sortable', sort_column IS NOT NULL)
           ORDER BY display_order), '[]'::json)
    FROM pgerp.grid_columns
    WHERE action_name = p_action;
$$ LANGUAGE sql STABLE;

-- Проверенная сортировка: запрошенное поле, если оно сортируемое, иначе поле по умолчанию.
CREATE FUNCTION pgerp.ui_grid_sort(p_action VARCHAR, p_data JSON, p_default_field VARCHAR, p_default_dir VARCHAR)
RETURNS TABLE (field VARCHAR, dir VARCHAR, sort_column VARCHAR) AS $$
    SELECT c.field_name,
           CASE WHEN lower(p_data->>'sort_dir') IN ('asc', 'desc') AND c.field_name = p_data->>'sort_field'
                THEN lower(p_data->>'sort_dir')
                ELSE p_default_dir
           END,
           c.sort_column
    FROM pgerp.grid_columns c
    WHERE c.action_name = p_action
      AND c.sort_column IS NOT NULL
      AND c.field_name IN (p_data->>'sort_field', p_default_field)
    -- Запрошенное поле приоритетнее поля по умолчанию
    ORDER BY c.field_name = p_data->>'sort_field' DESC NULLS LAST
    LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.ui_grid_row_actions(p_action VARCHAR)
RETURNS JSON AS $$
    SELECT COALESCE(json_agg(json_build_object(
               'action', row_action,
               'label', label,
               'style', style)
           ORDER BY sort_order), '[]'::json)
    FROM pgerp.grid_row_actions
    WHERE source_action = p_action;
$$ LANGUAGE sql STABLE;

-- Отправить инструкции во все открытые браузеры
CREATE FUNCTION pgerp.ui_push(VARIADIC p_instructions JSONB[])
RETURNS VOID AS $$
    SELECT pgerp.ui_push_to(NULL, VARIADIC p_instructions);
$$ LANGUAGE sql;

-- Один уровень дерева: дети узла p_data->>'parent_id' (пусто — корни), по алфавиту.
-- Узел — строка таблицы целиком и поля label, has_children.
CREATE FUNCTION pgerp.ui_tree_level(p_data JSON, p_source REGCLASS,
                                    p_label_column VARCHAR DEFAULT 'name',
                                    p_parent_column VARCHAR DEFAULT 'parent_id')
RETURNS JSON AS $$
DECLARE
    v_nodes JSON;
BEGIN
    EXECUTE format(
        'SELECT json_agg(to_jsonb(t) || jsonb_build_object(
                    ''label'', t.%1$I,
                    ''has_children'', EXISTS (SELECT 1 FROM %2$s c WHERE c.%3$I = t.id))
                ORDER BY t.%1$I, t.id)
         FROM %2$s t
         WHERE t.%3$I IS NOT DISTINCT FROM $1',
        p_label_column, p_source, p_parent_column)
    INTO v_nodes
    USING pgerp.ui_parse_id(p_data->>'parent_id');

    RETURN json_build_object('status', 'success', 'nodes', COALESCE(v_nodes, '[]'::json));
END;
$$ LANGUAGE plpgsql STABLE;

-- Универсальный источник данных таблицы: пагинация, сортировка, фильтр по мастеру и поиск.
--   p_source        — таблица/представление (задаётся кодом функции-источника, не клиентом);
--   p_master_column — колонка связи с мастером; без master_id в запросе строк нет (новая запись);
--   p_search_column — колонка поиска, p_search — искомый текст (обычно значение поля-фильтра).
-- В строки попадают все поля источника: кроме колонок таблицы они доступны действиям
-- строк и режиму выбора (например, подстановка значения в поле формы).
CREATE FUNCTION pgerp.ui_grid_page(p_action VARCHAR, p_data JSON, p_source REGCLASS,
                                   p_master_column VARCHAR DEFAULT NULL,
                                   p_default_sort VARCHAR DEFAULT 'id', p_default_dir VARCHAR DEFAULT 'desc',
                                   p_search_column VARCHAR DEFAULT NULL, p_search TEXT DEFAULT NULL,
                                   p_filters JSONB DEFAULT NULL)
RETURNS JSON AS $$
DECLARE
    v_limit       INT    := ui_page_param(p_data, 'limit', 10, 100);
    v_page        INT    := ui_page_param(p_data, 'page', 1, 1000000);
    v_master      BIGINT := ui_parse_id(p_data->>'master_id');
    v_search      TEXT   := NULLIF(trim(p_search), '');
    v_where       TEXT   := 'TRUE';
    v_filter      RECORD;
    v_sort        RECORD;
    v_sort_column TEXT;
    v_sort_dir    TEXT;
    v_total_rows  INT;
    v_total_pages INT;
    v_rows        JSON;
BEGIN
    IF p_master_column IS NOT NULL THEN
        v_where := format('%I = $1', p_master_column);
    END IF;
    -- strpos, а не LIKE: символы % и _ в тексте поиска ищутся как есть
    IF p_search_column IS NOT NULL AND v_search IS NOT NULL THEN
        v_where := v_where || format(' AND strpos(lower(%I::TEXT), lower($4)) > 0', p_search_column);
    END IF;
    -- Сравнение в тексте: значение из формы — строка, колонка может быть числом или датой
    FOR v_filter IN SELECT key, value FROM jsonb_each(COALESCE(p_filters, '{}')) LOOP
        IF jsonb_typeof(v_filter.value) = 'array' THEN
            v_where := v_where || format(' AND %I::TEXT = ANY (%L::TEXT[])', v_filter.key,
                                         ARRAY(SELECT jsonb_array_elements_text(v_filter.value)));
        ELSIF jsonb_typeof(v_filter.value) NOT IN ('null', 'object') AND NULLIF(v_filter.value #>> '{}', '') IS NOT NULL THEN
            v_where := v_where || format(' AND %I::TEXT = %L', v_filter.key, v_filter.value #>> '{}');
        END IF;
    END LOOP;

    SELECT * INTO v_sort FROM ui_grid_sort(p_action, p_data, p_default_sort, p_default_dir);
    v_sort_column := COALESCE(v_sort.sort_column, 'id');
    v_sort_dir    := COALESCE(v_sort.dir, p_default_dir);

    EXECUTE format('SELECT count(*) FROM %s WHERE %s', p_source, v_where)
    INTO v_total_rows
    USING v_master, NULL::INT, NULL::INT, v_search;

    v_total_pages := GREATEST(CEIL(v_total_rows::NUMERIC / v_limit)::INT, 1);
    v_page := LEAST(v_page, v_total_pages);

    EXECUTE format('SELECT json_agg(t) FROM (SELECT * FROM %s WHERE %s ORDER BY %I %s, id %s LIMIT $2 OFFSET $3) t',
                   p_source, v_where, v_sort_column, v_sort_dir, v_sort_dir)
    INTO v_rows
    USING v_master, v_limit, (v_page - 1) * v_limit, v_search;

    RETURN json_build_object(
        'status', 'success',
        'meta', json_build_object(
            'current_page', v_page,
            'limit', v_limit,
            'total_rows', v_total_rows,
            'total_pages', v_total_pages,
            'sort', json_build_object('field', COALESCE(v_sort.field, 'id'), 'dir', v_sort_dir)),
        'columns', ui_grid_columns(p_action),
        'row_actions', ui_grid_row_actions(p_action),
        'rows', COALESCE(v_rows, '[]'::json));
END;
$$ LANGUAGE plpgsql;

-- Вставка уровня меню из редактора; p_path — путь к уровню для текста ошибок ("Моё приложение › Справочники")
CREATE FUNCTION pgerp.ui_menu_insert(p_items JSON, p_parent BIGINT, p_path TEXT)
RETURNS VOID AS $$
DECLARE
    v_item  RECORD;
    v_title TEXT;
    v_form  TEXT;
    v_path  TEXT;
    v_id    BIGINT;
BEGIN
    IF p_items IS NULL OR json_typeof(p_items) = 'null' THEN
        RETURN;
    END IF;
    PERFORM ui_require(json_typeof(p_items) = 'array', 'Menu: items must be passed as a list');

    FOR v_item IN
        SELECT i, n FROM json_array_elements(p_items) WITH ORDINALITY AS t(i, n)
    LOOP
        v_title := NULLIF(trim(v_item.i->>'title'), '');
        v_form  := NULLIF(v_item.i->>'form', '');
        v_path  := concat_ws(' › ', p_path, COALESCE(v_title, format('item No. %s', v_item.n)));

        PERFORM ui_require(v_title IS NOT NULL, format('Menu, %s: enter the item title', v_path));
        PERFORM ui_require(length(v_title) <= 200, format('Menu, %s: the title is longer than 200 characters', v_path));
        PERFORM ui_require(v_form IS NULL OR EXISTS (SELECT 1 FROM pgerp.forms WHERE form_name = v_form),
                           format('Menu, %s: form "%s" does not exist', v_path, v_form));

        INSERT INTO pgerp.menu_items (parent_id, sort_order, title, form_name)
        VALUES (p_parent, v_item.n, v_title, v_form)
        RETURNING id INTO v_id;

        PERFORM pgerp.ui_menu_insert(v_item.i->'items', v_id, v_path);
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- {"items": [{title, form, items: [...]}]} — меню заменяется целиком
CREATE FUNCTION pgerp.ui_menu_save(p_data JSON)
RETURNS JSON AS $$
BEGIN
    -- Два одновременных сохранения не должны сложить два меню
    LOCK TABLE pgerp.menu_items IN EXCLUSIVE MODE;
    DELETE FROM pgerp.menu_items;
    PERFORM pgerp.ui_menu_insert(COALESCE(p_data->'items', '[]'::json), NULL, NULL);

    RETURN ui_ok(ui_message('Menu saved'));
END;
$$ LANGUAGE plpgsql;

-- Единый перечень типов компонентов (раньше был продублирован в ui_form_save).
CREATE FUNCTION pgerp.ui_component_types()
RETURNS VARCHAR[] AS $$
    SELECT ARRAY['label', 'input', 'date', 'hidden', 'display', 'lookup', 'combobox', 'button', 'grid',
                 'board', 'timer', 'tree', 'chart']::VARCHAR[];
$$ LANGUAGE sql IMMUTABLE;

-- Элементы выпадающего списка из таблицы или представления: {status, items: [{id, label}]},
-- по алфавиту подписи. Имена колонок задаёт код функции-источника, не клиент.
CREATE FUNCTION pgerp.ui_combo_items(p_source REGCLASS,
                                     p_label_column VARCHAR DEFAULT 'name',
                                     p_value_column VARCHAR DEFAULT 'id')
RETURNS JSON AS $$
DECLARE
    v_items JSON;
BEGIN
    EXECUTE format(
        'SELECT json_agg(json_build_object(''id'', t.%2$I, ''label'', t.%1$I) ORDER BY t.%1$I, t.%2$I)
         FROM %3$s t',
        p_label_column, p_value_column, p_source)
    INTO v_items;

    RETURN json_build_object('status', 'success', 'items', COALESCE(v_items, '[]'::json));
END;
$$ LANGUAGE plpgsql STABLE;

-- Данные графика из таблицы или представления: {status, format, labels: [...], series: [{name, values: [...]}]}.
-- p_label_column — подписи по оси X (категории или даты), p_value_columns — ряды (по колонке на ряд),
-- p_series_names — названия рядов на исходном языке (переводятся; без них — имена колонок),
-- p_order_column — порядок точек (по умолчанию — по подписи), p_format — number | money | percent.
-- Строки — какие видит пользователь: фильтры и видимость задаёт представление. Имена колонок — из кода, не от клиента
CREATE FUNCTION pgerp.ui_chart(p_source REGCLASS,
                               p_label_column VARCHAR,
                               p_value_columns VARCHAR[],
                               p_series_names VARCHAR[] DEFAULT NULL,
                               p_order_column VARCHAR DEFAULT NULL,
                               p_format VARCHAR DEFAULT 'number')
RETURNS JSON AS $$
DECLARE
    v_order  TEXT := format('t.%I', COALESCE(p_order_column, p_label_column));
    v_series TEXT;
    v_result JSON;
BEGIN
    PERFORM ui_require(cardinality(p_value_columns) > 0, 'Chart: specify at least one value column');
    PERFORM ui_require(p_format IN ('number', 'money', 'percent'), format('Chart: unknown format %s', p_format));
    SELECT string_agg(format('json_build_object(''name'', %L, ''values'', COALESCE(json_agg(t.%I ORDER BY %s), ''[]''))',
                             COALESCE(pgerp.ui_t(p_series_names[i]), c), c, v_order), ', ' ORDER BY i)
    INTO v_series
    FROM unnest(p_value_columns) WITH ORDINALITY AS u(c, i);
    EXECUTE format('SELECT json_build_object(''status'', ''success'', ''format'', %L,
                                             ''labels'', COALESCE(json_agg(t.%I ORDER BY %s), ''[]''),
                                             ''series'', json_build_array(%s))
                    FROM %s t', p_format, p_label_column, v_order, v_series, p_source)
    INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- Сохранение формы: выпадающий список требует действие-источник и может быть мастером таблицы
CREATE FUNCTION pgerp.ui_form_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_form_name  VARCHAR := p_data->>'name';
    v_title      VARCHAR := ui_text(p_data, 'title');
    v_folder     VARCHAR := ui_text(p_data, 'folder');
    v_components JSON    := COALESCE(p_data->'components', '[]'::json);
    v_comp       RECORD;
BEGIN
    PERFORM ui_require(v_form_name ~ '^[a-z_][a-z0-9_]*$',
                       'Form name: lowercase Latin letters, digits and "_"');

    FOR v_comp IN
        SELECT c->>'type' AS type, c->>'name' AS name, NULLIF(c->>'action', '') AS action,
               NULLIF(c->>'master', '') AS master, c->'options' AS options, n
        FROM json_array_elements(v_components) WITH ORDINALITY AS t(c, n)
    LOOP
        PERFORM ui_require(v_comp.type = ANY (ui_component_types()),
                           format('Component No. %s: unknown type "%s"', v_comp.n, v_comp.type));
        PERFORM ui_require(v_comp.name ~ '^[a-z_][a-z0-9_]*$',
                           format('Component No. %s: name must be lowercase Latin letters, digits and "_"', v_comp.n));

        IF v_comp.type = 'grid' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Table "%": select the data source action', v_comp.name;
        END IF;
        IF v_comp.type = 'tree' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Tree "%": select the data source action', v_comp.name;
        END IF;
        IF v_comp.type = 'combobox' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Drop-down list "%": select the item source action', v_comp.name;
        END IF;
        IF v_comp.type = 'lookup' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Lookup field "%": select the action that opens the list', v_comp.name;
        END IF;
        IF v_comp.type = 'timer' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Timer "%": select an action', v_comp.name;
        END IF;
        IF v_comp.type = 'chart' AND v_comp.action IS NULL THEN
            RAISE EXCEPTION 'Chart "%": select the data source action', v_comp.name;
        END IF;

        IF v_comp.action IS NOT NULL THEN
            PERFORM ui_require(
                EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_comp.action AND NOT is_system),
                format('Component "%s": action "%s" is not registered', v_comp.name, v_comp.action));
        END IF;
        IF v_comp.type = 'grid' AND v_comp.master IS NOT NULL THEN
            PERFORM ui_require(
                EXISTS (SELECT 1 FROM json_array_elements(v_components) c
                        WHERE c->>'name' = v_comp.master AND c->>'type' IN ('input', 'hidden', 'lookup', 'combobox', 'tree')),
                format('Table "%s": master field "%s" not found among the form fields', v_comp.name, v_comp.master));
        END IF;
        IF v_comp.options IS NOT NULL AND json_typeof(v_comp.options) NOT IN ('object', 'null') THEN
            RAISE EXCEPTION 'Component "%": options must be a JSON object', v_comp.name;
        END IF;
    END LOOP;

    PERFORM ui_require(
        (SELECT count(*) = count(DISTINCT c->>'name') FROM json_array_elements(v_components) c),
        'Component names must be unique');

    INSERT INTO pgerp.forms (form_name, title, folder)
    VALUES (v_form_name, COALESCE(v_title, v_form_name), v_folder)
    ON CONFLICT (form_name) DO UPDATE
        SET title = EXCLUDED.title, folder = EXCLUDED.folder, updated_at = now();

    DELETE FROM pgerp.form_components WHERE form_name = v_form_name;

    INSERT INTO pgerp.form_components
        (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options)
    SELECT v_form_name, n, c->>'type', c->>'name', c->>'label', NULLIF(c->>'action', ''),
           CASE WHEN c->>'type' = 'grid' THEN NULLIF(c->>'master', '') END,
           CASE WHEN c->>'type' NOT IN ('hidden', 'timer') THEN NULLIF(trim(c->>'tab'), '') END,
           CASE WHEN json_typeof(c->'options') = 'object' AND (c->'options')::jsonb <> '{}' THEN (c->'options')::jsonb END
    FROM json_array_elements(v_components) WITH ORDINALITY AS t(c, n);

    RETURN ui_ok(ui_message(format('Form "%s" saved', v_form_name)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.ui_user()
RETURNS VARCHAR AS $$
    SELECT NULLIF(current_setting('pgerp.user', TRUE), '');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.ui_user_id()
RETURNS BIGINT AS $$
    SELECT id FROM pgerp.users WHERE login = pgerp.ui_user();
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.auth_has_role(p_user_id BIGINT, p_role VARCHAR)
RETURNS BOOLEAN AS $$
    SELECT EXISTS (
        SELECT 1 FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
        WHERE ur.user_id = p_user_id AND r.role_name = p_role);
$$ LANGUAGE sql STABLE;

-- У текущего пользователя есть роль p_role
CREATE FUNCTION pgerp.ui_has_role(p_role VARCHAR)
RETURNS BOOLEAN AS $$
    SELECT pgerp.auth_has_role(pgerp.ui_user_id(), p_role);
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.auth_is_admin(p_user_id BIGINT)
RETURNS BOOLEAN AS $$
    SELECT pgerp.auth_has_role(p_user_id, 'admin');
$$ LANGUAGE sql STABLE;

-- Есть ли активный администратор — последнего нельзя отключить или лишить роли
CREATE FUNCTION pgerp.auth_admin_exists()
RETURNS BOOLEAN AS $$
    SELECT EXISTS (SELECT 1 FROM pgerp.users u WHERE u.is_active AND pgerp.auth_is_admin(u.id));
$$ LANGUAGE sql STABLE;

-- Формы пользователя: выданные его ролям и открываемые из них, транзитивно.
-- Администратору — все. Смена пароля — всем.
CREATE FUNCTION pgerp.auth_user_forms(p_user_id BIGINT)
RETURNS SETOF VARCHAR AS $$
    WITH RECURSIVE granted(form_name) AS (
        SELECT f.form_name::VARCHAR
        FROM pgerp.forms f
        WHERE pgerp.auth_is_admin(p_user_id)
           OR f.form_name = 'password_change'
           OR EXISTS (SELECT 1
                      FROM pgerp.role_forms rf
                      JOIN pgerp.user_roles ur ON ur.role_id = rf.role_id
                      WHERE ur.user_id = p_user_id AND rf.form_name = f.form_name)
        UNION
        SELECT af.form_name
        FROM granted g
        JOIN pgerp.form_actions fa ON fa.form_name = g.form_name
        JOIN pgerp.action_forms af ON af.action_name = fa.action_name
    )
    SELECT form_name FROM granted;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.auth_form_allowed(p_user_id BIGINT, p_form VARCHAR)
RETURNS BOOLEAN AS $$
    SELECT p_form IN (SELECT pgerp.auth_user_forms(p_user_id));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.auth_action_allowed(p_user_id BIGINT, p_action VARCHAR)
RETURNS BOOLEAN AS $$
    SELECT pgerp.auth_is_admin(p_user_id)
        OR EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = p_action AND everyone)
        OR EXISTS (SELECT 1
                   FROM pgerp.form_actions fa
                   WHERE fa.action_name = p_action
                     AND fa.form_name IN (SELECT pgerp.auth_user_forms(p_user_id)));
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.auth_hash(p_password TEXT)
RETURNS TEXT AS $$
    SELECT crypt(p_password, gen_salt('bf', 10));
$$ LANGUAGE sql VOLATILE;

CREATE FUNCTION pgerp.auth_password_ok(p_password TEXT, p_hash TEXT)
RETURNS BOOLEAN AS $$
    SELECT crypt(COALESCE(p_password, ''), p_hash) = p_hash;
$$ LANGUAGE sql STABLE;

-- Требования к новому паролю
CREATE FUNCTION pgerp.auth_check_password(p_login VARCHAR, p_password TEXT)
RETURNS VOID AS $$
BEGIN
    PERFORM ui_require(length(p_password) >= 8, 'The password must be at least 8 characters long');
    PERFORM ui_require(length(p_password) <= 72, 'The password must be at most 72 characters long');
    PERFORM ui_require(lower(p_password) <> lower(p_login), 'The password must not match the login');
END;
$$ LANGUAGE plpgsql;

-- Завершить сеанс: клиент выходит и открывает страницу входа
CREATE FUNCTION pgerp.ui_logout()
RETURNS JSONB AS $$
    SELECT pgerp.ui_instruction('logout');
$$ LANGUAGE sql STABLE;

-- p_forms — формы, которые показываются (NULL — все). Пункт с недоступной формой остаётся группой, если
-- в нём есть доступные подпункты; пустые группы скрываются.
CREATE FUNCTION pgerp.ui_menu_level(p_parent BIGINT, p_forms VARCHAR[])
RETURNS JSON AS $$
BEGIN
    RETURN COALESCE((
        SELECT json_agg(json_build_object('id', t.id, 'title', t.title, 'form', t.form, 'items', t.items)
                        ORDER BY t.sort_order, t.id)
        FROM (
            SELECT m.id, m.title, m.sort_order,
                   CASE WHEN p_forms IS NULL OR m.form_name = ANY (p_forms) THEN m.form_name END AS form,
                   pgerp.ui_menu_level(m.id, p_forms) AS items
            FROM pgerp.menu_items m
            WHERE m.parent_id IS NOT DISTINCT FROM p_parent
        ) t
        WHERE p_forms IS NULL OR t.form IS NOT NULL OR json_array_length(t.items) > 0), '[]'::json);
END;
$$ LANGUAGE plpgsql STABLE;

-- Сообщение {"form", "ui_instructions", "users"?}: users — логины адресатов, без него — всем.
-- Пустой список адресатов — ничего не отправляется.
CREATE FUNCTION pgerp.ui_push_send(p_form VARCHAR, p_users VARCHAR[], p_instructions JSONB[])
RETURNS VOID AS $$
DECLARE
    v_message TEXT;
BEGIN
    IF p_users IS NOT NULL AND cardinality(p_users) = 0 THEN
        RETURN;
    END IF;
    v_message := (jsonb_build_object(
        'form', p_form,
        'ui_instructions', pgerp.ui_ok(VARIADIC p_instructions)->'ui_instructions')
        || CASE WHEN p_users IS NOT NULL THEN jsonb_build_object('users', p_users) ELSE '{}' END)::TEXT;
    IF octet_length(v_message) > 7900 THEN
        RAISE EXCEPTION 'ui_push: the message exceeds 8000 bytes — send less data in it';
    END IF;
    PERFORM pg_notify('erp_ui', v_message);
END;
$$ LANGUAGE plpgsql;

-- Отправить инструкции в браузеры, где открыта форма p_form (NULL — во все)
CREATE FUNCTION pgerp.ui_push_to(p_form VARCHAR, VARIADIC p_instructions JSONB[])
RETURNS VOID AS $$
    SELECT pgerp.ui_push_send(p_form, NULL, p_instructions);
$$ LANGUAGE sql;

-- Во вкладки пользователя с логином p_user
CREATE FUNCTION pgerp.ui_push_to_user(p_user VARCHAR, VARIADIC p_instructions JSONB[])
RETURNS VOID AS $$
    SELECT pgerp.ui_push_send(NULL, ARRAY[lower(p_user)]::VARCHAR[], p_instructions);
$$ LANGUAGE sql;

-- Во вкладки активных пользователей с ролью p_role
CREATE FUNCTION pgerp.ui_push_to_role(p_role VARCHAR, VARIADIC p_instructions JSONB[])
RETURNS VOID AS $$
    SELECT pgerp.ui_push_send(NULL, ARRAY(
        SELECT u.login FROM pgerp.users u
        WHERE u.is_active AND pgerp.auth_has_role(u.id, p_role))::VARCHAR[], p_instructions);
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.ui_password_change(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_user   pgerp.users%ROWTYPE;
    v_old    TEXT := p_data->>'old_password';
    v_new    TEXT := p_data->>'new_password';
    v_repeat TEXT := p_data->>'new_password_repeat';
BEGIN
    SELECT * INTO v_user FROM pgerp.users WHERE id = pgerp.ui_user_id() FOR UPDATE;
    PERFORM ui_require(FOUND, 'User not found');
    PERFORM ui_require(pgerp.auth_password_ok(v_old, v_user.password_hash), 'The current password is incorrect');
    PERFORM ui_require(v_new = v_repeat, 'The new password and its repetition do not match');
    PERFORM pgerp.auth_check_password(v_user.login, v_new);
    PERFORM ui_require(v_new <> v_old, 'The new password must differ from the current one');

    UPDATE pgerp.users
    SET password_hash = pgerp.auth_hash(v_new), must_change_password = FALSE
    WHERE id = v_user.id;

    RETURN ui_ok(ui_close_form(), ui_message('Password changed'));
END;
$$ LANGUAGE plpgsql;

-- Отмена: при обязательной смене пароля — выход, иначе закрыть окно
CREATE FUNCTION pgerp.ui_password_change_cancel(p_data JSON)
RETURNS JSON AS $$
    SELECT CASE WHEN (SELECT must_change_password FROM pgerp.users WHERE id = pgerp.ui_user_id())
                THEN ui_ok(pgerp.ui_logout())
                ELSE ui_ok(ui_close_form()) END;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.users_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('users_page', p_data, 'pgerp.users_v', NULL, 'login', 'asc',
                        'login', p_data->>'user_filter');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.user_roles_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('user_roles_page', p_data, 'pgerp.user_roles_v', 'user_id', 'title', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.user_states_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'items', json_build_array(
        json_build_object('id', 'active',   'label', 'Active'),
        json_build_object('id', 'disabled', 'label', 'Disabled')));
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.user_new_open(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_ok(ui_open_form('user', p_title => 'New user',
                              p_data => jsonb_build_object('state', 'active')));
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.user_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_user pgerp.users%ROWTYPE;
BEGIN
    SELECT * INTO v_user FROM pgerp.users WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'User not found — it may have been deleted');

    RETURN ui_ok(ui_open_form('user',
        p_title => v_user.login,
        p_data  => jsonb_build_object(
            'id', v_user.id::TEXT,
            'login', v_user.login,
            'full_name', COALESCE(v_user.full_name, ''),
            'state', CASE WHEN v_user.is_active THEN 'active' ELSE 'disabled' END)));
END;
$$ LANGUAGE plpgsql;

-- Новый пароль задаёт администратор — пользователь сменит его при входе.
-- Новый пользователь остаётся в карточке: на вкладке «Роли» ему назначают роли.
CREATE FUNCTION pgerp.user_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id        BIGINT  := ui_parse_id(p_data->>'id');
    v_login     VARCHAR := lower(ui_text(p_data, 'login'));
    v_full_name VARCHAR := ui_text(p_data, 'full_name');
    v_state     VARCHAR := ui_text(p_data, 'state');
    v_password  TEXT    := NULLIF(p_data->>'password', '');
BEGIN
    PERFORM ui_require(v_login ~ '^[a-z0-9][a-z0-9_.@-]*$',
                       'Login: Latin letters, digits and _ . @ -, starting with a letter or digit');
    PERFORM ui_require(length(v_login) <= 50, 'Login must be at most 50 characters long');
    PERFORM ui_require(v_state IN ('active', 'disabled'), 'Select the account status');
    PERFORM ui_require(
        NOT EXISTS (SELECT 1 FROM pgerp.users WHERE login = v_login AND id IS DISTINCT FROM v_id),
        format('Login “%s” is already taken', v_login));
    IF v_password IS NOT NULL THEN
        PERFORM pgerp.auth_check_password(v_login, v_password);
    END IF;

    IF ui_is_new(p_data) THEN
        PERFORM ui_require(v_password IS NOT NULL, 'Set a password — the user will change it at the first sign-in');
        INSERT INTO pgerp.users (login, full_name, password_hash, is_active)
        VALUES (v_login, v_full_name, pgerp.auth_hash(v_password), v_state = 'active')
        RETURNING id INTO v_id;

        RETURN ui_ok(
            ui_set_values(jsonb_build_object('id', v_id::TEXT, 'password', '')),
            ui_set_title(v_login),
            ui_refresh_grid('user_roles_grid'),
            ui_refresh_grid('users_grid', p_keep_page => TRUE),
            ui_message('User created. Assign roles on the “Roles” tab'));
    END IF;

    PERFORM ui_require(v_state = 'active' OR v_id IS DISTINCT FROM pgerp.ui_user_id(),
                       'You cannot disable your own account');
    UPDATE pgerp.users
    SET login     = v_login,
        full_name = v_full_name,
        is_active = v_state = 'active',
        -- Включение снимает и блокировку после неудачных попыток входа
        failed_attempts = CASE WHEN v_state = 'active' THEN 0 ELSE failed_attempts END,
        locked_until    = CASE WHEN v_state = 'active' THEN NULL ELSE locked_until END,
        password_hash        = COALESCE(pgerp.auth_hash(v_password), password_hash),
        must_change_password = must_change_password OR v_password IS NOT NULL
    WHERE id = v_id;
    PERFORM ui_require(FOUND, 'User not found — it may have been deleted');
    PERFORM ui_require(pgerp.auth_admin_exists(), 'At least one active administrator must remain');

    RETURN ui_ok(ui_close_form(), ui_refresh_grid('users_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.user_role_add(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_user_id BIGINT := ui_parse_id(p_data->>'id');
    v_role_id BIGINT := ui_parse_id(p_data->>'role_to_add');
BEGIN
    PERFORM ui_require(v_user_id IS NOT NULL, 'Save the user first');
    PERFORM ui_require(v_role_id IS NOT NULL, 'Select a role');
    INSERT INTO pgerp.user_roles (user_id, role_id) VALUES (v_user_id, v_role_id)
    ON CONFLICT (user_id, role_id) DO NOTHING;

    RETURN ui_ok(
        ui_set_values(jsonb_build_object('role_to_add', '')),
        ui_refresh_grid('user_roles_grid'),
        ui_refresh_grid('users_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.user_role_remove(p_data JSON)
RETURNS JSON AS $$
BEGIN
    DELETE FROM pgerp.user_roles WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(pgerp.auth_admin_exists(), 'At least one active administrator must remain');

    RETURN ui_ok(
        ui_refresh_grid('user_roles_grid', p_keep_page => TRUE),
        ui_refresh_grid('users_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.roles_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('roles_page', p_data, 'pgerp.roles_v', NULL, 'title', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.role_forms_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('role_forms_page', p_data, 'pgerp.role_forms_v', 'role_id', 'title', 'asc');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.forms_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('pgerp.forms_combo_v', 'label', 'form_name');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.role_new_open(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_ok(ui_open_form('role', p_title => 'New role'));
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.role_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_role pgerp.roles%ROWTYPE;
BEGIN
    SELECT * INTO v_role FROM pgerp.roles WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Role not found — it may have been deleted');

    RETURN ui_ok(ui_open_form('role',
        p_title => v_role.title,
        p_data  => jsonb_build_object(
            'id', v_role.id::TEXT,
            'role_name', v_role.role_name,
            'title', v_role.title)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.role_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id        BIGINT  := ui_parse_id(p_data->>'id');
    v_role_name VARCHAR := lower(ui_text(p_data, 'role_name'));
    v_title     VARCHAR := ui_text(p_data, 'title');
BEGIN
    PERFORM ui_require(v_role_name ~ '^[a-z_][a-z0-9_]*$',
                       'Role code: lowercase Latin letters, digits and "_"');
    PERFORM ui_require(v_title IS NOT NULL, 'Enter the role title');
    PERFORM ui_require(
        NOT EXISTS (SELECT 1 FROM pgerp.roles WHERE role_name = v_role_name AND id IS DISTINCT FROM v_id),
        format('A role with code “%s” already exists', v_role_name));

    IF ui_is_new(p_data) THEN
        INSERT INTO pgerp.roles (role_name, title) VALUES (v_role_name, v_title)
        RETURNING id INTO v_id;

        RETURN ui_ok(
            ui_set_values(jsonb_build_object('id', v_id::TEXT)),
            ui_set_title(v_title),
            ui_refresh_grid('role_forms_grid'),
            ui_refresh_grid('roles_grid', p_keep_page => TRUE),
            ui_message('Role created. Add the forms it grants access to'));
    END IF;

    PERFORM ui_require(
        NOT EXISTS (SELECT 1 FROM pgerp.roles WHERE id = v_id AND role_name = 'admin' AND v_role_name <> 'admin'),
        'The administrator role code cannot be changed');
    UPDATE pgerp.roles SET role_name = v_role_name, title = v_title WHERE id = v_id;
    PERFORM ui_require(FOUND, 'Role not found — it may have been deleted');

    RETURN ui_ok(ui_close_form(), ui_refresh_grid('roles_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.role_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_role pgerp.roles%ROWTYPE;
BEGIN
    SELECT * INTO v_role FROM pgerp.roles WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Role not found — it may have been deleted');
    PERFORM ui_require(v_role.role_name <> 'admin', 'The administrator role cannot be deleted');

    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(
            format('Delete role “%s”? Its users will lose access to its forms.', v_role.title),
            'role_delete', jsonb_build_object('id', v_role.id, 'confirmed', TRUE),
            p_confirm_label => 'Delete'));
    END IF;

    DELETE FROM pgerp.roles WHERE id = v_role.id;
    RETURN ui_ok(ui_refresh_grid('roles_grid', p_keep_page => TRUE),
                 ui_refresh_grid('users_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.role_form_add(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_role_id BIGINT  := ui_parse_id(p_data->>'id');
    v_form    VARCHAR := ui_text(p_data, 'form_to_add');
BEGIN
    PERFORM ui_require(v_role_id IS NOT NULL, 'Save the role first');
    PERFORM ui_require(v_form IS NOT NULL, 'Select a form');
    PERFORM ui_require(
        NOT EXISTS (SELECT 1 FROM pgerp.roles WHERE id = v_role_id AND role_name = 'admin'),
        'The administrator has access to all forms');
    INSERT INTO pgerp.role_forms (role_id, form_name) VALUES (v_role_id, v_form)
    ON CONFLICT (role_id, form_name) DO NOTHING;

    RETURN ui_ok(
        ui_set_values(jsonb_build_object('form_to_add', '')),
        ui_refresh_grid('role_forms_grid'),
        ui_refresh_grid('roles_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.role_form_remove(p_data JSON)
RETURNS JSON AS $$
BEGIN
    DELETE FROM pgerp.role_forms WHERE id = ui_parse_id(p_data->>'id');
    RETURN ui_ok(
        ui_refresh_grid('role_forms_grid', p_keep_page => TRUE),
        ui_refresh_grid('roles_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.i18n_source_lang()
RETURNS VARCHAR AS $$
    SELECT code FROM pgerp.languages WHERE is_source;
$$ LANGUAGE sql STABLE;

-- Код языка из запроса ("en", "en-US", "EN") → язык из pgerp.languages или NULL
CREATE FUNCTION pgerp.i18n_resolve(p_lang VARCHAR)
RETURNS VARCHAR AS $$
    SELECT code FROM pgerp.languages WHERE code = lower(split_part(split_part(p_lang, '-', 1), '_', 1));
$$ LANGUAGE sql STABLE;

-- Язык текущего действия (задаёт маршрутизатор); вне него — исходный
-- Язык по умолчанию (английский) видит каждый, кто сам не выбрал другой; не задан — исходный
CREATE FUNCTION pgerp.i18n_default_lang()
RETURNS VARCHAR AS $$
    SELECT COALESCE((SELECT code FROM pgerp.languages WHERE is_default), pgerp.i18n_source_lang());
$$ LANGUAGE sql STABLE;

-- Язык текущего действия (задаёт маршрутизатор); не задан — язык по умолчанию
CREATE FUNCTION pgerp.ui_lang()
RETURNS VARCHAR AS $$
    SELECT COALESCE(pgerp.i18n_resolve(NULLIF(current_setting('pgerp.lang', TRUE), '')), pgerp.i18n_default_lang());
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.i18n_is_source()
RETURNS BOOLEAN AS $$
    SELECT pgerp.ui_lang() = pgerp.i18n_source_lang();
$$ LANGUAGE sql STABLE;

-- Точный перевод: подписи, заголовки, пункты меню
CREATE FUNCTION pgerp.ui_t_exact(p_text TEXT)
RETURNS TEXT AS $$
    SELECT COALESCE(
        (SELECT t.translation FROM pgerp.translations t
         WHERE t.lang = pgerp.ui_lang() AND t.source = p_text AND NOT pgerp.i18n_is_source()),
        p_text);
$$ LANGUAGE sql STABLE;

-- Регулярное выражение шаблона: спецсимволы экранируются, плейсхолдеры format() и RAISE — группы
CREATE FUNCTION pgerp.i18n_template_regex(p_source TEXT)
RETURNS TEXT AS $$
    SELECT '^' || replace(
        regexp_replace(
            replace(regexp_replace(p_source, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g'), '%%', chr(1)),
            '%([0-9]+\$)?[sIL]?', '(.*?)', 'g'),
        chr(1), '%') || '$';
$$ LANGUAGE sql IMMUTABLE;

-- Перевод текста на язык действия: точный, иначе по шаблону с подстановками, иначе исходный текст
CREATE FUNCTION pgerp.ui_t(p_text TEXT)
RETURNS TEXT AS $$
DECLARE
    v_lang     VARCHAR := pgerp.ui_lang();
    v_template RECORD;
    v_args     TEXT[];
    v_result   TEXT;
BEGIN
    IF p_text IS NULL OR p_text = '' OR v_lang = pgerp.i18n_source_lang() THEN
        RETURN p_text;
    END IF;

    SELECT translation INTO v_result FROM pgerp.translations WHERE lang = v_lang AND source = p_text;
    IF FOUND THEN
        RETURN v_result;
    END IF;

    -- Длинные шаблоны первыми: они точнее
    FOR v_template IN
        SELECT source, translation FROM pgerp.translations
        WHERE lang = v_lang AND is_template
        ORDER BY length(source) DESC
    LOOP
        v_args := regexp_match(p_text, pgerp.i18n_template_regex(v_template.source));
        IF v_args IS NOT NULL THEN
            BEGIN
                RETURN format(v_template.translation,
                              VARIADIC ARRAY(SELECT pgerp.ui_t_exact(a)
                                             FROM unnest(v_args) WITH ORDINALITY AS u(a, n) ORDER BY n));
            EXCEPTION WHEN OTHERS THEN
                -- Перевод не подходит к числу подстановок — показываем исходный текст
                RETURN p_text;
            END;
        END IF;
    END LOOP;
    RETURN p_text;
END;
$$ LANGUAGE plpgsql STABLE;

-- Строковые значения ключей p_keys объекта
CREATE FUNCTION pgerp.i18n_keys(p_object JSONB, p_keys TEXT[], p_exact BOOLEAN)
RETURNS JSONB AS $$
DECLARE
    v_key TEXT;
BEGIN
    IF jsonb_typeof(p_object) IS DISTINCT FROM 'object' THEN
        RETURN p_object;
    END IF;
    FOREACH v_key IN ARRAY p_keys LOOP
        IF jsonb_typeof(p_object->v_key) = 'string' THEN
            p_object := jsonb_set(p_object, ARRAY[v_key], to_jsonb(
                CASE WHEN p_exact THEN pgerp.ui_t_exact(p_object->>v_key) ELSE pgerp.ui_t(p_object->>v_key) END));
        END IF;
    END LOOP;
    RETURN p_object;
END;
$$ LANGUAGE plpgsql STABLE;

-- То же для каждого объекта массива
CREATE FUNCTION pgerp.i18n_array(p_array JSONB, p_keys TEXT[], p_exact BOOLEAN)
RETURNS JSONB AS $$
    SELECT CASE WHEN jsonb_typeof(p_array) = 'array' THEN
        COALESCE((SELECT jsonb_agg(pgerp.i18n_keys(e, p_keys, p_exact) ORDER BY n)
                  FROM jsonb_array_elements(p_array) WITH ORDINALITY AS t(e, n)), '[]'::jsonb)
        ELSE p_array END;
$$ LANGUAGE sql STABLE;

-- Заменить массив p_key объекта переведённым
CREATE FUNCTION pgerp.i18n_set_array(p_object JSONB, p_key TEXT, p_keys TEXT[], p_exact BOOLEAN)
RETURNS JSONB AS $$
    SELECT CASE WHEN jsonb_typeof(p_object->p_key) = 'array'
                THEN jsonb_set(p_object, ARRAY[p_key], pgerp.i18n_array(p_object->p_key, p_keys, p_exact))
                ELSE p_object END;
$$ LANGUAGE sql STABLE;

-- Ответ действия: ошибка, инструкции, колонки и кнопки строк таблицы, элементы выпадающего списка
CREATE FUNCTION pgerp.i18n_response(p_result JSON)
RETURNS JSON AS $$
DECLARE
    v_result JSONB;
BEGIN
    IF p_result IS NULL OR pgerp.i18n_is_source() OR json_typeof(p_result) <> 'object' THEN
        RETURN p_result;
    END IF;
    v_result := pgerp.i18n_keys(p_result::jsonb, '{message}', FALSE);
    v_result := pgerp.i18n_set_array(v_result, 'ui_instructions', '{text,title,confirm_label}', FALSE);
    v_result := pgerp.i18n_set_array(v_result, 'columns', '{title}', TRUE);
    v_result := pgerp.i18n_set_array(v_result, 'row_actions', '{label}', TRUE);
    v_result := pgerp.i18n_set_array(v_result, 'items', '{label}', TRUE);
    RETURN v_result::json;
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Схемы прикладного кода: public и схемы установленных решений (pgerp.solutions.db_schema)
-- ---------------------------------------------------------------------
CREATE FUNCTION pgerp.app_schemas()
RETURNS VARCHAR[] AS $$
    SELECT ARRAY['public']::VARCHAR[] || COALESCE(ARRAY(
        SELECT s.db_schema FROM pgerp.solutions s
        WHERE s.db_schema <> 'public' AND to_regnamespace(s.db_schema) IS NOT NULL
        GROUP BY s.db_schema ORDER BY min(s.created_at), s.db_schema), '{}');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.app_schema_oids()
RETURNS OID[] AS $$
    SELECT ARRAY(SELECT to_regnamespace(n)::OID FROM unnest(pgerp.app_schemas()) AS n);
$$ LANGUAGE sql STABLE;

-- Путь поиска для кода решений: функции и таблицы решений вызываются без схемы
CREATE FUNCTION pgerp.app_search_path()
RETURNS TEXT AS $$
    SELECT (SELECT string_agg(format('%I', n), ', ') FROM unnest(pgerp.app_schemas()) AS n) || ', pgerp';
$$ LANGUAGE sql STABLE;

-- Таблица или представление прикладного кода по имени; нет — NULL
CREATE FUNCTION pgerp.app_rel(p_name TEXT)
RETURNS REGCLASS AS $$
    SELECT c.oid::REGCLASS
    FROM pg_class c
    JOIN unnest(pgerp.app_schema_oids()) WITH ORDINALITY AS s(oid, n) ON s.oid = c.relnamespace
    WHERE c.relname = p_name
    ORDER BY s.n
    LIMIT 1;
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.app_type(p_name TEXT)
RETURNS REGTYPE AS $$
    SELECT t.oid::REGTYPE
    FROM pg_type t
    JOIN unnest(pgerp.app_schema_oids()) WITH ORDINALITY AS s(oid, n) ON s.oid = t.typnamespace
    WHERE t.typname = p_name
    ORDER BY s.n
    LIMIT 1;
$$ LANGUAGE sql STABLE;

-- Функция действия имя(json) прикладного кода; нет — NULL
CREATE FUNCTION pgerp.app_action_fn(p_name TEXT)
RETURNS REGPROCEDURE AS $$
    SELECT p.oid::REGPROCEDURE
    FROM pg_proc p
    JOIN unnest(pgerp.app_schema_oids()) WITH ORDINALITY AS s(oid, n) ON s.oid = p.pronamespace
    WHERE p.proname = p_name AND p.pronargs = 1 AND p.proargtypes[0] = 'json'::regtype
    ORDER BY s.n
    LIMIT 1;
$$ LANGUAGE sql STABLE;

-- p_lang — язык клиента (Accept-Language); язык из настройки пользователя важнее.
-- Путь поиска — схемы установленных решений: их код вызывает свои функции и таблицы без схемы
CREATE FUNCTION pgerp.handle_ui_event(p_user VARCHAR, p_action VARCHAR, p_form_data JSON,
                                      p_lang VARCHAR DEFAULT NULL)
RETURNS JSON AS $$
DECLARE
    v_user         pgerp.users%ROWTYPE;
    v_action       pgerp.ui_actions%ROWTYPE;
    v_result       JSON;
    v_message      TEXT;
    v_state        TEXT;
    v_instructions TEXT;
BEGIN
    PERFORM set_config('search_path', pgerp.app_search_path(), TRUE);
    PERFORM set_config('pgerp.lang', COALESCE(pgerp.i18n_resolve(p_lang), ''), TRUE);

    SELECT * INTO v_user FROM pgerp.users WHERE login = p_user AND is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING MESSAGE = pgerp.ui_t('Session ended — please sign in again'), ERRCODE = 'U0002';
    END IF;
    -- До конца транзакции: обработчики, триггеры и ui_push видят пользователя и язык
    PERFORM set_config('pgerp.user', v_user.login, TRUE);
    IF v_user.lang IS NOT NULL THEN
        PERFORM set_config('pgerp.lang', v_user.lang, TRUE);
    END IF;

    SELECT * INTO v_action FROM pgerp.ui_actions WHERE action_name = p_action;
    IF NOT FOUND THEN
        RAISE EXCEPTION USING MESSAGE = pgerp.ui_t(format('Unknown action: %s', p_action));
    END IF;

    IF NOT v_action.everyone THEN
        IF v_user.must_change_password THEN
            RAISE EXCEPTION USING MESSAGE = pgerp.ui_t('Change your password to continue'),
                                  ERRCODE = 'U0003';
        END IF;
        IF NOT pgerp.auth_action_allowed(v_user.id, p_action) THEN
            RAISE EXCEPTION USING ERRCODE = 'U0003', MESSAGE = pgerp.ui_t(
                format('Access denied to action “%s”', COALESCE(v_action.description, p_action)));
        END IF;
    END IF;

    BEGIN
        -- regproc при выводе даёт корректно экранированное имя функции
        EXECUTE format('SELECT %s($1)', v_action.function_name) INTO v_result USING p_form_data;
    EXCEPTION
        WHEN SQLSTATE 'U0001' THEN
            GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_instructions = PG_EXCEPTION_DETAIL;
            RETURN pgerp.i18n_response(json_build_object(
                'status', 'error',
                'message', v_message,
                'ui_instructions', v_instructions::JSON));
        -- Ошибки ввода и доступа — на языке пользователя; изменения обработчика откатываются
        WHEN raise_exception OR SQLSTATE 'U0002' OR SQLSTATE 'U0003' THEN
            GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
            RAISE EXCEPTION USING MESSAGE = pgerp.ui_t(v_message), ERRCODE = v_state;
    END;
    RETURN pgerp.i18n_response(v_result);
END;
$$ LANGUAGE plpgsql;

-- Вход. Ошибка — в error_message (текст для пользователя), иначе логин и роли.
-- Неудачные попытки считаются; после 5 подряд вход закрыт на 5 минут.
CREATE FUNCTION pgerp.auth_login(p_login VARCHAR, p_password TEXT, p_lang VARCHAR DEFAULT NULL)
RETURNS TABLE (user_login VARCHAR, user_roles VARCHAR[], error_message TEXT) AS $$
DECLARE
    c_attempts CONSTANT INT      := 5;
    c_lock     CONSTANT INTERVAL := '5 minutes';
    v_user     pgerp.users%ROWTYPE;
BEGIN
    PERFORM set_config('pgerp.lang', COALESCE(pgerp.i18n_resolve(p_lang), ''), TRUE);

    SELECT * INTO v_user FROM pgerp.users u WHERE u.login = lower(trim(p_login)) FOR UPDATE;
    IF NOT FOUND THEN
        -- Время ответа как у существующего логина: по нему нельзя подобрать логины
        PERFORM pgerp.auth_hash(COALESCE(p_password, ''));
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[], pgerp.ui_t('Invalid login or password');
        RETURN;
    END IF;
    IF v_user.lang IS NOT NULL THEN
        PERFORM set_config('pgerp.lang', v_user.lang, TRUE);
    END IF;

    IF v_user.locked_until > now() THEN
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[], pgerp.ui_t(
            format('Too many failed sign-in attempts. Try again in %s min.',
                   ceil(extract(epoch FROM v_user.locked_until - now()) / 60)));
        RETURN;
    END IF;

    IF NOT pgerp.auth_password_ok(p_password, v_user.password_hash) THEN
        UPDATE pgerp.users u
        SET failed_attempts = CASE WHEN u.failed_attempts + 1 >= c_attempts THEN 0 ELSE u.failed_attempts + 1 END,
            locked_until    = CASE WHEN u.failed_attempts + 1 >= c_attempts THEN now() + c_lock END
        WHERE u.id = v_user.id;
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[], pgerp.ui_t('Invalid login or password');
        RETURN;
    END IF;

    IF NOT v_user.is_active THEN
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[],
            pgerp.ui_t('The account is disabled — contact the administrator');
        RETURN;
    END IF;

    UPDATE pgerp.users u
    SET failed_attempts = 0, locked_until = NULL, last_login_at = now()
    WHERE u.id = v_user.id;

    RETURN QUERY
    SELECT v_user.login,
           ARRAY(SELECT r.role_name FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
                 WHERE ur.user_id = v_user.id ORDER BY r.role_name)::VARCHAR[],
           NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Форма на языке пользователя: заголовок, подписи, вкладки, пустой пункт списка.
-- "source": true — исходные тексты для редактора форм
CREATE FUNCTION pgerp.ui_form_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_form    VARCHAR := p_data->>'form';
    v_user_id BIGINT  := pgerp.ui_user_id();
    v_title   VARCHAR;
    v_result  JSONB;
BEGIN
    IF v_user_id IS NOT NULL THEN
        IF (SELECT must_change_password FROM pgerp.users WHERE id = v_user_id) THEN
            IF v_form IS DISTINCT FROM 'password_change' THEN
                RAISE EXCEPTION 'Change your password to continue' USING ERRCODE = 'U0003';
            END IF;
        ELSIF NOT pgerp.auth_form_allowed(v_user_id, v_form) THEN
            SELECT title INTO v_title FROM pgerp.forms WHERE form_name = v_form;
            RAISE EXCEPTION USING ERRCODE = 'U0003',
                MESSAGE = format('Access denied to form “%s”', COALESCE(v_title, v_form));
        END IF;
    END IF;

    v_result := pgerp.ui_form_get(p_data)::jsonb;
    IF (p_data->>'source')::BOOLEAN IS TRUE OR pgerp.i18n_is_source() THEN
        RETURN v_result::json;
    END IF;
    v_result := jsonb_set(v_result, '{form}', pgerp.i18n_keys(v_result->'form', '{title}', TRUE));
    v_result := jsonb_set(v_result, '{form,components}', COALESCE((
        SELECT jsonb_agg(
                   pgerp.i18n_keys(c, '{label,tab}', TRUE)
                   || CASE WHEN jsonb_typeof(c->'options') = 'object'
                           THEN jsonb_build_object('options', pgerp.i18n_keys(c->'options', '{placeholder}', TRUE))
                           ELSE '{}' END
                   ORDER BY n)
        FROM jsonb_array_elements(v_result->'form'->'components') WITH ORDINALITY AS t(c, n)), '[]'::jsonb));
    RETURN v_result::json;
END;
$$ LANGUAGE plpgsql;

-- Пункты меню с подпунктами на языке пользователя
CREATE FUNCTION pgerp.i18n_menu(p_items JSONB)
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(
               pgerp.i18n_keys(i, '{title}', TRUE) || jsonb_build_object('items', pgerp.i18n_menu(i->'items'))
               ORDER BY n), '[]'::jsonb)
    FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(i, n);
$$ LANGUAGE sql STABLE;

-- В меню — формы, выданные ролям пользователя напрямую. "source": true — исходные тексты для редактора меню
CREATE FUNCTION pgerp.ui_menu_get(p_data JSON)
RETURNS JSON AS $$
    WITH menu AS (
        SELECT pgerp.ui_menu_level(NULL,
            CASE WHEN pgerp.ui_user_id() IS NULL OR pgerp.auth_is_admin(pgerp.ui_user_id()) THEN NULL
                 ELSE ARRAY(SELECT rf.form_name
                            FROM pgerp.role_forms rf
                            JOIN pgerp.user_roles ur ON ur.role_id = rf.role_id
                            WHERE ur.user_id = pgerp.ui_user_id())::VARCHAR[] END)::jsonb AS items
    )
    SELECT json_build_object('status', 'success', 'items',
        CASE WHEN (p_data->>'source')::BOOLEAN IS TRUE OR pgerp.i18n_is_source() THEN items
             ELSE pgerp.i18n_menu(items) END)
    FROM menu;
$$ LANGUAGE sql STABLE;

-- Язык пользователя из переключателя в шапке
CREATE FUNCTION pgerp.ui_session_lang_set(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_lang VARCHAR := pgerp.i18n_resolve(p_data->>'lang');
BEGIN
    PERFORM ui_require(v_lang IS NOT NULL, format('Language “%s” is not supported', p_data->>'lang'));
    UPDATE pgerp.users SET lang = v_lang WHERE id = pgerp.ui_user_id();
    RETURN ui_ok();
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.roles_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('pgerp.roles_combo_v', 'title');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.translations_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('translations_page', p_data, 'pgerp.translations', NULL, 'source', 'asc',
                        'source', p_data->>'translation_filter');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.translation_missing_page(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_grid_page('translation_missing_page', p_data, 'pgerp.translation_missing_v', NULL, 'source', 'asc',
                        'source', p_data->>'translation_filter');
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.target_languages_combo(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_combo_items('pgerp.target_languages_v', 'title', 'code');
$$ LANGUAGE sql STABLE;

CREATE FUNCTION pgerp.translation_new_open(p_data JSON)
RETURNS JSON AS $$
    SELECT ui_ok(ui_open_form('translation', p_title => 'New translation',
        p_data => jsonb_build_object('lang', (SELECT code FROM pgerp.target_languages_v ORDER BY sort_order, code LIMIT 1))));
$$ LANGUAGE sql;

CREATE FUNCTION pgerp.translation_edit_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_row pgerp.translations%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM pgerp.translations WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Translation not found — it may have been deleted');
    RETURN ui_ok(ui_open_form('translation', p_title => 'Translation',
        p_data => jsonb_build_object('id', v_row.id::TEXT, 'lang', v_row.lang,
                                     'source', v_row.source, 'translation', v_row.translation)));
END;
$$ LANGUAGE plpgsql;

-- «Перевести» в списке текстов без перевода: язык и исходный текст уже заполнены
CREATE FUNCTION pgerp.translation_missing_open(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_row RECORD;
BEGIN
    SELECT * INTO v_row FROM pgerp.translation_missing_v WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'The text is already translated or no longer used');
    RETURN ui_ok(ui_open_form('translation', p_title => 'New translation',
        p_data => jsonb_build_object('lang', v_row.lang, 'source', v_row.source)));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.translation_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_id          BIGINT  := ui_parse_id(p_data->>'id');
    v_lang        VARCHAR := ui_text(p_data, 'lang');
    v_source      TEXT    := NULLIF(p_data->>'source', '');
    v_translation TEXT    := NULLIF(trim(p_data->>'translation'), '');
    v_count       INT;
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.target_languages_v WHERE code = v_lang), 'Select the translation language');
    PERFORM ui_require(v_source IS NOT NULL, 'Enter the source text');
    PERFORM ui_require(v_translation IS NOT NULL, 'Enter the translation');

    -- Перевод шаблона должен принять столько же подстановок, сколько их в исходном тексте
    v_count := (SELECT count(*) FROM regexp_matches(replace(v_source, '%%', ''), '%([0-9]+\$)?[sIL]?', 'g'));
    IF v_count > 0 THEN
        BEGIN
            PERFORM format(v_translation, VARIADIC array_fill('x'::TEXT, ARRAY[v_count]));
        EXCEPTION WHEN OTHERS THEN
            PERFORM ui_require(FALSE, format(
                'The source text has %s placeholders. Use %%s or %%1$s, %%2$s, … in the translation', v_count));
        END;
    END IF;

    IF ui_is_new(p_data) THEN
        INSERT INTO pgerp.translations (lang, source, translation) VALUES (v_lang, v_source, v_translation)
        ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;
    ELSE
        PERFORM ui_require(
            NOT EXISTS (SELECT 1 FROM pgerp.translations WHERE lang = v_lang AND source = v_source AND id <> v_id),
            'A translation of this text into this language already exists');
        UPDATE pgerp.translations SET lang = v_lang, source = v_source, translation = v_translation WHERE id = v_id;
        PERFORM ui_require(FOUND, 'Translation not found — it may have been deleted');
    END IF;

    RETURN ui_ok(
        ui_close_form(),
        ui_refresh_grid('translations_grid', p_keep_page => TRUE),
        ui_refresh_grid('translation_missing_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

CREATE FUNCTION pgerp.translation_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_row pgerp.translations%ROWTYPE;
BEGIN
    SELECT * INTO v_row FROM pgerp.translations WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Translation not found — it may have been deleted');

    IF NOT ui_confirmed(p_data) THEN
        RETURN ui_ok(ui_confirm(format('Delete translation “%s”?', v_row.translation), 'translation_delete',
                                jsonb_build_object('id', v_row.id, 'confirmed', TRUE),
                                p_confirm_label => 'Delete'));
    END IF;
    DELETE FROM pgerp.translations WHERE id = v_row.id;
    RETURN ui_ok(
        ui_refresh_grid('translations_grid', p_keep_page => TRUE),
        ui_refresh_grid('translation_missing_grid', p_keep_page => TRUE));
END;
$$ LANGUAGE plpgsql;

-- Сеанс: пользователь, язык, тема и списки для переключателей в шапке
CREATE FUNCTION pgerp.ui_session_get(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object(
        'status', 'success',
        'user', json_build_object(
            'login', u.login,
            'full_name', u.full_name,
            'roles', ARRAY(SELECT r.role_name FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
                           WHERE ur.user_id = u.id ORDER BY r.role_name),
            'is_admin', pgerp.auth_is_admin(u.id),
            'must_change_password', u.must_change_password,
            'lang', pgerp.ui_lang(),
            'theme', u.theme,
            -- Первый вход администратора: решения ещё не выбирались — клиент предложит установить
            'setup_required', pgerp.auth_is_admin(u.id)
                              AND NOT EXISTS (SELECT 1 FROM pgerp.settings WHERE key = 'solutions_setup')
                              AND NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE NOT is_core)),
        'languages', (SELECT json_agg(json_build_object('code', code, 'title', title) ORDER BY sort_order, code)
                      FROM pgerp.languages),
        'themes', (SELECT json_agg(json_build_object('code', code, 'title', pgerp.ui_t_exact(title))
                                   ORDER BY sort_order, code)
                   FROM pgerp.themes))
    FROM pgerp.users u
    WHERE u.id = pgerp.ui_user_id();
$$ LANGUAGE sql STABLE;

-- Тема пользователя из переключателя в шапке; пустое значение — как в системе
CREATE FUNCTION pgerp.ui_session_theme_set(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_theme VARCHAR := NULLIF(p_data->>'theme', '');
BEGIN
    PERFORM ui_require(v_theme IS NULL OR EXISTS (SELECT 1 FROM pgerp.themes WHERE code = v_theme),
                       format('Theme “%s” is not supported', v_theme));
    UPDATE pgerp.users SET theme = v_theme WHERE id = pgerp.ui_user_id();
    RETURN ui_ok();
END;
$$ LANGUAGE plpgsql;

-- Имя пользователя для показа: имя из учётной записи, иначе логин
CREATE FUNCTION pgerp.ui_user_name()
RETURNS VARCHAR AS $$
    SELECT COALESCE(NULLIF(trim(full_name), ''), login) FROM pgerp.users WHERE id = pgerp.ui_user_id();
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Проверки, вызывающие функции (после функций)
-- ---------------------------------------------------------------------
ALTER TABLE pgerp.form_components ADD CONSTRAINT form_components_component_type_check CHECK (((component_type)::text = ANY ((pgerp.ui_component_types())::text[])));

-- ---------------------------------------------------------------------
-- Представления
-- ---------------------------------------------------------------------
-- Действия, которые вызывает форма
CREATE VIEW pgerp.form_actions AS
SELECT form_name, action_event AS action_name
FROM pgerp.form_components
WHERE action_event IS NOT NULL
UNION
SELECT c.form_name, r.row_action
FROM pgerp.form_components c
JOIN pgerp.grid_row_actions r ON r.source_action = c.action_event
WHERE c.component_type = 'grid'
UNION
SELECT form_name, cancel_action
FROM pgerp.forms
WHERE cancel_action IS NOT NULL;

-- Формы, которые открывает действие: ui_open_form('имя', ...) в коде его функции.
-- Имя формы, вычисляемое во время работы, сюда не попадает — такую форму выдают роли явно.
CREATE VIEW pgerp.action_forms AS
-- prosrc — текст каталога с правилом сортировки "C": имя приводится к обычному
SELECT DISTINCT a.action_name, m[1]::VARCHAR COLLATE "default" AS form_name
FROM pgerp.ui_actions a
JOIN pg_proc p ON p.oid = a.function_name::OID
CROSS JOIN LATERAL regexp_matches(p.prosrc, 'ui_open_form\s*\(\s*''([a-z_][a-z0-9_]*)''', 'g') AS m
WHERE EXISTS (SELECT 1 FROM pgerp.forms f WHERE f.form_name = m[1]);

CREATE VIEW pgerp.users_v AS
SELECT u.id, u.login, u.full_name,
       (SELECT string_agg(pgerp.ui_t_exact(r.title), ', ' ORDER BY r.title)
        FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
        WHERE ur.user_id = u.id) AS roles,
       pgerp.ui_t_exact(CASE WHEN NOT u.is_active          THEN 'Disabled'
                             WHEN u.locked_until > now()   THEN 'Sign-in locked'
                             WHEN u.must_change_password   THEN 'Must change password'
                             ELSE 'Active' END) AS status,
       to_char(u.last_login_at, 'DD.MM.YYYY HH24:MI') AS last_login,
       u.last_login_at
FROM pgerp.users u;

CREATE VIEW pgerp.user_roles_v AS
SELECT ur.id, ur.user_id, r.role_name, r.title
FROM pgerp.user_roles ur
JOIN pgerp.roles r ON r.id = ur.role_id;

-- Формы для выбора: "Папка / Заголовок"
CREATE VIEW pgerp.forms_combo_v AS
SELECT form_name, concat_ws(' / ', pgerp.ui_t_exact(folder), pgerp.ui_t_exact(title)) AS label
FROM pgerp.forms;

CREATE VIEW pgerp.roles_v AS
SELECT r.id, r.role_name, pgerp.ui_t_exact(r.title) AS title,
       (SELECT count(*) FROM pgerp.user_roles ur WHERE ur.role_id = r.id) AS users_count,
       CASE WHEN r.role_name = 'admin' THEN pgerp.ui_t_exact('All forms')
            ELSE (SELECT string_agg(pgerp.ui_t_exact(f.title), ', ' ORDER BY f.title)
                  FROM pgerp.role_forms rf JOIN pgerp.forms f ON f.form_name = rf.form_name
                  WHERE rf.role_id = r.id) END AS forms
FROM pgerp.roles r;

CREATE VIEW pgerp.role_forms_v AS
SELECT rf.id, rf.role_id, rf.form_name, pgerp.ui_t_exact(f.title) AS title, pgerp.ui_t_exact(f.folder) AS folder
FROM pgerp.role_forms rf
JOIN pgerp.forms f ON f.form_name = rf.form_name;

CREATE VIEW pgerp.roles_combo_v AS
SELECT id, pgerp.ui_t_exact(title) AS title FROM pgerp.roles;

-- Метаданные и строковые литералы с кириллицей в коде функций схем public и pgerp
-- (сообщения ui_require, ui_message, шаблоны format()). Склеенные из частей тексты сюда
-- попадают частями — их обработчик переводит сам через ui_t().

-- Тексты без перевода на каждый язык, кроме исходного. id — устойчивый хеш языка и текста

CREATE VIEW pgerp.target_languages_v AS
SELECT code, title, sort_order FROM pgerp.languages WHERE NOT is_source;

-- ---------------------------------------------------------------------
-- Данные ядра: языки, темы, действия, формы, меню, роли, первый администратор, переводы
-- ---------------------------------------------------------------------
INSERT INTO pgerp.languages (code, title, is_source, is_default, sort_order) VALUES
    ('en', 'English', TRUE,  TRUE,  1),
    ('ru', 'Русский', FALSE, FALSE, 2);

INSERT INTO pgerp.themes (code, title, sort_order) VALUES
    ('dark',  'Dark',  2),
    ('light', 'Light', 1);

INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('action_source',            'pgerp.ui_action_source',          'Source code of the action function',    TRUE,  FALSE),
    ('form_close',               'pgerp.ui_form_close',             'Close the modal form',          FALSE, FALSE),
    ('form_delete',              'pgerp.ui_form_delete',            'Delete form',                   TRUE,  FALSE),
    ('form_get',                 'pgerp.ui_form_open',              'Form structure',                  TRUE,  TRUE),
    ('form_list',                'pgerp.ui_form_list',              'List of forms and actions',           TRUE,  FALSE),
    ('form_save',                'pgerp.ui_form_save',              'Save form',                 TRUE,  FALSE),
    ('forms_combo',              'pgerp.forms_combo',               'List: forms',                    FALSE, FALSE),
    ('menu_get',                 'pgerp.ui_menu_get',               'Application menu',                  TRUE,  TRUE),
    ('menu_save',                'pgerp.ui_menu_save',              'Save menu',                  TRUE,  FALSE),
    ('password_change',          'pgerp.ui_password_change',        'Change own password',              FALSE, TRUE),
    ('password_change_cancel',   'pgerp.ui_password_change_cancel', 'Cancel password change',              FALSE, TRUE),
    ('role_delete',              'pgerp.role_delete',               'Delete role',                    FALSE, FALSE),
    ('role_edit_open',           'pgerp.role_edit_open',            'Role card',                    FALSE, FALSE),
    ('role_form_add',            'pgerp.role_form_add',             'Add a form to a role',          FALSE, FALSE),
    ('role_form_remove',         'pgerp.role_form_remove',          'Remove a form from a role',           FALSE, FALSE),
    ('role_forms_page',          'pgerp.role_forms_page',           'Table: role forms',              FALSE, FALSE),
    ('role_new_open',            'pgerp.role_new_open',             'New role',                       FALSE, FALSE),
    ('role_save',                'pgerp.role_save',                 'Save role',                  FALSE, FALSE),
    ('roles_combo',              'pgerp.roles_combo',               'List: roles',                     FALSE, FALSE),
    ('roles_page',               'pgerp.roles_page',                'Table: roles',                    FALSE, FALSE),
    ('session_get',              'pgerp.ui_session_get',            'Current user',             TRUE,  TRUE),
    ('session_lang_set',         'pgerp.ui_session_lang_set',       'Change user language',         TRUE,  TRUE),
    ('session_theme_set',        'pgerp.ui_session_theme_set',      'Change user theme',          TRUE,  TRUE),
    ('target_languages_combo',   'pgerp.target_languages_combo',    'List: translation languages',           FALSE, FALSE),
    ('translation_delete',       'pgerp.translation_delete',        'Delete translation',                FALSE, FALSE),
    ('translation_edit_open',    'pgerp.translation_edit_open',     'Translation card',                FALSE, FALSE),
    ('translation_missing_open', 'pgerp.translation_missing_open',  'Translate an untranslated text',      FALSE, FALSE),
    ('translation_missing_page', 'pgerp.translation_missing_page',  'Table: untranslated texts',     FALSE, FALSE),
    ('translation_new_open',     'pgerp.translation_new_open',      'New translation',                    FALSE, FALSE),
    ('translation_save',         'pgerp.translation_save',          'Save translation',              FALSE, FALSE),
    ('translations_page',        'pgerp.translations_page',         'Table: translations',                FALSE, FALSE),
    ('user_edit_open',           'pgerp.user_edit_open',            'User card',            FALSE, FALSE),
    ('user_new_open',            'pgerp.user_new_open',             'New user',               FALSE, FALSE),
    ('user_role_add',            'pgerp.user_role_add',             'Assign a role to a user',     FALSE, FALSE),
    ('user_role_remove',         'pgerp.user_role_remove',          'Remove a role from a user',       FALSE, FALSE),
    ('user_roles_page',          'pgerp.user_roles_page',           'Table: user roles',       FALSE, FALSE),
    ('user_save',                'pgerp.user_save',                 'Save user',          FALSE, FALSE),
    ('user_states_combo',        'pgerp.user_states_combo',         'List: account statuses', FALSE, FALSE),
    ('users_page',               'pgerp.users_page',                'Table: users',            FALSE, FALSE);

INSERT INTO pgerp.forms (form_name, title, cancel_action, folder) VALUES
    ('password_change', 'Password change', 'password_change_cancel', 'Administration'),
    ('role',            'Role',         NULL,                     'Administration'),
    ('roles',           'Roles',         NULL,                     'Administration'),
    ('translation',     'Translation',      NULL,                     'Administration'),
    ('translations',    'Translations',     NULL,                     'Administration'),
    ('user',            'User', NULL,                     'Administration'),
    ('users',           'Users', NULL,                     'Administration');

INSERT INTO pgerp.form_components (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options) VALUES
    ('password_change', 1,  'label',    'hint',                     'The password must be at least 8 characters long.',                                                                                                                       NULL,                       NULL, NULL,             NULL),
    ('password_change', 2,  'input',    'old_password',             'Current password',                                                                                                                                       NULL,                       NULL, NULL,             '{"type": "password"}'),
    ('password_change', 3,  'input',    'new_password',             'New password',                                                                                                                                         NULL,                       NULL, NULL,             '{"type": "password"}'),
    ('password_change', 4,  'input',    'new_password_repeat',      'Repeat password',                                                                                                                                        NULL,                       NULL, NULL,             '{"type": "password"}'),
    ('password_change', 5,  'button',   'btn_change',               'Change password',                                                                                                                                       'password_change',          NULL, NULL,             NULL),
    ('password_change', 6,  'button',   'btn_cancel',               'Cancel',                                                                                                                                               'password_change_cancel',   NULL, NULL,             NULL),
    ('role',            1,  'hidden',   'id',                       NULL,                                                                                                                                                   NULL,                       NULL, NULL,             NULL),
    ('role',            2,  'input',    'role_name',                'Code',                                                                                                                                                  NULL,                       NULL, NULL,             NULL),
    ('role',            3,  'input',    'title',                    'Title',                                                                                                                                             NULL,                       NULL, NULL,             NULL),
    ('role',            4,  'label',    'forms_hint',               'Users with this role see these forms in the menu and can run their actions. Forms opened from them (cards, selection windows) are available automatically.', NULL,                       NULL, NULL,             NULL),
    ('role',            5,  'combobox', 'form_to_add',              'Form',                                                                                                                                                'forms_combo',              NULL, NULL,             NULL),
    ('role',            6,  'button',   'btn_form_add',             'Add form',                                                                                                                                       'role_form_add',            NULL, NULL,             NULL),
    ('role',            7,  'grid',     'role_forms_grid',          'Role forms',                                                                                                                                           'role_forms_page',          'id', NULL,             NULL),
    ('role',            8,  'button',   'btn_save',                 'Save',                                                                                                                                            'role_save',                NULL, NULL,             NULL),
    ('role',            9,  'button',   'btn_cancel',               'Close',                                                                                                                                              'form_close',               NULL, NULL,             NULL),
    ('roles',           1,  'button',   'btn_role_new',             'New role',                                                                                                                                           'role_new_open',            NULL, NULL,             NULL),
    ('roles',           2,  'grid',     'roles_grid',               'Roles',                                                                                                                                                 'roles_page',               NULL, NULL,             NULL),
    ('translation',     1,  'hidden',   'id',                       NULL,                                                                                                                                                   NULL,                       NULL, NULL,             NULL),
    ('translation',     2,  'combobox', 'lang',                     'Language',                                                                                                                                                 'target_languages_combo',   NULL, NULL,             '{"placeholder": "—"}'),
    ('translation',     3,  'input',    'source',                   'Source text (Russian)',                                                                                                                             NULL,                       NULL, NULL,             NULL),
    ('translation',     4,  'input',    'translation',              'Translation',                                                                                                                                              NULL,                       NULL, NULL,             NULL),
    ('translation',     5,  'label',    'hint',                     'Placeholders: %s in the source text (or % in RAISE); in the translation, %s or %1$s, %2$s in the order of the source text.',                                       NULL,                       NULL, NULL,             NULL),
    ('translation',     6,  'button',   'btn_save',                 'Save',                                                                                                                                            'translation_save',         NULL, NULL,             NULL),
    ('translation',     7,  'button',   'btn_cancel',               'Close',                                                                                                                                              'form_close',               NULL, NULL,             NULL),
    ('translations',    1,  'input',    'translation_filter',       'Source text contains',                                                                                                                              NULL,                       NULL, NULL,             '{"refresh": "translations_grid, translation_missing_grid"}'),
    ('translations',    2,  'button',   'btn_translation_new',      'New translation',                                                                                                                                        'translation_new_open',     NULL, NULL,             NULL),
    ('translations',    3,  'grid',     'translations_grid',        'Translations',                                                                                                                                             'translations_page',        NULL, 'Translations',       NULL),
    ('translations',    4,  'grid',     'translation_missing_grid', 'Untranslated',                                                                                                                                         'translation_missing_page', NULL, 'Untranslated',   NULL),
    ('user',            1,  'hidden',   'id',                       NULL,                                                                                                                                                   NULL,                       NULL, NULL,             NULL),
    ('user',            2,  'input',    'login',                    'Login',                                                                                                                                                NULL,                       NULL, 'Account', NULL),
    ('user',            3,  'input',    'full_name',                'Full name',                                                                                                                                                  NULL,                       NULL, 'Account', NULL),
    ('user',            4,  'combobox', 'state',                    'Status',                                                                                                                                            'user_states_combo',        NULL, 'Account', '{"placeholder": "—"}'),
    ('user',            5,  'input',    'password',                 'New password (leave empty to keep)',                                                                                                                     NULL,                       NULL, 'Account', '{"type": "password"}'),
    ('user',            6,  'label',    'password_hint',            'The user will change this password at the next sign-in.',                                                                                             NULL,                       NULL, 'Account', NULL),
    ('user',            7,  'combobox', 'role_to_add',              'Role',                                                                                                                                                 'roles_combo',              NULL, 'Roles',           NULL),
    ('user',            8,  'button',   'btn_role_add',             'Assign role',                                                                                                                                       'user_role_add',            NULL, 'Roles',           NULL),
    ('user',            9,  'grid',     'user_roles_grid',          'User roles',                                                                                                                                    'user_roles_page',          'id', 'Roles',           NULL),
    ('user',            10, 'button',   'btn_save',                 'Save',                                                                                                                                            'user_save',                NULL, NULL,             NULL),
    ('user',            11, 'button',   'btn_cancel',               'Close',                                                                                                                                              'form_close',               NULL, NULL,             NULL),
    ('users',           1,  'input',    'user_filter',              'Login',                                                                                                                                                NULL,                       NULL, NULL,             '{"refresh": "users_grid"}'),
    ('users',           2,  'button',   'btn_user_new',             'New user',                                                                                                                                   'user_new_open',            NULL, NULL,             NULL),
    ('users',           3,  'grid',     'users_grid',               'Users',                                                                                                                                         'users_page',               NULL, NULL,             NULL);

INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column) VALUES
    ('role_forms_page',          1, 'title',       'Form',           'text',   'title'),
    ('role_forms_page',          2, 'folder',      'Folder',           'text',   'folder'),
    ('roles_page',               1, 'title',       'Title',        'text',   'title'),
    ('roles_page',               2, 'role_name',   'Code',             'text',   'role_name'),
    ('roles_page',               3, 'users_count', 'User count',   'number', 'users_count'),
    ('roles_page',               4, 'forms',       'Forms',           'text',   NULL),
    ('translation_missing_page', 1, 'lang',        'Language',            'text',   'lang'),
    ('translation_missing_page', 2, 'source',      'Source text',  'text',   'source'),
    ('translation_missing_page', 3, 'origin',      'Used in', 'text',   'origin'),
    ('translations_page',        1, 'lang',        'Language',            'text',   'lang'),
    ('translations_page',        2, 'source',      'Source text',  'text',   'source'),
    ('translations_page',        3, 'translation', 'Translation',         'text',   'translation'),
    ('user_roles_page',          1, 'title',       'Role',            'text',   'title'),
    ('user_roles_page',          2, 'role_name',   'Code',             'text',   'role_name'),
    ('users_page',               1, 'login',       'Login',           'text',   'login'),
    ('users_page',               2, 'full_name',   'Full name',           'text',   'full_name'),
    ('users_page',               3, 'roles',       'Roles',            'text',   NULL),
    ('users_page',               4, 'status',      'Status',       'text',   'status'),
    ('users_page',               5, 'last_login',  'Last sign-in',  'text',   'last_login_at');

INSERT INTO pgerp.grid_row_actions (source_action, sort_order, row_action, label, style) VALUES
    ('role_forms_page',          1, 'role_form_remove',         'Remove',    'danger'),
    ('roles_page',               1, 'role_edit_open',           'Edit',  'default'),
    ('roles_page',               2, 'role_delete',              'Delete',   'danger'),
    ('translation_missing_page', 1, 'translation_missing_open', 'Translate', 'default'),
    ('translations_page',        1, 'translation_edit_open',    'Edit',  'default'),
    ('translations_page',        2, 'translation_delete',       'Delete',   'danger'),
    ('user_roles_page',          1, 'user_role_remove',         'Remove',    'danger'),
    ('users_page',               1, 'user_edit_open',           'Edit',  'default');

INSERT INTO pgerp.menu_items (id, parent_id, sort_order, title, form_name) VALUES
    (17, NULL, 3, 'Administration', NULL),
    (18, 17,   1, 'Users',      'users'),
    (19, 17,   2, 'Roles',              'roles'),
    (20, 17,   3, 'Translations',          'translations');

INSERT INTO pgerp.roles (id, role_name, title) VALUES
    (1, 'admin', 'Administrator');

-- Первый администратор: admin / admin, пароль нужно сменить при первом входе
INSERT INTO pgerp.users (id, login, full_name, password_hash, must_change_password)
VALUES (1, 'admin', 'Administrator', pgerp.auth_hash('admin'), TRUE);
INSERT INTO pgerp.user_roles (user_id, role_id)
SELECT u.id, r.id FROM pgerp.users u, pgerp.roles r WHERE u.login = 'admin' AND r.role_name = 'admin';

-- Переводы текстов ядра (164)
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'ui_push: the message exceeds 8000 bytes — send less data in it', 'ui_push: сообщение длиннее 8000 байт — передайте в нём меньше данных'),
    ('ru', 'Administrator', 'Администратор'),
    ('ru', 'The administrator has access to all forms', 'Администратору доступны все формы'),
    ('ru', 'Administration', 'Администрирование'),
    ('ru', 'Active', 'Активен'),
    ('ru', 'Untranslated', 'Без перевода'),
    ('ru', 'The source text has %s placeholders. Use %%s or %%1$s, %%2$s, … in the translation', 'В исходном тексте подстановок: %s. В переводе используйте %%s или %%1$s, %%2$s, …'),
    ('ru', 'All forms', 'Все формы'),
    ('ru', 'Sign-in locked', 'Вход заблокирован'),
    ('ru', 'Select a role', 'Выберите роль'),
    ('ru', 'Select the account status', 'Выберите состояние учётной записи'),
    ('ru', 'Select a form', 'Выберите форму'),
    ('ru', 'Select the translation language', 'Выберите язык перевода'),
    ('ru', 'Drop-down list "%": select the item source action', 'Выпадающий список "%": выберите действие-источник элементов'),
    ('ru', 'Used in', 'Где встречается'),
    ('ru', 'Action "%" is not registered', 'Действие "%" не зарегистрировано'),
    ('ru', 'Tree "%": select the data source action', 'Дерево "%": выберите действие-источник данных'),
    ('ru', 'Add form', 'Добавить форму'),
    ('ru', 'Add a form to a role', 'Добавление формы в роль'),
    ('ru', 'At least one active administrator must remain', 'Должен остаться хотя бы один активный администратор'),
    ('ru', 'Must change password', 'Должен сменить пароль'),
    ('ru', 'Set a password — the user will change it at the first sign-in', 'Задайте пароль — пользователь сменит его при первом входе'),
    ('ru', 'Close', 'Закрыть'),
    ('ru', 'Close the modal form', 'Закрыть модальную форму'),
    ('ru', 'Edit', 'Изменить'),
    ('ru', 'Component names must be unique', 'Имена компонентов должны быть уникальны'),
    ('ru', 'Full name', 'Имя'),
    ('ru', 'Form name: lowercase Latin letters, digits and "_"', 'Имя формы: латинские буквы в нижнем регистре, цифры и "_"'),
    ('ru', 'Source code of the action function', 'Исходный код функции действия'),
    ('ru', 'Source text', 'Исходный текст'),
    ('ru', 'Source text (Russian)', 'Исходный текст (русский)'),
    ('ru', 'Source text contains', 'Исходный текст содержит'),
    ('ru', 'Translation card', 'Карточка перевода'),
    ('ru', 'User card', 'Карточка пользователя'),
    ('ru', 'Role card', 'Карточка роли'),
    ('ru', 'Code', 'Код'),
    ('ru', 'The administrator role code cannot be changed', 'Код роли администратора менять нельзя'),
    ('ru', 'Role code: lowercase Latin letters, digits and "_"', 'Код роли: латинские буквы в нижнем регистре, цифры и "_"'),
    ('ru', 'Component "%": options must be a JSON object', 'Компонент "%": параметры должны быть объектом JSON'),
    ('ru', 'Component "%s": action "%s" is not registered', 'Компонент "%s": действие "%s" не зарегистрировано'),
    ('ru', 'Component No. %s: name must be lowercase Latin letters, digits and "_"', 'Компонент №%s: имя — латинские буквы в нижнем регистре, цифры и "_"'),
    ('ru', 'Component No. %s: unknown type "%s"', 'Компонент №%s: неизвестный тип "%s"'),
    ('ru', 'Login', 'Логин'),
    ('ru', 'Login “%s” is already taken', 'Логин «%s» уже занят'),
    ('ru', 'Login must be at most 50 characters long', 'Логин — не длиннее 50 символов'),
    ('ru', 'Login: Latin letters, digits and _ . @ -, starting with a letter or digit', 'Логин: латинские буквы, цифры и символы _ . @ -, начинается с буквы или цифры'),
    ('ru', 'Application menu', 'Меню приложения'),
    ('ru', 'Menu saved', 'Меню сохранено'),
    ('ru', 'Menu, %s: the title is longer than 200 characters', 'Меню, %s: название длиннее 200 символов'),
    ('ru', 'Menu, %s: enter the item title', 'Меню, %s: укажите название пункта'),
    ('ru', 'Menu, %s: form "%s" does not exist', 'Меню, %s: формы "%s" нет'),
    ('ru', 'Menu: items must be passed as a list', 'Меню: пункты передаются списком'),
    ('ru', 'Title', 'Название'),
    ('ru', 'Assign a role to a user', 'Назначение роли пользователю'),
    ('ru', 'Assign role', 'Назначить роль'),
    ('ru', 'Invalid login or password', 'Неверный логин или пароль'),
    ('ru', 'Unknown action: %s', 'Неизвестное действие: %s'),
    ('ru', 'You cannot disable your own account', 'Нельзя отключить свою учётную запись'),
    ('ru', 'Access denied to action “%s”', 'Нет доступа к действию «%s»'),
    ('ru', 'Access denied to form “%s”', 'Нет доступа к форме «%s»'),
    ('ru', 'New role', 'Новая роль'),
    ('ru', 'New password', 'Новый пароль'),
    ('ru', 'New password (leave empty to keep)', 'Новый пароль (пусто — не менять)'),
    ('ru', 'The new password must differ from the current one', 'Новый пароль должен отличаться от текущего'),
    ('ru', 'The new password and its repetition do not match', 'Новый пароль и повтор не совпадают'),
    ('ru', 'New translation', 'Новый перевод'),
    ('ru', 'New user', 'Новый пользователь'),
    ('ru', 'Disabled', 'Отключён'),
    ('ru', 'Cancel', 'Отмена'),
    ('ru', 'Cancel password change', 'Отмена смены пароля'),
    ('ru', 'Folder', 'Папка'),
    ('ru', 'Password changed', 'Пароль изменён'),
    ('ru', 'The password must not match the login', 'Пароль не должен совпадать с логином'),
    ('ru', 'The password must be at most 72 characters long', 'Пароль — не длиннее 72 символов'),
    ('ru', 'The password must be at least 8 characters long', 'Пароль — не короче 8 символов'),
    ('ru', 'The password must be at least 8 characters long.', 'Пароль — не короче 8 символов.'),
    ('ru', 'Translate', 'Перевести'),
    ('ru', 'Translation', 'Перевод'),
    ('ru', 'Translation not found — it may have been deleted', 'Перевод не найден — возможно, он удалён'),
    ('ru', 'Translate an untranslated text', 'Перевод текста без перевода'),
    ('ru', 'A translation of this text into this language already exists', 'Перевод этого текста на этот язык уже есть'),
    ('ru', 'Translations', 'Переводы'),
    ('ru', 'Repeat password', 'Повтор пароля'),
    ('ru', 'Placeholders: %s in the source text (or % in RAISE); in the translation, %s or %1$s, %2$s in the order of the source text.', 'Подстановки: в исходном тексте %s (или % в RAISE), в переводе — %s или %1$s, %2$s по порядку исходного текста.'),
    ('ru', 'Lookup field "%": select the action that opens the list', 'Поле выбора "%": выберите действие открытия списка'),
    ('ru', 'User count', 'Пользователей'),
    ('ru', 'Users', 'Пользователи'),
    ('ru', 'Users with this role see these forms in the menu and can run their actions. Forms opened from them (cards, selection windows) are available automatically.', 'Пользователи роли видят эти формы в меню и выполняют их действия. Формы, которые открываются из них (карточки, окна выбора), доступны автоматически.'),
    ('ru', 'User', 'Пользователь'),
    ('ru', 'User not found', 'Пользователь не найден'),
    ('ru', 'User not found — it may have been deleted', 'Пользователь не найден — возможно, он удалён'),
    ('ru', 'The user will change this password at the next sign-in.', 'Пользователь сменит заданный пароль при следующем входе.'),
    ('ru', 'User created. Assign roles on the “Roles” tab', 'Пользователь создан. Назначьте ему роли на вкладке «Роли»'),
    ('ru', 'Last sign-in', 'Последний вход'),
    ('ru', 'Roles', 'Роли'),
    ('ru', 'User roles', 'Роли пользователя'),
    ('ru', 'Role', 'Роль'),
    ('ru', 'The administrator role cannot be deleted', 'Роль администратора удалить нельзя'),
    ('ru', 'Role not found — it may have been deleted', 'Роль не найдена — возможно, она удалена'),
    ('ru', 'A role with code “%s” already exists', 'Роль с кодом «%s» уже есть'),
    ('ru', 'Role created. Add the forms it grants access to', 'Роль создана. Добавьте формы, к которым она даёт доступ'),
    ('ru', 'Light', 'Светлая'),
    ('ru', 'Session ended — please sign in again', 'Сеанс завершён — войдите снова'),
    ('ru', 'Too many failed sign-in attempts. Try again in %s min.', 'Слишком много неудачных попыток входа. Повторите через %s мин.'),
    ('ru', 'Password change', 'Смена пароля'),
    ('ru', 'Change own password', 'Смена своего пароля'),
    ('ru', 'Change user theme', 'Смена темы пользователя'),
    ('ru', 'Change user language', 'Смена языка пользователя'),
    ('ru', 'Change your password to continue', 'Смените пароль, чтобы продолжить работу'),
    ('ru', 'Change password', 'Сменить пароль'),
    ('ru', 'Save the user first', 'Сначала сохраните пользователя'),
    ('ru', 'Save the role first', 'Сначала сохраните роль'),
    ('ru', 'Remove a role from a user', 'Снятие роли с пользователя'),
    ('ru', 'Status', 'Состояние'),
    ('ru', 'Save menu', 'Сохранение меню'),
    ('ru', 'Save translation', 'Сохранение перевода'),
    ('ru', 'Save user', 'Сохранение пользователя'),
    ('ru', 'Save role', 'Сохранение роли'),
    ('ru', 'Save form', 'Сохранение формы'),
    ('ru', 'Save', 'Сохранить'),
    ('ru', 'List of forms and actions', 'Список форм и действий'),
    ('ru', 'List: roles', 'Список: роли'),
    ('ru', 'List: account statuses', 'Список: состояния учётной записи'),
    ('ru', 'List: forms', 'Список: формы'),
    ('ru', 'List: translation languages', 'Список: языки перевода'),
    ('ru', 'Form structure', 'Структура формы'),
    ('ru', 'Table "%": select the data source action', 'Таблица "%": выберите действие-источник данных'),
    ('ru', 'Table "%s": master field "%s" not found among the form fields', 'Таблица "%s": поле-мастер "%s" не найдено среди полей формы'),
    ('ru', 'Table: translations', 'Таблица: переводы'),
    ('ru', 'Table: users', 'Таблица: пользователи'),
    ('ru', 'Table: roles', 'Таблица: роли'),
    ('ru', 'Table: user roles', 'Таблица: роли пользователя'),
    ('ru', 'Table: untranslated texts', 'Таблица: тексты без перевода'),
    ('ru', 'Table: role forms', 'Таблица: формы роли'),
    ('ru', 'Timer "%": select an action', 'Таймер "%": выберите действие'),
    ('ru', 'The text is already translated or no longer used', 'Текст уже переведён или больше не используется'),
    ('ru', 'Current password', 'Текущий пароль'),
    ('ru', 'The current password is incorrect', 'Текущий пароль указан неверно'),
    ('ru', 'Current user', 'Текущий пользователь'),
    ('ru', 'Theme “%s” is not supported', 'Тема «%s» не поддерживается'),
    ('ru', 'Dark', 'Тёмная'),
    ('ru', 'Remove', 'Убрать'),
    ('ru', 'Delete translation', 'Удаление перевода'),
    ('ru', 'Delete role', 'Удаление роли'),
    ('ru', 'Delete form', 'Удаление формы'),
    ('ru', 'Remove a form from a role', 'Удаление формы из роли'),
    ('ru', 'Delete', 'Удалить'),
    ('ru', 'Delete translation “%s”?', 'Удалить перевод «%s»?'),
    ('ru', 'Delete role “%s”? Its users will lose access to its forms.', 'Удалить роль «%s»? Её пользователи потеряют доступ к её формам.'),
    ('ru', 'Enter the source text', 'Укажите исходный текст'),
    ('ru', 'Enter the role title', 'Укажите название роли'),
    ('ru', 'Enter the translation', 'Укажите перевод'),
    ('ru', 'Account', 'Учётная запись'),
    ('ru', 'The account is disabled — contact the administrator', 'Учётная запись отключена — обратитесь к администратору'),
    ('ru', 'Form', 'Форма'),
    ('ru', 'Form "%" not found', 'Форма "%" не найдена'),
    ('ru', 'Form "%s" not found', 'Форма "%s" не найдена'),
    ('ru', 'Form "%s" saved', 'Форма "%s" сохранена'),
    ('ru', 'Forms', 'Формы'),
    ('ru', 'Role forms', 'Формы роли'),
    ('ru', 'Language', 'Язык'),
    ('ru', 'Language “%s” is not supported', 'Язык «%s» не поддерживается'),
    ('ru', 'item No. %s', 'пункт №%s'),
    ('ru', '—', '—');

SELECT setval(pg_get_serial_sequence('pgerp.menu_items', 'id'), (SELECT max(id) FROM pgerp.menu_items));
SELECT setval(pg_get_serial_sequence('pgerp.roles', 'id'), (SELECT max(id) FROM pgerp.roles));
SELECT setval(pg_get_serial_sequence('pgerp.users', 'id'), (SELECT max(id) FROM pgerp.users));

-- #####################################################################
-- Редактор функций действий
-- #####################################################################
-- =====================================================================
-- Редактор функций действий (кнопка «{ }» у поля «Действие» в редакторе форм).
--
--  * function_get — код функции действия для правки или, если действия ещё нет, заготовка
--    под тип компонента: обработчик кнопки/таймера с полями формы, источник таблицы, дерева,
--    выпадающего списка, открытие списка для поля выбора.
--  * function_save — создать или заменить функцию и зарегистрировать действие.
--
-- Правятся только прикладные обработчики public.имя(JSON) RETURNS JSON без особых свойств;
-- функции ядра (pgerp) и прочие показываются только для чтения. Клиент присылает не SQL, а имя,
-- язык, изменчивость и тело: заголовок CREATE FUNCTION собирает база (%I, ограничитель тела,
-- которого нет в самом теле) — дописать к нему второй оператор нельзя. Оба действия системные:
-- доступны только администратору.
--
-- Функции, созданные в редакторе, живут в базе, как и формы из редактора форм; чтобы они попали
-- в новую установку, их переносят в миграцию.
-- =====================================================================

-- Почему функцию нельзя править в редакторе; NULL — можно
CREATE FUNCTION pgerp.ui_function_lock_reason(p_function REGPROCEDURE)
RETURNS TEXT AS $$
    SELECT CASE
        WHEN p.pronamespace <> ALL (pgerp.app_schema_oids())
            THEN 'A core function (pgerp schema) is changed only by migrations'
        WHEN p.pronargs <> 1 OR p.proargtypes[0] <> 'json'::regtype OR p.prorettype <> 'json'::regtype OR p.proretset
            THEN 'Only action handlers can be edited: name(p_data JSON) RETURNS JSON'
        WHEN l.lanname NOT IN ('plpgsql', 'sql')
            THEN format('The editor does not support language %s', l.lanname)
        WHEN p.proconfig IS NOT NULL OR p.prosecdef OR p.proisstrict
            THEN 'The function has special properties (SET, SECURITY DEFINER, STRICT) — change it with a migration'
    END
    FROM pg_proc p
    JOIN pg_language l ON l.oid = p.prolang
    WHERE p.oid = p_function;
$$ LANGUAGE sql STABLE;

-- Свободное имя действия: base, base_2, base_3, …
CREATE FUNCTION pgerp.ui_function_free_name(p_base TEXT)
RETURNS TEXT AS $$
DECLARE
    v_base TEXT := left(COALESCE(NULLIF(regexp_replace(lower(p_base), '[^a-z0-9_]+', '_', 'g'), ''), 'action'), 55);
    v_name TEXT;
    v_n    INT  := 1;
BEGIN
    IF v_base !~ '^[a-z_]' THEN
        v_base := 'fn_' || v_base;
    END IF;
    v_name := v_base;
    WHILE EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_name)
       OR pgerp.app_action_fn(v_name) IS NOT NULL LOOP
        v_n := v_n + 1;
        v_name := v_base || '_' || v_n;
    END LOOP;
    RETURN v_name;
END;
$$ LANGUAGE plpgsql STABLE;

-- Заготовки тел функций по типу компонента; handler — кнопка, таймер и остальные.
-- Подстановки: {name} — имя действия, {label} — подпись компонента, {label_literal} — она же строкой SQL,
-- {declare} — переменные для полей формы, {require} — проверка первого поля
CREATE TABLE pgerp.function_templates (
    component_type VARCHAR(20) PRIMARY KEY,
    body           TEXT        NOT NULL
);

INSERT INTO pgerp.function_templates (component_type, body) VALUES
('handler', $t$-- {label}: the values of all form fields arrive in p_data.
{declare}BEGIN
{require}    -- Change the data

    RETURN ui_ok(ui_message('Done'));
END;
$t$),
('grid', $t$-- Table source: a page of rows with sorting and search.
-- Columns and row buttons live in pgerp.grid_columns and pgerp.grid_row_actions for action '{name}';
-- without columns the table shows all row fields.
BEGIN
    RETURN ui_grid_page('{name}', p_data, 'my_table');  -- table or view
END;
$t$),
('chart', $t$-- Chart source: {labels: [...], series: [{name, values: [...]}], format: number|money|percent}.
-- Receives the form field values (filters). The chart type is the component option "chart": bar, line, area, pie.
BEGIN
    RETURN ui_chart('my_view', 'label', ARRAY['value'], ARRAY['Value'], p_order_column => 'label');
END;
$t$),
('tree', $t$-- Tree source: one level — children of node p_data->>'parent_id' (empty — roots).
BEGIN
    RETURN ui_tree_level(p_data, 'my_table');  -- table with columns id, parent_id, name
END;
$t$),
('combobox', $t$-- Drop-down list items: {items: [{id, label}]}. Receives the form field values.
BEGIN
    RETURN ui_combo_items('my_table', 'name');  -- table and label column
END;
$t$),
('lookup', $t$-- Lookup field: open a list form in selection mode; the selected row returns to the field.
BEGIN
    RETURN ui_ok(ui_open_form('my_list_form',
        p_title  => {label_literal},
        p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name')));
END;
$t$);

-- Заготовка тела функции для компонента: p_type — тип, p_fields — поля формы [{name, type, label}]
CREATE FUNCTION pgerp.ui_function_template(p_name TEXT, p_type TEXT, p_label TEXT, p_fields JSON)
RETURNS TEXT AS $$
DECLARE
    v_label   TEXT := regexp_replace(COALESCE(p_label, p_name), '\s+', ' ', 'g');
    v_body    TEXT;
    v_declare TEXT;
    v_first   RECORD;
BEGIN
    SELECT body INTO v_body FROM pgerp.function_templates WHERE component_type = p_type;
    IF NOT FOUND THEN
        SELECT body INTO v_body FROM pgerp.function_templates WHERE component_type = 'handler';
    END IF;

    -- Переменные для полей формы: дата и поле выбора — сразу в своём типе
    SELECT string_agg(format('    %s %s := %s;',
                             rpad('v_' || (f->>'name'), 24),
                             CASE f->>'type' WHEN 'date' THEN 'DATE' WHEN 'lookup' THEN 'BIGINT' ELSE 'TEXT' END,
                             CASE f->>'type'
                                 WHEN 'date'   THEN format('ui_parse_date(p_data->>%L)', f->>'name')
                                 WHEN 'lookup' THEN format('ui_parse_id(p_data->>%L)', f->>'name')
                                 ELSE format('ui_text(p_data, %L)', f->>'name') END),
                      E'\n' ORDER BY n)
    INTO v_declare
    FROM json_array_elements(COALESCE(p_fields, '[]')) WITH ORDINALITY AS t(f, n)
    WHERE f->>'name' ~ '^[a-z_][a-z0-9_]*$';

    -- Проверка первого поля, которое заполняет пользователь
    SELECT f->>'name' AS name, regexp_replace(COALESCE(NULLIF(f->>'label', ''), f->>'name'), '\s+', ' ', 'g') AS label
    INTO v_first
    FROM json_array_elements(COALESCE(p_fields, '[]')) AS f
    WHERE f->>'name' ~ '^[a-z_][a-z0-9_]*$' AND f->>'type' NOT IN ('hidden', 'display')
    LIMIT 1;

    v_body := replace(v_body, '{declare}', CASE WHEN v_declare IS NOT NULL THEN E'DECLARE\n' || v_declare || E'\n' ELSE '' END);
    v_body := replace(v_body, '{require}', CASE WHEN v_first.name IS NOT NULL
        THEN format(E'    PERFORM ui_require(v_%s IS NOT NULL, %L);\n\n', v_first.name,
                    format('Fill in the “%s” field', v_first.label))
        ELSE '' END);
    v_body := replace(v_body, '{label_literal}', quote_literal(v_label));
    v_body := replace(v_body, '{label}', v_label);
    RETURN replace(v_body, '{name}', p_name);
END;
$$ LANGUAGE plpgsql STABLE;

-- Действие function_get. {"action": имя} — код функции действия; без action — заготовка для компонента
-- {"form", "component", "type", "label", "fields": [{name, type, label}]}
CREATE FUNCTION pgerp.ui_function_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_action pgerp.ui_actions%ROWTYPE;
    v_form      TEXT := NULLIF(p_data->>'form', '');
    v_component TEXT := regexp_replace(COALESCE(p_data->>'component', ''), '^btn_', '');
    v_name      TEXT;
    v_reason    TEXT;
BEGIN
    IF NULLIF(p_data->>'action', '') IS NULL THEN
        -- Имя: форма_компонент без «btn_»; форма не повторяется, если компонент уже начинается с неё
        v_name := pgerp.ui_function_free_name(
            CASE WHEN v_form IS NULL OR v_component LIKE v_form || '%' THEN v_component
                 ELSE concat_ws('_', v_form, NULLIF(v_component, '')) END);
        RETURN json_build_object('status', 'success', 'function', json_build_object(
            'is_new', TRUE,
            'editable', TRUE,
            'name', v_name,
            'description', COALESCE(NULLIF(p_data->>'label', ''), v_name),
            'language', 'plpgsql',
            'volatility', 'VOLATILE',
            'argument', 'p_data',
            'body', pgerp.ui_function_template(v_name, p_data->>'type', NULLIF(p_data->>'label', ''), p_data->'fields')));
    END IF;

    SELECT * INTO v_action FROM pgerp.ui_actions WHERE action_name = p_data->>'action';
    PERFORM ui_require(FOUND, format('Action “%s” is not registered', p_data->>'action'));
    v_reason := pgerp.ui_function_lock_reason(v_action.function_name::REGPROCEDURE);

    RETURN (
        SELECT json_build_object('status', 'success', 'function', json_build_object(
            'is_new', FALSE,
            'editable', v_reason IS NULL,
            'reason', v_reason,
            'name', v_action.action_name,
            'function', v_action.function_name::REGPROCEDURE::TEXT,
            'description', v_action.description,
            'language', l.lanname,
            'volatility', CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' ELSE 'VOLATILE' END,
            'argument', COALESCE(p.proargnames[1], 'p_data'),
            'body', p.prosrc,
            'source', pg_get_functiondef(p.oid)))
        FROM pg_proc p
        JOIN pg_language l ON l.oid = p.prolang
        WHERE p.oid = v_action.function_name);
END;
$$ LANGUAGE plpgsql STABLE;

-- Действие function_save: {name, description, language, volatility, body, is_new}.
-- Новая функция — public.name(p_data JSON) RETURNS JSON и действие с тем же именем;
-- существующая — заменяется с прежним именем параметра.
CREATE FUNCTION pgerp.ui_function_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name        TEXT    := ui_text(p_data, 'name');
    v_description TEXT    := ui_text(p_data, 'description');
    v_language    TEXT    := lower(COALESCE(ui_text(p_data, 'language'), 'plpgsql'));
    v_volatility  TEXT    := upper(COALESCE(ui_text(p_data, 'volatility'), 'VOLATILE'));
    v_body        TEXT    := p_data->>'body';
    v_is_new      BOOLEAN := COALESCE((p_data->>'is_new')::BOOLEAN, FALSE);
    v_action      pgerp.ui_actions%ROWTYPE;
    v_argument    TEXT    := 'p_data';
    v_tag         TEXT    := '$fn$';
    v_n           INT     := 0;
    v_message     TEXT;
    v_context     TEXT;
    -- Новая функция — в схеме решения, к которому относится её имя (префикс), иначе в public
    v_schema      TEXT    := pgerp.solution_schema(pgerp.solution_of('function', ui_text(p_data, 'name')));
BEGIN
    PERFORM ui_require(v_name ~ '^[a-z_][a-z0-9_]*$' AND length(v_name) <= 63,
                       'Function name: lowercase Latin letters, digits and "_", up to 63 characters');
    PERFORM ui_require(v_language IN ('plpgsql', 'sql'), 'Function language: plpgsql or sql');
    PERFORM ui_require(v_volatility IN ('VOLATILE', 'STABLE', 'IMMUTABLE'), 'Volatility: VOLATILE, STABLE or IMMUTABLE');
    PERFORM ui_require(NULLIF(trim(v_body), '') IS NOT NULL, 'Write the function code');

    IF v_is_new THEN
        PERFORM ui_require(NOT EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_name),
                           format('Action “%s” already exists — choose another name', v_name));
        PERFORM ui_require(pgerp.app_action_fn(v_name) IS NULL,
                           format('Function %s(json) already exists — choose another name', v_name));
    ELSE
        SELECT * INTO v_action FROM pgerp.ui_actions WHERE action_name = v_name;
        PERFORM ui_require(FOUND, format('Action “%s” is not registered', v_name));
        PERFORM ui_require((SELECT proname = v_name FROM pg_proc WHERE oid = v_action.function_name),
                           'The action calls a function with another name — change it with a migration');
        v_message := pgerp.ui_function_lock_reason(v_action.function_name::REGPROCEDURE);
        PERFORM ui_require(v_message IS NULL, v_message);
        SELECT COALESCE(proargnames[1], 'p_data'), pronamespace::regnamespace::TEXT INTO v_argument, v_schema
        FROM pg_proc WHERE oid = v_action.function_name;
    END IF;

    -- Ограничитель тела, которого нет в самом теле: код не может закрыть его и дописать свой оператор
    WHILE strpos(v_body, v_tag) > 0 LOOP
        v_n := v_n + 1;
        v_tag := format('$fn%s$', v_n);
    END LOOP;

    BEGIN
        EXECUTE format('CREATE OR REPLACE FUNCTION %I.%I(%I JSON) RETURNS JSON LANGUAGE %s %s AS %s%s%s',
                       v_schema, v_name, v_argument, v_language, v_volatility, v_tag, v_body, v_tag);
    EXCEPTION WHEN OTHERS THEN
        -- Ошибка компиляции — текстом для пользователя. Строку от начала тела PostgreSQL сообщает
        -- не всегда («near line N» в контексте компиляции); синтаксическая ошибка — только «at or near …»
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_context = PG_EXCEPTION_CONTEXT;
        v_context := substring(v_context FROM 'function "[^"]*" near line (\d+)');
        IF v_context IS NOT NULL THEN
            RAISE EXCEPTION '%', format('Code error (line %s): %s', v_context, v_message);
        END IF;
        RAISE EXCEPTION '%', format('Code error: %s', v_message);
    END;

    IF v_is_new THEN
        INSERT INTO pgerp.ui_actions (action_name, function_name, description)
        VALUES (v_name, pgerp.app_action_fn(v_name)::OID::REGPROC, COALESCE(v_description, v_name));
    ELSE
        UPDATE pgerp.ui_actions SET description = COALESCE(v_description, description) WHERE action_name = v_name;
    END IF;

    RETURN ui_ok(ui_message(format('Function “%s” saved', v_name)))::jsonb
        || jsonb_build_object('action', v_name);
END;
$$ LANGUAGE plpgsql;

INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system) VALUES
    ('function_get',  'pgerp.ui_function_get',  'Action function code or a template for the editor', TRUE),
    ('function_save', 'pgerp.ui_function_save', 'Save an action function from the editor',          TRUE);

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Action function code or a template for the editor', 'Код функции действия или заготовка для редактора'),
    ('ru', 'Save an action function from the editor', 'Сохранение функции действия из редактора'),
    ('ru', 'A core function (pgerp schema) is changed only by migrations', 'Функция ядра (схема pgerp) меняется только миграциями'),
    ('ru', 'Only action handlers can be edited: name(p_data JSON) RETURNS JSON', 'В редакторе правятся только обработчики действий: имя(p_data JSON) RETURNS JSON'),
    ('ru', 'The editor does not support language %s', 'Язык %s не поддерживается редактором'),
    ('ru', 'The function has special properties (SET, SECURITY DEFINER, STRICT) — change it with a migration', 'У функции есть особые свойства (SET, SECURITY DEFINER, STRICT) — измените её миграцией'),
    ('ru', 'Action “%s” is not registered', 'Действие «%s» не зарегистрировано'),
    ('ru', 'Function name: lowercase Latin letters, digits and "_", up to 63 characters', 'Имя функции: латинские буквы в нижнем регистре, цифры и "_", до 63 символов'),
    ('ru', 'Function language: plpgsql or sql', 'Язык функции: plpgsql или sql'),
    ('ru', 'Volatility: VOLATILE, STABLE or IMMUTABLE', 'Изменчивость: VOLATILE, STABLE или IMMUTABLE'),
    ('ru', 'Write the function code', 'Напишите код функции'),
    ('ru', 'Action “%s” already exists — choose another name', 'Действие «%s» уже есть — выберите другое имя'),
    ('ru', 'Function %s(json) already exists — choose another name', 'Функция %s(json) уже есть — выберите другое имя'),
    ('ru', 'The action calls a function with another name — change it with a migration', 'Действие вызывает функцию с другим именем — её правят миграцией'),
    ('ru', 'Code error: %s', 'Ошибка в коде: %s'),
    ('ru', 'Code error (line %s): %s', 'Ошибка в коде (строка %s): %s'),
    ('ru', 'Fill in the “%s” field', 'Заполните поле «%s»'),
    ('ru', 'Done', 'Готово'),
    ('ru', 'Function “%s” saved', 'Функция «%s» сохранена')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;

-- #####################################################################
-- Окно сообщений: ui_print
-- #####################################################################
-- =====================================================================
-- Окно сообщений: ui_print
-- =====================================================================
-- Функция действия (и всё, что она вызывает: другие функции, триггеры) выводит текст в панель
-- сообщений внизу экрана:
--     PERFORM ui_print('Пересчитано позиций: ' || v_count);
--     PERFORM ui_print(format('Сумма записи «%s» меньше нуля', v_name), 'warning');
-- Сообщение уходит как NOTICE со своим кодом, шлюз собирает такие NOTICE и добавляет в ответ
-- массив messages: [{text, kind}]. NOTICE не откатывается вместе с транзакцией, поэтому сообщения,
-- выведенные до ошибки, тоже показываются. Текст переводится по таблице переводов.
-- Коды: U0010 — информация, U0011 — предупреждение, U0012 — ошибка (только вид сообщения:
-- выполнение не прерывается).

CREATE FUNCTION pgerp.ui_print(p_text TEXT, p_kind VARCHAR DEFAULT 'info')
RETURNS VOID AS $$
BEGIN
    IF p_kind IS NULL OR p_kind NOT IN ('info', 'warning', 'error') THEN
        RAISE EXCEPTION USING MESSAGE = format(pgerp.ui_t('Unknown message kind: %s (allowed: info, warning, error)'), p_kind);
    END IF;
    RAISE NOTICE USING
        MESSAGE = COALESCE(pgerp.ui_t(p_text), 'NULL'),
        ERRCODE = CASE p_kind WHEN 'warning' THEN 'U0011' WHEN 'error' THEN 'U0012' ELSE 'U0010' END;
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION pgerp.ui_print(TEXT, VARCHAR) IS 'Report: text to the message panel at the bottom of the screen (info, warning, error)';

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Unknown message kind: %s (allowed: info, warning, error)', 'Неизвестный вид сообщения: %s (допустимы info, warning, error)')
ON CONFLICT DO NOTHING;

-- Заготовка обработчика в редакторе функций — с подсказкой про ui_print
UPDATE pgerp.function_templates
SET body = replace(body, E'    -- Change the data\n',
                   E'    -- Change the data\n    -- PERFORM ui_print(''Text for the message panel'');  -- a line in the panel at the bottom of the screen\n')
WHERE component_type = 'handler';

-- #####################################################################
-- Отчёты PDF
-- #####################################################################
-- =====================================================================
-- Отчёты PDF (JasperReports)
-- =====================================================================
-- Шаблон отчёта (jrxml) хранится в базе вместе с функцией данных. Функция данных — обычная
-- функция действия fn(p_data JSON) RETURNS JSON; она получает параметры из ui_report и возвращает
-- JSON-объект: ключи верхнего уровня — параметры отчёта ($P{...}), массив rows — строки ($F{...}).
-- Тексты $R{...} в шаблоне переводятся по таблице переводов на язык пользователя.
--
-- Показ отчёта — инструкция из любого действия:
--     RETURN ui_ok(ui_report('my_app_invoice', jsonb_build_object('id', v_id)));
-- ui_report запоминает запрос (кто, какой отчёт, с какими параметрами) и возвращает инструкцию
-- show_report с адресом api/reports/<id>. Право на отчёт даёт само действие: по адресу отчёт
-- получит только тот же пользователь и только в течение часа. Шлюз берёт шаблон и данные
-- действием report_fill, заполняет отчёт JasperReports и отдаёт PDF; клиент показывает его в окне.
--
-- Редактор отчётов (editor.html?reports, только администратор): report_list, report_get,
-- report_save (шлюз сначала компилирует jrxml), report_delete, report_preview (данные для
-- предпросмотра несохранённого шаблона).

CREATE TABLE pgerp.reports (
    name          VARCHAR(63) PRIMARY KEY CHECK (name ~ '^[a-z_][a-z0-9_]*$'),
    title         TEXT NOT NULL CHECK (title <> ''),
    data_action   VARCHAR(100) REFERENCES pgerp.ui_actions(action_name) ON UPDATE CASCADE,
    sample_params JSONB NOT NULL DEFAULT '{}' CHECK (jsonb_typeof(sample_params) = 'object'),
    jrxml         TEXT NOT NULL,
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_by    VARCHAR(100)
);

COMMENT ON TABLE pgerp.reports IS 'PDF reports: JasperReports template (jrxml) and the action that supplies the data';
COMMENT ON COLUMN pgerp.reports.sample_params IS 'Parameters for the preview in the editor, e.g. {"id": 1}';

-- Запросы на показ отчёта: адрес api/reports/<id> действует час и только для того, кто его получил
CREATE TABLE pgerp.report_requests (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    login       VARCHAR(100) NOT NULL,
    report_name VARCHAR(63) NOT NULL REFERENCES pgerp.reports(name) ON UPDATE CASCADE ON DELETE CASCADE,
    params      JSONB NOT NULL,
    title       TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX report_requests_created_at_idx ON pgerp.report_requests (created_at);

-- Показать отчёт: инструкция show_report. p_params — параметры для функции данных,
-- p_title — заголовок окна и имя файла вместо названия отчёта
CREATE FUNCTION pgerp.ui_report(p_report VARCHAR, p_params JSONB DEFAULT '{}', p_title TEXT DEFAULT NULL)
RETURNS JSONB AS $$
DECLARE
    v_report pgerp.reports%ROWTYPE;
    v_id     UUID;
BEGIN
    SELECT * INTO v_report FROM pgerp.reports WHERE name = p_report;
    PERFORM ui_require(FOUND, format('Report “%s” not found', p_report));
    PERFORM ui_require(pgerp.ui_user() IS NOT NULL, 'A report can only be shown from a user action');

    DELETE FROM pgerp.report_requests WHERE created_at < now() - interval '1 day';
    INSERT INTO pgerp.report_requests (login, report_name, params, title)
    VALUES (pgerp.ui_user(), p_report, COALESCE(p_params, '{}'), p_title)
    RETURNING id INTO v_id;

    RETURN ui_instruction('show_report', jsonb_build_object(
        'url', 'api/reports/' || v_id,
        'title', COALESCE(p_title, v_report.title)));
END;
$$ LANGUAGE plpgsql VOLATILE;

COMMENT ON FUNCTION pgerp.ui_report(VARCHAR, JSONB, TEXT) IS 'Show a PDF report: show_report instruction';

-- Переводы текстов $R{...} шаблона на язык пользователя: {"Итого": "Total", ...}
CREATE FUNCTION pgerp.report_texts(p_jrxml TEXT)
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_object_agg(key, pgerp.ui_t(key)), '{}')
    FROM (SELECT DISTINCT m[1] AS key
          FROM regexp_matches(COALESCE(p_jrxml, ''), '\$R\{([^}]+)\}', 'g') AS m) k;
$$ LANGUAGE sql STABLE;

-- Данные отчёта: функция действия p_action с параметрами; без действия — пустой объект
CREATE FUNCTION pgerp.report_data(p_action VARCHAR, p_params JSONB)
RETURNS JSON AS $$
DECLARE
    v_function REGPROC;
    v_result   JSON;
BEGIN
    IF p_action IS NULL THEN
        RETURN '{}';
    END IF;
    SELECT function_name INTO v_function FROM pgerp.ui_actions WHERE action_name = p_action;
    PERFORM ui_require(FOUND, format('Action “%s” is not registered', p_action));
    EXECUTE format('SELECT %s($1)', v_function) INTO v_result USING COALESCE(p_params, '{}')::JSON;
    PERFORM ui_require(json_typeof(v_result) = 'object',
                       format('The data function of report “%s” must return a JSON object', p_action));
    RETURN v_result;
END;
$$ LANGUAGE plpgsql;

-- Действие report_fill (шлюз, GET api/reports/<id>): шаблон, данные, переводы и язык (формат чисел и дат)
CREATE FUNCTION pgerp.ui_report_fill(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_request pgerp.report_requests%ROWTYPE;
    v_report  pgerp.reports%ROWTYPE;
BEGIN
    SELECT * INTO v_request
    FROM pgerp.report_requests
    WHERE id::TEXT = p_data->>'request'
      AND login = pgerp.ui_user()
      AND created_at > now() - interval '1 hour';
    PERFORM ui_require(FOUND, 'The report has expired — open it again');

    SELECT * INTO v_report FROM pgerp.reports WHERE name = v_request.report_name;
    RETURN json_build_object(
        'status', 'success',
        'report', json_build_object(
            'name', v_report.name,
            'title', pgerp.ui_t(COALESCE(v_request.title, v_report.title)),
            'version', extract(epoch FROM v_report.updated_at)::TEXT,
            'jrxml', v_report.jrxml),
        'data', pgerp.report_data(v_report.data_action, v_request.params),
        'texts', pgerp.report_texts(v_report.jrxml),
        'lang', pgerp.ui_lang());
END;
$$ LANGUAGE plpgsql;

-- Действие report_preview (редактор): данные и переводы для несохранённого шаблона
-- {data_action, params, jrxml}
CREATE FUNCTION pgerp.ui_report_preview(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_params JSONB := COALESCE(p_data->'params', '{}')::JSONB;
BEGIN
    PERFORM ui_require(jsonb_typeof(v_params) = 'object', 'Preview parameters must be a JSON object, e.g. {"id": 1}');
    RETURN json_build_object(
        'status', 'success',
        'data', pgerp.report_data(NULLIF(p_data->>'data_action', ''), v_params),
        'texts', pgerp.report_texts(p_data->>'jrxml'),
        'lang', pgerp.ui_lang());
END;
$$ LANGUAGE plpgsql;

-- Шаблон нового отчёта (формат JasperReports 7)
CREATE FUNCTION pgerp.report_template()
RETURNS TEXT AS $$
    SELECT $t$<jasperReport name="report" pageWidth="595" pageHeight="842" columnWidth="555" leftMargin="20" rightMargin="20" topMargin="20" bottomMargin="20">
	<!-- Parameters $P{...} are top-level JSON keys from the data function, fields $F{...} are elements of the rows array.
	     $R{text} is the text translated into the user's language (the "Translations" form). -->
	<parameter name="title" class="java.lang.String"/>
	<field name="name" class="java.lang.String"/>
	<title height="40">
		<element kind="textField" x="0" y="0" width="555" height="30" fontSize="16.0" bold="true">
			<expression><![CDATA[$P{title}]]></expression>
		</element>
	</title>
	<detail>
		<band height="20">
			<element kind="textField" x="0" y="0" width="555" height="20" textAdjust="StretchHeight">
				<expression><![CDATA[$F{name}]]></expression>
			</element>
		</band>
	</detail>
	<pageFooter height="20">
		<element kind="textField" x="0" y="0" width="555" height="20" hTextAlign="Right">
			<expression><![CDATA[$R{Page} + " " + $V{PAGE_NUMBER}]]></expression>
		</element>
	</pageFooter>
</jasperReport>
$t$;
$$ LANGUAGE sql IMMUTABLE;

-- Действие report_list: отчёты и действия, которые могут давать данные
CREATE FUNCTION pgerp.ui_report_list(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object(
        'status', 'success',
        'reports', COALESCE((SELECT json_agg(json_build_object('name', name, 'title', title, 'data_action', data_action,
                                                               'solution', pgerp.solution_of('report', name))
                                             ORDER BY title)
                             FROM pgerp.reports), '[]'),
        'actions', COALESCE((SELECT json_agg(json_build_object('name', action_name, 'description', description)
                                             ORDER BY action_name)
                             FROM pgerp.ui_actions WHERE NOT is_system), '[]'));
$$ LANGUAGE sql STABLE;

-- Действие report_get: {"name"} — отчёт; без имени — заготовка нового
CREATE FUNCTION pgerp.ui_report_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_report pgerp.reports%ROWTYPE;
BEGIN
    IF NULLIF(p_data->>'name', '') IS NULL THEN
        RETURN json_build_object('status', 'success', 'report', json_build_object(
            'is_new', TRUE, 'name', '', 'title', '', 'data_action', NULL,
            'sample_params', '{}'::JSON, 'jrxml', pgerp.report_template()));
    END IF;
    SELECT * INTO v_report FROM pgerp.reports WHERE name = p_data->>'name';
    PERFORM ui_require(FOUND, format('Report “%s” not found', p_data->>'name'));
    RETURN json_build_object('status', 'success', 'report', json_build_object(
        'is_new', FALSE,
        'name', v_report.name,
        'title', v_report.title,
        'data_action', v_report.data_action,
        'sample_params', v_report.sample_params,
        'jrxml', v_report.jrxml,
        'updated_at', v_report.updated_at,
        'updated_by', v_report.updated_by));
END;
$$ LANGUAGE plpgsql STABLE;

-- Действие report_save: {name, title, data_action, sample_params, jrxml, is_new}.
-- Вызывается шлюзом (POST api/reports/save) после успешной компиляции jrxml
CREATE FUNCTION pgerp.ui_report_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name   TEXT  := trim(COALESCE(p_data->>'name', ''));
    v_title  TEXT  := trim(COALESCE(p_data->>'title', ''));
    v_action TEXT  := NULLIF(p_data->>'data_action', '');
    v_params JSONB := COALESCE(p_data->'sample_params', '{}')::JSONB;
BEGIN
    PERFORM ui_require(v_name ~ '^[a-z_][a-z0-9_]*$' AND length(v_name) <= 63,
                       'Report name: lowercase Latin letters, digits and _, up to 63 characters');
    PERFORM ui_require(v_title <> '', 'Enter the report title');
    PERFORM ui_require(NULLIF(trim(p_data->>'jrxml'), '') IS NOT NULL, 'The report template is empty');
    PERFORM ui_require(jsonb_typeof(v_params) = 'object', 'Preview parameters must be a JSON object, e.g. {"id": 1}');
    PERFORM ui_require(v_action IS NULL OR EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_action),
                       format('Action “%s” is not registered', v_action));

    IF (p_data->>'is_new')::BOOLEAN THEN
        PERFORM ui_require(NOT EXISTS (SELECT 1 FROM pgerp.reports WHERE name = v_name),
                           format('Report “%s” already exists — choose another name', v_name));
        INSERT INTO pgerp.reports (name, title, data_action, sample_params, jrxml, updated_by)
        VALUES (v_name, v_title, v_action, v_params, p_data->>'jrxml', pgerp.ui_user());
    ELSE
        UPDATE pgerp.reports
        SET title = v_title, data_action = v_action, sample_params = v_params, jrxml = p_data->>'jrxml',
            updated_at = now(), updated_by = pgerp.ui_user()
        WHERE name = v_name;
        PERFORM ui_require(FOUND, format('Report “%s” not found', v_name));
    END IF;

    RETURN (ui_ok(ui_message(format('Report “%s” saved', v_title))) || jsonb_build_object('name', v_name))::JSON;
END;
$$ LANGUAGE plpgsql;

-- Действие report_delete: {"name"}
CREATE FUNCTION pgerp.ui_report_delete(p_data JSON)
RETURNS JSON AS $$
BEGIN
    DELETE FROM pgerp.reports WHERE name = p_data->>'name';
    PERFORM ui_require(FOUND, format('Report “%s” not found', p_data->>'name'));
    RETURN ui_ok(ui_message(format('Report “%s” deleted', p_data->>'name')))::JSON;
END;
$$ LANGUAGE plpgsql;

-- Системные действия: без форм — только администратору. report_fill — всем вошедшим:
-- доступ проверяет запрос (тот же пользователь, не старше часа)
INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('report_fill',    'pgerp.ui_report_fill',    'PDF report: template and data for a ui_report request', TRUE, TRUE),
    ('report_preview', 'pgerp.ui_report_preview', 'PDF report: data for preview in the editor', TRUE, FALSE),
    ('report_list',    'pgerp.ui_report_list',    'Report list for the editor',                    TRUE, FALSE),
    ('report_get',     'pgerp.ui_report_get',     'Report for the editor or a new report template',        TRUE, FALSE),
    ('report_save',    'pgerp.ui_report_save',    'Save a report from the editor',                  TRUE, FALSE),
    ('report_delete',  'pgerp.ui_report_delete',  'Delete a report',                                 TRUE, FALSE);

-- Заготовка функции данных отчёта для редактора функций
INSERT INTO pgerp.function_templates (component_type, body) VALUES
('report', $t$-- Data of report "{label}". p_data holds the parameters from ui_report (or "Preview parameters").
-- Top-level keys are report parameters ($P{...}), the rows array holds report rows ($F{...}).
BEGIN
    RETURN json_build_object(
        'title', {label_literal},
        'rows', COALESCE((SELECT json_agg(r) FROM (
            SELECT 'Sample row' AS name   -- query for the report rows
        ) r), '[]'));
END;
$t$);

-- Тексты отчётов — в форме «Переводы»: названия и $R{...} из шаблонов
CREATE VIEW pgerp.translatable_texts AS
SELECT DISTINCT ON (source) source, origin
FROM (
    SELECT title AS source, 'Form' AS origin, 1 AS priority FROM pgerp.forms
    UNION ALL SELECT folder, 'Form folder', 1 FROM pgerp.forms WHERE folder IS NOT NULL
    UNION ALL SELECT label, 'Form component', 1 FROM pgerp.form_components WHERE label IS NOT NULL
    UNION ALL SELECT tab, 'Form tab', 1 FROM pgerp.form_components WHERE tab IS NOT NULL
    UNION ALL SELECT options->>'placeholder', 'Empty list item', 1 FROM pgerp.form_components
              WHERE options->>'placeholder' IS NOT NULL
    UNION ALL SELECT column_title, 'Table column', 1 FROM pgerp.grid_columns
    UNION ALL SELECT label, 'Row button', 1 FROM pgerp.grid_row_actions
    UNION ALL SELECT title, 'Menu', 1 FROM pgerp.menu_items
    UNION ALL SELECT description, 'Action', 1 FROM pgerp.ui_actions WHERE description IS NOT NULL
    UNION ALL SELECT title, 'Role', 1 FROM pgerp.roles
    UNION ALL SELECT title, 'Report', 1 FROM pgerp.reports
    UNION ALL
    SELECT m[1], 'Report: ' || r.name, 1
    FROM pgerp.reports r
    CROSS JOIN LATERAL regexp_matches(r.jrxml, '\$R\{([^}]+)\}', 'g') AS m
    UNION ALL
    SELECT replace(m[1], '''''', ''''), 'Code: ' || p.proname, 2
    FROM pg_proc p
    CROSS JOIN LATERAL regexp_matches(p.prosrc, '''((?:[^'']|'''')*)''', 'g') AS m
    WHERE p.pronamespace = ANY (pgerp.app_schema_oids() || 'pgerp'::regnamespace::OID)
      AND m[1] ~ '^[[:upper:]][[:lower:]]'  -- похоже на фразу: с заглавной буквы, не идентификатор и не SQL

) t
WHERE trim(source) <> ''
ORDER BY source, priority, origin;

-- Тексты без перевода на каждый язык, кроме исходного. id — устойчивый хеш языка и текста. Текст, который
-- переводится шаблоном (например «Заполните поле «Имя»» шаблоном «Заполните поле «%s»»), уже переведён
CREATE VIEW pgerp.translation_missing_v AS
SELECT ('x' || substr(md5(l.code || chr(1) || t.source), 1, 13))::BIT(52)::BIGINT AS id,
       l.code AS lang, t.source, t.origin
FROM pgerp.languages l
CROSS JOIN pgerp.translatable_texts t
WHERE NOT l.is_source
  AND NOT EXISTS (SELECT 1 FROM pgerp.translations tr WHERE tr.lang = l.code AND tr.source = t.source)
  AND NOT EXISTS (SELECT 1 FROM pgerp.translations tr
                  WHERE tr.lang = l.code AND tr.is_template
                    AND t.source ~ pgerp.i18n_template_regex(tr.source));

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Report “%s” not found', 'Отчёт «%s» не найден'),
    ('ru', 'A report can only be shown from a user action', 'Отчёт показывается только из действия пользователя'),
    ('ru', 'The data function of report “%s” must return a JSON object', 'Функция данных отчёта «%s» должна вернуть JSON-объект'),
    ('ru', 'The report has expired — open it again', 'Отчёт устарел — откройте его снова'),
    ('ru', 'Preview parameters must be a JSON object, e.g. {"id": 1}', 'Параметры предпросмотра — JSON-объект, например {"id": 1}'),
    ('ru', 'Report name: lowercase Latin letters, digits and _, up to 63 characters',
           'Имя отчёта — латинские буквы в нижнем регистре, цифры и _, не длиннее 63 символов'),
    ('ru', 'Enter the report title', 'Укажите название отчёта'),
    ('ru', 'The report template is empty', 'Шаблон отчёта пуст'),
    ('ru', 'Report “%s” already exists — choose another name', 'Отчёт «%s» уже есть — выберите другое имя'),
    ('ru', 'Report “%s” saved', 'Отчёт «%s» сохранён'),
    ('ru', 'Report “%s” deleted', 'Отчёт «%s» удалён'),
    ('ru', 'PDF report: template and data for a ui_report request', 'Отчёт PDF: шаблон и данные по запросу ui_report'),
    ('ru', 'PDF report: data for preview in the editor', 'Отчёт PDF: данные для предпросмотра в редакторе'),
    ('ru', 'Report list for the editor', 'Список отчётов для редактора'),
    ('ru', 'Report for the editor or a new report template', 'Отчёт для редактора или заготовка нового'),
    ('ru', 'Save a report from the editor', 'Сохранение отчёта из редактора'),
    ('ru', 'Delete a report', 'Удаление отчёта'),
    ('ru', 'Page', 'Страница'),
    ('ru', 'Sample row', 'Пример строки')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;

-- #####################################################################
-- Колонки таблиц в редакторе форм
-- #####################################################################
-- =====================================================================
-- Колонки таблиц в редакторе форм
-- =====================================================================
-- Колонки таблицы (pgerp.grid_columns) привязаны к действию-источнику данных, а не к форме:
-- таблицы с одним источником в разных формах показывают одни и те же колонки.
--  * grid_columns_get  {action} — колонки, поля, которые может показать источник, пример строк и формы,
--                      где источник используется;
--  * grid_columns_save {action, columns: [{field, title, type, sort_column}]} — заменить колонки целиком.
-- Только администратору (системные действия без форм).

-- Пробный вызов источника: первые строки и их поля. Вызов откатывается целиком — источник с побочными
-- действиями ничего не изменит; ошибка (например, источник требует параметров) — пустой результат
CREATE FUNCTION pgerp.grid_source_sample(p_action VARCHAR)
RETURNS JSON AS $$
DECLARE
    v_function REGPROC;
    v_result   JSON;
BEGIN
    SELECT function_name INTO v_function FROM pgerp.ui_actions WHERE action_name = p_action;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    BEGIN
        EXECUTE format('SELECT %s($1)', v_function) INTO v_result USING '{"page": 1, "limit": 3}'::JSON;
        RAISE EXCEPTION USING ERRCODE = 'U0099';  -- откатить всё, что сделал вызов; v_result остаётся
    EXCEPTION WHEN OTHERS THEN
        NULL;
    END;
    IF json_typeof(v_result) = 'object' AND json_typeof(v_result->'rows') = 'array' THEN
        RETURN v_result->'rows';
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Поля, которые может показать источник: столбцы таблицы или представления из вызова
-- ui_grid_page('<действие>', p_data, '<источник>', ...) в коде функции, иначе — поля строк пробного вызова.
-- Порядок — как в источнике. Тип — для подсказки формата колонки
CREATE FUNCTION pgerp.grid_source_fields(p_action VARCHAR, p_sample JSON DEFAULT NULL)
RETURNS TABLE (name TEXT, data_type TEXT) AS $$
DECLARE
    v_source TEXT;
    v_class  REGCLASS;
BEGIN
    SELECT (regexp_match(p.prosrc, 'ui_grid_page\s*\(\s*''[^'']*''\s*,\s*\w+\s*,\s*''([^'']+)''', 'i'))[1]
    INTO v_source
    FROM pgerp.ui_actions a
    JOIN pg_proc p ON p.oid = a.function_name
    WHERE a.action_name = p_action;

    v_class := to_regclass(v_source);
    IF v_class IS NOT NULL THEN
        RETURN QUERY
        SELECT a.attname::TEXT, format_type(a.atttypid, a.atttypmod)
        FROM pg_attribute a
        WHERE a.attrelid = v_class AND a.attnum > 0 AND NOT a.attisdropped
        ORDER BY a.attnum;
        RETURN;
    END IF;

    IF json_typeof(p_sample) = 'array' AND json_array_length(p_sample) > 0
       AND json_typeof(p_sample->0) = 'object' THEN
        RETURN QUERY
        SELECT k::TEXT, json_typeof(p_sample->0->k)
        FROM json_object_keys(p_sample->0) AS k;
    END IF;
END;
$$ LANGUAGE plpgsql STABLE;

-- Действие grid_columns_get: {"action": источник}
CREATE FUNCTION pgerp.ui_grid_columns_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_action TEXT := p_data->>'action';
    v_sample JSON;
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_action),
                       format('Action “%s” is not registered', v_action));
    v_sample := pgerp.grid_source_sample(v_action);

    RETURN json_build_object(
        'status', 'success',
        'action', v_action,
        'columns', COALESCE((SELECT json_agg(json_build_object(
                                 'field', field_name, 'title', column_title,
                                 'type', cell_type, 'sort_column', sort_column) ORDER BY display_order)
                             FROM pgerp.grid_columns WHERE action_name = v_action), '[]'),
        'fields', COALESCE((SELECT json_agg(json_build_object('name', f.name, 'data_type', f.data_type))
                            FROM pgerp.grid_source_fields(v_action, v_sample) f), '[]'),
        'sample', COALESCE(v_sample, '[]'),
        'forms', COALESCE((SELECT json_agg(DISTINCT jsonb_build_object('name', f.form_name, 'title', f.title))
                           FROM pgerp.form_components c
                           JOIN pgerp.forms f ON f.form_name = c.form_name
                           WHERE c.component_type = 'grid' AND c.action_event = v_action), '[]'));
END;
$$ LANGUAGE plpgsql;

-- Действие grid_columns_save: {"action", "columns": [{field, title, type, sort_column}]}.
-- Пустой список — таблица покажет все поля строки как есть
CREATE FUNCTION pgerp.ui_grid_columns_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_action  TEXT := p_data->>'action';
    v_fields  TEXT[];
    v_column  RECORD;
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.ui_actions WHERE action_name = v_action),
                       format('Action “%s” is not registered', v_action));
    PERFORM ui_require(json_typeof(p_data->'columns') = 'array', 'Columns must be a list');

    -- Поля источника известны — колонки и сортировка только по ним
    SELECT array_agg(f.name) INTO v_fields
    FROM pgerp.grid_source_fields(v_action, pgerp.grid_source_sample(v_action)) f;

    FOR v_column IN
        SELECT trim(COALESCE(c->>'field', '')) AS field,
               trim(COALESCE(c->>'title', '')) AS title,
               COALESCE(NULLIF(c->>'type', ''), 'text') AS type,
               NULLIF(trim(COALESCE(c->>'sort_column', '')), '') AS sort_column,
               n
        FROM json_array_elements(p_data->'columns') WITH ORDINALITY AS t(c, n)
    LOOP
        PERFORM ui_require(v_column.field ~ '^[a-z_][a-z0-9_]*$' AND length(v_column.field) <= 50,
                           format('Column %s: the field must use lowercase Latin letters, digits and _', v_column.n));
        PERFORM ui_require(v_column.title <> '' AND length(v_column.title) <= 100,
                           format('Column “%s”: the title must be 1 to 100 characters', v_column.field));
        PERFORM ui_require(v_column.type IN ('text', 'datetime', 'number', 'money', 'badge'),
                           format('Column “%s”: unknown format %s', v_column.field, v_column.type));
        PERFORM ui_require(v_fields IS NULL OR v_column.field = ANY (v_fields),
                           format('The source data has no field “%s”', v_column.field));
        PERFORM ui_require(v_column.sort_column IS NULL
                           OR (v_column.sort_column ~ '^[a-z_][a-z0-9_]*$'
                               AND (v_fields IS NULL OR v_column.sort_column = ANY (v_fields))),
                           format('Column “%s”: you can only sort by a source field', v_column.field));
    END LOOP;
    PERFORM ui_require(NOT EXISTS (SELECT c->>'field' FROM json_array_elements(p_data->'columns') c
                                   GROUP BY c->>'field' HAVING count(*) > 1),
                       'Each field can be used in one column only');

    DELETE FROM pgerp.grid_columns WHERE action_name = v_action;
    INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column)
    SELECT v_action, n, trim(c->>'field'), trim(c->>'title'), COALESCE(NULLIF(c->>'type', ''), 'text'),
           NULLIF(trim(COALESCE(c->>'sort_column', '')), '')
    FROM json_array_elements(p_data->'columns') WITH ORDINALITY AS t(c, n);

    RETURN ui_ok(ui_message('Table columns saved'))::JSON;
END;
$$ LANGUAGE plpgsql;

INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('grid_columns_get',  'pgerp.ui_grid_columns_get',  'Table columns and source fields for the editor',  TRUE, FALSE),
    ('grid_columns_save', 'pgerp.ui_grid_columns_save', 'Save table columns from the editor',         TRUE, FALSE);

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Columns must be a list', 'Колонки передаются списком'),
    ('ru', 'Column %s: the field must use lowercase Latin letters, digits and _', 'Колонка %s: поле — латинские буквы в нижнем регистре, цифры и _'),
    ('ru', 'Column “%s”: the title must be 1 to 100 characters', 'Колонка «%s»: заголовок — от 1 до 100 символов'),
    ('ru', 'Column “%s”: unknown format %s', 'Колонка «%s»: неизвестный формат %s'),
    ('ru', 'The source data has no field “%s”', 'Поля «%s» нет в данных источника'),
    ('ru', 'Column “%s”: you can only sort by a source field', 'Колонка «%s»: сортировать можно только по полю источника'),
    ('ru', 'Each field can be used in one column only', 'Каждое поле — не больше одной колонки'),
    ('ru', 'Table columns saved', 'Колонки таблицы сохранены'),
    ('ru', 'Table columns and source fields for the editor', 'Колонки таблицы и поля источника для редактора'),
    ('ru', 'Save table columns from the editor', 'Сохранение колонок таблицы из редактора')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;

-- #####################################################################
-- Фильтры таблиц
-- #####################################################################
-- =====================================================================
-- Фильтры таблицы по нескольким колонкам: ui_grid_page(..., p_filters)
-- =====================================================================
-- p_filters — {"колонка": значение, ...}: строки, у которых колонка равна значению. Пустые значения
-- (NULL, '') пропускаются — фильтр «Все». Значение-массив — колонка равна любому из элементов.
-- Имена колонок задаёт код функции-источника (как p_source и p_master_column), значения — пользователь:
-- они подставляются только как литералы.
--     SELECT ui_grid_page('my_app_items_page', p_data, 'my_app_items_v',
--                         p_filters => jsonb_build_object('group_id', p_data->>'group_filter',
--                                                         'owner_login', p_data->>'owner_filter'));


COMMENT ON FUNCTION pgerp.ui_grid_page(VARCHAR, JSON, REGCLASS, VARCHAR, VARCHAR, VARCHAR, VARCHAR, TEXT, JSONB) IS
    'Table page: sorting, master, column search, p_filters {column: value}';

-- #####################################################################
-- Разработка решений: решения, схема данных, SQL-консоль, выпуски
-- #####################################################################
-- Решение — прикладной модуль: таблицы, представления, функции, формы, действия,
-- отчёты, роли и папка меню. Объект входит в решение, если его имя начинается с префикса
-- решения или он добавлен в решение явно (pgerp.solution_objects). Таблицы, представления и функции
-- решения лежат в его схеме базы (pgerp.solutions.db_schema) или в public; маршрутизатор ставит схемы
-- решений в путь поиска, поэтому код решений обращается к своим объектам без схемы. Объекты ядра
-- (схема pgerp, формы администрирования, роль admin) в решения не входят.
--
-- Пакет решения — папка db/solutions/<решение>/: solution.json (название, описание, схема по умолчанию)
-- и выпуски V<n>__<решение>_<название>.sql. Выпуск — разница между текущим состоянием решения и снимком
-- прошлого выпуска (первый — решение целиком), вызов pgerp.solution_release_apply(...) с SQL внутри: он
-- выполняется один раз на базу (на базе, где выпуск создан, он уже записан в pgerp.solution_releases).
-- Пакеты устанавливает и обновляет шлюз: администратор в редакторе или при первом входе, а при запуске
-- приложения — новые выпуски уже установленных решений.
--
-- Все действия этого раздела системные: только администратору (редактор и MCP).

-- ---------------------------------------------------------------------
-- Решения и их состав
-- ---------------------------------------------------------------------
CREATE TABLE pgerp.solutions (
    name             VARCHAR(50) PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]*$'),
    title            VARCHAR(200) NOT NULL CHECK (trim(title) <> ''),
    prefix           VARCHAR(30) UNIQUE CHECK (prefix ~ '^[a-z][a-z0-9_]*$'),
    menu_folder      VARCHAR(200),
    -- Папка пакета решения: db/solutions/<папка>/ (выпуски V<n>__….sql и solution.json)
    migration_folder VARCHAR(100) NOT NULL CHECK (migration_folder ~ '^[a-z][a-z0-9_]*$'),
    description      TEXT,
    is_core          BOOLEAN NOT NULL DEFAULT FALSE,
    -- Схема базы, в которой лежат таблицы, представления и функции решения
    db_schema        VARCHAR(63) NOT NULL DEFAULT 'public'
        CHECK (db_schema ~ '^[a-z_][a-z0-9_]*$' AND db_schema !~ '^pg_' AND db_schema <> 'pgerp'),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Настройки установки: solutions_setup — администратор уже выбрал решения при первом входе
CREATE TABLE pgerp.settings (
    key        VARCHAR(100) PRIMARY KEY,
    value      JSONB,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Объекты, добавленные в решение явно (без префикса или вопреки чужому префиксу)
CREATE TABLE pgerp.solution_objects (
    object_type VARCHAR(20) NOT NULL
        CHECK (object_type IN ('table', 'view', 'sequence', 'function', 'type', 'form', 'action', 'report', 'role')),
    object_name VARCHAR(100) NOT NULL,
    solution    VARCHAR(50) NOT NULL REFERENCES pgerp.solutions(name) ON UPDATE CASCADE ON DELETE CASCADE,
    PRIMARY KEY (object_type, object_name)
);

-- Таблицы, строки которых переносятся выпуском (справочники, настройки, демо-данные)
CREATE TABLE pgerp.solution_data (
    table_name VARCHAR(63) PRIMARY KEY,
    solution   VARCHAR(50) NOT NULL REFERENCES pgerp.solutions(name) ON UPDATE CASCADE ON DELETE CASCADE
);

-- Выпуски: снимок решения на момент выпуска — основа для следующей разницы
CREATE TABLE pgerp.solution_releases (
    solution   VARCHAR(50) NOT NULL REFERENCES pgerp.solutions(name) ON UPDATE CASCADE ON DELETE CASCADE,
    version    INT NOT NULL CHECK (version >= 0),
    label      VARCHAR(200) NOT NULL,
    file_name  VARCHAR(200),
    script     TEXT,
    snapshot   JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by VARCHAR(50),
    PRIMARY KEY (solution, version)
);

-- Переименования из конструктора таблиц: выпуск переименует, а не удалит и создаст заново
CREATE TABLE pgerp.solution_renames (
    id         BIGSERIAL PRIMARY KEY,
    kind       VARCHAR(10) NOT NULL CHECK (kind IN ('table', 'column')),
    table_name VARCHAR(63) NOT NULL,
    old_name   VARCHAR(63) NOT NULL,
    new_name   VARCHAR(63) NOT NULL,
    renamed_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);

-- Все прикладные объекты: таблицы, представления, последовательности, функции и типы схем решений и public
-- (без объектов расширений и истории Flyway) и метаданные (формы, действия, отчёты, роли)
CREATE VIEW pgerp.dev_catalog AS
SELECT CASE WHEN c.relkind IN ('r', 'p') THEN 'table' WHEN c.relkind IN ('v', 'm') THEN 'view' ELSE 'sequence' END::VARCHAR AS object_type,
       c.relname::VARCHAR AS object_name
FROM pg_class c
WHERE c.relnamespace = ANY (pgerp.app_schema_oids())
  AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
  AND NOT c.relispartition
  AND c.relname <> 'flyway_schema_history'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
  -- последовательности колонок (serial, identity) — часть своей таблицы
  AND NOT (c.relkind = 'S' AND EXISTS (SELECT 1 FROM pg_depend d
                                       WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid
                                         AND d.refobjsubid > 0 AND d.deptype IN ('a', 'i')))
UNION
SELECT 'function', p.proname::VARCHAR
FROM pg_proc p
WHERE p.pronamespace = ANY (pgerp.app_schema_oids())
  AND p.prokind IN ('f', 'p')
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
UNION
SELECT 'type', t.typname::VARCHAR
FROM pg_type t
WHERE t.typnamespace = ANY (pgerp.app_schema_oids())
  AND t.typtype = 'e'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d
                  WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
UNION
SELECT 'form', form_name::VARCHAR FROM pgerp.forms
UNION
SELECT 'action', a.action_name::VARCHAR
FROM pgerp.ui_actions a
JOIN pg_proc p ON p.oid = a.function_name
WHERE NOT a.is_system AND p.pronamespace <> 'pgerp'::regnamespace
UNION
SELECT 'report', name::VARCHAR FROM pgerp.reports
UNION
SELECT 'role', role_name::VARCHAR FROM pgerp.roles WHERE role_name <> 'admin';

-- Решение объекта: явное включение важнее префикса; из префиксов — самый длинный
CREATE FUNCTION pgerp.solution_of(p_type VARCHAR, p_name VARCHAR)
RETURNS VARCHAR AS $$
    SELECT COALESCE(
        (SELECT solution FROM pgerp.solution_objects WHERE object_type = p_type AND object_name = p_name),
        (SELECT name FROM pgerp.solutions
         WHERE prefix IS NOT NULL AND NOT is_core AND starts_with(p_name, prefix)
         ORDER BY length(prefix) DESC
         LIMIT 1));
$$ LANGUAGE sql STABLE;

CREATE VIEW pgerp.dev_objects AS
SELECT c.object_type, c.object_name, pgerp.solution_of(c.object_type, c.object_name) AS solution,
       EXISTS (SELECT 1 FROM pgerp.solution_objects o
               WHERE o.object_type = c.object_type AND o.object_name = c.object_name) AS is_explicit
FROM pgerp.dev_catalog c;

-- Объекты решения
CREATE FUNCTION pgerp.solution_members(p_solution VARCHAR, p_type VARCHAR)
RETURNS SETOF VARCHAR AS $$
    SELECT object_name FROM pgerp.dev_objects
    WHERE solution = p_solution AND object_type = p_type
    ORDER BY object_name;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Снимок решения: структура объектов и SQL метаданных — для разницы между выпусками
-- ---------------------------------------------------------------------
-- Определение без схемы объекта: «… ON my_app.my_app_items …» → «… ON my_app_items …» (первое вхождение после p_marker)
CREATE FUNCTION pgerp.dev_unqualify(p_def TEXT, p_marker TEXT, p_object OID)
RETURNS TEXT AS $$
    SELECT CASE WHEN strpos(p_def, p_marker || n.prefix) > 0
                THEN overlay(p_def PLACING p_marker FROM strpos(p_def, p_marker || n.prefix) FOR length(p_marker || n.prefix))
                ELSE p_def END
    FROM (SELECT format('%I.', nspname) AS prefix
          FROM pg_namespace
          WHERE oid = COALESCE((SELECT relnamespace FROM pg_class WHERE oid = p_object),
                               (SELECT pronamespace FROM pg_proc WHERE oid = p_object))) n;
$$ LANGUAGE sql STABLE;

-- Колонки, ограничения, индексы, триггеры и комментарии таблицы
CREATE FUNCTION pgerp.dev_table_state(p_table REGCLASS)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'comment', obj_description(p_table, 'pg_class'),
        'columns', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'name', a.attname,
                       'type', format_type(a.atttypid, a.atttypmod),
                       'not_null', a.attnotnull,
                       'default', CASE WHEN a.attgenerated = '' THEN pg_get_expr(d.adbin, d.adrelid) END,
                       'generated', CASE WHEN a.attgenerated = 's' THEN pg_get_expr(d.adbin, d.adrelid) END,
                       'identity', CASE a.attidentity WHEN 'a' THEN 'ALWAYS' WHEN 'd' THEN 'BY DEFAULT' END,
                       -- serial: значение по умолчанию — своя последовательность колонки
                       'serial', CASE WHEN a.attidentity = '' AND a.atttypid IN ('int2'::regtype, 'int4'::regtype, 'int8'::regtype)
                                          AND pg_get_expr(d.adbin, d.adrelid)
                                              = format('nextval(%L::regclass)', pg_get_serial_sequence(p_table::TEXT, a.attname)::regclass::TEXT)
                                      THEN CASE a.atttypid WHEN 'int2'::regtype THEN 'smallserial'
                                                           WHEN 'int4'::regtype THEN 'serial' ELSE 'bigserial' END END,
                       'collation', CASE WHEN a.attcollation <> t.typcollation
                                         THEN (SELECT format('%I', collname) FROM pg_collation WHERE oid = a.attcollation) END,
                       'comment', col_description(p_table, a.attnum))
                   ORDER BY a.attnum)
            FROM pg_attribute a
            JOIN pg_type t ON t.oid = a.atttypid
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = p_table AND a.attnum > 0 AND NOT a.attisdropped), '[]'),
        'constraints', COALESCE((
            SELECT jsonb_object_agg(conname, jsonb_build_object('type', contype, 'def', pg_get_constraintdef(oid)))
            FROM pg_constraint
            WHERE conrelid = p_table AND contype IN ('p', 'u', 'c', 'f', 'x')), '{}'),
        'indexes', COALESCE((
            SELECT jsonb_object_agg(ic.relname, pgerp.dev_unqualify(pg_get_indexdef(i.indexrelid), ' ON ', p_table))
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = p_table
              AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.conrelid = p_table)), '{}'),
        'triggers', COALESCE((
            SELECT jsonb_object_agg(tgname, pgerp.dev_unqualify(pg_get_triggerdef(oid), ' ON ', p_table))
            FROM pg_trigger
            WHERE tgrelid = p_table AND NOT tgisinternal), '{}'));
$$ LANGUAGE sql STABLE;

-- Представления решения в порядке зависимостей: каждое — после тех, на которые ссылается
CREATE FUNCTION pgerp.dev_views_ordered(p_views VARCHAR[])
RETURNS TABLE (view_name VARCHAR, view_oid OID, level INT) AS $$
    WITH RECURSIVE v AS (
        SELECT c.oid, c.relname::VARCHAR AS name
        FROM pg_class c
        WHERE c.relnamespace = ANY (pgerp.app_schema_oids()) AND c.relkind IN ('v', 'm') AND c.relname = ANY (p_views)
    ),
    deps AS (
        SELECT DISTINCT v.oid AS view_oid, d.refobjid AS ref_oid
        FROM v
        JOIN pg_rewrite r ON r.ev_class = v.oid
        JOIN pg_depend d ON d.classid = 'pg_rewrite'::regclass AND d.objid = r.oid
                        AND d.refclassid = 'pg_class'::regclass AND d.refobjid <> v.oid
        WHERE d.refobjid IN (SELECT oid FROM v)
    ),
    lvl AS (
        SELECT v.oid, 0 AS level FROM v
        UNION ALL
        SELECT d.view_oid, l.level + 1
        FROM lvl l
        JOIN deps d ON d.ref_oid = l.oid
        WHERE l.level < 100
    )
    SELECT v.name, v.oid, max(l.level)::INT
    FROM v JOIN lvl l ON l.oid = v.oid
    GROUP BY v.name, v.oid;
$$ LANGUAGE sql STABLE;

-- Строки запроса как список VALUES: каждое значение — текстом, литералом SQL (NULL — NULL).
-- Колонки запроса должны быть текстовыми: текст любого типа читается обратно его функцией ввода
CREATE FUNCTION pgerp.dev_values(p_query TEXT)
RETURNS TEXT AS $$
DECLARE
    v_result TEXT;
BEGIN
    EXECUTE format(
        $q$SELECT string_agg('    (' || (SELECT string_agg(quote_nullable(e.value), ', ' ORDER BY e.n)
                                       FROM json_each_text(row_to_json(q.r)) WITH ORDINALITY AS e(key, value, n)) || ')',
                             E',\n' ORDER BY q.q_n)
           FROM (SELECT q0 AS r, row_number() OVER () AS q_n FROM (%s) q0) q$q$, p_query)
    INTO v_result;
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- Список литералов для IN (...)
CREATE FUNCTION pgerp.dev_in_list(p_values VARCHAR[])
RETURNS TEXT AS $$
    SELECT COALESCE(string_agg(quote_literal(v), ', ' ORDER BY v), 'NULL') FROM unnest(p_values) AS v;
$$ LANGUAGE sql IMMUTABLE;

-- Таблицы в порядке внешних ключей: каждая — после тех, на которые ссылается
CREATE FUNCTION pgerp.dev_tables_ordered(p_tables VARCHAR[])
RETURNS TABLE (table_name VARCHAR, level INT) AS $$
    WITH RECURSIVE t AS (
        SELECT c.oid, c.relname::VARCHAR AS name
        FROM pg_class c
        WHERE c.relnamespace = ANY (pgerp.app_schema_oids()) AND c.relkind IN ('r', 'p') AND c.relname = ANY (p_tables)
    ),
    deps AS (
        SELECT DISTINCT conrelid AS table_oid, confrelid AS ref_oid
        FROM pg_constraint
        WHERE contype = 'f' AND conrelid <> confrelid
          AND conrelid IN (SELECT oid FROM t) AND confrelid IN (SELECT oid FROM t)
    ),
    lvl AS (
        SELECT t.oid, 0 AS level FROM t
        UNION ALL
        SELECT d.table_oid, l.level + 1
        FROM lvl l JOIN deps d ON d.ref_oid = l.oid
        WHERE l.level < 100
    )
    SELECT t.name, max(l.level)::INT
    FROM t JOIN lvl l ON l.oid = t.oid
    GROUP BY t.name;
$$ LANGUAGE sql STABLE;

-- Строки таблицы-справочника: вставка с обновлением по первичному ключу и сдвиг последовательностей
CREATE FUNCTION pgerp.dev_data_sql(p_table VARCHAR)
RETURNS TEXT AS $$
DECLARE
    v_table     REGCLASS := pgerp.app_rel(p_table);
    v_columns   TEXT[];
    v_pk        TEXT[];
    v_values    TEXT;
    v_overriding BOOLEAN;
    v_sql       TEXT;
    v_serial    TEXT;
BEGIN
    SELECT array_agg(a.attname::TEXT ORDER BY a.attnum), bool_or(a.attidentity = 'a')
    INTO v_columns, v_overriding
    FROM pg_attribute a
    WHERE a.attrelid = v_table AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = '';

    SELECT array_agg(a.attname::TEXT ORDER BY k.n)
    INTO v_pk
    FROM pg_constraint c
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, n)
    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
    WHERE c.conrelid = v_table AND c.contype = 'p';

    v_values := pgerp.dev_values(format('SELECT %s FROM %s ORDER BY %s',
        (SELECT string_agg(format('%I::TEXT', c), ', ') FROM unnest(v_columns) c),
        v_table,
        COALESCE((SELECT string_agg(format('%I', c), ', ') FROM unnest(v_pk) c), '1')));

    -- Значения последовательностей колонок (serial, identity) — после строк
    SELECT string_agg(format(E'SELECT setval(pg_get_serial_sequence(%L, %L), COALESCE((SELECT max(%I) FROM %s), 0) + 1, false);',
                             v_table::TEXT, a.attname, a.attname, v_table), E'\n' ORDER BY a.attnum)
    INTO v_serial
    FROM pg_attribute a
    WHERE a.attrelid = v_table AND a.attnum > 0 AND NOT a.attisdropped
      AND pg_get_serial_sequence(v_table::TEXT, a.attname) IS NOT NULL;

    IF v_values IS NULL THEN
        RETURN format('-- Data %s: no rows', v_table);
    END IF;

    v_sql := format(E'INSERT INTO %s (%s)%s VALUES\n%s',
                    v_table,
                    (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_columns) c),
                    CASE WHEN v_overriding THEN ' OVERRIDING SYSTEM VALUE' ELSE '' END,
                    v_values);
    IF v_pk IS NOT NULL THEN
        v_sql := v_sql || format(E'\nON CONFLICT (%s) DO %s;',
            (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_pk) c),
            COALESCE('UPDATE SET ' || (SELECT string_agg(format('%1$I = EXCLUDED.%1$I', c), ', ')
                                       FROM unnest(v_columns) c WHERE c <> ALL (v_pk)), 'NOTHING'));
    ELSE
        -- Без первичного ключа строки не сопоставить: заполняется только пустая таблица
        v_sql := format(E'DO $data$\nBEGIN\n    IF NOT EXISTS (SELECT 1 FROM %s) THEN\n        %s;\n    END IF;\nEND;\n$data$;',
                        v_table, replace(v_sql, E'\n', E'\n        '));
    END IF;
    RETURN v_sql || COALESCE(E'\n' || v_serial, '');
END;
$$ LANGUAGE plpgsql STABLE;

-- Меню решения: папка верхнего уровня с подпунктами — исходные тексты, как в редакторе меню
CREATE FUNCTION pgerp.dev_menu_tree(p_parent BIGINT)
RETURNS JSONB AS $$
    SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                  'title', m.title,
                                  'form', m.form_name,
                                  'items', NULLIF(pgerp.dev_menu_tree(m.id), '[]'::jsonb)))
                              ORDER BY m.sort_order, m.id), '[]'::jsonb)
    FROM pgerp.menu_items m
    WHERE m.parent_id = p_parent;
$$ LANGUAGE sql STABLE;

-- Папка меню решения из выпуска: прежняя папка заменяется, место в меню сохраняется
CREATE FUNCTION pgerp.solution_menu_apply(p_folder TEXT, p_items JSON)
RETURNS VOID AS $$
DECLARE
    v_sort INT;
    v_id   BIGINT;
BEGIN
    SELECT min(sort_order) INTO v_sort FROM pgerp.menu_items WHERE parent_id IS NULL AND title = p_folder;
    DELETE FROM pgerp.menu_items WHERE parent_id IS NULL AND title = p_folder;
    IF p_items IS NULL THEN
        RETURN;
    END IF;
    INSERT INTO pgerp.menu_items (parent_id, sort_order, title)
    VALUES (NULL, COALESCE(v_sort, (SELECT COALESCE(max(sort_order), 0) + 1 FROM pgerp.menu_items WHERE parent_id IS NULL)), p_folder)
    RETURNING id INTO v_id;
    PERFORM pgerp.ui_menu_insert(p_items, v_id, p_folder);
END;
$$ LANGUAGE plpgsql;

-- SQL метаданных решения по разделам: каждый раздел выпуск включает целиком, если он изменился
CREATE FUNCTION pgerp.dev_meta_sql(p_solution VARCHAR, p_corpus TEXT)
RETURNS JSONB AS $$
DECLARE
    v_s       pgerp.solutions%ROWTYPE;
    v_forms   VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'form'));
    v_actions VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'action'));
    v_reports VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'report'));
    v_roles   VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'role'));
    v_menu    BIGINT;
    v_texts   TEXT;
    v_values  TEXT;
    v_result  JSONB := '{}';
BEGIN
    SELECT * INTO v_s FROM pgerp.solutions WHERE name = p_solution;

    -- Решение: описание, явный состав, таблицы с данными
    v_result := v_result || jsonb_build_object('solution', concat_ws(E'\n',
        format(E'INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description)\nVALUES (%s, %s, %s, %s, %s, %s)\n'
               'ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, prefix = EXCLUDED.prefix, menu_folder = EXCLUDED.menu_folder,\n'
               '    migration_folder = EXCLUDED.migration_folder, description = EXCLUDED.description;',
               quote_literal(v_s.name), quote_literal(v_s.title), quote_nullable(v_s.prefix), quote_nullable(v_s.menu_folder),
               quote_literal(v_s.migration_folder), quote_nullable(v_s.description)),
        format('DELETE FROM pgerp.solution_objects WHERE solution = %L;', p_solution),
        (SELECT E'INSERT INTO pgerp.solution_objects (object_type, object_name, solution) VALUES\n' || v
                || E'\nON CONFLICT (object_type, object_name) DO UPDATE SET solution = EXCLUDED.solution;'
         FROM pgerp.dev_values(format('SELECT object_type::TEXT, object_name::TEXT, solution::TEXT FROM pgerp.solution_objects
                                       WHERE solution = %L ORDER BY 1, 2', p_solution)) AS v WHERE v IS NOT NULL),
        format('DELETE FROM pgerp.solution_data WHERE solution = %L;', p_solution),
        (SELECT E'INSERT INTO pgerp.solution_data (table_name, solution) VALUES\n' || v
                || E'\nON CONFLICT (table_name) DO UPDATE SET solution = EXCLUDED.solution;'
         FROM pgerp.dev_values(format('SELECT table_name::TEXT, solution::TEXT FROM pgerp.solution_data
                                       WHERE solution = %L ORDER BY 1', p_solution)) AS v WHERE v IS NOT NULL)));

    -- Действия: функция — по имени со схемой
    v_values := pgerp.dev_values(format(
        'SELECT a.action_name::TEXT, format(%L, p.proname), a.description::TEXT, a.everyone::TEXT
         FROM pgerp.ui_actions a JOIN pg_proc p ON p.oid = a.function_name
         WHERE a.action_name IN (%s) ORDER BY 1', '%I', pgerp.dev_in_list(v_actions)));
    IF v_values IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('actions',
            E'INSERT INTO pgerp.ui_actions (action_name, function_name, description, everyone) VALUES\n' || v_values
            || E'\nON CONFLICT (action_name) DO UPDATE SET function_name = EXCLUDED.function_name, description = EXCLUDED.description,\n'
            || '    everyone = EXCLUDED.everyone, is_system = FALSE;');
    END IF;

    v_values := pgerp.dev_values(format(
        'SELECT form_name::TEXT, title::TEXT, cancel_action::TEXT, folder::TEXT FROM pgerp.forms WHERE form_name IN (%s) ORDER BY 1',
        pgerp.dev_in_list(v_forms)));
    IF v_values IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('forms',
            E'INSERT INTO pgerp.forms (form_name, title, cancel_action, folder) VALUES\n' || v_values
            || E'\nON CONFLICT (form_name) DO UPDATE SET title = EXCLUDED.title, cancel_action = EXCLUDED.cancel_action,\n'
            || '    folder = EXCLUDED.folder, updated_at = now();');
        v_result := v_result || jsonb_build_object('components', concat_ws(E'\n',
            format('DELETE FROM pgerp.form_components WHERE form_name IN (%s);', pgerp.dev_in_list(v_forms)),
            (SELECT E'INSERT INTO pgerp.form_components (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options) VALUES\n'
                    || v || ';'
             FROM pgerp.dev_values(format(
                 'SELECT form_name::TEXT, sort_order::TEXT, component_type::TEXT, component_name::TEXT, label::TEXT,
                         action_event::TEXT, master_field::TEXT, tab::TEXT, options::TEXT
                  FROM pgerp.form_components WHERE form_name IN (%s) ORDER BY form_name, sort_order', pgerp.dev_in_list(v_forms))) AS v
             WHERE v IS NOT NULL)));
    END IF;

    -- Колонки и кнопки строк таблиц: принадлежат действию-источнику
    IF EXISTS (SELECT 1 FROM pgerp.grid_columns WHERE action_name = ANY (v_actions))
       OR EXISTS (SELECT 1 FROM pgerp.grid_row_actions WHERE source_action = ANY (v_actions)) THEN
        v_result := v_result || jsonb_build_object('grids', concat_ws(E'\n',
            format('DELETE FROM pgerp.grid_columns WHERE action_name IN (%s);', pgerp.dev_in_list(v_actions)),
            (SELECT E'INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column) VALUES\n'
                    || v || ';'
             FROM pgerp.dev_values(format(
                 'SELECT action_name::TEXT, display_order::TEXT, field_name::TEXT, column_title::TEXT, cell_type::TEXT, sort_column::TEXT
                  FROM pgerp.grid_columns WHERE action_name IN (%s) ORDER BY action_name, display_order', pgerp.dev_in_list(v_actions))) AS v
             WHERE v IS NOT NULL),
            format('DELETE FROM pgerp.grid_row_actions WHERE source_action IN (%s);', pgerp.dev_in_list(v_actions)),
            (SELECT E'INSERT INTO pgerp.grid_row_actions (source_action, sort_order, row_action, label, style) VALUES\n'
                    || v || ';'
             FROM pgerp.dev_values(format(
                 'SELECT source_action::TEXT, sort_order::TEXT, row_action::TEXT, label::TEXT, style::TEXT
                  FROM pgerp.grid_row_actions WHERE source_action IN (%s) ORDER BY source_action, sort_order', pgerp.dev_in_list(v_actions))) AS v
             WHERE v IS NOT NULL)));
    END IF;

    v_values := pgerp.dev_values(format(
        'SELECT name::TEXT, title, data_action::TEXT, sample_params::TEXT, jrxml FROM pgerp.reports WHERE name IN (%s) ORDER BY 1',
        pgerp.dev_in_list(v_reports)));
    IF v_values IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('reports',
            E'INSERT INTO pgerp.reports (name, title, data_action, sample_params, jrxml) VALUES\n' || v_values
            || E'\nON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, data_action = EXCLUDED.data_action,\n'
            || '    sample_params = EXCLUDED.sample_params, jrxml = EXCLUDED.jrxml, updated_at = now();');
    END IF;

    -- Роли и выданные им формы (пользователи ролей — данные установки, не решения)
    v_values := pgerp.dev_values(format(
        'SELECT role_name::TEXT, title::TEXT FROM pgerp.roles WHERE role_name IN (%s) ORDER BY 1', pgerp.dev_in_list(v_roles)));
    IF v_values IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('roles', concat_ws(E'\n',
            E'INSERT INTO pgerp.roles (role_name, title) VALUES\n' || v_values
            || E'\nON CONFLICT (role_name) DO UPDATE SET title = EXCLUDED.title;',
            format('DELETE FROM pgerp.role_forms WHERE role_id IN (SELECT id FROM pgerp.roles WHERE role_name IN (%s));',
                   pgerp.dev_in_list(v_roles)),
            (SELECT E'INSERT INTO pgerp.role_forms (role_id, form_name)\nSELECT r.id, v.form_name FROM (VALUES\n' || v
                    || E'\n) AS v(role_name, form_name)\nJOIN pgerp.roles r ON r.role_name = v.role_name\n'
                    || 'WHERE EXISTS (SELECT 1 FROM pgerp.forms f WHERE f.form_name = v.form_name);'
             FROM pgerp.dev_values(format(
                 'SELECT r.role_name::TEXT, rf.form_name::TEXT FROM pgerp.role_forms rf JOIN pgerp.roles r ON r.id = rf.role_id
                  WHERE r.role_name IN (%s) ORDER BY 1, 2', pgerp.dev_in_list(v_roles))) AS v
             WHERE v IS NOT NULL)));
    END IF;

    -- Папка меню
    IF v_s.menu_folder IS NOT NULL THEN
        SELECT id INTO v_menu FROM pgerp.menu_items WHERE parent_id IS NULL AND title = v_s.menu_folder ORDER BY sort_order LIMIT 1;
        IF v_menu IS NOT NULL THEN
            v_result := v_result || jsonb_build_object('menu',
                format(E'SELECT pgerp.solution_menu_apply(%L, %L);', v_s.menu_folder, jsonb_pretty(pgerp.dev_menu_tree(v_menu))));
        END IF;
    END IF;

    -- Переводы текстов решения: тексты метаданных и код (строки из функций и представлений — в p_corpus)
    SELECT concat_ws(E'\n', p_corpus, v_s.title, v_s.description, v_s.menu_folder,
        (SELECT string_agg(concat_ws(E'\n', title, folder), E'\n') FROM pgerp.forms WHERE form_name = ANY (v_forms)),
        (SELECT string_agg(concat_ws(E'\n', label, tab, options->>'placeholder'), E'\n') FROM pgerp.form_components WHERE form_name = ANY (v_forms)),
        (SELECT string_agg(column_title, E'\n') FROM pgerp.grid_columns WHERE action_name = ANY (v_actions)),
        (SELECT string_agg(label, E'\n') FROM pgerp.grid_row_actions WHERE source_action = ANY (v_actions)),
        (SELECT string_agg(description, E'\n') FROM pgerp.ui_actions WHERE action_name = ANY (v_actions)),
        (SELECT string_agg(title || E'\n' || jrxml, E'\n') FROM pgerp.reports WHERE name = ANY (v_reports)),
        (SELECT string_agg(title, E'\n') FROM pgerp.roles WHERE role_name = ANY (v_roles)),
        (SELECT string_agg(m.title, E'\n') FROM pgerp.menu_items m
         WHERE m.form_name = ANY (v_forms) OR m.id = v_menu OR m.parent_id = v_menu))
    INTO v_texts;
    -- Текст из одного знака (a, №, ←) — только целой строкой, а не частью другого текста
    v_values := pgerp.dev_values(format(
        'SELECT lang::TEXT, source, translation FROM pgerp.translations
         WHERE CASE WHEN length(source) > 1 THEN strpos(%1$L, source) > 0
                    ELSE strpos(E''\n'' || %1$L || E''\n'', E''\n'' || source || E''\n'') > 0 END
         ORDER BY source, lang', v_texts));
    IF v_values IS NOT NULL THEN
        v_result := v_result || jsonb_build_object('translations',
            E'INSERT INTO pgerp.translations (lang, source, translation) VALUES\n' || v_values
            || E'\nON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;');
    END IF;

    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

-- Снимок решения
CREATE FUNCTION pgerp.solution_state(p_solution VARCHAR)
RETURNS JSONB AS $$
DECLARE
    v_s         pgerp.solutions%ROWTYPE;
    v_tables    VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'table'));
    v_views     VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'view'));
    v_functions VARCHAR[] := ARRAY(SELECT pgerp.solution_members(p_solution, 'function'));
    v_result    JSONB;
    v_corpus    TEXT;
BEGIN
    SELECT * INTO v_s FROM pgerp.solutions WHERE name = p_solution;
    PERFORM ui_require(FOUND, format('Solution “%s” not found', p_solution));

    v_result := jsonb_build_object(
        'format', 1,
        'solution', jsonb_build_object('name', v_s.name, 'title', v_s.title, 'prefix', v_s.prefix,
                                       'menu_folder', v_s.menu_folder, 'migration_folder', v_s.migration_folder),
        'tables', COALESCE((SELECT jsonb_object_agg(t, pgerp.dev_table_state(pgerp.app_rel(t)))
                            FROM unnest(v_tables) t), '{}'),
        'views', COALESCE((SELECT jsonb_object_agg(o.view_name, jsonb_build_object(
                                      'def', rtrim(pg_get_viewdef(o.view_oid, TRUE), E'; \n'),
                                      'materialized', c.relkind = 'm',
                                      'level', o.level,
                                      'comment', obj_description(o.view_oid, 'pg_class'),
                                      'indexes', COALESCE((SELECT jsonb_object_agg(ic.relname, pg_get_indexdef(i.indexrelid))
                                                           FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                                                           WHERE i.indrelid = o.view_oid), '{}')))
                           FROM pgerp.dev_views_ordered(v_views) o JOIN pg_class c ON c.oid = o.view_oid), '{}'),
        'functions', COALESCE((SELECT jsonb_object_agg(format('%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)),
                                                       jsonb_build_object(
                                                           'name', p.proname,
                                                           'args', pg_get_function_identity_arguments(p.oid),
                                                           'kind', p.prokind,
                                                           'result', pg_get_function_result(p.oid),
                                                           'def', pgerp.dev_unqualify(pg_get_functiondef(p.oid), 'FUNCTION ', p.oid)))
                               FROM pg_proc p
                               WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.prokind IN ('f', 'p')
                                 AND p.proname = ANY (v_functions)), '{}'),
        'types', COALESCE((SELECT jsonb_object_agg(t.typname, jsonb_build_object(
                                      'labels', (SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder) FROM pg_enum e WHERE e.enumtypid = t.oid)))
                           FROM pg_type t
                           WHERE t.typnamespace = ANY (pgerp.app_schema_oids()) AND t.typtype = 'e'
                             AND t.typname = ANY (ARRAY(SELECT pgerp.solution_members(p_solution, 'type')))), '{}'),
        'sequences', COALESCE((SELECT jsonb_object_agg(c.relname, jsonb_build_object('def', format(
                                          'CREATE SEQUENCE IF NOT EXISTS %I AS %s INCREMENT %s MINVALUE %s MAXVALUE %s START %s%s;',
                                          c.relname, format_type(s.seqtypid, NULL), s.seqincrement, s.seqmin, s.seqmax, s.seqstart,
                                          CASE WHEN s.seqcycle THEN ' CYCLE' ELSE '' END)))
                               FROM pg_class c JOIN pg_sequence s ON s.seqrelid = c.oid
                               WHERE c.relnamespace = ANY (pgerp.app_schema_oids())
                                 AND c.relname = ANY (ARRAY(SELECT pgerp.solution_members(p_solution, 'sequence')))), '{}'),
        'meta', jsonb_build_object(
            'forms', to_jsonb(ARRAY(SELECT pgerp.solution_members(p_solution, 'form'))),
            'actions', to_jsonb(ARRAY(SELECT pgerp.solution_members(p_solution, 'action'))),
            'reports', to_jsonb(ARRAY(SELECT pgerp.solution_members(p_solution, 'report'))),
            'roles', to_jsonb(ARRAY(SELECT pgerp.solution_members(p_solution, 'role'))),
            'menu_folder', v_s.menu_folder),
        'data', COALESCE((SELECT jsonb_object_agg(d.table_name, pgerp.dev_data_sql(d.table_name))
                          FROM pgerp.solution_data d
                          WHERE d.solution = p_solution AND pgerp.app_rel(d.table_name) IS NOT NULL), '{}'));

    -- Тексты кода — для подбора переводов
    SELECT string_agg(f->>'def', E'\n') INTO v_corpus FROM jsonb_each(v_result->'functions') AS e(k, f);
    v_corpus := concat_ws(E'\n', v_corpus, (SELECT string_agg(v->>'def', E'\n') FROM jsonb_each(v_result->'views') AS e(k, v)));
    RETURN v_result || jsonb_build_object('sql', pgerp.dev_meta_sql(p_solution, v_corpus));
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Скрипт выпуска: разница между снимками (без прежнего снимка — решение целиком)
-- ---------------------------------------------------------------------
-- Определение колонки для CREATE TABLE и ADD COLUMN
CREATE FUNCTION pgerp.dev_column_sql(p_col JSONB)
RETURNS TEXT AS $$
    SELECT format('%I %s', p_col->>'name', COALESCE(p_col->>'serial', p_col->>'type'))
        || COALESCE(' COLLATE ' || (p_col->>'collation'), '')
        || CASE WHEN p_col->>'generated' IS NOT NULL THEN format(' GENERATED ALWAYS AS (%s) STORED', p_col->>'generated')
                WHEN p_col->>'identity' IS NOT NULL THEN format(' GENERATED %s AS IDENTITY', p_col->>'identity')
                WHEN p_col->>'serial' IS NULL AND p_col->>'default' IS NOT NULL THEN ' DEFAULT ' || (p_col->>'default')
                ELSE '' END
        || CASE WHEN (p_col->>'not_null')::BOOLEAN AND p_col->>'serial' IS NULL AND p_col->>'identity' IS NULL
                THEN ' NOT NULL' ELSE '' END;
$$ LANGUAGE sql IMMUTABLE;

-- Добавление ограничения, если его ещё нет
CREATE FUNCTION pgerp.dev_add_constraint_sql(p_table TEXT, p_name TEXT, p_def TEXT)
RETURNS TEXT AS $$
    SELECT format(E'DO $c$\nBEGIN\n    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = %L::regclass AND conname = %L) THEN\n' ||
                  E'        ALTER TABLE %s ADD CONSTRAINT %I %s;\n    END IF;\nEND;\n$c$;',
                  format('%I', p_table), p_name, format('%I', p_table), p_name, p_def);
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.dev_index_sql(p_def TEXT)
RETURNS TEXT AS $$
    SELECT regexp_replace(p_def, '^CREATE (UNIQUE )?INDEX ', 'CREATE \1INDEX IF NOT EXISTS ') || ';';
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.dev_view_sql(p_name TEXT, p_view JSONB)
RETURNS TEXT AS $$
    SELECT CASE WHEN (p_view->>'materialized')::BOOLEAN
                THEN format(E'CREATE MATERIALIZED VIEW IF NOT EXISTS %I AS\n%s;', p_name, p_view->>'def')
                     || COALESCE(E'\n' || (SELECT string_agg(pgerp.dev_index_sql(d), E'\n') FROM jsonb_each_text(p_view->'indexes') AS i(n, d)), '')
                ELSE format(E'CREATE OR REPLACE VIEW %I AS\n%s;', p_name, p_view->>'def') END
        || CASE WHEN p_view->>'comment' IS NOT NULL
                THEN format(E'\nCOMMENT ON %sVIEW %I IS %L;',
                            CASE WHEN (p_view->>'materialized')::BOOLEAN THEN 'MATERIALIZED ' ELSE '' END, p_name, p_view->>'comment')
                ELSE '' END;
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.solution_script(p_new JSONB, p_old JSONB, p_since TIMESTAMPTZ)
RETURNS JSONB AS $$
DECLARE
    v_full        BOOLEAN := p_old IS NULL;
    v_old         JSONB   := COALESCE(p_old, '{}');
    v_renames     TEXT[]  := '{}';
    v_drop_views  TEXT[]  := '{}';
    v_drop_fk     TEXT[]  := '{}';
    v_drop_parts  TEXT[]  := '{}';
    v_drop_tables TEXT[]  := '{}';
    v_types       TEXT[]  := '{}';
    v_tables      TEXT[]  := '{}';
    v_constraints TEXT[]  := '{}';
    v_functions   TEXT[]  := '{}';
    v_views       TEXT[]  := '{}';
    v_fk          TEXT[]  := '{}';
    v_indexes     TEXT[]  := '{}';
    v_triggers    TEXT[]  := '{}';
    v_comments    TEXT[]  := '{}';
    v_data        TEXT[]  := '{}';
    v_meta        TEXT[]  := '{}';
    v_drop_meta   TEXT[]  := '{}';
    v_drop_last   TEXT[]  := '{}';
    v_changes     TEXT[]  := '{}';
    v_warnings    TEXT[]  := '{}';
    v_recreate    BOOLEAN := FALSE;
    v_rename      pgerp.solution_renames%ROWTYPE;
    v_name        TEXT;
    v_n           JSONB;
    v_o           JSONB;
    v_c           JSONB;
    v_oc          JSONB;
    v_list        TEXT[];
    v_key         TEXT;
    v_def         JSONB;
    v_script      TEXT;
BEGIN
    -- Переименования из конструктора: прежний снимок приводится к новым именам
    IF NOT v_full THEN
        FOR v_rename IN SELECT * FROM pgerp.solution_renames WHERE renamed_at > p_since ORDER BY id LOOP
            IF v_rename.kind = 'table' AND v_old->'tables' ? v_rename.old_name AND NOT v_old->'tables' ? v_rename.new_name
               AND p_new->'tables' ? v_rename.new_name THEN
                v_old := jsonb_set(v_old, '{tables}', (v_old->'tables' - v_rename.old_name)
                                   || jsonb_build_object(v_rename.new_name, v_old->'tables'->v_rename.old_name));
                v_renames := v_renames || format('ALTER TABLE IF EXISTS %I RENAME TO %I;', v_rename.old_name, v_rename.new_name);
                v_changes := v_changes || format('Table %s renamed to %s', v_rename.old_name, v_rename.new_name);
            ELSIF v_rename.kind = 'column' AND v_old->'tables' ? v_rename.table_name
                  AND EXISTS (SELECT 1 FROM jsonb_array_elements(v_old->'tables'->v_rename.table_name->'columns') c
                              WHERE c->>'name' = v_rename.old_name)
                  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_old->'tables'->v_rename.table_name->'columns') c
                                  WHERE c->>'name' = v_rename.new_name) THEN
                v_old := jsonb_set(v_old, ARRAY['tables', v_rename.table_name, 'columns'], (
                    SELECT jsonb_agg(CASE WHEN c->>'name' = v_rename.old_name
                                          THEN jsonb_set(c, '{name}', to_jsonb(v_rename.new_name)) ELSE c END ORDER BY n)
                    FROM jsonb_array_elements(v_old->'tables'->v_rename.table_name->'columns') WITH ORDINALITY AS t(c, n)));
                v_renames := v_renames || format(
                    E'DO $r$\nBEGIN\n    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = to_regclass(%L) AND attname = %L AND NOT attisdropped) THEN\n' ||
                    E'        ALTER TABLE %I RENAME COLUMN %I TO %I;\n    END IF;\nEND;\n$r$;',
                    format('%I', v_rename.table_name), v_rename.old_name, v_rename.table_name, v_rename.old_name, v_rename.new_name);
                v_changes := v_changes || format('Column %s.%s renamed to %s', v_rename.table_name, v_rename.old_name, v_rename.new_name);
            END IF;
        END LOOP;
    END IF;

    -- Перечисления
    FOR v_name, v_n IN SELECT key, value FROM jsonb_each(p_new->'types') ORDER BY key LOOP
        v_o := v_old->'types'->v_name;
        IF v_o IS NULL THEN
            v_types := v_types || format(
                E'DO $t$\nBEGIN\n    IF to_regtype(%L) IS NULL THEN\n        CREATE TYPE %I AS ENUM (%s);\n    END IF;\nEND;\n$t$;',
                format('%I', v_name), v_name,
                (SELECT string_agg(quote_literal(l), ', ' ORDER BY n) FROM jsonb_array_elements_text(v_n->'labels') WITH ORDINALITY AS t(l, n)));
            v_changes := v_changes || format('New type %s', v_name);
        ELSIF v_o <> v_n THEN
            v_types := v_types || ARRAY(
                SELECT format('ALTER TYPE %I ADD VALUE IF NOT EXISTS %L%s;', v_name, l,
                              COALESCE(' AFTER ' || quote_literal(lag(l) OVER (ORDER BY n)), ''))
                FROM jsonb_array_elements_text(v_n->'labels') WITH ORDINALITY AS t(l, n));
            v_changes := v_changes || format('Changed type %s', v_name);
            IF EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_o->'labels') l WHERE NOT v_n->'labels' ? l) THEN
                v_warnings := v_warnings || format('Values were removed from type %s — the release does not delete them, do it manually', v_name);
            END IF;
        END IF;
    END LOOP;
    FOR v_name IN SELECT key FROM jsonb_each(v_old->'types') WHERE NOT p_new->'types' ? key LOOP
        v_drop_last := v_drop_last || format('DROP TYPE IF EXISTS %I;', v_name);
        v_changes := v_changes || format('Deleted type %s', v_name);
    END LOOP;

    -- Последовательности
    FOR v_name, v_n IN SELECT key, value FROM jsonb_each(p_new->'sequences') ORDER BY key LOOP
        IF NOT v_old->'sequences' ? v_name THEN
            v_types := v_types || (v_n->>'def');
            v_changes := v_changes || format('New sequence %s', v_name);
        END IF;
    END LOOP;
    FOR v_name IN SELECT key FROM jsonb_each(v_old->'sequences') WHERE NOT p_new->'sequences' ? key LOOP
        v_drop_last := v_drop_last || format('DROP SEQUENCE IF EXISTS %I;', v_name);
        v_changes := v_changes || format('Deleted sequence %s', v_name);
    END LOOP;

    -- Таблицы
    FOR v_name, v_n IN SELECT key, value FROM jsonb_each(p_new->'tables') ORDER BY key LOOP
        v_o := v_old->'tables'->v_name;
        IF v_o IS NULL THEN
            v_tables := v_tables || format(E'CREATE TABLE IF NOT EXISTS %I (\n%s\n);', v_name, (
                SELECT string_agg('    ' || x, E',\n' ORDER BY ord, n)
                FROM (SELECT 1 AS ord, n, pgerp.dev_column_sql(c) AS x
                      FROM jsonb_array_elements(v_n->'columns') WITH ORDINALITY AS t(c, n)
                      UNION ALL
                      SELECT 2, CASE c.value->>'type' WHEN 'p' THEN 0 ELSE 1 END, format('CONSTRAINT %I %s', c.key, c.value->>'def')
                      FROM jsonb_each(v_n->'constraints') AS c
                      WHERE c.value->>'type' <> 'f') s));
            v_fk := v_fk || ARRAY(SELECT pgerp.dev_add_constraint_sql(v_name, c.key, c.value->>'def')
                                  FROM jsonb_each(v_n->'constraints') AS c WHERE c.value->>'type' = 'f' ORDER BY c.key);
            v_indexes := v_indexes || ARRAY(SELECT pgerp.dev_index_sql(i.value) FROM jsonb_each_text(v_n->'indexes') AS i ORDER BY i.key);
            v_triggers := v_triggers || ARRAY(SELECT format('DROP TRIGGER IF EXISTS %I ON %I;', g.key, v_name) || E'\n' || g.value || ';'
                                              FROM jsonb_each_text(v_n->'triggers') AS g ORDER BY g.key);
            v_comments := v_comments || ARRAY(SELECT format('COMMENT ON TABLE %I IS %L;', v_name, v_n->>'comment')
                                              WHERE v_n->>'comment' IS NOT NULL)
                                     || ARRAY(SELECT format('COMMENT ON COLUMN %I.%I IS %L;', v_name, c->>'name', c->>'comment')
                                              FROM jsonb_array_elements(v_n->'columns') AS c WHERE c->>'comment' IS NOT NULL);
            v_changes := v_changes || format('New table %s', v_name);
            CONTINUE;
        END IF;

        -- Колонки
        FOR v_c IN SELECT c FROM jsonb_array_elements(v_n->'columns') AS c LOOP
            SELECT c INTO v_oc FROM jsonb_array_elements(v_o->'columns') AS c WHERE c->>'name' = v_c->>'name';
            IF v_oc IS NULL THEN
                v_tables := v_tables || format('ALTER TABLE %I ADD COLUMN IF NOT EXISTS %s;', v_name, pgerp.dev_column_sql(v_c));
                v_changes := v_changes || format('New column %s.%s', v_name, v_c->>'name');
                IF (v_c->>'not_null')::BOOLEAN AND v_c->>'default' IS NULL AND v_c->>'serial' IS NULL
                   AND v_c->>'identity' IS NULL AND v_c->>'generated' IS NULL THEN
                    v_warnings := v_warnings || format(
                        'Column %s.%s is required and has no default: the release will fail if the table already has rows',
                        v_name, v_c->>'name');
                END IF;
            ELSE
                IF v_c->>'type' IS DISTINCT FROM v_oc->>'type' THEN
                    v_tables := v_tables || format('ALTER TABLE %I ALTER COLUMN %I TYPE %s USING %I::%s;',
                                                   v_name, v_c->>'name', v_c->>'type', v_c->>'name', v_c->>'type');
                    v_changes := v_changes || format('Column %s.%s: type %s → %s', v_name, v_c->>'name', v_oc->>'type', v_c->>'type');
                    v_warnings := v_warnings || format('Column %s.%s changes its type: values that cannot be converted will stop the release',
                                                       v_name, v_c->>'name');
                    v_recreate := TRUE;
                END IF;
                IF v_c->>'default' IS DISTINCT FROM v_oc->>'default'
                   AND NOT (v_c->>'serial' IS NOT NULL AND v_oc->>'serial' IS NOT NULL) AND v_c->>'generated' IS NULL THEN
                    v_tables := v_tables || CASE WHEN v_c->>'default' IS NULL
                        THEN format('ALTER TABLE %I ALTER COLUMN %I DROP DEFAULT;', v_name, v_c->>'name')
                        ELSE format('ALTER TABLE %I ALTER COLUMN %I SET DEFAULT %s;', v_name, v_c->>'name', v_c->>'default') END;
                    v_changes := v_changes || format('Column %s.%s: default value', v_name, v_c->>'name');
                END IF;
                IF (v_c->>'not_null')::BOOLEAN IS DISTINCT FROM (v_oc->>'not_null')::BOOLEAN THEN
                    v_tables := v_tables || format('ALTER TABLE %I ALTER COLUMN %I %s NOT NULL;', v_name, v_c->>'name',
                                                   CASE WHEN (v_c->>'not_null')::BOOLEAN THEN 'SET' ELSE 'DROP' END);
                    v_changes := v_changes || format(CASE WHEN (v_c->>'not_null')::BOOLEAN THEN 'Column %s.%s: required'
                                                          ELSE 'Column %s.%s: optional' END, v_name, v_c->>'name');
                END IF;
                IF v_c->>'generated' IS DISTINCT FROM v_oc->>'generated' OR v_c->>'identity' IS DISTINCT FROM v_oc->>'identity'
                   OR v_c->>'collation' IS DISTINCT FROM v_oc->>'collation' THEN
                    v_warnings := v_warnings || format(
                        'Column %s.%s: the generated expression, identity or collation changed — the release does not carry this over',
                        v_name, v_c->>'name');
                END IF;
                IF v_c->>'comment' IS DISTINCT FROM v_oc->>'comment' THEN
                    v_comments := v_comments || format('COMMENT ON COLUMN %I.%I IS %s;', v_name, v_c->>'name',
                                                       quote_nullable(v_c->>'comment'));
                END IF;
            END IF;
        END LOOP;
        FOR v_oc IN SELECT c FROM jsonb_array_elements(v_o->'columns') AS c
                    WHERE NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_n->'columns') n WHERE n->>'name' = c->>'name') LOOP
            v_tables := v_tables || format('ALTER TABLE %I DROP COLUMN IF EXISTS %I;', v_name, v_oc->>'name');
            v_changes := v_changes || format('Deleted column %s.%s', v_name, v_oc->>'name');
            v_warnings := v_warnings || format('Column %s.%s will be deleted with its data. If this is a rename, '
                                               'do it in the table designer — the release will rename the column', v_name, v_oc->>'name');
            v_recreate := TRUE;
        END LOOP;

        -- Ограничения: изменённые удаляются и создаются заново
        FOR v_key, v_def IN SELECT key, value FROM jsonb_each(v_o->'constraints') LOOP
            IF v_n->'constraints'->v_key IS DISTINCT FROM v_def THEN
                IF v_def->>'type' = 'f' THEN
                    v_drop_fk := v_drop_fk || format('ALTER TABLE IF EXISTS %I DROP CONSTRAINT IF EXISTS %I;', v_name, v_key);
                ELSE
                    v_drop_parts := v_drop_parts || format('ALTER TABLE IF EXISTS %I DROP CONSTRAINT IF EXISTS %I;', v_name, v_key);
                END IF;
                IF NOT v_n->'constraints' ? v_key THEN
                    v_changes := v_changes || format('Deleted constraint %s.%s', v_name, v_key);
                END IF;
            END IF;
        END LOOP;
        FOR v_key, v_def IN SELECT key, value FROM jsonb_each(v_n->'constraints') ORDER BY key LOOP
            IF v_o->'constraints'->v_key IS DISTINCT FROM v_def THEN
                IF v_def->>'type' = 'f' THEN
                    v_fk := v_fk || pgerp.dev_add_constraint_sql(v_name, v_key, v_def->>'def');
                ELSE
                    v_constraints := v_constraints || pgerp.dev_add_constraint_sql(v_name, v_key, v_def->>'def');
                END IF;
                v_changes := v_changes || format(CASE WHEN v_o->'constraints' ? v_key THEN 'Changed constraint %s.%s'
                                                      ELSE 'New constraint %s.%s' END, v_name, v_key);
            END IF;
        END LOOP;

        -- Индексы и триггеры
        FOR v_key IN SELECT key FROM jsonb_each_text(v_o->'indexes') i
                     WHERE (v_n->'indexes'->>i.key) IS DISTINCT FROM i.value LOOP
            v_drop_parts := v_drop_parts || format('DROP INDEX IF EXISTS %I;', v_key);
            IF NOT v_n->'indexes' ? v_key THEN
                v_changes := v_changes || format('Deleted index %s', v_key);
            END IF;
        END LOOP;
        FOR v_key IN SELECT key FROM jsonb_each_text(v_n->'indexes') i
                     WHERE (v_o->'indexes'->>i.key) IS DISTINCT FROM i.value ORDER BY key LOOP
            v_indexes := v_indexes || pgerp.dev_index_sql(v_n->'indexes'->>v_key);
            v_changes := v_changes || format(CASE WHEN v_o->'indexes' ? v_key THEN 'Changed index %s' ELSE 'New index %s' END, v_key);
        END LOOP;
        FOR v_key IN SELECT key FROM jsonb_each_text(v_o->'triggers') g WHERE NOT v_n->'triggers' ? g.key LOOP
            v_drop_parts := v_drop_parts || format('DROP TRIGGER IF EXISTS %I ON %I;', v_key, v_name);
            v_changes := v_changes || format('Deleted trigger %s.%s', v_name, v_key);
        END LOOP;
        FOR v_key IN SELECT key FROM jsonb_each_text(v_n->'triggers') g
                     WHERE (v_o->'triggers'->>g.key) IS DISTINCT FROM g.value ORDER BY key LOOP
            v_triggers := v_triggers || (format('DROP TRIGGER IF EXISTS %I ON %I;', v_key, v_name) || E'\n'
                                         || (v_n->'triggers'->>v_key) || ';');
            v_changes := v_changes || format(CASE WHEN v_o->'triggers' ? v_key THEN 'Changed trigger %s.%s' ELSE 'New trigger %s.%s' END,
                                             v_name, v_key);
        END LOOP;
        IF v_n->>'comment' IS DISTINCT FROM v_o->>'comment' THEN
            v_comments := v_comments || format('COMMENT ON TABLE %I IS %s;', v_name, quote_nullable(v_n->>'comment'));
        END IF;
    END LOOP;

    v_list := ARRAY(SELECT key FROM jsonb_each(v_old->'tables') WHERE NOT p_new->'tables' ? key ORDER BY key);
    IF cardinality(v_list) > 0 THEN
        v_drop_tables := v_drop_tables || format('DROP TABLE IF EXISTS %s;',
            (SELECT string_agg(format('%I', t), ', ') FROM unnest(v_list) t));
        v_changes := v_changes || ARRAY(SELECT format('Deleted table %s', t) FROM unnest(v_list) t);
        v_warnings := v_warnings || ARRAY(SELECT format('Table %s will be deleted with its data', t) FROM unnest(v_list) t);
        v_recreate := TRUE;
    END IF;

    -- Функции: тело заменяется; если сменился тип результата — пересоздаётся
    FOR v_key, v_n IN SELECT key, value FROM jsonb_each(p_new->'functions') ORDER BY key LOOP
        v_o := v_old->'functions'->v_key;
        IF v_o IS NULL OR v_o->>'def' IS DISTINCT FROM v_n->>'def' THEN
            IF v_o IS NOT NULL AND v_o->>'result' IS DISTINCT FROM v_n->>'result' THEN
                v_functions := v_functions || format('DROP %s IF EXISTS %s;',
                    CASE WHEN v_o->>'kind' = 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, v_key);
                v_recreate := TRUE;
            END IF;
            v_functions := v_functions || (rtrim(v_n->>'def', E'\n') || ';');
            v_changes := v_changes || format(CASE WHEN v_o IS NULL THEN 'New function %s' ELSE 'Changed function %s' END, v_key);
        END IF;
    END LOOP;
    FOR v_key, v_o IN SELECT key, value FROM jsonb_each(v_old->'functions') WHERE NOT p_new->'functions' ? key ORDER BY key LOOP
        v_drop_last := v_drop_last || format('DROP %s IF EXISTS %s;',
            CASE WHEN v_o->>'kind' = 'p' THEN 'PROCEDURE' ELSE 'FUNCTION' END, v_key);
        v_changes := v_changes || format('Deleted function %s', v_key);
    END LOOP;

    -- Представления: при любом изменении пересоздаются все представления решения в порядке зависимостей —
    -- так меняются колонки и зависимые представления, а изменения таблиц не упираются в представления
    v_recreate := v_recreate OR EXISTS (
        SELECT 1 FROM jsonb_each(p_new->'views') n
        WHERE (v_old->'views'->n.key) - 'level' IS DISTINCT FROM n.value - 'level')
        OR EXISTS (SELECT 1 FROM jsonb_each(v_old->'views') o WHERE NOT p_new->'views' ? o.key);
    IF v_full OR v_recreate THEN
        IF NOT v_full THEN
            v_drop_views := ARRAY(
                SELECT format('DROP %sVIEW IF EXISTS %I;',
                              CASE WHEN (value->>'materialized')::BOOLEAN THEN 'MATERIALIZED ' ELSE '' END, key)
                FROM jsonb_each(v_old->'views') ORDER BY (value->>'level')::INT DESC, key);
        END IF;
        v_views := ARRAY(SELECT pgerp.dev_view_sql(key, value) FROM jsonb_each(p_new->'views')
                         ORDER BY (value->>'level')::INT, key);
        v_changes := v_changes || ARRAY(
            SELECT format(CASE WHEN v_old->'views' ? n.key THEN 'Changed view %s' ELSE 'New view %s' END, n.key)
            FROM jsonb_each(p_new->'views') n
            WHERE (v_old->'views'->n.key) - 'level' IS DISTINCT FROM n.value - 'level'
            ORDER BY n.key)
            || ARRAY(SELECT format('Deleted view %s', o.key) FROM jsonb_each(v_old->'views') o
                     WHERE NOT p_new->'views' ? o.key ORDER BY o.key);
    END IF;

    -- Данные таблиц-справочников: в порядке внешних ключей
    v_data := ARRAY(
        SELECT format(E'-- %s\n%s', d.key, d.value)
        FROM jsonb_each_text(p_new->'data') d
        LEFT JOIN pgerp.dev_tables_ordered(ARRAY(SELECT jsonb_object_keys(p_new->'data'))::VARCHAR[]) o ON o.table_name = d.key
        WHERE v_full OR (v_old->'data'->>d.key) IS DISTINCT FROM d.value
        ORDER BY o.level NULLS LAST, d.key);
    v_changes := v_changes || ARRAY(SELECT format('Data of table %s', d.key) FROM jsonb_each_text(p_new->'data') d
                                    WHERE v_full OR (v_old->'data'->>d.key) IS DISTINCT FROM d.value ORDER BY d.key);
    -- Строки справочника ссылаются на таблицу, строки которой выпуск не переносит
    v_warnings := v_warnings || ARRAY(
        SELECT DISTINCT format('Data of table %s references %s, whose rows the release does not carry: '
                               'another database may lack the required rows', c.conrelid::regclass, c.confrelid::regclass)
        FROM pg_constraint c
        WHERE c.contype = 'f' AND c.conrelid <> c.confrelid
          AND c.conrelid::regclass::TEXT IN (SELECT jsonb_object_keys(p_new->'data'))
          AND c.confrelid::regclass::TEXT NOT IN (SELECT jsonb_object_keys(p_new->'data'))
          AND c.confrelid::regclass::TEXT IN (SELECT jsonb_object_keys(p_new->'tables')));

    -- Метаданные: раздел целиком, если он изменился
    FOR v_key IN SELECT unnest(ARRAY['actions', 'forms', 'components', 'grids', 'reports', 'roles', 'menu']) LOOP
        IF (p_new->'sql'->>v_key) IS NOT NULL AND (v_full OR (v_old->'sql'->>v_key) IS DISTINCT FROM (p_new->'sql'->>v_key)) THEN
            v_meta := v_meta || (p_new->'sql'->>v_key);
            v_changes := v_changes || CASE v_key
                WHEN 'actions' THEN 'Metadata: actions' WHEN 'forms' THEN 'Metadata: forms'
                WHEN 'components' THEN 'Metadata: form components' WHEN 'grids' THEN 'Metadata: table columns and row buttons'
                WHEN 'reports' THEN 'Metadata: reports' WHEN 'roles' THEN 'Metadata: roles and their forms'
                ELSE 'Metadata: menu' END;
        END IF;
    END LOOP;
    IF NOT v_full AND (v_old->'sql'->>'grids') IS NOT NULL AND (p_new->'sql'->>'grids') IS NULL THEN
        v_meta := v_meta || format('DELETE FROM pgerp.grid_columns WHERE action_name IN (%1$s);' ||
                                   E'\nDELETE FROM pgerp.grid_row_actions WHERE source_action IN (%1$s);',
                                   pgerp.dev_in_list(ARRAY(SELECT jsonb_array_elements_text(v_old->'meta'->'actions'))::VARCHAR[]));
    END IF;
    IF NOT v_full AND v_old->'meta'->>'menu_folder' IS NOT NULL
       AND ((p_new->'sql'->>'menu') IS NULL OR v_old->'meta'->>'menu_folder' IS DISTINCT FROM p_new->'meta'->>'menu_folder') THEN
        v_meta := v_meta || format('SELECT pgerp.solution_menu_apply(%L, NULL);', v_old->'meta'->>'menu_folder');
        v_changes := v_changes || format('Deleted menu folder “%s”', v_old->'meta'->>'menu_folder');
    END IF;

    -- Удалённые из решения формы, отчёты, роли и действия
    FOR v_key, v_name IN SELECT * FROM (VALUES ('forms', 'pgerp.forms WHERE form_name'), ('reports', 'pgerp.reports WHERE name'),
                                               ('roles', 'pgerp.roles WHERE role_name'), ('actions', 'pgerp.ui_actions WHERE action_name')) AS t(k, s) LOOP
        v_list := ARRAY(SELECT jsonb_array_elements_text(v_old->'meta'->v_key)
                        EXCEPT SELECT jsonb_array_elements_text(p_new->'meta'->v_key) ORDER BY 1);
        IF cardinality(v_list) > 0 THEN
            v_drop_meta := v_drop_meta || format('DELETE FROM %s IN (%s);', v_name, pgerp.dev_in_list(v_list::VARCHAR[]));
            v_changes := v_changes || format(CASE v_key WHEN 'forms' THEN 'Deleted forms: %s' WHEN 'reports' THEN 'Deleted reports: %s'
                                                        WHEN 'roles' THEN 'Deleted roles: %s' ELSE 'Deleted actions: %s' END,
                                             array_to_string(v_list, ', '));
        END IF;
    END LOOP;

    IF (p_new->'sql'->>'translations') IS NOT NULL
       AND (v_full OR (v_old->'sql'->>'translations') IS DISTINCT FROM (p_new->'sql'->>'translations')) THEN
        v_drop_last := v_drop_last || (p_new->'sql'->>'translations');
        v_changes := v_changes || 'Translations'::TEXT;
    END IF;

    IF v_full OR (v_old->'sql'->>'solution') IS DISTINCT FROM (p_new->'sql'->>'solution') THEN
        IF NOT v_full THEN
            v_changes := v_changes || 'Solution description and contents'::TEXT;
        END IF;
    END IF;

    -- Сборка: разделы с заголовками, пустые пропускаются
    SELECT string_agg(format(E'-- %s\n%s', title, array_to_string(parts, E'\n\n')), E'\n\n' ORDER BY n)
    INTO v_script
    FROM (VALUES
        (1, 'Solution', ARRAY[p_new->'sql'->>'solution']),
        (2, 'Renames', v_renames),
        (3, 'Views: drop before re-creation', v_drop_views),
        (4, 'Foreign keys: drop changed ones', v_drop_fk),
        (5, 'Constraints, indexes and triggers: drop changed ones', v_drop_parts),
        (6, 'Dropped tables', v_drop_tables),
        (7, 'Types and sequences', v_types),
        (8, 'Tables', v_tables),
        (9, 'Constraints', v_constraints),
        (10, 'Functions', v_functions),
        (11, 'Views', v_views),
        (12, 'Foreign keys', v_fk),
        (13, 'Indexes', v_indexes),
        (14, 'Triggers', v_triggers),
        (15, 'Comments', v_comments),
        (16, 'Data', v_data),
        (17, 'Metadata', v_meta),
        (18, 'Dropped metadata', v_drop_meta),
        (19, 'Dropped functions and types, translations', v_drop_last)) AS s(n, title, parts)
    WHERE cardinality(array_remove(parts, NULL)) > 0;

    RETURN jsonb_build_object(
        'script', v_script,
        'full', v_full,
        'empty', NOT v_full AND cardinality(v_changes) = 0,
        'changes', to_jsonb(v_changes),
        'warnings', to_jsonb(v_warnings));
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Выпуски
-- ---------------------------------------------------------------------
-- Следующая версия выпуска решения: номера у каждого решения свои (файлы пакета db/solutions/<папка>/V<n>__…)
CREATE FUNCTION pgerp.solution_next_version(p_solution VARCHAR)
RETURNS INT AS $$
    SELECT COALESCE(max(version), 0) + 1 FROM pgerp.solution_releases WHERE solution = p_solution;
$$ LANGUAGE sql STABLE;

-- Схема решения; решения нет — public
CREATE FUNCTION pgerp.solution_schema(p_solution VARCHAR)
RETURNS VARCHAR AS $$
    SELECT COALESCE((SELECT db_schema FROM pgerp.solutions WHERE name = p_solution), 'public');
$$ LANGUAGE sql STABLE;

-- Часть имени файла из названия выпуска: латиница, цифры и _
CREATE FUNCTION pgerp.dev_slug(p_text TEXT)
RETURNS TEXT AS $$
DECLARE
    v_text TEXT := lower(COALESCE(p_text, ''));
    v_pair TEXT[];
BEGIN
    FOREACH v_pair SLICE 1 IN ARRAY ARRAY[['ж', 'zh'], ['ч', 'ch'], ['ш', 'sh'], ['щ', 'sch'], ['ю', 'yu'], ['я', 'ya'],
                                          ['х', 'kh'], ['ц', 'ts'], ['ё', 'e'], ['ъ', ''], ['ь', '']] LOOP
        v_text := replace(v_text, v_pair[1], v_pair[2]);
    END LOOP;
    v_text := translate(v_text, 'абвгдезийклмнопрстуфыэ', 'abvgdeziyklmnoprstufye');
    v_text := trim(BOTH '_' FROM regexp_replace(v_text, '[^a-z0-9]+', '_', 'g'));
    RETURN COALESCE(NULLIF(left(v_text, 50), ''), 'release');
END;
$$ LANGUAGE plpgsql IMMUTABLE;

-- Применение выпуска (файл пакета решения): один раз на базу. Объекты создаются в схеме решения:
-- она первая в пути поиска. Схема — уже установленного решения, иначе выбранная при установке
-- (pgerp.install_schema, ставит установщик), иначе public
CREATE FUNCTION pgerp.solution_release_apply(p_solution VARCHAR, p_version INT, p_label TEXT, p_script TEXT)
RETURNS VOID AS $$
DECLARE
    v_schema VARCHAR := COALESCE((SELECT db_schema FROM pgerp.solutions WHERE name = p_solution),
                                 NULLIF(current_setting('pgerp.install_schema', TRUE), ''), 'public');
BEGIN
    IF EXISTS (SELECT 1 FROM pgerp.solution_releases WHERE solution = p_solution AND version = p_version) THEN
        RAISE NOTICE 'Release % of solution % is already in this database — skipped', p_version, p_solution;
        RETURN;
    END IF;
    PERFORM ui_require(v_schema ~ '^[a-z_][a-z0-9_]*$' AND v_schema !~ '^pg_' AND v_schema <> 'pgerp',
                       format('Schema “%s” is not allowed for a solution', v_schema));
    EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);
    PERFORM set_config('search_path', format('%I, ', v_schema) || pgerp.app_search_path(), TRUE);
    -- Функции ссылаются друг на друга и на представления, создаваемые ниже в том же выпуске
    PERFORM set_config('check_function_bodies', 'off', TRUE);
    EXECUTE p_script;
    UPDATE pgerp.solutions SET db_schema = v_schema WHERE name = p_solution;
    PERFORM set_config('search_path', pgerp.app_search_path(), TRUE);
    INSERT INTO pgerp.solution_releases (solution, version, label, snapshot, created_by)
    VALUES (p_solution, p_version, p_label, pgerp.solution_state(p_solution), COALESCE(pgerp.ui_user(), 'install'));
END;
$$ LANGUAGE plpgsql;

-- Выпуск: скрипт и файл пакета решения. p_full — решение целиком, без разницы с прошлым выпуском
CREATE FUNCTION pgerp.solution_release_build(p_solution VARCHAR, p_label TEXT, p_full BOOLEAN)
RETURNS JSONB AS $$
DECLARE
    v_s       pgerp.solutions%ROWTYPE;
    v_last    pgerp.solution_releases%ROWTYPE;
    v_state   JSONB;
    v_diff    JSONB;
    v_version INT := pgerp.solution_next_version(p_solution);
    v_label   TEXT := COALESCE(NULLIF(trim(p_label), ''), format('Release %s', pgerp.solution_next_version(p_solution)));
    v_file    TEXT;
    v_tag     TEXT := '$release$';
    v_n       INT  := 0;
BEGIN
    SELECT * INTO v_s FROM pgerp.solutions WHERE name = p_solution;
    PERFORM ui_require(FOUND, format('Solution “%s” not found', p_solution));
    PERFORM ui_require(NOT v_s.is_core, 'The platform core is released through core migrations, not from the editor');

    SELECT * INTO v_last FROM pgerp.solution_releases WHERE solution = p_solution ORDER BY version DESC LIMIT 1;
    v_state := pgerp.solution_state(p_solution);
    v_diff := pgerp.solution_script(v_state, CASE WHEN p_full THEN NULL ELSE v_last.snapshot END, v_last.created_at);

    WHILE strpos(v_diff->>'script', v_tag) > 0 LOOP
        v_n := v_n + 1;
        v_tag := format('$release%s$', v_n);
    END LOOP;
    v_file := format('V%s__%s_%s.sql', v_version, p_solution, pgerp.dev_slug(p_label));

    RETURN jsonb_build_object(
        'solution', p_solution,
        'version', v_version,
        'label', v_label,
        'base_version', CASE WHEN NOT p_full THEN v_last.version END,
        'folder', v_s.migration_folder,
        'file_name', v_file,
        'path', format('src/main/resources/db/solutions/%s/%s', v_s.migration_folder, v_file),
        -- Описание пакета: шлюз создаёт solution.json, если его ещё нет
        'manifest', jsonb_strip_nulls(jsonb_build_object('name', v_s.name, 'title', v_s.title, 'description', v_s.description,
                                                         'schema', v_s.db_schema)),
        'full', v_diff->'full',
        'empty', v_diff->'empty',
        'changes', v_diff->'changes',
        'warnings', v_diff->'warnings',
        'snapshot', v_state,
        'content', concat_ws(E'\n',
            format('-- PgERP: release %s of solution “%s” (%s) — %s', v_version, v_s.title, p_solution, v_label),
            format('-- Created %s, %s. %s', to_char(now(), 'YYYY-MM-DD HH24:MI'), COALESCE(pgerp.ui_user(), 'no user'),
                   CASE WHEN (v_diff->>'full')::BOOLEAN THEN 'The whole solution.'
                        ELSE format('Changes since release %s:', v_last.version) END),
            (SELECT string_agg('--   * ' || c, E'\n') FROM jsonb_array_elements_text(v_diff->'changes') c
             WHERE NOT (v_diff->>'full')::BOOLEAN),
            (SELECT E'-- Warning:\n' || string_agg('--   ! ' || w, E'\n') FROM jsonb_array_elements_text(v_diff->'warnings') w
             HAVING count(*) > 0),
            '-- A release is applied once: a database where it is already recorded (pgerp.solution_releases) skips it.',
            format('SELECT pgerp.solution_release_apply(%L, %s, %L, %s', p_solution, v_version, v_label, v_tag),
            COALESCE(v_diff->>'script', '-- no changes'),
            v_tag || ');',
            ''));
END;
$$ LANGUAGE plpgsql STABLE;


-- ---------------------------------------------------------------------
-- Установка пакетов решений (вызывает шлюз: редактор, окно первого входа, обновление при запуске)
-- ---------------------------------------------------------------------
-- Начало установки или обновления: p_login — администратор (NULL — обновление при запуске приложения),
-- p_schema — схема нового решения (по умолчанию — из solution.json, иначе имя решения). Возвращает
-- установленную версию (0 — не установлено): шлюз выполняет файлы пакета с номерами больше неё.
-- p_reset — чистая установка: решение и его схема удаляются перед установкой (pgerp.solution_reset)
CREATE FUNCTION pgerp.solution_install_begin(p_login VARCHAR, p_solution VARCHAR, p_schema VARCHAR,
                                             p_reset BOOLEAN DEFAULT FALSE)
RETURNS INT AS $$
DECLARE
    v_user_id BIGINT;
    v_schema  VARCHAR := lower(trim(COALESCE(p_schema, '')));
BEGIN
    IF p_login IS NOT NULL THEN
        SELECT id INTO v_user_id FROM pgerp.users WHERE login = p_login AND is_active;
        IF v_user_id IS NULL OR NOT pgerp.auth_is_admin(v_user_id) THEN
            RAISE EXCEPTION USING ERRCODE = 'U0003', MESSAGE = pgerp.ui_t('Only an administrator can install solutions');
        END IF;
        PERFORM set_config('pgerp.user', p_login, TRUE);
    END IF;
    PERFORM ui_require(p_solution ~ '^[a-z][a-z0-9_]*$' AND p_solution <> 'core', format('Invalid solution name: %s', p_solution));
    IF p_reset THEN
        PERFORM ui_require(p_login IS NOT NULL, 'A clean installation is started only by an administrator');
        PERFORM pgerp.solution_reset(p_solution, COALESCE(NULLIF(v_schema, ''), p_solution));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE name = p_solution) THEN
        v_schema := COALESCE(NULLIF(v_schema, ''), p_solution);
        PERFORM ui_require(v_schema ~ '^[a-z_][a-z0-9_]*$' AND v_schema !~ '^pg_' AND v_schema <> 'pgerp' AND length(v_schema) <= 63,
                           'Schema: lowercase Latin letters, digits and _; not pgerp and not pg_…');
        PERFORM set_config('pgerp.install_schema', v_schema, TRUE);
    END IF;
    RETURN COALESCE((SELECT max(version) FROM pgerp.solution_releases WHERE solution = p_solution), 0);
END;
$$ LANGUAGE plpgsql;

-- Чистая установка: удалить решение — его формы, действия, отчёты, роли, папку меню, выпуски — и схему
-- со всеми таблицами и данными. Своя схема удаляется целиком (DROP SCHEMA … CASCADE); в public — только
-- объекты решения. p_schema — схема, если решение ещё не установлено (осталась от прошлой установки).
-- Переводы и пользователи остаются: пакет добавляет их без повторов
CREATE FUNCTION pgerp.solution_reset(p_solution VARCHAR, p_schema VARCHAR)
RETURNS VOID AS $$
DECLARE
    v_s       pgerp.solutions%ROWTYPE;
    v_schema  VARCHAR := lower(trim(COALESCE(p_schema, '')));
    v_actions VARCHAR[];
    v_drop    TEXT;
BEGIN
    SELECT * INTO v_s FROM pgerp.solutions WHERE name = p_solution;
    IF FOUND THEN
        PERFORM ui_require(NOT v_s.is_core, 'The platform core cannot be reinstalled');
        v_schema := v_s.db_schema;
        -- Состав решения — до удаления схемы: действия решения узнаются по его функциям
        v_actions := ARRAY(SELECT pgerp.solution_members(p_solution, 'action'));
        IF v_s.menu_folder IS NOT NULL THEN
            PERFORM pgerp.solution_menu_apply(v_s.menu_folder, NULL);
        END IF;
        DELETE FROM pgerp.forms WHERE form_name IN (SELECT pgerp.solution_members(p_solution, 'form'));
        DELETE FROM pgerp.reports WHERE name IN (SELECT pgerp.solution_members(p_solution, 'report'));
        DELETE FROM pgerp.roles WHERE role_name IN (SELECT pgerp.solution_members(p_solution, 'role'));
        DELETE FROM pgerp.grid_row_actions WHERE row_action = ANY (v_actions);
        DELETE FROM pgerp.ui_actions WHERE action_name = ANY (v_actions);
        IF v_schema = 'public' THEN
            FOR v_drop IN
                SELECT format('DROP %s IF EXISTS %s CASCADE', CASE o.object_type WHEN 'table' THEN 'TABLE' WHEN 'sequence' THEN 'SEQUENCE'
                                  WHEN 'type' THEN 'TYPE' WHEN 'view' THEN
                                      CASE WHEN c.relkind = 'm' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END END,
                              format('public.%I', o.object_name))
                FROM pgerp.dev_objects o
                LEFT JOIN pg_class c ON c.relname = o.object_name AND c.relnamespace = 'public'::regnamespace
                WHERE o.solution = p_solution AND o.object_type IN ('table', 'view', 'sequence', 'type')
                UNION ALL
                SELECT format('DROP ROUTINE IF EXISTS %s CASCADE', p.oid::regprocedure)
                FROM pg_proc p
                WHERE p.pronamespace = 'public'::regnamespace AND p.prokind IN ('f', 'p')
                  AND p.proname IN (SELECT pgerp.solution_members(p_solution, 'function'))
            LOOP
                EXECUTE v_drop;
            END LOOP;
        END IF;
        DELETE FROM pgerp.solutions WHERE name = p_solution;
    END IF;
    IF v_schema <> 'public' THEN
        PERFORM ui_require(v_schema ~ '^[a-z_][a-z0-9_]*$' AND v_schema !~ '^pg_' AND v_schema NOT IN ('pgerp', 'information_schema'),
                           format('Schema “%s” cannot be deleted', v_schema));
        PERFORM ui_require(NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE db_schema = v_schema),
                           format('Schema “%s” belongs to another solution', v_schema));
        EXECUTE format('DROP SCHEMA IF EXISTS %I CASCADE', v_schema);
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Конец установки: путь поиска базы по умолчанию — со схемами решений (для консоли psql и заданий;
-- приложение ставит его само в каждом действии). Нет прав на ALTER DATABASE — не страшно
CREATE FUNCTION pgerp.solution_install_end(p_solution VARCHAR)
RETURNS JSON AS $$
BEGIN
    BEGIN
        EXECUTE format('ALTER DATABASE %I SET search_path = %s', current_database(), pgerp.app_search_path());
    EXCEPTION WHEN insufficient_privilege THEN
        NULL;
    END;
    RETURN (SELECT json_build_object('name', name, 'title', title, 'db_schema', db_schema,
                                     'version', (SELECT max(version) FROM pgerp.solution_releases r WHERE r.solution = s.name))
            FROM pgerp.solutions s WHERE name = p_solution);
END;
$$ LANGUAGE plpgsql;

-- Установленные решения и их версии — для списка пакетов
CREATE FUNCTION pgerp.solution_packages_state()
RETURNS JSON AS $$
    SELECT COALESCE(json_object_agg(s.name, json_build_object(
               'title', s.title, 'db_schema', s.db_schema,
               'version', (SELECT max(version) FROM pgerp.solution_releases r WHERE r.solution = s.name))), '{}')
    FROM pgerp.solutions s
    WHERE NOT s.is_core;
$$ LANGUAGE sql STABLE;

-- solutions_setup_done: {} — администратор выбрал решения при первом входе (окно больше не показывается)
CREATE FUNCTION pgerp.ui_solutions_setup_done(p_data JSON)
RETURNS JSON AS $$
BEGIN
    INSERT INTO pgerp.settings (key, value) VALUES ('solutions_setup', to_jsonb(pgerp.ui_user()))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
    RETURN ui_ok();
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Действия: решения
-- ---------------------------------------------------------------------
CREATE FUNCTION pgerp.solution_json(p_s pgerp.solutions)
RETURNS JSONB AS $$
    SELECT jsonb_build_object(
        'name', p_s.name, 'title', p_s.title, 'prefix', p_s.prefix, 'menu_folder', p_s.menu_folder,
        'migration_folder', p_s.migration_folder, 'description', p_s.description, 'is_core', p_s.is_core,
        'db_schema', p_s.db_schema,
        'installed_version', (SELECT max(version) FROM pgerp.solution_releases WHERE solution = p_s.name),
        'counts', (SELECT COALESCE(jsonb_object_agg(object_type, n), '{}')
                   FROM (SELECT object_type, count(*) AS n FROM pgerp.dev_objects WHERE solution = p_s.name GROUP BY 1) c),
        'last_release', (SELECT jsonb_build_object('version', version, 'label', label, 'created_at', created_at)
                         FROM pgerp.solution_releases WHERE solution = p_s.name ORDER BY version DESC LIMIT 1));
$$ LANGUAGE sql STABLE;

-- solution_list: {} → решения и число объектов вне решений
CREATE FUNCTION pgerp.ui_solution_list(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object(
        'status', 'success',
        'solutions', COALESCE((SELECT jsonb_agg(pgerp.solution_json(s)
                                                || jsonb_build_object('title', pgerp.ui_t_exact(s.title))
                                                ORDER BY s.is_core, s.title)
                               FROM pgerp.solutions s), '[]'),
        'unassigned', (SELECT count(*) FROM pgerp.dev_objects WHERE solution IS NULL));
$$ LANGUAGE sql STABLE;

-- solution_get: {"name"} → решение, его объекты и выпуски; без имени — заготовка нового и объекты вне решений
CREATE FUNCTION pgerp.ui_solution_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_s pgerp.solutions%ROWTYPE;
BEGIN
    IF NULLIF(p_data->>'name', '') IS NOT NULL THEN
        SELECT * INTO v_s FROM pgerp.solutions WHERE name = p_data->>'name';
        PERFORM ui_require(FOUND, format('Solution “%s” not found', p_data->>'name'));
    END IF;
    RETURN json_build_object(
        'status', 'success',
        'solution', CASE WHEN v_s.name IS NULL
            THEN jsonb_build_object('is_new', TRUE, 'name', '', 'title', '', 'prefix', NULL, 'menu_folder', NULL,
                                    'migration_folder', NULL, 'description', NULL, 'is_core', FALSE, 'db_schema', NULL)
            ELSE pgerp.solution_json(v_s) || jsonb_build_object('is_new', FALSE) END,
        'objects', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                 'type', o.object_type, 'name', o.object_name, 'explicit', o.is_explicit,
                                 'data', o.object_type = 'table' AND EXISTS (SELECT 1 FROM pgerp.solution_data d WHERE d.table_name = o.object_name))
                             ORDER BY o.object_type, o.object_name)
                             FROM pgerp.dev_objects o WHERE o.solution = v_s.name), '[]'),
        'unassigned', COALESCE((SELECT jsonb_agg(jsonb_build_object('type', o.object_type, 'name', o.object_name)
                                                 ORDER BY o.object_type, o.object_name)
                                FROM pgerp.dev_objects o WHERE o.solution IS NULL), '[]'),
        'releases', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                                  'version', r.version, 'label', r.label, 'file_name', r.file_name,
                                  'created_at', r.created_at, 'created_by', r.created_by, 'has_script', r.script IS NOT NULL)
                              ORDER BY r.version DESC)
                              FROM pgerp.solution_releases r WHERE r.solution = v_s.name), '[]'));
END;
$$ LANGUAGE plpgsql STABLE;

-- solution_save: {is_new, name, title, prefix, menu_folder, migration_folder, db_schema, description}.
-- Схема задаётся новому решению (по умолчанию — имя решения) и создаётся; потом не меняется
CREATE FUNCTION pgerp.ui_solution_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name   TEXT    := lower(COALESCE(ui_text(p_data, 'name'), ''));
    v_schema TEXT    := lower(COALESCE(ui_text(p_data, 'db_schema'), ui_text(p_data, 'name'), ''));
    v_title  TEXT    := ui_text(p_data, 'title');
    v_prefix TEXT    := lower(ui_text(p_data, 'prefix'));
    v_folder TEXT    := lower(COALESCE(ui_text(p_data, 'migration_folder'), lower(COALESCE(ui_text(p_data, 'name'), ''))));
    v_is_new BOOLEAN := COALESCE((p_data->>'is_new')::BOOLEAN, FALSE);
BEGIN
    PERFORM ui_require(v_name ~ '^[a-z][a-z0-9_]*$' AND length(v_name) <= 50,
                       'Solution name: lowercase Latin letters, digits and _, starting with a letter');
    PERFORM ui_require(v_title IS NOT NULL, 'Enter the solution title');
    PERFORM ui_require(v_prefix IS NULL OR (v_prefix ~ '^[a-z][a-z0-9_]*$' AND length(v_prefix) <= 30),
                       'Prefix: lowercase Latin letters, digits and _, for example my_app_');
    PERFORM ui_require(v_folder ~ '^[a-z][a-z0-9_]*$', 'Package folder: lowercase Latin letters, digits and _');
    PERFORM ui_require(v_folder <> 'core', 'The core folder belongs to the core; choose another one');
    PERFORM ui_require(v_prefix IS NULL OR NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE prefix = v_prefix AND name <> v_name),
                       format('Prefix %s already belongs to another solution', v_prefix));

    IF v_is_new THEN
        PERFORM ui_require(NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE name = v_name),
                           format('Solution “%s” already exists — choose another name', v_name));
        PERFORM ui_require(v_schema ~ '^[a-z_][a-z0-9_]*$' AND v_schema !~ '^pg_' AND v_schema <> 'pgerp' AND length(v_schema) <= 63,
                           'Schema: lowercase Latin letters, digits and _; not pgerp and not pg_…');
        EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_schema);
        INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description, db_schema)
        VALUES (v_name, v_title, v_prefix, ui_text(p_data, 'menu_folder'), v_folder, ui_text(p_data, 'description'), v_schema);
    ELSE
        PERFORM ui_require(NOT COALESCE((SELECT is_core FROM pgerp.solutions WHERE name = v_name), FALSE),
                           'The platform core cannot be changed in the editor');
        UPDATE pgerp.solutions
        SET title = v_title, prefix = v_prefix, menu_folder = ui_text(p_data, 'menu_folder'),
            migration_folder = v_folder, description = ui_text(p_data, 'description')
        WHERE name = v_name;
        PERFORM ui_require(FOUND, format('Solution “%s” not found', v_name));
    END IF;
    RETURN (ui_ok(ui_message(format('Solution “%s” saved', v_title))) || jsonb_build_object('name', v_name))::JSON;
END;
$$ LANGUAGE plpgsql;

-- solution_delete: {"name"} — объекты остаются в базе, но выходят из решения
CREATE FUNCTION pgerp.ui_solution_delete(p_data JSON)
RETURNS JSON AS $$
BEGIN
    PERFORM ui_require(NOT COALESCE((SELECT is_core FROM pgerp.solutions WHERE name = p_data->>'name'), FALSE),
                       'The platform core cannot be changed in the editor');
    -- Своя схема с объектами выпала бы из пути поиска — код решения перестал бы работать
    PERFORM ui_require(NOT EXISTS (SELECT 1 FROM pgerp.solutions s JOIN pg_class c ON c.relnamespace = to_regnamespace(s.db_schema)
                                   WHERE s.name = p_data->>'name' AND s.db_schema <> 'public'),
                       format('The schema of solution “%s” has tables: delete them or move them to another solution first', p_data->>'name'));
    DELETE FROM pgerp.solutions WHERE name = p_data->>'name';
    PERFORM ui_require(FOUND, format('Solution “%s” not found', p_data->>'name'));
    RETURN ui_ok(ui_message(format('Solution “%s” deleted; its objects remain in the database', p_data->>'name')));
END;
$$ LANGUAGE plpgsql;

-- solution_object_set: {"type", "name", "solution"} — явно включить объект в решение; пустое решение — исключить
CREATE FUNCTION pgerp.ui_solution_object_set(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_type     TEXT := p_data->>'type';
    v_name     TEXT := p_data->>'name';
    v_solution TEXT := ui_text(p_data, 'solution');
BEGIN
    PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.dev_catalog WHERE object_type = v_type AND object_name = v_name),
                       format('There is no %s “%s”', v_type, v_name));
    IF v_solution IS NULL THEN
        DELETE FROM pgerp.solution_objects WHERE object_type = v_type AND object_name = v_name;
    ELSE
        PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.solutions WHERE name = v_solution AND NOT is_core),
                           format('Solution “%s” not found', v_solution));
        INSERT INTO pgerp.solution_objects (object_type, object_name, solution) VALUES (v_type, v_name, v_solution)
        ON CONFLICT (object_type, object_name) DO UPDATE SET solution = EXCLUDED.solution;
    END IF;
    DELETE FROM pgerp.solution_data d
    WHERE v_type = 'table' AND d.table_name = v_name AND d.solution IS DISTINCT FROM pgerp.solution_of('table', v_name);
    RETURN json_build_object('status', 'success', 'solution', pgerp.solution_of(v_type, v_name));
END;
$$ LANGUAGE plpgsql;

-- solution_data_set: {"table", "enabled"} — переносить ли строки таблицы в выпуске
CREATE FUNCTION pgerp.ui_solution_data_set(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_table    TEXT := p_data->>'table';
    v_solution TEXT := pgerp.solution_of('table', p_data->>'table');
BEGIN
    PERFORM ui_require(v_solution IS NOT NULL AND EXISTS (SELECT 1 FROM pgerp.dev_catalog WHERE object_type = 'table' AND object_name = v_table),
                       format('Table “%s” does not belong to any solution', v_table));
    IF COALESCE((p_data->>'enabled')::BOOLEAN, TRUE) THEN
        INSERT INTO pgerp.solution_data (table_name, solution) VALUES (v_table, v_solution)
        ON CONFLICT (table_name) DO UPDATE SET solution = EXCLUDED.solution;
    ELSE
        DELETE FROM pgerp.solution_data WHERE table_name = v_table;
    END IF;
    RETURN json_build_object('status', 'success');
END;
$$ LANGUAGE plpgsql;

-- Изменения и предупреждения выпуска — на языке пользователя (текст миграции остаётся на исходном)
CREATE FUNCTION pgerp.dev_release_translated(p_release JSONB)
RETURNS JSONB AS $$
    SELECT p_release || jsonb_build_object(
        'changes', COALESCE((SELECT jsonb_agg(pgerp.ui_t(c) ORDER BY n) FROM jsonb_array_elements_text(p_release->'changes') WITH ORDINALITY AS t(c, n)), '[]'),
        'warnings', COALESCE((SELECT jsonb_agg(pgerp.ui_t(w) ORDER BY n) FROM jsonb_array_elements_text(p_release->'warnings') WITH ORDINALITY AS t(w, n)), '[]'));
$$ LANGUAGE sql STABLE;

-- release_preview: {"solution", "full"} → что войдёт в выпуск: изменения, предупреждения, текст миграции
CREATE FUNCTION pgerp.ui_release_preview(p_data JSON)
RETURNS JSON AS $$
    SELECT (jsonb_build_object('status', 'success')
            || pgerp.dev_release_translated(pgerp.solution_release_build(p_data->>'solution', p_data->>'label',
                                                                         COALESCE((p_data->>'full')::BOOLEAN, FALSE)) - 'snapshot'))::JSON;
$$ LANGUAGE sql STABLE;

-- release_create: {"solution", "label"} → выпуск записан; файл выпуска — в content (шлюз сохраняет его
-- в пакет решения, если задана папка пакетов ERP_DEV_SOLUTIONS_DIR)
CREATE FUNCTION pgerp.ui_release_create(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_release JSONB;
BEGIN
    -- Номер выпуска: два одновременных выпуска не должны получить одну версию
    LOCK TABLE pgerp.solution_releases IN EXCLUSIVE MODE;
    v_release := pgerp.solution_release_build(p_data->>'solution', p_data->>'label', FALSE);
    PERFORM ui_require(NOT (v_release->>'empty')::BOOLEAN, 'Nothing has changed in the solution since the last release');
    INSERT INTO pgerp.solution_releases (solution, version, label, file_name, script, snapshot, created_by)
    VALUES (v_release->>'solution', (v_release->>'version')::INT, v_release->>'label', v_release->>'file_name',
            v_release->>'content', v_release->'snapshot', pgerp.ui_user());
    RETURN (ui_ok(ui_message(format('Release %s created: %s', v_release->>'version', v_release->>'file_name')))
            || pgerp.dev_release_translated(v_release - 'snapshot'))::JSON;
END;
$$ LANGUAGE plpgsql;

-- release_get: {"solution", "version"} → текст миграции выпуска
CREATE FUNCTION pgerp.ui_release_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_release pgerp.solution_releases%ROWTYPE;
BEGIN
    SELECT * INTO v_release FROM pgerp.solution_releases
    WHERE solution = p_data->>'solution' AND version = (p_data->>'version')::INT;
    PERFORM ui_require(FOUND, format('Release %s of solution “%s” not found', p_data->>'version', p_data->>'solution'));
    RETURN json_build_object('status', 'success', 'release', json_build_object(
        'solution', v_release.solution, 'version', v_release.version, 'label', v_release.label,
        'file_name', v_release.file_name, 'created_at', v_release.created_at, 'created_by', v_release.created_by,
        'content', v_release.script,
        'folder', (SELECT migration_folder FROM pgerp.solutions WHERE name = v_release.solution)));
END;
$$ LANGUAGE plpgsql STABLE;

-- release_delete: {"solution", "version"} — отменить последний выпуск: следующий снова соберёт его изменения.
-- Файл выпуска, если его уже сохранили, удаляется вручную
CREATE FUNCTION pgerp.ui_release_delete(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_version INT := (p_data->>'version')::INT;
BEGIN
    PERFORM ui_require(v_version = (SELECT max(version) FROM pgerp.solution_releases WHERE solution = p_data->>'solution'),
                       'Only the last release of a solution can be cancelled');
    PERFORM ui_require(v_version > 0, 'The initial state of a solution cannot be cancelled');
    DELETE FROM pgerp.solution_releases WHERE solution = p_data->>'solution' AND version = v_version;
    RETURN ui_ok(ui_message(format('Release %s cancelled. If the release file has already been saved, delete it', v_version)));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Схема данных: просмотр, конструктор таблиц, представления, удаление объектов
-- ---------------------------------------------------------------------
CREATE FUNCTION pgerp.dev_ident(p_name TEXT, p_what TEXT)
RETURNS TEXT AS $$
BEGIN
    PERFORM ui_require(p_name ~ '^[a-z_][a-z0-9_]*$' AND length(p_name) <= 63,
                       format('%s “%s”: lowercase Latin letters, digits and _, up to 63 characters', pgerp.ui_t(p_what), COALESCE(p_name, '')));
    RETURN p_name;
END;
$$ LANGUAGE plpgsql STABLE;

-- Тип колонки в каноническом виде (varchar(100) → character varying(100)); serial-типы — как есть
CREATE FUNCTION pgerp.dev_type(p_type TEXT, p_column TEXT)
RETURNS TEXT AS $$
DECLARE
    v_type TEXT := lower(trim(COALESCE(p_type, '')));
    v_result TEXT;
BEGIN
    IF v_type IN ('smallserial', 'serial', 'bigserial') THEN
        RETURN v_type;
    END IF;
    BEGIN
        v_result := format_type(to_regtype(v_type), to_regtypemod(v_type));
    EXCEPTION WHEN OTHERS THEN
        v_result := NULL;
    END;
    PERFORM ui_require(v_result IS NOT NULL, format('Column “%s”: unknown type “%s”', p_column, p_type));
    RETURN v_result;
END;
$$ LANGUAGE plpgsql STABLE;

CREATE FUNCTION pgerp.dev_columns_list(p_columns JSON, p_what TEXT)
RETURNS TEXT AS $$
DECLARE
    v_list TEXT;
BEGIN
    SELECT string_agg(format('%I', pgerp.dev_ident(c, p_what)), ', ' ORDER BY n) INTO v_list
    FROM json_array_elements_text(COALESCE(p_columns, '[]')) WITH ORDINALITY AS t(c, n);
    PERFORM ui_require(v_list IS NOT NULL, format('%s: select columns', pgerp.ui_t(p_what)));
    RETURN v_list;
END;
$$ LANGUAGE plpgsql STABLE;

-- schema_get: {"solution"} — таблицы, представления и функции решения; без решения — всех схем решений и public
CREATE FUNCTION pgerp.ui_schema_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_solution TEXT := ui_text(p_data, 'solution');
BEGIN
    RETURN json_build_object(
        'status', 'success',
        'tables', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'name', o.object_name, 'solution', o.solution, 'comment', obj_description(c.oid, 'pg_class'),
                       'rows', GREATEST(c.reltuples, 0)::BIGINT,
                       'data', EXISTS (SELECT 1 FROM pgerp.solution_data d WHERE d.table_name = o.object_name),
                       'columns', (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
                                              'name', a.attname, 'type', format_type(a.atttypid, a.atttypmod),
                                              'not_null', a.attnotnull,
                                              'pk', EXISTS (SELECT 1 FROM pg_constraint k WHERE k.conrelid = c.oid AND k.contype = 'p'
                                                                                            AND a.attnum = ANY (k.conkey)),
                                              'ref', (SELECT format('%s.%s', f.confrelid::regclass, ra.attname)
                                                      FROM pg_constraint f
                                                      JOIN pg_attribute ra ON ra.attrelid = f.confrelid AND ra.attnum = f.confkey[1]
                                                      WHERE f.conrelid = c.oid AND f.contype = 'f' AND f.conkey = ARRAY[a.attnum]
                                                      LIMIT 1),
                                              'comment', col_description(c.oid, a.attnum))) ORDER BY a.attnum)
                                   FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped))
                   ORDER BY o.object_name)
            FROM pgerp.dev_objects o
            JOIN pg_class c ON c.relname = o.object_name AND c.relnamespace = ANY (pgerp.app_schema_oids())
            WHERE o.object_type = 'table' AND (v_solution IS NULL OR o.solution = v_solution)), '[]'),
        'views', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'name', o.object_name, 'solution', o.solution, 'materialized', c.relkind = 'm',
                       'comment', obj_description(c.oid, 'pg_class'),
                       'columns', (SELECT jsonb_agg(jsonb_build_object('name', a.attname, 'type', format_type(a.atttypid, a.atttypmod))
                                                    ORDER BY a.attnum)
                                   FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped))
                   ORDER BY o.object_name)
            FROM pgerp.dev_objects o
            JOIN pg_class c ON c.relname = o.object_name AND c.relnamespace = ANY (pgerp.app_schema_oids())
            WHERE o.object_type = 'view' AND (v_solution IS NULL OR o.solution = v_solution)), '[]'),
        'functions', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'name', p.proname, 'signature', format('%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)),
                       'result', pg_get_function_result(p.oid), 'solution', o.solution,
                       'kind', CASE WHEN a.action_name IS NOT NULL THEN 'action'
                                    WHEN p.prorettype = 'trigger'::regtype THEN 'trigger' ELSE 'helper' END,
                       'action', a.action_name, 'description', a.description)
                   ORDER BY p.proname, p.oid)
            FROM pgerp.dev_objects o
            JOIN pg_proc p ON p.proname = o.object_name AND p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.prokind IN ('f', 'p')
            LEFT JOIN pgerp.ui_actions a ON a.function_name = p.oid
            WHERE o.object_type = 'function' AND (v_solution IS NULL OR o.solution = v_solution)), '[]'));
END;
$$ LANGUAGE plpgsql STABLE;

-- table_get: {"name"} — структура таблицы для конструктора; без имени — заготовка новой
CREATE FUNCTION pgerp.ui_table_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name  TEXT := ui_text(p_data, 'name');
    v_table REGCLASS;
BEGIN
    IF v_name IS NULL THEN
        RETURN json_build_object('status', 'success', 'table', json_build_object(
            'is_new', TRUE, 'name', '', 'comment', NULL, 'solution', ui_text(p_data, 'solution'),
            'columns', json_build_array(json_build_object('name', 'id', 'type', 'bigserial', 'not_null', TRUE, 'default', NULL, 'comment', NULL)),
            'primary_key', json_build_array('id'),
            'foreign_keys', '[]'::JSON, 'uniques', '[]'::JSON, 'checks', '[]'::JSON, 'indexes', '[]'::JSON,
            'triggers', '[]'::JSON, 'referenced_by', '[]'::JSON));
    END IF;
    v_table := pgerp.app_rel(v_name);
    PERFORM ui_require(v_table IS NOT NULL AND (SELECT relkind IN ('r', 'p') FROM pg_class WHERE oid = v_table),
                       format('Table “%s” not found', v_name));
    RETURN json_build_object('status', 'success', 'table', json_build_object(
        'is_new', FALSE,
        'name', v_name,
        'solution', pgerp.solution_of('table', v_name),
        'data', EXISTS (SELECT 1 FROM pgerp.solution_data WHERE table_name = v_name),
        'comment', obj_description(v_table, 'pg_class'),
        'rows', (SELECT GREATEST(reltuples, 0)::BIGINT FROM pg_class WHERE oid = v_table),
        'columns', (SELECT json_agg(json_build_object(
                                'name', c->>'name', 'type', COALESCE(c->>'serial', c->>'type'),
                                'not_null', (c->>'not_null')::BOOLEAN,
                                'default', CASE WHEN c->>'serial' IS NULL THEN c->>'default' END,
                                'generated', c->>'generated', 'identity', c->>'identity', 'comment', c->>'comment') ORDER BY n)
                    FROM jsonb_array_elements(pgerp.dev_table_state(v_table)->'columns') WITH ORDINALITY AS t(c, n)),
        'primary_key', COALESCE((SELECT json_agg(a.attname ORDER BY k.n)
                                 FROM pg_constraint c CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, n)
                                 JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
                                 WHERE c.conrelid = v_table AND c.contype = 'p'), '[]'),
        'foreign_keys', COALESCE((SELECT json_agg(json_build_object(
                                      'name', c.conname, 'def', pg_get_constraintdef(c.oid),
                                      'columns', (SELECT json_agg(a.attname ORDER BY k.n) FROM unnest(c.conkey) WITH ORDINALITY AS k(attnum, n)
                                                  JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum),
                                      'ref_table', c.confrelid::regclass::TEXT,
                                      'ref_columns', (SELECT json_agg(a.attname ORDER BY k.n) FROM unnest(c.confkey) WITH ORDINALITY AS k(attnum, n)
                                                      JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.attnum),
                                      'on_delete', CASE c.confdeltype WHEN 'c' THEN 'CASCADE' WHEN 'n' THEN 'SET NULL' WHEN 'd' THEN 'SET DEFAULT'
                                                                      WHEN 'r' THEN 'RESTRICT' ELSE 'NO ACTION' END)
                                  ORDER BY c.conname)
                                  FROM pg_constraint c WHERE c.conrelid = v_table AND c.contype = 'f'), '[]'),
        'uniques', COALESCE((SELECT json_agg(json_build_object('name', conname, 'def', pg_get_constraintdef(oid)) ORDER BY conname)
                             FROM pg_constraint WHERE conrelid = v_table AND contype IN ('u', 'x')), '[]'),
        'checks', COALESCE((SELECT json_agg(json_build_object('name', conname, 'def', pg_get_constraintdef(oid)) ORDER BY conname)
                            FROM pg_constraint WHERE conrelid = v_table AND contype = 'c'), '[]'),
        'indexes', COALESCE((SELECT json_agg(json_build_object('name', ic.relname, 'def', pg_get_indexdef(i.indexrelid), 'unique', i.indisunique)
                                             ORDER BY ic.relname)
                             FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
                             WHERE i.indrelid = v_table
                               AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.conrelid = v_table)), '[]'),
        'triggers', COALESCE((SELECT json_agg(json_build_object('name', tgname, 'def', pg_get_triggerdef(oid)) ORDER BY tgname)
                              FROM pg_trigger WHERE tgrelid = v_table AND NOT tgisinternal), '[]'),
        'referenced_by', COALESCE((SELECT json_agg(json_build_object('table', conrelid::regclass::TEXT, 'name', conname) ORDER BY 1)
                                   FROM pg_constraint WHERE confrelid = v_table AND contype = 'f' AND conrelid <> v_table), '[]')));
END;
$$ LANGUAGE plpgsql STABLE;

-- Выполнение операторов конструктора: ошибка называет оператор
CREATE FUNCTION pgerp.dev_execute(p_statements TEXT[])
RETURNS VOID AS $$
DECLARE
    v_sql     TEXT;
    v_message TEXT;
BEGIN
    FOREACH v_sql IN ARRAY p_statements LOOP
        BEGIN
            EXECUTE v_sql;
        EXCEPTION WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
            RAISE EXCEPTION '%', format('%s — in statement: %s', v_message, v_sql);
        END;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Явное включение объекта в решение, если по префиксу он туда не попадает
CREATE FUNCTION pgerp.dev_assign(p_type TEXT, p_name TEXT, p_solution TEXT)
RETURNS VOID AS $$
BEGIN
    IF p_solution IS NOT NULL AND pgerp.solution_of(p_type, p_name) IS DISTINCT FROM p_solution
       AND EXISTS (SELECT 1 FROM pgerp.solutions WHERE name = p_solution AND NOT is_core) THEN
        INSERT INTO pgerp.solution_objects (object_type, object_name, solution) VALUES (p_type, p_name, p_solution)
        ON CONFLICT (object_type, object_name) DO UPDATE SET solution = EXCLUDED.solution;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- table_save: {is_new, name, old_name, solution, comment, columns: [{name, old_name, type, not_null, default, comment}],
-- primary_key: [колонки], foreign_keys: [{name, columns, ref_table, ref_columns, on_delete}], uniques: [{name, columns}],
-- checks: [{name, expression}], indexes: [{name, columns, unique}], apply}.
-- Ограничения и индексы с name — существующие (остаются как есть), без name — новые; существующие, которых нет
-- в списке, удаляются. apply = false — только SQL для предпросмотра
CREATE FUNCTION pgerp.ui_table_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_is_new   BOOLEAN := COALESCE((p_data->>'is_new')::BOOLEAN, FALSE);
    v_name     TEXT    := pgerp.dev_ident(lower(trim(p_data->>'name')), 'Table name');
    v_old_name TEXT    := COALESCE(NULLIF(trim(p_data->>'old_name'), ''), lower(trim(p_data->>'name')));
    v_solution TEXT    := ui_text(p_data, 'solution');
    v_apply    BOOLEAN := COALESCE((p_data->>'apply')::BOOLEAN, FALSE);
    v_table    REGCLASS;
    v_sql      TEXT[]  := '{}';
    v_pre      TEXT[]  := '{}';
    v_head     INT     := 0;
    v_renames  JSONB   := '[]';
    v_items    TEXT[];
    v_col      RECORD;
    v_cur      JSONB;
    v_type     TEXT;
    v_pk_old   TEXT[];
    v_pk_new   TEXT[];
    v_pk_name  TEXT;
    v_item     JSON;
    v_t        TEXT;
    -- Схема: существующей таблицы, иначе решения (указанного или по префиксу имени), иначе public
    v_schema   TEXT;
BEGIN
    PERFORM ui_require(json_typeof(p_data->'columns') = 'array' AND json_array_length(p_data->'columns') > 0,
                       'A table needs at least one column');
    PERFORM ui_require((SELECT count(*) = count(DISTINCT lower(trim(c->>'name'))) FROM json_array_elements(p_data->'columns') c),
                       'Column names must be unique');
    v_schema := COALESCE(CASE WHEN NOT v_is_new THEN (SELECT relnamespace::regnamespace::TEXT FROM pg_class WHERE oid = pgerp.app_rel(v_old_name)) END,
                         pgerp.solution_schema(COALESCE(v_solution, pgerp.solution_of('table', v_name))));
    v_t := format('%I.%I', v_schema, v_name);
    SELECT array_agg(pgerp.dev_ident(c, 'Primary key') ORDER BY n) INTO v_pk_new
    FROM json_array_elements_text(COALESCE(p_data->'primary_key', '[]')) WITH ORDINALITY AS t(c, n);

    IF v_is_new THEN
        PERFORM ui_require(pgerp.app_rel(v_name) IS NULL, format('Table or view “%s” already exists', v_name));
        v_items := ARRAY(
            SELECT format('    %I %s', pgerp.dev_ident(lower(trim(c->>'name')), 'Column'), pgerp.dev_type(c->>'type', c->>'name'))
                || CASE WHEN NULLIF(trim(c->>'default'), '') IS NOT NULL THEN ' DEFAULT ' || trim(c->>'default') ELSE '' END
                || CASE WHEN (c->>'not_null')::BOOLEAN THEN ' NOT NULL' ELSE '' END
            FROM json_array_elements(p_data->'columns') WITH ORDINALITY AS t(c, n) ORDER BY n);
        IF v_pk_new IS NOT NULL THEN
            v_items := v_items || format('    PRIMARY KEY (%s)', (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_pk_new) c));
        END IF;
        v_sql := v_sql || format(E'CREATE TABLE %s (\n%s\n);', v_t, array_to_string(v_items, E',\n'));
    ELSE
        v_table := pgerp.app_rel(v_old_name);
        PERFORM ui_require(v_table IS NOT NULL AND (SELECT relkind IN ('r', 'p') FROM pg_class WHERE oid = v_table),
                           format('Table “%s” not found', v_old_name));
        IF v_old_name <> v_name THEN
            PERFORM ui_require(pgerp.app_rel(v_name) IS NULL, format('Table or view “%s” already exists', v_name));
            v_sql := v_sql || format('ALTER TABLE %I.%I RENAME TO %I;', v_schema, v_old_name, v_name);
            v_head := 1;
            v_renames := v_renames || jsonb_build_object('kind', 'table', 'table', v_old_name, 'old', v_old_name, 'new', v_name);
        END IF;

        -- Колонки: сопоставление по прежнему имени (old_name) или по имени
        FOR v_col IN
            SELECT pgerp.dev_ident(lower(trim(c->>'name')), 'Column') AS name,
                   COALESCE(NULLIF(trim(c->>'old_name'), ''), lower(trim(c->>'name'))) AS old_name,
                   c->>'type' AS type, COALESCE((c->>'not_null')::BOOLEAN, FALSE) AS not_null,
                   NULLIF(trim(c->>'default'), '') AS def, NULLIF(trim(c->>'comment'), '') AS comment, n
            FROM json_array_elements(p_data->'columns') WITH ORDINALITY AS t(c, n)
        LOOP
            SELECT c INTO v_cur FROM jsonb_array_elements(pgerp.dev_table_state(v_table)->'columns') c WHERE c->>'name' = v_col.old_name;
            IF v_cur IS NULL THEN
                v_sql := v_sql || (format('ALTER TABLE %s ADD COLUMN %I %s', v_t, v_col.name, pgerp.dev_type(v_col.type, v_col.name))
                    || COALESCE(' DEFAULT ' || v_col.def, '') || CASE WHEN v_col.not_null THEN ' NOT NULL' ELSE '' END || ';');
                IF v_col.comment IS NOT NULL THEN
                    v_sql := v_sql || format('COMMENT ON COLUMN %s.%I IS %L;', v_t, v_col.name, v_col.comment);
                END IF;
                CONTINUE;
            END IF;
            IF v_col.old_name <> v_col.name THEN
                v_sql := v_sql || format('ALTER TABLE %s RENAME COLUMN %I TO %I;', v_t, v_col.old_name, v_col.name);
                v_renames := v_renames || jsonb_build_object('kind', 'column', 'table', v_name, 'old', v_col.old_name, 'new', v_col.name);
            END IF;
            v_type := pgerp.dev_type(v_col.type, v_col.name);
            IF v_type <> COALESCE(v_cur->>'serial', v_cur->>'type') THEN
                PERFORM ui_require(v_type NOT IN ('smallserial', 'serial', 'bigserial'),
                                   format('Column “%s”: serial can be set only for a new column', v_col.name));
                v_sql := v_sql || format('ALTER TABLE %s ALTER COLUMN %I TYPE %s USING %I::%s;', v_t, v_col.name, v_type, v_col.name, v_type);
            END IF;
            IF v_cur->>'serial' IS NULL AND v_cur->>'generated' IS NULL AND v_col.def IS DISTINCT FROM v_cur->>'default' THEN
                v_sql := v_sql || CASE WHEN v_col.def IS NULL
                    THEN format('ALTER TABLE %s ALTER COLUMN %I DROP DEFAULT;', v_t, v_col.name)
                    ELSE format('ALTER TABLE %s ALTER COLUMN %I SET DEFAULT %s;', v_t, v_col.name, v_col.def) END;
            END IF;
            IF v_col.not_null <> (v_cur->>'not_null')::BOOLEAN AND NOT (v_col.name = ANY (COALESCE(v_pk_new, '{}'))) THEN
                v_sql := v_sql || format('ALTER TABLE %s ALTER COLUMN %I %s NOT NULL;', v_t, v_col.name,
                                         CASE WHEN v_col.not_null THEN 'SET' ELSE 'DROP' END);
            END IF;
            IF v_col.comment IS DISTINCT FROM v_cur->>'comment' THEN
                v_sql := v_sql || format('COMMENT ON COLUMN %s.%I IS %s;', v_t, v_col.name, quote_nullable(v_col.comment));
            END IF;
        END LOOP;
        -- Колонки, которых больше нет
        v_sql := v_sql || ARRAY(
            SELECT format('ALTER TABLE %s DROP COLUMN %I;', v_t, c->>'name')
            FROM jsonb_array_elements(pgerp.dev_table_state(v_table)->'columns') c
            WHERE NOT EXISTS (SELECT 1 FROM json_array_elements(p_data->'columns') n
                              WHERE COALESCE(NULLIF(trim(n->>'old_name'), ''), lower(trim(n->>'name'))) = c->>'name'));

        -- Первичный ключ
        SELECT c.conname, array_agg(a.attname::TEXT ORDER BY k.n) INTO v_pk_name, v_pk_old
        FROM pg_constraint c CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, n)
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.conrelid = v_table AND c.contype = 'p'
        GROUP BY c.conname;
        -- Прежний ключ — с новыми именами переименованных колонок
        v_pk_old := ARRAY(SELECT COALESCE((SELECT lower(trim(n->>'name')) FROM json_array_elements(p_data->'columns') n
                                           WHERE COALESCE(NULLIF(trim(n->>'old_name'), ''), lower(trim(n->>'name'))) = o), o)
                          FROM unnest(v_pk_old) WITH ORDINALITY AS t(o, i) ORDER BY i);
        IF v_pk_old IS DISTINCT FROM v_pk_new AND NOT (cardinality(v_pk_old) = 0 AND v_pk_new IS NULL) THEN
            IF v_pk_name IS NOT NULL THEN
                v_pre := v_pre || format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I;', v_t, v_pk_name);
            END IF;
            IF v_pk_new IS NOT NULL THEN
                v_sql := v_sql || format('ALTER TABLE %s ADD PRIMARY KEY (%s);', v_t, (SELECT string_agg(format('%I', c), ', ') FROM unnest(v_pk_new) c));
            END IF;
        END IF;

        -- Существующие ограничения и индексы, которых нет в списке, — до изменения колонок:
        -- удаление колонки само удаляет её ограничения и индексы
        v_pre := v_pre || ARRAY(
            SELECT format('ALTER TABLE %s DROP CONSTRAINT IF EXISTS %I;', v_t, c.conname)
            FROM pg_constraint c
            WHERE c.conrelid = v_table AND c.contype IN ('f', 'u', 'x', 'c')
              AND NOT EXISTS (SELECT 1 FROM json_array_elements(COALESCE(p_data->'foreign_keys', '[]')) x WHERE x->>'name' = c.conname)
              AND NOT EXISTS (SELECT 1 FROM json_array_elements(COALESCE(p_data->'uniques', '[]')) x WHERE x->>'name' = c.conname)
              AND NOT EXISTS (SELECT 1 FROM json_array_elements(COALESCE(p_data->'checks', '[]')) x WHERE x->>'name' = c.conname)
            ORDER BY c.conname);
        v_pre := v_pre || ARRAY(
            SELECT format('DROP INDEX IF EXISTS %I.%I;', v_schema, ic.relname)
            FROM pg_index i JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = v_table
              AND NOT EXISTS (SELECT 1 FROM pg_constraint c WHERE c.conindid = i.indexrelid AND c.conrelid = v_table)
              AND NOT EXISTS (SELECT 1 FROM json_array_elements(COALESCE(p_data->'indexes', '[]')) x WHERE x->>'name' = ic.relname)
            ORDER BY ic.relname);
        -- Порядок: переименование таблицы, удаления, колонки, ключ
        v_sql := v_sql[1:v_head] || v_pre || v_sql[v_head + 1:];
    END IF;

    -- Новые ограничения и индексы
    FOR v_item IN SELECT x FROM json_array_elements(COALESCE(p_data->'uniques', '[]')) x WHERE NULLIF(x->>'name', '') IS NULL LOOP
        v_sql := v_sql || format('ALTER TABLE %s ADD UNIQUE (%s);', v_t, pgerp.dev_columns_list(v_item->'columns', 'Unique'));
    END LOOP;
    FOR v_item IN SELECT x FROM json_array_elements(COALESCE(p_data->'checks', '[]')) x WHERE NULLIF(x->>'name', '') IS NULL LOOP
        PERFORM ui_require(NULLIF(trim(v_item->>'expression'), '') IS NOT NULL, 'Check: enter a condition');
        v_sql := v_sql || format('ALTER TABLE %s ADD CHECK (%s);', v_t, trim(v_item->>'expression'));
    END LOOP;
    FOR v_item IN SELECT x FROM json_array_elements(COALESCE(p_data->'foreign_keys', '[]')) x WHERE NULLIF(x->>'name', '') IS NULL LOOP
        PERFORM ui_require(pgerp.app_rel(v_item->>'ref_table') IS NOT NULL OR to_regclass(v_item->>'ref_table') IS NOT NULL,
                           format('Foreign key: table “%s” not found', v_item->>'ref_table'));
        v_sql := v_sql || format('ALTER TABLE %s ADD FOREIGN KEY (%s) REFERENCES %s%s%s;', v_t,
            pgerp.dev_columns_list(v_item->'columns', 'Foreign key'),
            COALESCE(pgerp.app_rel(v_item->>'ref_table'), to_regclass(v_item->>'ref_table'))::TEXT,
            CASE WHEN json_array_length(COALESCE(v_item->'ref_columns', '[]')) > 0
                 THEN format(' (%s)', pgerp.dev_columns_list(v_item->'ref_columns', 'Foreign key')) ELSE '' END,
            CASE upper(COALESCE(v_item->>'on_delete', ''))
                WHEN 'CASCADE' THEN ' ON DELETE CASCADE' WHEN 'SET NULL' THEN ' ON DELETE SET NULL'
                WHEN 'RESTRICT' THEN ' ON DELETE RESTRICT' ELSE '' END);
    END LOOP;
    FOR v_item IN SELECT x FROM json_array_elements(COALESCE(p_data->'indexes', '[]')) x WHERE NULLIF(x->>'name', '') IS NULL LOOP
        v_sql := v_sql || format('CREATE %sINDEX ON %s (%s);', CASE WHEN (v_item->>'unique')::BOOLEAN THEN 'UNIQUE ' ELSE '' END,
                                 v_t, pgerp.dev_columns_list(v_item->'columns', 'Index'));
    END LOOP;

    IF v_is_new THEN
        v_sql := v_sql || ARRAY(SELECT format('COMMENT ON COLUMN %s.%I IS %L;', v_t, lower(trim(c->>'name')), trim(c->>'comment'))
                                FROM json_array_elements(p_data->'columns') c WHERE NULLIF(trim(c->>'comment'), '') IS NOT NULL);
    END IF;
    IF ui_text(p_data, 'comment') IS DISTINCT FROM (CASE WHEN v_table IS NOT NULL THEN obj_description(v_table, 'pg_class') END) THEN
        v_sql := v_sql || format('COMMENT ON TABLE %s IS %s;', v_t, quote_nullable(ui_text(p_data, 'comment')));
    END IF;

    IF v_apply AND cardinality(v_sql) > 0 THEN
        PERFORM pgerp.dev_execute(v_sql);
        INSERT INTO pgerp.solution_renames (kind, table_name, old_name, new_name)
        SELECT r->>'kind', r->>'table', r->>'old', r->>'new' FROM jsonb_array_elements(v_renames) r;
        IF v_old_name <> v_name THEN
            UPDATE pgerp.solution_objects SET object_name = v_name WHERE object_type = 'table' AND object_name = v_old_name;
            UPDATE pgerp.solution_data SET table_name = v_name WHERE table_name = v_old_name;
        END IF;
        PERFORM pgerp.dev_assign('table', v_name, v_solution);
    END IF;

    RETURN json_build_object('status', 'success', 'name', v_name, 'applied', v_apply AND cardinality(v_sql) > 0,
                             'statements', to_json(v_sql),
                             'message', CASE WHEN cardinality(v_sql) = 0 THEN 'No changes'
                                             WHEN v_apply THEN format('Table “%s” saved', v_name) END);
END;
$$ LANGUAGE plpgsql;

-- view_get: {"name"} — запрос представления; без имени — заготовка
CREATE FUNCTION pgerp.ui_view_get(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name TEXT := ui_text(p_data, 'name');
    v_view REGCLASS;
BEGIN
    IF v_name IS NULL THEN
        RETURN json_build_object('status', 'success', 'view', json_build_object(
            'is_new', TRUE, 'name', '', 'sql', E'SELECT t.id,\n       t.name\nFROM my_table t', 'comment', NULL,
            'materialized', FALSE, 'solution', ui_text(p_data, 'solution')));
    END IF;
    v_view := pgerp.app_rel(v_name);
    PERFORM ui_require(v_view IS NOT NULL AND (SELECT relkind IN ('v', 'm') FROM pg_class WHERE oid = v_view),
                       format('View “%s” not found', v_name));
    RETURN json_build_object('status', 'success', 'view', json_build_object(
        'is_new', FALSE, 'name', v_name,
        'sql', trim(rtrim(pg_get_viewdef(v_view, TRUE), E'; \n')),
        'materialized', (SELECT relkind = 'm' FROM pg_class WHERE oid = v_view),
        'comment', obj_description(v_view, 'pg_class'),
        'solution', pgerp.solution_of('view', v_name),
        'columns', (SELECT json_agg(json_build_object('name', attname, 'type', format_type(atttypid, atttypmod)) ORDER BY attnum)
                    FROM pg_attribute WHERE attrelid = v_view AND attnum > 0 AND NOT attisdropped),
        'dependents', COALESCE((SELECT json_agg(DISTINCT r.ev_class::regclass::TEXT)
                                FROM pg_depend d JOIN pg_rewrite r ON r.oid = d.objid
                                WHERE d.classid = 'pg_rewrite'::regclass AND d.refobjid = v_view AND r.ev_class <> v_view), '[]')));
END;
$$ LANGUAGE plpgsql STABLE;

-- view_save: {is_new, name, old_name, sql, comment, solution, apply}. Если колонки изменились так, что
-- CREATE OR REPLACE невозможен, представление пересоздаётся (зависимые представления этому мешают — будет ошибка)
CREATE FUNCTION pgerp.ui_view_save(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_is_new   BOOLEAN := COALESCE((p_data->>'is_new')::BOOLEAN, FALSE);
    v_name     TEXT    := pgerp.dev_ident(lower(trim(p_data->>'name')), 'View name');
    v_old_name TEXT    := COALESCE(NULLIF(trim(p_data->>'old_name'), ''), lower(trim(p_data->>'name')));
    v_query    TEXT    := trim(rtrim(COALESCE(p_data->>'sql', ''), E'; \n\t'));
    v_apply    BOOLEAN := COALESCE((p_data->>'apply')::BOOLEAN, FALSE);
    v_mat      BOOLEAN;
    v_sql      TEXT[]  := '{}';
    v_create   TEXT;
    v_message  TEXT;
    v_state    TEXT;
    -- Схема: существующего представления, иначе решения (указанного или по префиксу имени), иначе public
    v_schema   TEXT    := COALESCE((SELECT relnamespace::regnamespace::TEXT FROM pg_class
                                    WHERE oid = pgerp.app_rel(COALESCE(NULLIF(trim(p_data->>'old_name'), ''), lower(trim(p_data->>'name'))))),
                                   pgerp.solution_schema(COALESCE(ui_text(p_data, 'solution'), pgerp.solution_of('view', lower(trim(p_data->>'name'))))));
    v_v        TEXT;
BEGIN
    PERFORM ui_require(v_query <> '', 'Write the view query (SELECT …)');
    v_v := format('%I.%I', v_schema, v_name);
    IF v_is_new THEN
        PERFORM ui_require(pgerp.app_rel(v_name) IS NULL, format('Table or view “%s” already exists', v_name));
        v_mat := FALSE;
    ELSE
        SELECT relkind = 'm' INTO v_mat FROM pg_class WHERE oid = pgerp.app_rel(v_old_name) AND relkind IN ('v', 'm');
        PERFORM ui_require(v_mat IS NOT NULL, format('View “%s” not found', v_old_name));
        IF v_old_name <> v_name THEN
            v_sql := v_sql || format('ALTER %sVIEW %I.%I RENAME TO %I;', CASE WHEN v_mat THEN 'MATERIALIZED ' ELSE '' END, v_schema, v_old_name, v_name);
        END IF;
    END IF;
    v_create := CASE WHEN v_mat THEN format(E'DROP MATERIALIZED VIEW %1$s;\nCREATE MATERIALIZED VIEW %1$s AS\n%2$s;', v_v, v_query)
                     ELSE format(E'CREATE OR REPLACE VIEW %s AS\n%s;', v_v, v_query) END;
    v_sql := v_sql || v_create;
    IF ui_text(p_data, 'comment') IS DISTINCT FROM (CASE WHEN NOT v_is_new THEN obj_description(pgerp.app_rel(v_old_name), 'pg_class') END) THEN
        v_sql := v_sql || format('COMMENT ON %sVIEW %s IS %s;', CASE WHEN v_mat THEN 'MATERIALIZED ' ELSE '' END,
                                 v_v, quote_nullable(ui_text(p_data, 'comment')));
    END IF;

    IF v_apply THEN
        FOREACH v_create IN ARRAY v_sql LOOP
            BEGIN
                EXECUTE v_create;
            EXCEPTION WHEN OTHERS THEN
                GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
                -- Колонки убраны, переименованы или сменили тип: только пересоздание
                IF v_state IN ('42P16', '42804') AND NOT v_mat THEN
                    BEGIN
                        EXECUTE format(E'DROP VIEW %1$s;\nCREATE VIEW %1$s AS\n%2$s;', v_v, v_query);
                        v_sql := array_replace(v_sql, v_create, format(E'DROP VIEW %1$s;\nCREATE VIEW %1$s AS\n%2$s;', v_v, v_query));
                    EXCEPTION WHEN OTHERS THEN
                        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
                        RAISE EXCEPTION '%', format('Could not recreate the view: %s', v_message);
                    END;
                ELSE
                    RAISE EXCEPTION '%', format('%s — in statement: %s', v_message, v_create);
                END IF;
            END;
        END LOOP;
        IF v_old_name <> v_name THEN
            UPDATE pgerp.solution_objects SET object_name = v_name WHERE object_type = 'view' AND object_name = v_old_name;
        END IF;
        PERFORM pgerp.dev_assign('view', v_name, ui_text(p_data, 'solution'));
    END IF;
    RETURN json_build_object('status', 'success', 'name', v_name, 'applied', v_apply, 'statements', to_json(v_sql),
                             'message', CASE WHEN v_apply THEN format('View “%s” saved', v_name) END);
END;
$$ LANGUAGE plpgsql;

-- function_source: {"name"} — полный код функций решений с этим именем (всех перегрузок)
CREATE FUNCTION pgerp.ui_function_source(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_functions JSON;
BEGIN
    SELECT json_agg(json_build_object(
               'signature', format('%I(%s)', p.proname, pg_get_function_identity_arguments(p.oid)),
               'result', pg_get_function_result(p.oid),
               'language', l.lanname,
               'action', (SELECT action_name FROM pgerp.ui_actions WHERE function_name = p.oid LIMIT 1),
               'solution', pgerp.solution_of('function', p.proname),
               'editor_reason', pgerp.ui_function_lock_reason(p.oid::REGPROCEDURE),
               'source', pg_get_functiondef(p.oid)) ORDER BY p.oid)
    INTO v_functions
    FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
    WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.proname = p_data->>'name' AND p.prokind IN ('f', 'p');
    PERFORM ui_require(v_functions IS NOT NULL, format('There is no function “%s” in the solution schemas', p_data->>'name'));
    RETURN json_build_object('status', 'success', 'functions', v_functions);
END;
$$ LANGUAGE plpgsql STABLE;

-- object_drop: {"type": table|view|function|sequence|type|action, "name", "cascade", "apply"}.
-- Без apply — что будет удалено и что от объекта зависит. action — регистрация действия (функция остаётся)
CREATE FUNCTION pgerp.ui_object_drop(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_type    TEXT    := p_data->>'type';
    v_name    TEXT    := p_data->>'name';
    v_cascade BOOLEAN := COALESCE((p_data->>'cascade')::BOOLEAN, FALSE);
    v_apply   BOOLEAN := COALESCE((p_data->>'apply')::BOOLEAN, FALSE);
    v_sql     TEXT[];
    v_deps    TEXT[]  := '{}';
    v_oid     OID;
BEGIN
    PERFORM ui_require(v_type IN ('table', 'view', 'function', 'sequence', 'type', 'action'),
                       'Object type: table, view, function, sequence, type or action');
    PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.dev_catalog WHERE object_type = v_type AND object_name = v_name),
                       format('There is no %s “%s”', v_type, v_name));

    IF v_type = 'action' THEN
        v_deps := ARRAY(SELECT format('form %s, component %s', form_name, component_name) FROM pgerp.form_components WHERE action_event = v_name
                        UNION ALL SELECT format('row button of table %s', source_action) FROM pgerp.grid_row_actions WHERE row_action = v_name
                        UNION ALL SELECT format('report %s', name) FROM pgerp.reports WHERE data_action = v_name
                        UNION ALL SELECT format('cancel action of form %s', form_name) FROM pgerp.forms WHERE cancel_action = v_name);
        PERFORM ui_require(NOT v_apply OR cardinality(v_deps) = 0,
                           format('Action “%s” is used by: %s', v_name, array_to_string(v_deps, '; ')));
        v_sql := ARRAY[format('DELETE FROM pgerp.ui_actions WHERE action_name = %L;', v_name)];
    ELSIF v_type = 'function' THEN
        v_sql := ARRAY(SELECT format('DROP FUNCTION %I.%I(%s)%s;', p.pronamespace::regnamespace::TEXT, p.proname,
                                     pg_get_function_identity_arguments(p.oid), CASE WHEN v_cascade THEN ' CASCADE' ELSE '' END)
                       FROM pg_proc p WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.proname = v_name AND p.prokind IN ('f', 'p'));
        v_deps := ARRAY(SELECT format('action %s', a.action_name) FROM pgerp.ui_actions a JOIN pg_proc p ON p.oid = a.function_name
                        WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.proname = v_name)
               || ARRAY(SELECT format('trigger %s of table %s', t.tgname, t.tgrelid::regclass) FROM pg_trigger t JOIN pg_proc p ON p.oid = t.tgfoid
                        WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.proname = v_name);
        PERFORM ui_require(NOT v_apply OR NOT EXISTS (SELECT 1 FROM pgerp.ui_actions a JOIN pg_proc p ON p.oid = a.function_name
                                                      WHERE p.pronamespace = ANY (pgerp.app_schema_oids()) AND p.proname = v_name),
                           format('Function “%s” handles an action: delete the action first', v_name));
    ELSE
        v_oid := CASE v_type WHEN 'type' THEN pgerp.app_type(v_name)::OID ELSE pgerp.app_rel(v_name)::OID END;
        v_sql := ARRAY[format('DROP %s %I.%I%s;',
            CASE v_type WHEN 'table' THEN 'TABLE' WHEN 'sequence' THEN 'SEQUENCE' WHEN 'type' THEN 'TYPE'
                        ELSE CASE WHEN (SELECT relkind FROM pg_class WHERE oid = v_oid) = 'm' THEN 'MATERIALIZED VIEW' ELSE 'VIEW' END END,
            COALESCE((SELECT relnamespace::regnamespace::TEXT FROM pg_class WHERE oid = v_oid),
                     (SELECT typnamespace::regnamespace::TEXT FROM pg_type WHERE oid = v_oid)),
            v_name, CASE WHEN v_cascade THEN ' CASCADE' ELSE '' END)];
        v_deps := ARRAY(
            SELECT DISTINCT CASE WHEN d.classid = 'pg_rewrite'::regclass
                                 THEN format('view %s', (SELECT ev_class::regclass FROM pg_rewrite WHERE oid = d.objid))
                                 WHEN d.classid = 'pg_constraint'::regclass
                                 THEN (SELECT format('foreign key %s of table %s', conname, conrelid::regclass) FROM pg_constraint WHERE oid = d.objid)
                                 ELSE pg_describe_object(d.classid, d.objid, d.objsubid) END
            FROM pg_depend d
            WHERE d.refobjid = v_oid AND d.deptype = 'n'
              AND NOT (d.classid = 'pg_rewrite'::regclass AND (SELECT ev_class FROM pg_rewrite WHERE oid = d.objid) = v_oid)
              AND NOT (d.classid = 'pg_constraint'::regclass AND (SELECT conrelid FROM pg_constraint WHERE oid = d.objid) = v_oid));
    END IF;

    v_deps := ARRAY(SELECT pgerp.ui_t(d) FROM unnest(v_deps) AS d);
    IF v_apply THEN
        PERFORM pgerp.dev_execute(v_sql);
        DELETE FROM pgerp.solution_objects WHERE object_type = v_type AND object_name = v_name;
        DELETE FROM pgerp.solution_data WHERE v_type = 'table' AND table_name = v_name;
    END IF;
    RETURN json_build_object('status', 'success', 'applied', v_apply, 'statements', to_json(v_sql), 'dependents', to_json(v_deps),
                             'message', CASE WHEN v_apply THEN format('Deleted: %s', v_name) END);
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- SQL-консоль и проверка действий
-- ---------------------------------------------------------------------
-- sql_run: {"sql", "rollback", "max_rows"} — запрос или скрипт от имени базы (только администратору).
-- Запрос, возвращающий строки, — колонки и строки (не больше max_rows); иначе — число затронутых строк.
-- rollback — выполнить и откатить. Ошибка запроса — в поле error, а не исключением
CREATE FUNCTION pgerp.ui_sql_run(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_sql      TEXT    := p_data->>'sql';
    v_rollback BOOLEAN := COALESCE((p_data->>'rollback')::BOOLEAN, FALSE);
    v_max      INT     := LEAST(GREATEST(COALESCE((p_data->>'max_rows')::INT, 200), 1), 5000);
    v_started  TIMESTAMPTZ := clock_timestamp();
    v_rows     JSONB   := '[]';
    v_columns  JSONB;
    v_count    BIGINT  := 0;
    v_mode     TEXT    := 'rows';
    v_row      RECORD;
    v_json     JSON;
    v_error    JSONB;
    v_rolled   BOOLEAN := FALSE;
    v_message  TEXT;
    v_detail   TEXT;
    v_hint     TEXT;
    v_state    TEXT;
    v_context  TEXT;
    v_user     TEXT    := current_setting('pgerp.user', TRUE);
    v_lang     TEXT    := current_setting('pgerp.lang', TRUE);
BEGIN
    PERFORM ui_require(NULLIF(trim(COALESCE(v_sql, '')), '') IS NOT NULL, 'Write a query');
    PERFORM set_config('statement_timeout', '60s', TRUE);
    BEGIN
        BEGIN
            FOR v_row IN EXECUTE v_sql LOOP
                v_count := v_count + 1;
                IF v_count <= v_max THEN
                    v_json := row_to_json(v_row);
                    IF v_columns IS NULL THEN
                        SELECT jsonb_agg(key ORDER BY n) INTO v_columns FROM json_each(v_json) WITH ORDINALITY AS e(key, value, n);
                    END IF;
                    v_rows := v_rows || jsonb_build_array((SELECT jsonb_agg(value::JSONB ORDER BY n)
                                                           FROM json_each(v_json) WITH ORDINALITY AS e(key, value, n)));
                END IF;
            END LOOP;
        EXCEPTION WHEN OTHERS THEN
            -- Команда без строк результата (DDL, INSERT без RETURNING) или скрипт из нескольких операторов.
            -- Курсор разбирает все операторы скрипта заранее: ошибка «объекта нет» может значить, что его
            -- создаёт оператор выше, — такой скрипт выполняется по порядку. Ошибка одиночного запроса — как есть
            GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE;
            IF v_state <> '42P11' AND strpos(rtrim(v_sql, E' \n\r\t;'), ';') = 0 THEN
                RAISE;
            END IF;
            v_mode := 'command';
            v_rows := '[]';
            v_columns := NULL;
            v_count := 0;
            EXECUTE v_sql;
            GET DIAGNOSTICS v_count = ROW_COUNT;
        END;
        IF v_rollback THEN
            RAISE EXCEPTION USING ERRCODE = 'U0099', MESSAGE = 'rollback';
        END IF;
    EXCEPTION
        WHEN SQLSTATE 'U0099' THEN
            v_rolled := TRUE;
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_detail = PG_EXCEPTION_DETAIL, v_hint = PG_EXCEPTION_HINT,
                                    v_state = RETURNED_SQLSTATE, v_context = PG_EXCEPTION_CONTEXT;
            -- Контекст без строк самой консоли и маршрутизатора
            v_context := NULLIF(trim(regexp_replace(v_context,
                '(PL/pgSQL function (ui_sql_run|handle_ui_event)[^\n]*|SQL statement "SELECT ui_sql_run\(\$1\)")\n?', '', 'g')), '');
            v_error := jsonb_strip_nulls(jsonb_build_object('message', v_message, 'detail', NULLIF(v_detail, ''),
                                                            'hint', NULLIF(v_hint, ''), 'sqlstate', v_state,
                                                            'context', v_context));
            v_rolled := TRUE;
    END;
    -- Запрос мог сменить пользователя или язык сеанса (например, вызовом handle_ui_event)
    PERFORM set_config('pgerp.user', COALESCE(v_user, ''), TRUE);
    PERFORM set_config('pgerp.lang', COALESCE(v_lang, ''), TRUE);
    RETURN json_build_object(
        'status', 'success',
        'mode', CASE WHEN v_error IS NOT NULL THEN 'error' ELSE v_mode END,
        'columns', COALESCE(v_columns, '[]'),
        'rows', CASE WHEN v_error IS NULL AND v_mode = 'rows' THEN v_rows ELSE '[]' END,
        'row_count', CASE WHEN v_error IS NULL THEN v_count END,
        'truncated', v_count > v_max AND v_mode = 'rows',
        'rolled_back', v_rolled,
        'duration_ms', round(extract(EPOCH FROM clock_timestamp() - v_started) * 1000),
        'error', v_error);
END;
$$ LANGUAGE plpgsql;

-- action_run: {"action", "data", "user", "rollback"} — вызвать действие так, как его вызывает форма:
-- с правами пользователя user (по умолчанию — текущего). rollback (по умолчанию да) — откатить изменения
CREATE FUNCTION pgerp.ui_action_run(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_user     TEXT    := COALESCE(ui_text(p_data, 'user'), pgerp.ui_user());
    v_action   TEXT    := ui_text(p_data, 'action');
    v_rollback BOOLEAN := COALESCE((p_data->>'rollback')::BOOLEAN, TRUE);
    v_payload  JSON    := COALESCE(p_data->'data', '{}');
    v_current  TEXT    := current_setting('pgerp.user', TRUE);
    v_lang     TEXT    := current_setting('pgerp.lang', TRUE);
    v_result   JSON;
    v_error    JSONB;
    v_rolled   BOOLEAN := FALSE;
    v_message  TEXT;
    v_state    TEXT;
BEGIN
    PERFORM ui_require(v_action IS NOT NULL, 'Enter an action');
    PERFORM ui_require(json_typeof(v_payload) = 'object', 'Action data is a JSON object, for example {"id": "1"}');
    BEGIN
        v_result := pgerp.handle_ui_event(v_user, v_action, v_payload, NULLIF(v_lang, ''));
        IF v_rollback THEN
            RAISE EXCEPTION USING ERRCODE = 'U0099', MESSAGE = 'rollback';
        END IF;
    EXCEPTION
        WHEN SQLSTATE 'U0099' THEN
            v_rolled := TRUE;
        WHEN OTHERS THEN
            GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT, v_state = RETURNED_SQLSTATE;
            v_error := jsonb_build_object('message', v_message, 'sqlstate', v_state);
            v_rolled := TRUE;
    END;
    PERFORM set_config('pgerp.user', COALESCE(v_current, ''), TRUE);
    PERFORM set_config('pgerp.lang', COALESCE(v_lang, ''), TRUE);
    RETURN json_build_object('status', 'success', 'user', v_user, 'action', v_action,
                             'response', v_result, 'error', v_error, 'rolled_back', v_rolled);
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Действия
-- ---------------------------------------------------------------------
INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('solution_list',       'pgerp.ui_solution_list',       'Solutions: list',                              TRUE, FALSE),
    ('solution_get',        'pgerp.ui_solution_get',        'Solution: contents and releases',                    TRUE, FALSE),
    ('solution_save',       'pgerp.ui_solution_save',       'Solution: save',                          TRUE, FALSE),
    ('solution_delete',     'pgerp.ui_solution_delete',     'Solution: delete (objects remain)',         TRUE, FALSE),
    ('solution_object_set', 'pgerp.ui_solution_object_set', 'Solution: add an object explicitly',             TRUE, FALSE),
    ('solution_data_set',   'pgerp.ui_solution_data_set',   'Solution: carry table rows in a release',     TRUE, FALSE),
    ('release_preview',     'pgerp.ui_release_preview',     'Release: changes and migration text',           TRUE, FALSE),
    ('release_create',      'pgerp.ui_release_create',      'Release: create',                             TRUE, FALSE),
    ('release_get',         'pgerp.ui_release_get',         'Release: migration text',                       TRUE, FALSE),
    ('release_delete',      'pgerp.ui_release_delete',      'Release: cancel the last one',                    TRUE, FALSE),
    ('schema_get',          'pgerp.ui_schema_get',          'Data schema: tables, views, functions', TRUE, FALSE),
    ('table_get',           'pgerp.ui_table_get',           'Data schema: table structure',              TRUE, FALSE),
    ('table_save',          'pgerp.ui_table_save',          'Data schema: create and alter a table',   TRUE, FALSE),
    ('view_get',            'pgerp.ui_view_get',            'Data schema: view query',           TRUE, FALSE),
    ('view_save',           'pgerp.ui_view_save',           'Data schema: save a view',       TRUE, FALSE),
    ('function_source',     'pgerp.ui_function_source',     'Data schema: function source',                    TRUE, FALSE),
    ('object_drop',         'pgerp.ui_object_drop',         'Data schema: delete an object',               TRUE, FALSE),
    ('sql_run',             'pgerp.ui_sql_run',             'SQL console: run a query',              TRUE, FALSE),
    ('action_run',          'pgerp.ui_action_run',          'SQL console: test an action',               TRUE, FALSE),
    ('solutions_setup_done', 'pgerp.ui_solutions_setup_done', 'Solutions: first sign-in choice completed',   TRUE, FALSE);

-- ---------------------------------------------------------------------
-- Решение «Ядро платформы»: формы администрирования (объекты схемы pgerp в решения не входят)
-- ---------------------------------------------------------------------
INSERT INTO pgerp.solutions (name, title, migration_folder, is_core, description) VALUES
    ('core', 'Platform core', 'core', TRUE, 'Schema pgerp, administration forms and the admin role. Changed only by core migrations');
INSERT INTO pgerp.solution_objects (object_type, object_name, solution)
SELECT 'form', form_name, 'core' FROM pgerp.forms
WHERE form_name IN ('password_change', 'role', 'roles', 'translation', 'translations', 'user', 'users');

-- ---------------------------------------------------------------------
-- Переводы: сообщения решений, схемы данных, консоли и выпусков, изменения выпуска, описания действий
-- ---------------------------------------------------------------------
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Solution “%s” not found', 'Решение «%s» не найдено'),
    ('ru', 'Table %s renamed to %s', 'Таблица %s переименована в %s'),
    ('ru', 'Column %s.%s renamed to %s', 'Колонка %s.%s переименована в %s'),
    ('ru', 'New type %s', 'Новый тип %s'),
    ('ru', 'Changed type %s', 'Изменён тип %s'),
    ('ru', 'Values were removed from type %s — the release does not delete them, do it manually', 'Из типа %s убраны значения — выпуск их не удаляет, это делается вручную'),
    ('ru', 'Deleted type %s', 'Удалён тип %s'),
    ('ru', 'New sequence %s', 'Новая последовательность %s'),
    ('ru', 'Deleted sequence %s', 'Удалена последовательность %s'),
    ('ru', 'New table %s', 'Новая таблица %s'),
    ('ru', 'New column %s.%s', 'Новая колонка %s.%s'),
    ('ru', 'Column %s.%s is required and has no default: the release will fail if the table already has rows', 'Колонка %s.%s обязательна и без значения по умолчанию: выпуск не применится, если в таблице уже есть строки'),
    ('ru', 'Column %s.%s: type %s → %s', 'Колонка %s.%s: тип %s → %s'),
    ('ru', 'Column %s.%s changes its type: values that cannot be converted will stop the release', 'Колонка %s.%s меняет тип: значения, которые не преобразуются, остановят выпуск'),
    ('ru', 'Column %s.%s: default value', 'Колонка %s.%s: значение по умолчанию'),
    ('ru', 'Column %s.%s: required', 'Колонка %s.%s: обязательная'),
    ('ru', 'Column %s.%s: optional', 'Колонка %s.%s: необязательная'),
    ('ru', 'Column %s.%s: the generated expression, identity or collation changed — the release does not carry this over', 'Колонка %s.%s: вычисляемое выражение, identity или правило сортировки изменились — выпуск их не переносит'),
    ('ru', 'Deleted column %s.%s', 'Удалена колонка %s.%s'),
    ('ru', 'Column %s.%s will be deleted with its data. If this is a rename, do it in the table designer — the release will rename the column', 'Колонка %s.%s будет удалена вместе с данными. Если это переименование, сделайте его в конструкторе таблиц — выпуск переименует колонку'),
    ('ru', 'Deleted constraint %s.%s', 'Удалено ограничение %s.%s'),
    ('ru', 'Changed constraint %s.%s', 'Изменено ограничение %s.%s'),
    ('ru', 'New constraint %s.%s', 'Новое ограничение %s.%s'),
    ('ru', 'Deleted index %s', 'Удалён индекс %s'),
    ('ru', 'Changed index %s', 'Изменён индекс %s'),
    ('ru', 'New index %s', 'Новый индекс %s'),
    ('ru', 'Deleted trigger %s.%s', 'Удалён триггер %s.%s'),
    ('ru', 'Changed trigger %s.%s', 'Изменён триггер %s.%s'),
    ('ru', 'New trigger %s.%s', 'Новый триггер %s.%s'),
    ('ru', 'Deleted table %s', 'Удалена таблица %s'),
    ('ru', 'Table %s will be deleted with its data', 'Таблица %s будет удалена вместе с данными'),
    ('ru', 'New function %s', 'Новая функция %s'),
    ('ru', 'Changed function %s', 'Изменена функция %s'),
    ('ru', 'Deleted function %s', 'Удалена функция %s'),
    ('ru', 'New view %s', 'Новое представление %s'),
    ('ru', 'Changed view %s', 'Изменено представление %s'),
    ('ru', 'Deleted view %s', 'Удалено представление %s'),
    ('ru', 'Data of table %s', 'Данные таблицы %s'),
    ('ru', 'Data of table %s references %s, whose rows the release does not carry: another database may lack the required rows', 'Данные таблицы %s ссылаются на %s, строки которой выпуск не переносит: на другой базе нужных строк может не быть'),
    ('ru', 'Metadata: actions', 'Метаданные: действия'),
    ('ru', 'Metadata: forms', 'Метаданные: формы'),
    ('ru', 'Metadata: form components', 'Метаданные: компоненты форм'),
    ('ru', 'Metadata: table columns and row buttons', 'Метаданные: колонки и кнопки таблиц'),
    ('ru', 'Metadata: reports', 'Метаданные: отчёты'),
    ('ru', 'Metadata: roles and their forms', 'Метаданные: роли и их формы'),
    ('ru', 'Metadata: menu', 'Метаданные: меню'),
    ('ru', 'Deleted menu folder “%s”', 'Удалена папка меню «%s»'),
    ('ru', 'Deleted forms: %s', 'Удалены формы: %s'),
    ('ru', 'Deleted reports: %s', 'Удалены отчёты: %s'),
    ('ru', 'Deleted roles: %s', 'Удалены роли: %s'),
    ('ru', 'Deleted actions: %s', 'Удалены действия: %s'),
    ('ru', 'Translations', 'Переводы'),
    ('ru', 'Solution description and contents', 'Описание и состав решения'),
    ('ru', 'Release %s', 'Выпуск %s'),
    ('ru', 'The platform core is released through core migrations, not from the editor', 'Ядро платформы выпускается миграциями ядра, а не из редактора'),
    ('ru', 'Solution name: lowercase Latin letters, digits and _, starting with a letter', 'Имя решения: латинские буквы в нижнем регистре, цифры и _, начинается с буквы'),
    ('ru', 'Enter the solution title', 'Укажите название решения'),
    ('ru', 'Prefix: lowercase Latin letters, digits and _, for example my_app_', 'Префикс: латинские буквы в нижнем регистре, цифры и _, например my_app_'),
    ('ru', 'Package folder: lowercase Latin letters, digits and _', 'Папка пакета: латинские буквы в нижнем регистре, цифры и _'),
    ('ru', 'The core folder belongs to the core; choose another one', 'Папка core занята ядром; выберите другую'),
    ('ru', 'Schema: lowercase Latin letters, digits and _; not pgerp and not pg_…', 'Схема: латинские буквы в нижнем регистре, цифры и _; не pgerp и не pg_…'),
    ('ru', 'Schema “%s” is not allowed for a solution', 'Схема «%s» недопустима для решения'),
    ('ru', 'The schema of solution “%s” has tables: delete them or move them to another solution first', 'В схеме решения «%s» есть таблицы: сначала удалите их или перенесите в другое решение'),
    ('ru', 'Prefix %s already belongs to another solution', 'Префикс %s уже у другого решения'),
    ('ru', 'Solution “%s” already exists — choose another name', 'Решение «%s» уже есть — выберите другое имя'),
    ('ru', 'The platform core cannot be changed in the editor', 'Ядро платформы в редакторе не меняется'),
    ('ru', 'Solution “%s” saved', 'Решение «%s» сохранено'),
    ('ru', 'Solution “%s” deleted; its objects remain in the database', 'Решение «%s» удалено; его объекты остались в базе'),
    ('ru', 'There is no %s “%s”', 'Объекта %s «%s» нет'),
    ('ru', 'Table “%s” does not belong to any solution', 'Таблица «%s» не входит ни в одно решение'),
    ('ru', 'Nothing has changed in the solution since the last release', 'После прошлого выпуска в решении ничего не изменилось'),
    ('ru', 'Release %s created: %s', 'Выпуск %s создан: %s'),
    ('ru', 'Release %s of solution “%s” not found', 'Выпуск %s решения «%s» не найден'),
    ('ru', 'Only the last release of a solution can be cancelled', 'Отменить можно только последний выпуск решения'),
    ('ru', 'The initial state of a solution cannot be cancelled', 'Исходное состояние решения не отменяется'),
    ('ru', 'Release %s cancelled. If the release file has already been saved, delete it', 'Выпуск %s отменён. Если файл выпуска уже сохранён, удалите его'),
    ('ru', '%s “%s”: lowercase Latin letters, digits and _, up to 63 characters', '%s «%s»: латинские буквы в нижнем регистре, цифры и _, до 63 символов'),
    ('ru', 'Column “%s”: unknown type “%s”', 'Колонка «%s»: неизвестный тип «%s»'),
    ('ru', '%s: select columns', '%s: выберите колонки'),
    ('ru', 'Table “%s” not found', 'Таблица «%s» не найдена'),
    ('ru', '%s — in statement: %s', '%s — в операторе: %s'),
    ('ru', 'Table name', 'Имя таблицы'),
    ('ru', 'A table needs at least one column', 'В таблице должна быть хотя бы одна колонка'),
    ('ru', 'Column names must be unique', 'Имена колонок должны быть уникальны'),
    ('ru', 'Primary key', 'Первичный ключ'),
    ('ru', 'Table or view “%s” already exists', 'Таблица или представление «%s» уже есть'),
    ('ru', 'Column', 'Колонка'),
    ('ru', 'Column “%s”: serial can be set only for a new column', 'Колонка «%s»: serial задаётся только новой колонке'),
    ('ru', 'Unique', 'Уникальность'),
    ('ru', 'Check: enter a condition', 'Проверка: укажите условие'),
    ('ru', 'Foreign key: table “%s” not found', 'Внешний ключ: таблица «%s» не найдена'),
    ('ru', 'Foreign key', 'Внешний ключ'),
    ('ru', 'Index', 'Индекс'),
    ('ru', 'No changes', 'Изменений нет'),
    ('ru', 'Table “%s” saved', 'Таблица «%s» сохранена'),
    ('ru', 'View “%s” not found', 'Представление «%s» не найдено'),
    ('ru', 'View name', 'Имя представления'),
    ('ru', 'Write the view query (SELECT …)', 'Напишите запрос представления (SELECT …)'),
    ('ru', 'Could not recreate the view: %s', 'Представление пересоздать не удалось: %s'),
    ('ru', 'View “%s” saved', 'Представление «%s» сохранено'),
    ('ru', 'There is no function “%s” in the solution schemas', 'Функции «%s» в схемах решений нет'),
    ('ru', 'Object type: table, view, function, sequence, type or action', 'Тип объекта: table, view, function, sequence, type или action'),
    ('ru', 'form %s, component %s', 'форма %s, компонент %s'),
    ('ru', 'row button of table %s', 'кнопка строк таблицы %s'),
    ('ru', 'report %s', 'отчёт %s'),
    ('ru', 'cancel action of form %s', 'отмена формы %s'),
    ('ru', 'Action “%s” is used by: %s', 'Действие «%s» используется: %s'),
    ('ru', 'action %s', 'действие %s'),
    ('ru', 'trigger %s of table %s', 'триггер %s таблицы %s'),
    ('ru', 'Function “%s” handles an action: delete the action first', 'Функция «%s» — обработчик действия: сначала удалите действие'),
    ('ru', 'view %s', 'представление %s'),
    ('ru', 'foreign key %s of table %s', 'внешний ключ %s таблицы %s'),
    ('ru', 'Deleted: %s', 'Удалено: %s'),
    ('ru', 'Write a query', 'Напишите запрос'),
    ('ru', 'Enter an action', 'Укажите действие'),
    ('ru', 'Action data is a JSON object, for example {"id": "1"}', 'Данные действия — JSON-объект, например {"id": "1"}'),
    ('ru', 'Solutions: list', 'Решения: список'),
    ('ru', 'Solution: contents and releases', 'Решение: состав и выпуски'),
    ('ru', 'Solution: save', 'Решение: сохранение'),
    ('ru', 'Solution: delete (objects remain)', 'Решение: удаление (объекты остаются)'),
    ('ru', 'Solution: add an object explicitly', 'Решение: явное включение объекта'),
    ('ru', 'Solution: carry table rows in a release', 'Решение: перенос строк таблицы в выпуске'),
    ('ru', 'Release: changes and migration text', 'Выпуск: изменения и текст миграции'),
    ('ru', 'Release: create', 'Выпуск: создание'),
    ('ru', 'Release: migration text', 'Выпуск: текст миграции'),
    ('ru', 'Release: cancel the last one', 'Выпуск: отмена последнего'),
    ('ru', 'Data schema: tables, views, functions', 'Схема данных: таблицы, представления, функции'),
    ('ru', 'Data schema: table structure', 'Схема данных: структура таблицы'),
    ('ru', 'Data schema: create and alter a table', 'Схема данных: создание и изменение таблицы'),
    ('ru', 'Data schema: view query', 'Схема данных: запрос представления'),
    ('ru', 'Data schema: save a view', 'Схема данных: сохранение представления'),
    ('ru', 'Data schema: function source', 'Схема данных: код функции'),
    ('ru', 'Data schema: delete an object', 'Схема данных: удаление объекта'),
    ('ru', 'SQL console: run a query', 'SQL-консоль: выполнение запроса'),
    ('ru', 'SQL console: test an action', 'SQL-консоль: проверка действия'),
    ('ru', 'Solutions: first sign-in choice completed', 'Решения: выбор при первом входе завершён'),
    ('ru', 'Only an administrator can install solutions', 'Устанавливать решения может только администратор'),
    ('ru', 'Invalid solution name: %s', 'Недопустимое имя решения: %s'),
    ('ru', 'A clean installation is started only by an administrator', 'Чистую установку запускает только администратор'),
    ('ru', 'The platform core cannot be reinstalled', 'Ядро платформы нельзя переустановить'),
    ('ru', 'Schema “%s” cannot be deleted', 'Схему «%s» нельзя удалить'),
    ('ru', 'Schema “%s” belongs to another solution', 'Схема «%s» принадлежит другому решению'),
    ('ru', 'Chart "%": select the data source action', 'График «%»: выберите действие-источник данных'),
    ('ru', 'Chart: specify at least one value column', 'График: укажите хотя бы одну колонку значений'),
    ('ru', 'Chart: unknown format %s', 'График: неизвестный формат %s'),
    ('ru', 'Value', 'Значение')
ON CONFLICT (lang, source) DO NOTHING;

-- #####################################################################
-- MCP-сервер
-- #####################################################################
-- =====================================================================
-- MCP-сервер: разработка прикладных решений ИИ-агентом (Claude Code, Claude Desktop и др.)
-- =====================================================================
-- Шлюз принимает POST /mcp (Model Context Protocol, транспорт Streamable HTTP) с токеном
-- Authorization: Bearer <токен>, находит по токену пользователя (pgerp.mcp_token_login) и передаёт
-- тело запроса JSON-RPC в pgerp.mcp_handle как есть. Инструменты MCP — строки pgerp.mcp_tools: каждый
-- вызывает действие через маршрутизатор handle_ui_event с правами владельца токена, как кнопка формы.
-- Новый инструмент — строка в mcp_tools; Java при этом не меняется.
--
-- Токены выдаёт администратор (редактор → «Доступ MCP»); в базе хранится только хеш токена.
-- =====================================================================

CREATE TABLE pgerp.mcp_tokens (
    id           BIGSERIAL PRIMARY KEY,
    user_id      BIGINT NOT NULL REFERENCES pgerp.users(id) ON DELETE CASCADE,
    title        VARCHAR(200) NOT NULL CHECK (trim(title) <> ''),
    token_hash   TEXT NOT NULL UNIQUE,
    token_hint   VARCHAR(20) NOT NULL,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    created_by   VARCHAR(50),
    last_used_at TIMESTAMPTZ,
    expires_at   TIMESTAMPTZ
);
CREATE INDEX mcp_tokens_user_id_idx ON pgerp.mcp_tokens (user_id);

-- Инструменты: имя → действие. fixed_args дописываются к аргументам вызова (например, исходные тексты формы);
-- hook — обработка в шлюзе: compile_jrxml — проверка шаблона отчёта до сохранения,
-- write_migration — запись файла выпуска в пакет решения (ERP_DEV_SOLUTIONS_DIR), packages — инструмент целиком
-- выполняет шлюз (пакеты решений лежат в приложении): action_name задаёт права на него
CREATE TABLE pgerp.mcp_tools (
    name         VARCHAR(64) PRIMARY KEY CHECK (name ~ '^[a-z][a-z0-9_]*$'),
    action_name  VARCHAR(100) NOT NULL REFERENCES pgerp.ui_actions(action_name) ON UPDATE CASCADE ON DELETE CASCADE,
    title        VARCHAR(200) NOT NULL,
    description  TEXT NOT NULL,
    input_schema JSONB NOT NULL DEFAULT '{"type": "object", "properties": {}}' CHECK (input_schema->>'type' = 'object'),
    fixed_args   JSONB CHECK (fixed_args IS NULL OR jsonb_typeof(fixed_args) = 'object'),
    read_only    BOOLEAN NOT NULL DEFAULT FALSE,
    hook         VARCHAR(30) CHECK (hook IN ('compile_jrxml', 'write_migration', 'packages')),
    sort_order   INT NOT NULL DEFAULT 0
);

-- ---------------------------------------------------------------------
-- Токены
-- ---------------------------------------------------------------------
-- Логин владельца действующего токена; NULL — токен неизвестен, отозван, истёк или пользователь отключён
CREATE FUNCTION pgerp.mcp_token_login(p_token TEXT)
RETURNS VARCHAR AS $$
DECLARE
    v_token pgerp.mcp_tokens%ROWTYPE;
    v_login VARCHAR;
BEGIN
    IF p_token IS NULL OR length(p_token) < 20 OR length(p_token) > 200 THEN
        RETURN NULL;
    END IF;
    SELECT t.* INTO v_token
    FROM pgerp.mcp_tokens t
    WHERE t.token_hash = encode(digest(p_token, 'sha256'), 'hex')
      AND (t.expires_at IS NULL OR t.expires_at > now());
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT login INTO v_login FROM pgerp.users WHERE id = v_token.user_id AND is_active;
    IF v_login IS NOT NULL AND (v_token.last_used_at IS NULL OR v_token.last_used_at < now() - INTERVAL '1 minute') THEN
        UPDATE pgerp.mcp_tokens SET last_used_at = now() WHERE id = v_token.id;
    END IF;
    RETURN v_login;
END;
$$ LANGUAGE plpgsql
SET search_path = public, pgerp;

-- mcp_tokens_list: {} → токены (без самих токенов)
CREATE FUNCTION pgerp.ui_mcp_tokens_list(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object(
        'status', 'success',
        'tokens', COALESCE((SELECT json_agg(json_build_object(
                                'id', t.id, 'title', t.title, 'login', u.login, 'hint', t.token_hint,
                                'created_at', t.created_at, 'created_by', t.created_by,
                                'last_used_at', t.last_used_at, 'expires_at', t.expires_at,
                                'expired', t.expires_at IS NOT NULL AND t.expires_at <= now()) ORDER BY t.created_at DESC)
                            FROM pgerp.mcp_tokens t JOIN pgerp.users u ON u.id = t.user_id), '[]'),
        'users', COALESCE((SELECT json_agg(json_build_object('login', login, 'name', COALESCE(full_name, login),
                                                             'is_admin', pgerp.auth_is_admin(id)) ORDER BY login)
                           FROM pgerp.users WHERE is_active), '[]'));
$$ LANGUAGE sql STABLE;

-- mcp_token_create: {"title", "login", "days"} → новый токен; показывается один раз
CREATE FUNCTION pgerp.ui_mcp_token_create(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_title TEXT := ui_text(p_data, 'title');
    v_login TEXT := COALESCE(ui_text(p_data, 'login'), pgerp.ui_user());
    v_days  INT  := NULLIF(ui_text(p_data, 'days'), '')::INT;
    v_user  pgerp.users%ROWTYPE;
    v_token TEXT := 'pgerp_' || encode(gen_random_bytes(32), 'hex');
BEGIN
    PERFORM ui_require(v_title IS NOT NULL, 'Enter the token purpose, for example “Claude Code on my laptop”');
    SELECT * INTO v_user FROM pgerp.users WHERE login = v_login AND is_active;
    PERFORM ui_require(FOUND, format('There is no active user “%s”', v_login));
    PERFORM ui_require(v_days IS NULL OR v_days BETWEEN 1 AND 3650, 'Validity is from 1 to 3650 days or no expiry');
    INSERT INTO pgerp.mcp_tokens (user_id, title, token_hash, token_hint, created_by, expires_at)
    VALUES (v_user.id, v_title, encode(digest(v_token, 'sha256'), 'hex'), left(v_token, 10) || '…', pgerp.ui_user(),
            CASE WHEN v_days IS NOT NULL THEN now() + make_interval(days => v_days) END);
    RETURN json_build_object('status', 'success', 'token', v_token, 'login', v_user.login,
                             'is_admin', pgerp.auth_is_admin(v_user.id));
END;
$$ LANGUAGE plpgsql
SET search_path = public, pgerp;

-- mcp_token_revoke: {"id"}
CREATE FUNCTION pgerp.ui_mcp_token_revoke(p_data JSON)
RETURNS JSON AS $$
BEGIN
    DELETE FROM pgerp.mcp_tokens WHERE id = ui_parse_id(p_data->>'id');
    PERFORM ui_require(FOUND, 'Token not found — it may have been revoked already');
    RETURN ui_ok(ui_message('Token revoked'));
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------------
-- Роли и переводы: компактные действия для агента и редактора
-- ---------------------------------------------------------------------
-- role_list: {} → роли с выданными формами
CREATE FUNCTION pgerp.ui_role_list(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'roles', COALESCE((
        SELECT json_agg(json_build_object(
                   'role_name', r.role_name, 'title', r.title, 'solution', pgerp.solution_of('role', r.role_name),
                   'forms', COALESCE((SELECT json_agg(rf.form_name ORDER BY rf.form_name) FROM pgerp.role_forms rf WHERE rf.role_id = r.id), '[]'),
                   'users', (SELECT count(*) FROM pgerp.user_roles ur WHERE ur.role_id = r.id)) ORDER BY r.role_name)
        FROM pgerp.roles r), '[]'));
$$ LANGUAGE sql STABLE;

-- role_set: {"role_name", "title", "forms": [...]} — создать или изменить роль; формы роли заменяются списком.
-- Формы, открываемые из выданных (карточки, окна выбора), доступны автоматически — их выдавать не нужно
CREATE FUNCTION pgerp.ui_role_set(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_name  TEXT := lower(ui_text(p_data, 'role_name'));
    v_title TEXT := ui_text(p_data, 'title');
    v_id    BIGINT;
    v_form  TEXT;
BEGIN
    PERFORM ui_require(v_name ~ '^[a-z_][a-z0-9_]*$' AND length(v_name) <= 50,
                       'Role code: lowercase Latin letters, digits and _');
    PERFORM ui_require(v_name <> 'admin', 'The admin role sees everything and is not configurable');
    PERFORM ui_require(v_title IS NOT NULL, 'Enter the role title');
    INSERT INTO pgerp.roles (role_name, title) VALUES (v_name, v_title)
    ON CONFLICT (role_name) DO UPDATE SET title = EXCLUDED.title
    RETURNING id INTO v_id;
    IF p_data->'forms' IS NOT NULL AND json_typeof(p_data->'forms') = 'array' THEN
        FOR v_form IN SELECT json_array_elements_text(p_data->'forms') LOOP
            PERFORM ui_require(EXISTS (SELECT 1 FROM pgerp.forms WHERE form_name = v_form), format('There is no form “%s”', v_form));
        END LOOP;
        DELETE FROM pgerp.role_forms WHERE role_id = v_id;
        INSERT INTO pgerp.role_forms (role_id, form_name)
        SELECT DISTINCT v_id, f FROM json_array_elements_text(p_data->'forms') f;
    END IF;
    RETURN ui_ok(ui_message(format('Role “%s” saved', v_title)));
END;
$$ LANGUAGE plpgsql;

-- translation_list: {"lang", "missing", "search", "limit"} — переводы или тексты без перевода
CREATE FUNCTION pgerp.ui_translation_list(p_data JSON)
RETURNS JSON AS $$
DECLARE
    v_lang   TEXT := COALESCE(ui_text(p_data, 'lang'), (SELECT code FROM pgerp.target_languages_v ORDER BY sort_order LIMIT 1));
    v_search TEXT := ui_text(p_data, 'search');
    v_limit  INT  := LEAST(GREATEST(COALESCE((p_data->>'limit')::INT, 200), 1), 2000);
BEGIN
    IF COALESCE((p_data->>'missing')::BOOLEAN, FALSE) THEN
        RETURN json_build_object('status', 'success', 'lang', v_lang, 'missing', COALESCE((
            SELECT json_agg(json_build_object('source', source, 'origin', origin) ORDER BY source)
            FROM (SELECT source, origin FROM pgerp.translation_missing_v
                  WHERE lang = v_lang AND (v_search IS NULL OR source ILIKE '%' || v_search || '%')
                  ORDER BY source LIMIT v_limit) m), '[]'));
    END IF;
    RETURN json_build_object('status', 'success', 'lang', v_lang, 'translations', COALESCE((
        SELECT json_agg(json_build_object('source', source, 'translation', translation) ORDER BY source)
        FROM (SELECT source, translation FROM pgerp.translations
              WHERE lang = v_lang AND (v_search IS NULL OR source ILIKE '%' || v_search || '%' OR translation ILIKE '%' || v_search || '%')
              ORDER BY source LIMIT v_limit) t), '[]'));
END;
$$ LANGUAGE plpgsql STABLE;

-- ---------------------------------------------------------------------
-- Справочник разработчика: как устроена платформа и как вести разработку инструментами (на английском)
-- ---------------------------------------------------------------------
CREATE FUNCTION pgerp.dev_guide()
RETURNS TEXT AS $guide$
SELECT $text$# PgERP: building application solutions

## How it works
Data-Driven UI: all logic and the interface description live in PostgreSQL. Java is a thin gateway; the browser draws forms
from metadata and executes the instructions that PL/pgSQL functions return.
- Application tables, views and functions live in their solution's schema (solution_get → db_schema; defaults to the
  solution name) or in public. The core is schema pgerp (do not touch it). Solution code calls its own objects without a schema.
  The search path is solution schemas, public, pgerp: core helpers are called without a schema (ui_ok, ui_require, …).
- An action is a function name(p_data JSON) RETURNS JSON registered in pgerp.ui_actions.
  The browser calls it with the values of all form fields: {"field_name": "value", …} (values are strings).
- Rights: role → granted forms → actions of those forms; forms opened from granted ones are available automatically.
  The administrator sees everything. The router checks rights on every call.
- Write all texts in English (the source language); translations live in pgerp.translations, keyed by the source text.

## Solutions
A solution is an application module: objects with its name prefix (my_app_) or added explicitly.
Start with solution_list / solution_get. A new solution — solution_save (name, title, prefix, menu folder).
Give every object a name with the solution prefix: tables, functions, actions, forms, reports, roles.
Mark reference tables whose rows every installation needs (stages, types) with solution_data_set.

## Workflow
1. Data model: table_save (designer: columns, key, foreign keys, indexes; apply=false — review the SQL),
   view_save — views for lists (handy for collecting labels of related tables and a search_text field).
   Anything complex — sql_run (DDL, helper functions, triggers).
2. Actions: function_save creates name(p_data JSON) RETURNS JSON in the solution schema and registers the action.
   Helper functions and triggers — sql_run with CREATE FUNCTION. The code of any function — function_source.
3. Forms: form_save {name, title, folder, components: [...]}; for an example, form_get any existing form (form_list).
4. Table columns — grid_columns_save for the source action; menu — menu_get/menu_save (the whole menu!);
   roles — role_set; translations — translation_list (missing=true) and translation_save.
5. Testing: action_run calls an action on behalf of a user with a rollback (rollback by default);
   sql_run — queries against the data.
6. Release: release_preview shows the changes and the release text; release_create records a release —
   a solution package file (V<number>__<solution>_<title>.sql) for the folder src/main/resources/db/solutions/<solution folder>/.
   If the gateway is configured with a packages folder (ERP_DEV_SOLUTIONS_DIR), the file is saved automatically; otherwise save content.
   Packages from the build are installed in the editor ("Solutions → Install") and updated when the application starts.

## Action handler
```sql
CREATE OR REPLACE FUNCTION my_app_item_save(p_data JSON) RETURNS JSON AS $$
DECLARE
    v_id    BIGINT  := ui_parse_id(p_data->>'id');
    v_name  TEXT    := ui_text(p_data, 'name');
    v_amount NUMERIC := ui_parse_money(p_data->>'amount');
BEGIN
    PERFORM ui_require(v_name IS NOT NULL, 'Enter the name');
    IF ui_is_new(p_data) THEN
        INSERT INTO my_app_items (name, amount) VALUES (v_name, v_amount) RETURNING id INTO v_id;
    ELSE
        UPDATE my_app_items SET name = v_name, amount = v_amount WHERE id = v_id;
        PERFORM ui_require(FOUND, 'Record not found');
    END IF;
    RETURN ui_ok(ui_close_form(), ui_refresh_grid('my_app_items_grid', p_keep_page => TRUE),
                 ui_message(format('Record “%s” saved', v_name)));
END;
$$ LANGUAGE plpgsql;
```
Reading fields: ui_text(p_data, 'field') (empty → NULL), ui_parse_id, ui_parse_date (YYYY-MM-DD), ui_parse_money,
ui_is_new(p_data) (no id), ui_confirmed(p_data). Checks: PERFORM ui_require(condition, 'error text') — the user
sees the text and the changes are rolled back. ui_error(text, instructions…) — an error with instructions.
User: ui_user() (login), ui_has_role('role'). Messages: PERFORM ui_print('text'[, 'warning'|'error']).
Texts with placeholders — format(ui_t('Record #%s'), id), translated by template.

## Response and UI instructions
ui_ok(instructions…) → {"status": "success", "ui_instructions": [...]}. Instructions:
ui_message(text); ui_confirm(text, action, data, p_confirm_label) — on consent calls the action with the data
(add "confirmed": true and check ui_confirmed); ui_open_form(form, p_data => field values, p_title,
p_select => selection mode {value_field, display_field, fill}); ui_close_form(); ui_clear_form();
ui_set_values(values, p_form => another open form); ui_clear_fields(fields…); ui_set_title(title);
ui_refresh_grid(table|tree|list, p_keep_page); ui_report(report, parameters, title).
Without a user request: ui_push(…), ui_push_to(form, …), ui_push_to_user(login, …), ui_push_to_role(role, …).

## Data sources
- Table (grid): RETURN ui_grid_page('<action>', p_data, '<table|view>', p_master_column, 'sort field',
  'asc'|'desc', p_search_column => 'search_text', p_search => p_data->>'search', p_filters => jsonb_build_object('column', value)).
  Columns — pgerp.grid_columns of the action (grid_columns_save): field, title, type (text|number|money|datetime|badge),
  sort_column. Row buttons — pgerp.grid_row_actions (sql_run): the action receives {"id": row id}.
  Detail table: the master property is the form field holding the master id; the source receives master_id.
- Drop-down list (combobox): RETURN ui_combo_items('<table|view>', 'label column', 'value column').
- Tree (tree): RETURN ui_tree_level(p_data, '<table>', 'name', 'parent_id').
- Chart (chart): RETURN ui_chart('<table|view>', 'label column', ARRAY['value column', …], ARRAY['Series name', …],
  p_order_column => 'order column', p_format => 'number'|'money'|'percent') → {labels, series: [{name, values}], format}.
  The source receives the form field values; options: chart (bar — histogram, line — trend, area, pie), stacked, height.
  Refreshed like a table: ui_refresh_grid('<chart name>').
- Lookup field (lookup): the action opens a list form in selection mode:
  RETURN ui_ok(ui_open_form('<list form>', p_title => 'Select …', p_select => jsonb_build_object('value_field', 'id', 'display_field', 'name')));
  the value goes into field <name>, the text into <name>__display.

## Form
form_save: {"name", "title", "folder", "components": [{"type", "name", "label", "action", "master", "tab", "options"}]}.
Types: label, input, date, hidden, display, lookup, combobox, button, grid, tree, board, timer, chart.
action is required for grid, tree, combobox, lookup, timer, chart; for button it is the click action. Component order is the order
in the array; consecutive buttons form one row. tab — a tab. options: column (layout column number), refresh (input/combobox:
which tables to reload), placeholder (combobox), type: password (input), hotkey (button), interval (timer), page_size (grid: rows per page,
1–100, default 10), chart / stacked / height (chart).
A typical card: hidden id, fields, buttons "Save" (the save action) and "Cancel" (action form_close).
A typical list: input search with options {"refresh": "<table>"}, a grid with a source, an "Add" button (opens the card).
The form cancel action (the close cross, Escape) — pgerp.forms.cancel_action (sql_run: UPDATE pgerp.forms SET cancel_action = …).
Open a card from a list row: a row button (grid_row_actions) → an action with {"id"} → ui_open_form('card', p_data => values).

## Rules
- Do not change objects of schema pgerp or core metadata. Do not delete data unless explicitly asked.
- Before table_save/view_save/object_drop with apply=true, review the statements (apply=false).
- Test actions with action_run as a user with the required role.
- When done — release_preview; create a release (release_create) when the user asks.
$text$;
$guide$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.ui_dev_guide(p_data JSON)
RETURNS JSON AS $$
    SELECT json_build_object('status', 'success', 'guide', pgerp.dev_guide());
$$ LANGUAGE sql IMMUTABLE;

-- ---------------------------------------------------------------------
-- Протокол MCP (JSON-RPC 2.0)
-- ---------------------------------------------------------------------
CREATE FUNCTION pgerp.mcp_error(p_id JSONB, p_code INT, p_message TEXT)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('jsonrpc', '2.0', 'id', p_id, 'error', jsonb_build_object('code', p_code, 'message', p_message));
$$ LANGUAGE sql IMMUTABLE;

CREATE FUNCTION pgerp.mcp_result(p_id JSONB, p_result JSONB)
RETURNS JSONB AS $$
    SELECT jsonb_build_object('jsonrpc', '2.0', 'id', p_id, 'result', p_result);
$$ LANGUAGE sql IMMUTABLE;

-- Вызов инструмента: действие через маршрутизатор с правами пользователя; ошибка — результат с isError
CREATE FUNCTION pgerp.mcp_tool_call(p_login VARCHAR, p_params JSONB, p_lang VARCHAR)
RETURNS JSONB AS $$
DECLARE
    v_tool    pgerp.mcp_tools%ROWTYPE;
    v_args    JSONB := COALESCE(p_params->'arguments', '{}');
    v_result  JSONB;
    v_message TEXT;
    v_user    TEXT := current_setting('pgerp.user', TRUE);
BEGIN
    SELECT * INTO v_tool FROM pgerp.mcp_tools WHERE name = p_params->>'name';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('_error', jsonb_build_object('code', -32602, 'message', format('Unknown tool: %s', p_params->>'name')));
    END IF;
    IF jsonb_typeof(v_args) <> 'object' THEN
        RETURN jsonb_build_object('_error', jsonb_build_object('code', -32602, 'message', 'arguments must be an object'));
    END IF;
    v_args := v_args || COALESCE(v_tool.fixed_args, '{}');
    BEGIN
        v_result := pgerp.handle_ui_event(p_login, v_tool.action_name, v_args::JSON, p_lang)::JSONB;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
        PERFORM set_config('pgerp.user', COALESCE(v_user, ''), TRUE);
        RETURN jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_message)), 'isError', TRUE);
    END;
    IF v_result->>'status' = 'error' THEN
        RETURN jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_result->>'message')),
                                  'isError', TRUE);
    END IF;
    v_result := v_result - 'status';
    RETURN jsonb_build_object('content', jsonb_build_array(jsonb_build_object('type', 'text', 'text', v_result::TEXT)), 'isError', FALSE)
        -- Файл выпуска сохраняет шлюз: поле _gateway он убирает из ответа
        || CASE WHEN v_tool.hook = 'write_migration' AND v_result ? 'content' THEN
               jsonb_build_object('_gateway', jsonb_build_object('write_migration', jsonb_build_object(
                   'folder', v_result->>'folder', 'file_name', v_result->>'file_name', 'content', v_result->>'content',
                   'manifest', v_result->'manifest')))
           ELSE '{}' END;
END;
$$ LANGUAGE plpgsql;

-- Запрос JSON-RPC (или пакет запросов) → ответ; NULL — только уведомления, ответа не требуется
CREATE FUNCTION pgerp.mcp_handle(p_login VARCHAR, p_request JSON, p_lang VARCHAR DEFAULT NULL)
RETURNS JSON AS $$
DECLARE
    v_request JSONB := p_request::JSONB;
    v_id      JSONB;
    v_method  TEXT;
    v_params  JSONB;
    v_user_id BIGINT;
    v_version TEXT;
    v_result  JSONB;
BEGIN
    IF jsonb_typeof(v_request) = 'array' THEN
        RETURN (SELECT json_agg(r) FROM (SELECT pgerp.mcp_handle(p_login, e::JSON, p_lang) AS r
                                         FROM jsonb_array_elements(v_request) e) t WHERE r IS NOT NULL);
    END IF;
    IF jsonb_typeof(v_request) <> 'object' OR v_request->>'method' IS NULL THEN
        RETURN pgerp.mcp_error(COALESCE(v_request->'id', 'null'), -32600, 'Invalid Request')::JSON;
    END IF;
    -- Уведомления (без id) ответа не получают
    IF NOT v_request ? 'id' THEN
        RETURN NULL;
    END IF;
    v_id := v_request->'id';
    v_method := v_request->>'method';
    v_params := COALESCE(v_request->'params', '{}');
    SELECT id INTO v_user_id FROM pgerp.users WHERE login = p_login AND is_active;
    IF v_user_id IS NULL THEN
        RETURN pgerp.mcp_error(v_id, -32001, 'The token user is disabled')::JSON;
    END IF;

    CASE v_method
    WHEN 'initialize' THEN
        v_version := v_params->>'protocolVersion';
        RETURN pgerp.mcp_result(v_id, jsonb_build_object(
            'protocolVersion', CASE WHEN v_version IN ('2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05') THEN v_version
                                    ELSE '2025-06-18' END,
            'capabilities', jsonb_build_object('tools', jsonb_build_object('listChanged', FALSE)),
            'serverInfo', jsonb_build_object('name', 'pgerp', 'title', 'PgERP', 'version', '1.0'),
            'instructions', 'PgERP is a platform where application solutions (tables, PL/pgSQL functions, forms, menus, roles, reports) '
                            || 'live entirely in PostgreSQL. Call platform_guide before you start: it describes the platform, '
                            || 'its rules and the development workflow. Write interface texts in English.'))::JSON;

    WHEN 'ping' THEN
        RETURN pgerp.mcp_result(v_id, '{}')::JSON;
    WHEN 'tools/list' THEN
        RETURN pgerp.mcp_result(v_id, jsonb_build_object('tools', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'name', t.name, 'title', t.title, 'description', t.description, 'inputSchema', t.input_schema,
                       'annotations', jsonb_build_object('title', t.title, 'readOnlyHint', t.read_only,
                                                         'destructiveHint', NOT t.read_only AND t.name IN ('object_drop', 'sql_run'),
                                                         'openWorldHint', FALSE))
                   ORDER BY t.sort_order, t.name)
            FROM pgerp.mcp_tools t
            WHERE pgerp.auth_action_allowed(v_user_id, t.action_name)), '[]')))::JSON;
    WHEN 'tools/call' THEN
        v_result := pgerp.mcp_tool_call(p_login, v_params, p_lang);
        IF v_result ? '_error' THEN
            RETURN pgerp.mcp_error(v_id, (v_result->'_error'->>'code')::INT, v_result->'_error'->>'message')::JSON;
        END IF;
        RETURN (pgerp.mcp_result(v_id, v_result - '_gateway')
                || CASE WHEN v_result ? '_gateway' THEN jsonb_build_object('_gateway', v_result->'_gateway') ELSE '{}' END)::JSON;
    ELSE
        RETURN pgerp.mcp_error(v_id, -32601, format('Method not found: %s', v_method))::JSON;
    END CASE;
END;
$$ LANGUAGE plpgsql
SET search_path = public, pgerp;

-- ---------------------------------------------------------------------
-- Действия и инструменты
-- ---------------------------------------------------------------------
INSERT INTO pgerp.ui_actions (action_name, function_name, description, is_system, everyone) VALUES
    ('mcp_tokens_list',  'pgerp.ui_mcp_tokens_list',  'MCP: access tokens',         TRUE, FALSE),
    ('mcp_token_create', 'pgerp.ui_mcp_token_create', 'MCP: issue a token',          TRUE, FALSE),
    ('mcp_token_revoke', 'pgerp.ui_mcp_token_revoke', 'MCP: revoke a token',           TRUE, FALSE),
    ('dev_guide',        'pgerp.ui_dev_guide',        'Developer guide',     TRUE, FALSE),
    ('role_list',        'pgerp.ui_role_list',        'Roles and their forms',             TRUE, FALSE),
    ('role_set',         'pgerp.ui_role_set',         'Role: create and grant forms',      TRUE, FALSE),
    ('translation_list', 'pgerp.ui_translation_list', 'Translations and untranslated texts', TRUE, FALSE);

INSERT INTO pgerp.mcp_tools (sort_order, name, action_name, title, read_only, hook, fixed_args, description, input_schema) VALUES
(1, 'platform_guide', 'dev_guide', 'Platform guide', TRUE, NULL, NULL,
 'How PgERP works, rules and workflow for building an application solution, core helpers and the form format. Call it first.',
 '{"type": "object", "properties": {}}'),

(10, 'solution_list', 'solution_list', 'Solutions', TRUE, NULL, NULL,
 'Application solutions (modules) of this installation: prefix, menu and migration folder, object count, last release.',
 '{"type": "object", "properties": {}}'),
(11, 'solution_get', 'solution_get', 'Solution: contents', TRUE, NULL, NULL,
 'Solution objects (tables, views, functions, forms, actions, reports, roles), releases and objects outside solutions.',
 '{"type": "object", "properties": {"name": {"type": "string", "description": "Solution name"}}, "required": ["name"]}'),
(12, 'solution_save', 'solution_save', 'Solution: create or update', FALSE, NULL, NULL,
 'Creates (is_new=true) or updates a solution. Objects with its prefix belong to the solution automatically.',
 '{"type": "object", "properties": {
    "is_new": {"type": "boolean"}, "name": {"type": "string", "description": "Name: Latin letters, e.g. my_app"},
    "title": {"type": "string"}, "prefix": {"type": "string", "description": "Object name prefix, e.g. my_app_"},
    "menu_folder": {"type": "string", "description": "Top-level menu folder"},
    "migration_folder": {"type": "string", "description": "Package folder db/solutions/<folder>; defaults to the solution name"},
    "db_schema": {"type": "string", "description": "Database schema for solution objects (on creation only); defaults to the solution name"},
    "description": {"type": "string"}}, "required": ["name", "title"]}'),
(13, 'solution_object_set', 'solution_object_set', 'Solution: include an object', FALSE, NULL, NULL,
 'Explicitly includes an object in a solution (if its name lacks the prefix) or excludes it (empty solution).',
 '{"type": "object", "properties": {
    "type": {"type": "string", "enum": ["table", "view", "sequence", "function", "type", "form", "action", "report", "role"]},
    "name": {"type": "string"}, "solution": {"type": "string"}}, "required": ["type", "name"]}'),
(14, 'solution_data_set', 'solution_data_set', 'Solution: carry table rows', FALSE, NULL, NULL,
 'Marks a reference table: its rows go into the release (insert or update by primary key).',
 '{"type": "object", "properties": {"table": {"type": "string"}, "enabled": {"type": "boolean"}}, "required": ["table"]}'),
(15, 'solution_packages', 'solution_save', 'Solution packages', TRUE, 'packages', NULL,
 'Solution packages shipped with the application (db/solutions/<folder>): title, schema, latest and installed versions.',
 '{"type": "object", "properties": {}}'),
(16, 'solution_install', 'solution_save', 'Solution package: install or update', FALSE, 'packages', NULL,
 'Installs a solution from its package (objects go into schema, by default the package''s) or updates it to the latest release. '
 || 'Install only when the user asks.',
 '{"type": "object", "properties": {"name": {"type": "string", "description": "Solution name"},
    "schema": {"type": "string", "description": "Database schema for a new solution"}}, "required": ["name"]}'),

(20, 'schema_get', 'schema_get', 'Data schema', TRUE, NULL, NULL,
 'Tables (columns, keys, references), views and functions of a solution; without solution — of all solutions and public.',
 '{"type": "object", "properties": {"solution": {"type": "string"}}}'),
(21, 'table_get', 'table_get', 'Table: structure', TRUE, NULL, NULL,
 'Table structure for table_save: columns, primary key, foreign keys, unique constraints, checks, indexes, triggers.',
 '{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}'),
(22, 'table_save', 'table_save', 'Table: create or update', FALSE, NULL, NULL,
 'Table designer. Pass the whole structure: columns (old_name — rename), primary_key, constraints and indexes. '
 || 'Existing constraints and indexes have a name (they stay), new ones have none; unlisted ones are dropped. '
 || 'apply=false — SQL only (statements). Renames are remembered: the release renames instead of re-creating.',
 '{"type": "object", "properties": {
    "is_new": {"type": "boolean"}, "name": {"type": "string"}, "old_name": {"type": "string"},
    "solution": {"type": "string", "description": "The solution, if the table name lacks its prefix"},
    "comment": {"type": "string"},
    "columns": {"type": "array", "items": {"type": "object", "properties": {
        "name": {"type": "string"}, "old_name": {"type": "string"},
        "type": {"type": "string", "description": "bigserial, bigint, integer, text, varchar(200), numeric(12,2), boolean, date, timestamptz, jsonb…"},
        "not_null": {"type": "boolean"}, "default": {"type": "string", "description": "SQL expression: 0, now(), ''new''"},
        "comment": {"type": "string"}}, "required": ["name", "type"]}},
    "primary_key": {"type": "array", "items": {"type": "string"}},
    "foreign_keys": {"type": "array", "items": {"type": "object", "properties": {
        "name": {"type": "string"}, "columns": {"type": "array", "items": {"type": "string"}},
        "ref_table": {"type": "string"}, "ref_columns": {"type": "array", "items": {"type": "string"}},
        "on_delete": {"type": "string", "enum": ["NO ACTION", "CASCADE", "SET NULL", "RESTRICT"]}}}},
    "uniques": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "columns": {"type": "array", "items": {"type": "string"}}}}},
    "checks": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "expression": {"type": "string"}}}},
    "indexes": {"type": "array", "items": {"type": "object", "properties": {"name": {"type": "string"}, "columns": {"type": "array", "items": {"type": "string"}}, "unique": {"type": "boolean"}}}},
    "apply": {"type": "boolean"}}, "required": ["name", "columns"]}'),
(23, 'view_get', 'view_get', 'View: query', TRUE, NULL, NULL,
 'The view query, its columns and dependent views.',
 '{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}'),
(24, 'view_save', 'view_save', 'View: create or update', FALSE, NULL, NULL,
 'CREATE OR REPLACE VIEW; re-creates the view if columns were removed or changed type. apply=false — SQL only.',
 '{"type": "object", "properties": {
    "is_new": {"type": "boolean"}, "name": {"type": "string"}, "old_name": {"type": "string"},
    "sql": {"type": "string", "description": "SELECT …"}, "comment": {"type": "string"}, "solution": {"type": "string"},
    "apply": {"type": "boolean"}}, "required": ["name", "sql"]}'),
(25, 'object_drop', 'object_drop', 'Drop an object', FALSE, NULL, NULL,
 'Drops a table, view, function (all overloads), sequence, type or action registration. '
 || 'apply=false — what will be dropped and what depends on the object.',
 '{"type": "object", "properties": {
    "type": {"type": "string", "enum": ["table", "view", "function", "sequence", "type", "action"]},
    "name": {"type": "string"}, "cascade": {"type": "boolean"}, "apply": {"type": "boolean"}}, "required": ["type", "name"]}'),

(30, 'function_source', 'function_source', 'Function: code', TRUE, NULL, NULL,
 'Full code of solution functions with this name (CREATE OR REPLACE FUNCTION …) and the action if the function handles one.',
 '{"type": "object", "properties": {"name": {"type": "string"}}, "required": ["name"]}'),
(31, 'function_get', 'function_get', 'Action: code or stub', TRUE, NULL, NULL,
 'With action — the action function body for function_save; without action — a stub for a form component '
 || '{form, component, type (button|grid|tree|combobox|lookup|timer), label, fields: [{name, type, label}]}.',
 '{"type": "object", "properties": {
    "action": {"type": "string"}, "form": {"type": "string"}, "component": {"type": "string"}, "type": {"type": "string"},
    "label": {"type": "string"}, "fields": {"type": "array", "items": {"type": "object"}}}}'),
(32, 'function_save', 'function_save', 'Action: save the function', FALSE, NULL, NULL,
 'Creates or replaces name(p_data JSON) RETURNS JSON (in the solution schema by name prefix) and registers the action name. body — only the body '
 || '(DECLARE … BEGIN … END; for plpgsql or a query for sql), without CREATE FUNCTION and $$. '
 || 'Functions with other signatures (helpers, triggers) — via sql_run.',
 '{"type": "object", "properties": {
    "is_new": {"type": "boolean"}, "name": {"type": "string"}, "description": {"type": "string"},
    "language": {"type": "string", "enum": ["plpgsql", "sql"]},
    "volatility": {"type": "string", "enum": ["VOLATILE", "STABLE", "IMMUTABLE"]},
    "body": {"type": "string"}}, "required": ["name", "body", "is_new"]}'),

(40, 'form_list', 'form_list', 'Forms and actions', TRUE, NULL, NULL,
 'All forms {name, title, folder} and registered application actions {name, description}.',
 '{"type": "object", "properties": {}}'),
(41, 'form_get', 'form_get', 'Form: structure', TRUE, NULL, '{"source": true}',
 'Form structure with source texts: {name, title, folder, cancel, components: [{type, name, label, action, master, tab, options}]}.',
 '{"type": "object", "properties": {"form": {"type": "string"}}, "required": ["form"]}'),
(42, 'form_save', 'form_save', 'Form: save', FALSE, NULL, NULL,
 'Saves the whole form (components are replaced). Component actions must already be registered.',
 '{"type": "object", "properties": {
    "name": {"type": "string"}, "title": {"type": "string"}, "folder": {"type": "string"},
    "components": {"type": "array", "items": {"type": "object", "properties": {
        "type": {"type": "string", "enum": ["label", "input", "date", "hidden", "display", "lookup", "combobox", "button", "grid", "tree", "board", "timer", "chart"]},
        "name": {"type": "string"}, "label": {"type": "string"}, "action": {"type": "string"},
        "master": {"type": "string"}, "tab": {"type": "string"}, "options": {"type": "object"}}, "required": ["type", "name"]}}},
    "required": ["name", "title", "components"]}'),
(43, 'form_delete', 'form_delete', 'Form: delete', FALSE, NULL, NULL,
 'Deletes a form with its components.',
 '{"type": "object", "properties": {"form": {"type": "string"}}, "required": ["form"]}'),
(44, 'grid_columns_get', 'grid_columns_get', 'Form table: columns', TRUE, NULL, NULL,
 'Columns of a table source, source fields and sample rows.',
 '{"type": "object", "properties": {"action": {"type": "string", "description": "Table source action"}}, "required": ["action"]}'),
(45, 'grid_columns_save', 'grid_columns_save', 'Form table: save columns', FALSE, NULL, NULL,
 'Table source columns in order; an empty list means all row fields.',
 '{"type": "object", "properties": {
    "action": {"type": "string"},
    "columns": {"type": "array", "items": {"type": "object", "properties": {
        "field": {"type": "string"}, "title": {"type": "string"},
        "type": {"type": "string", "enum": ["text", "number", "money", "datetime", "badge"]},
        "sort_column": {"type": "string", "description": "Source column for sorting; empty — no sorting"}},
        "required": ["field", "title"]}}}, "required": ["action", "columns"]}'),
(46, 'menu_get', 'menu_get', 'Menu', TRUE, NULL, '{"source": true}',
 'The application menu as a tree {items: [{title, form, items}]} with source texts.',
 '{"type": "object", "properties": {}}'),
(47, 'menu_save', 'menu_save', 'Menu: save as a whole', FALSE, NULL, NULL,
 'Replaces the WHOLE menu: call menu_get first, then pass the entire tree with your changes.',
 '{"type": "object", "properties": {"items": {"type": "array", "items": {"type": "object", "properties": {
    "title": {"type": "string"}, "form": {"type": "string"}, "items": {"type": "array", "items": {"type": "object"}}}}}},
    "required": ["items"]}'),
(48, 'role_list', 'role_list', 'Roles', TRUE, NULL, NULL,
 'Roles, their granted forms and user count.',
 '{"type": "object", "properties": {}}'),
(49, 'role_set', 'role_set', 'Role: create and grant forms', FALSE, NULL, NULL,
 'Creates or updates a role; forms replaces the granted forms (forms opened from them are available automatically).',
 '{"type": "object", "properties": {"role_name": {"type": "string"}, "title": {"type": "string"},
    "forms": {"type": "array", "items": {"type": "string"}}}, "required": ["role_name", "title"]}'),
(50, 'translation_list', 'translation_list', 'Translations', TRUE, NULL, NULL,
 'Translations into language lang (ru by default); missing=true — interface and code texts without a translation.',
 '{"type": "object", "properties": {"lang": {"type": "string"}, "missing": {"type": "boolean"},
    "search": {"type": "string"}, "limit": {"type": "integer"}}}'),
(51, 'translation_save', 'translation_save', 'Translation: save', FALSE, NULL, NULL,
 'Translation of a source (English) text. In templates with %s the translation must have the same number of placeholders.',
 '{"type": "object", "properties": {"lang": {"type": "string"}, "source": {"type": "string"}, "translation": {"type": "string"}},
    "required": ["lang", "source", "translation"]}'),
(52, 'report_list', 'report_list', 'PDF reports', TRUE, NULL, NULL,
 'PDF reports (JasperReports 7) and actions that can serve as data functions.',
 '{"type": "object", "properties": {}}'),
(53, 'report_get', 'report_get', 'Report: template', TRUE, NULL, NULL,
 'A report with its jrxml template; without name — a stub for a new one.',
 '{"type": "object", "properties": {"name": {"type": "string"}}}'),
(54, 'report_save', 'report_save', 'Report: save', FALSE, 'compile_jrxml', NULL,
 'Saves a report; the jrxml template is compiled first. The data function (data_action) returns {params, rows}.',
 '{"type": "object", "properties": {
    "is_new": {"type": "boolean"}, "name": {"type": "string"}, "title": {"type": "string"}, "data_action": {"type": "string"},
    "sample_params": {"type": "object"}, "jrxml": {"type": "string"}}, "required": ["name", "title", "jrxml", "is_new"]}'),

(60, 'sql_run', 'sql_run', 'SQL: run', FALSE, NULL, NULL,
 'Runs a query or script as the database owner: result rows (up to max_rows) or the number of affected rows. '
 || 'rollback=true — run and roll back. An error goes into the error field.',
 '{"type": "object", "properties": {"sql": {"type": "string"}, "rollback": {"type": "boolean"},
    "max_rows": {"type": "integer"}}, "required": ["sql"]}'),
(61, 'action_run', 'action_run', 'Action: test', FALSE, NULL, NULL,
 'Calls an action like a form does: data — field values, user — on whose behalf (their roles'' rights). '
 || 'rollback (true by default) — changes are rolled back. Returns the action response or an error.',
 '{"type": "object", "properties": {"action": {"type": "string"}, "data": {"type": "object"}, "user": {"type": "string"},
    "rollback": {"type": "boolean"}}, "required": ["action"]}'),

(70, 'release_preview', 'release_preview', 'Release: preview', TRUE, NULL, NULL,
 'What changed in the solution since the last release, warnings and the Flyway migration text (content). full=true — the whole solution.',
 '{"type": "object", "properties": {"solution": {"type": "string"}, "label": {"type": "string"}, "full": {"type": "boolean"}},
    "required": ["solution"]}'),
(71, 'release_create', 'release_create', 'Release: create', FALSE, 'write_migration', NULL,
 'Records a release: the next solution snapshot and the package file (file_name, path, content). The gateway saves the file '
 || 'if a packages folder is configured; otherwise save content at path. Create a release only when the user asks.',
 '{"type": "object", "properties": {"solution": {"type": "string"}, "label": {"type": "string", "description": "Release title"}},
    "required": ["solution", "label"]}'),
(72, 'release_get', 'release_get', 'Release: migration text', TRUE, NULL, NULL,
 'Migration text of a recorded release.',
 '{"type": "object", "properties": {"solution": {"type": "string"}, "version": {"type": "integer"}}, "required": ["solution", "version"]}');

-- ---------------------------------------------------------------------
-- Переводы: сообщения токенов MCP, ролей и описания действий
-- ---------------------------------------------------------------------
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Enter the token purpose, for example “Claude Code on my laptop”', 'Укажите назначение токена, например «Claude Code на ноутбуке»'),
    ('ru', 'There is no active user “%s”', 'Активного пользователя «%s» нет'),
    ('ru', 'Validity is from 1 to 3650 days or no expiry', 'Срок действия — от 1 до 3650 дней или без срока'),
    ('ru', 'Token not found — it may have been revoked already', 'Токен не найден — возможно, он уже отозван'),
    ('ru', 'Token revoked', 'Токен отозван'),
    ('ru', 'Role code: lowercase Latin letters, digits and _', 'Код роли: латинские буквы в нижнем регистре, цифры и _'),
    ('ru', 'The admin role sees everything and is not configurable', 'Роль admin видит всё и не настраивается'),
    ('ru', 'Enter the role title', 'Укажите название роли'),
    ('ru', 'There is no form “%s”', 'Формы «%s» нет'),
    ('ru', 'Role “%s” saved', 'Роль «%s» сохранена'),
    ('ru', 'The token user is disabled', 'Пользователь токена отключён'),
    ('ru', 'MCP: access tokens', 'MCP: токены доступа'),
    ('ru', 'MCP: issue a token', 'MCP: выдача токена'),
    ('ru', 'MCP: revoke a token', 'MCP: отзыв токена'),
    ('ru', 'Developer guide', 'Справочник разработчика'),
    ('ru', 'Roles and their forms', 'Роли и их формы'),
    ('ru', 'Role: create and grant forms', 'Роль: создание и формы'),
    ('ru', 'Translations and untranslated texts', 'Переводы и тексты без перевода')
ON CONFLICT (lang, source) DO NOTHING;

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Platform core', 'Ядро платформы'),
    ('ru', 'Schema pgerp, administration forms and the admin role. Changed only by core migrations',
           'Схема pgerp, формы администрирования и роль admin. Меняется только миграциями ядра'),
    ('ru', 'Initial state', 'Исходное состояние')
ON CONFLICT (lang, source) DO NOTHING;
