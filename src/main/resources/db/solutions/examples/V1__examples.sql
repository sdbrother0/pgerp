-- =====================================================================
-- Пакет решения «Примеры», выпуск 1: небольшие примеры возможностей платформы
-- =====================================================================
--  * Hello World — кнопка и сообщение на языке пользователя (ui_t с подстановкой).
--  * Деление — проверки ввода (ui_require), ошибка с инструкциями (ui_error).
--  * Падающие блоки — игра на поле из клеток: таймер, горячие клавиши, set_values.
--  * Чат — сообщения во всех открытых вкладках без перезагрузки (ui_push_to).
--
-- Устанавливает администратор (при первом входе или в редакторе: «Решения → Установить»); объекты
-- создаются в схеме решения (по умолчанию examples, выбирается при установке). Объекты примеров — без
-- общего префикса имён, поэтому входят в решение явно (pgerp.solution_objects).
-- Выпуск применяется один раз: на базе, где он уже записан (pgerp.solution_releases), он пропускается.
SELECT pgerp.solution_release_apply('examples', 1, 'Examples', $release$
-- Решение
INSERT INTO pgerp.solutions (name, title, prefix, menu_folder, migration_folder, description)
VALUES ('examples', 'Examples', NULL, 'Examples', 'examples', 'Hello World, division, falling blocks, chat')
ON CONFLICT (name) DO UPDATE SET title = EXCLUDED.title, prefix = EXCLUDED.prefix, menu_folder = EXCLUDED.menu_folder,
    migration_folder = EXCLUDED.migration_folder, description = EXCLUDED.description;
DELETE FROM pgerp.solution_objects WHERE solution = 'examples';
INSERT INTO pgerp.solution_objects (object_type, object_name, solution) VALUES
    ('action', 'chat_announce', 'examples'),
    ('action', 'chat_page', 'examples'),
    ('action', 'chat_send', 'examples'),
    ('action', 'division_run', 'examples'),
    ('action', 'game_down', 'examples'),
    ('action', 'game_drop', 'examples'),
    ('action', 'game_left', 'examples'),
    ('action', 'game_pause', 'examples'),
    ('action', 'game_right', 'examples'),
    ('action', 'game_start', 'examples'),
    ('action', 'hello_run', 'examples'),
    ('form', 'chat', 'examples'),
    ('form', 'division', 'examples'),
    ('form', 'falling_blocks', 'examples'),
    ('form', 'hello_world', 'examples'),
    ('function', 'chat_announce', 'examples'),
    ('function', 'chat_page', 'examples'),
    ('function', 'chat_send', 'examples'),
    ('function', 'division_parse', 'examples'),
    ('function', 'division_run', 'examples'),
    ('function', 'game_current', 'examples'),
    ('function', 'game_down', 'examples'),
    ('function', 'game_drop', 'examples'),
    ('function', 'game_free', 'examples'),
    ('function', 'game_height', 'examples'),
    ('function', 'game_land', 'examples'),
    ('function', 'game_left', 'examples'),
    ('function', 'game_move', 'examples'),
    ('function', 'game_pause', 'examples'),
    ('function', 'game_response', 'examples'),
    ('function', 'game_right', 'examples'),
    ('function', 'game_rows', 'examples'),
    ('function', 'game_spawn', 'examples'),
    ('function', 'game_start', 'examples'),
    ('function', 'game_width', 'examples'),
    ('function', 'hello_run', 'examples'),
    ('table', 'chat_messages', 'examples'),
    ('view', 'chat_messages_v', 'examples')
ON CONFLICT (object_type, object_name) DO UPDATE SET solution = EXCLUDED.solution;
DELETE FROM pgerp.solution_data WHERE solution = 'examples';

-- Таблицы
CREATE TABLE IF NOT EXISTS chat_messages (
    id bigserial,
    author character varying(50) NOT NULL,
    text character varying(500) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT chat_messages_pkey PRIMARY KEY (id)
);

-- Функции
CREATE OR REPLACE FUNCTION chat_announce(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_author TEXT := ui_user_name();
    v_text   TEXT := ui_text(p_data, 'message');
BEGIN
    PERFORM ui_require(v_text IS NOT NULL, 'Write the announcement text');

    PERFORM ui_push(ui_message(format('Announcement from %s: %s', v_author, left(v_text, 500))));

    RETURN ui_ok(ui_clear_fields('message'));
END;
$function$;

CREATE OR REPLACE FUNCTION chat_page(p_data json)
 RETURNS json
 LANGUAGE sql
AS $function$
    SELECT ui_grid_page('chat_page', p_data, 'chat_messages_v', NULL, 'sent_at', 'desc');
$function$;

CREATE OR REPLACE FUNCTION chat_send(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_author TEXT := ui_user_name();
    v_text   TEXT := ui_text(p_data, 'message');
BEGIN
    PERFORM ui_require(v_text IS NOT NULL, 'Write a message');

    INSERT INTO chat_messages (author, text) VALUES (left(v_author, 50), left(v_text, 500));

    -- Таблица обновится у всех, где открыт чат, в том числе у отправителя.
    -- Команда уйдёт при фиксации транзакции — когда сообщение уже видно в базе.
    PERFORM ui_push_to('chat', ui_refresh_grid('chat_grid'));

    RETURN ui_ok(ui_clear_fields('message'));
END;
$function$;

CREATE OR REPLACE FUNCTION division_parse(p_value text, p_field character varying)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_text TEXT := replace(replace(trim(p_value), ' ', ''), ',', '.');
BEGIN
    IF v_text IS NULL OR v_text = '' THEN
        RAISE EXCEPTION 'Enter a value for field %', p_field;
    END IF;
    IF v_text !~ '^[+-]?(\d+\.?\d*|\.\d+)$' THEN
        RAISE EXCEPTION 'Field %: "%" is not a number', p_field, trim(p_value);
    END IF;
    RETURN v_text::NUMERIC;
END;
$function$;

CREATE OR REPLACE FUNCTION division_run(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_a NUMERIC := division_parse(p_data->>'a', 'a');
    v_b NUMERIC := division_parse(p_data->>'b', 'b');
BEGIN
    IF v_b = 0 THEN
        PERFORM ui_error('Division by zero is not possible', ui_clear_fields('result'));
    END IF;

    RETURN ui_ok(ui_set_values(jsonb_build_object(
        'result', replace(trim_scale(round(v_a / v_b, 10))::TEXT, '.', ','))));
END;
$function$;

CREATE OR REPLACE FUNCTION game_current(p_data json)
 RETURNS jsonb
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ui_text(p_data, 'state')::JSONB;
$function$;

CREATE OR REPLACE FUNCTION game_down(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_state JSONB := game_current(p_data);
    v_y     INT;
BEGIN
    IF v_state IS NULL THEN
        RETURN ui_ok();
    END IF;
    v_y := (v_state->>'y')::INT + 1;
    IF game_free(game_rows(v_state), (v_state->>'x')::INT, v_y) THEN
        RETURN game_response(jsonb_set(v_state, '{y}', to_jsonb(v_y)));
    END IF;
    RETURN game_response(game_land(v_state));
END;
$function$;

CREATE OR REPLACE FUNCTION game_drop(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_state JSONB := game_current(p_data);
    v_rows  TEXT[];
    v_x     INT;
    v_y     INT;
BEGIN
    IF v_state IS NULL THEN
        RETURN ui_ok();
    END IF;
    v_rows := game_rows(v_state);
    v_x := (v_state->>'x')::INT;
    v_y := (v_state->>'y')::INT;
    WHILE game_free(v_rows, v_x, v_y + 1) LOOP
        v_y := v_y + 1;
    END LOOP;
    RETURN game_response(game_land(jsonb_set(v_state, '{y}', to_jsonb(v_y))));
END;
$function$;

CREATE OR REPLACE FUNCTION game_free(p_rows text[], p_x integer, p_y integer)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT p_x BETWEEN 0 AND game_width() - 1
       AND p_y BETWEEN 0 AND game_height() - 1
       AND substr(p_rows[p_y + 1], p_x + 1, 1) = '.';
$function$;

CREATE OR REPLACE FUNCTION game_height()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$SELECT 12$function$;

CREATE OR REPLACE FUNCTION game_land(p_state jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_rows    TEXT[] := game_rows(p_state);
    v_x       INT    := (p_state->>'x')::INT;
    v_y       INT    := (p_state->>'y')::INT;
    v_kept    TEXT[];
    v_cleared INT;
BEGIN
    v_rows[v_y + 1] := overlay(v_rows[v_y + 1] PLACING '#' FROM v_x + 1 FOR 1);
    v_kept := ARRAY(SELECT r FROM unnest(v_rows) WITH ORDINALITY AS u(r, n) WHERE strpos(r, '.') > 0 ORDER BY n);
    v_cleared := game_height() - cardinality(v_kept);
    v_rows := array_fill(repeat('.', game_width()), ARRAY[v_cleared]) || v_kept;
    RETURN game_spawn(v_rows, (p_state->>'score')::INT + v_cleared);
END;
$function$;

CREATE OR REPLACE FUNCTION game_left(p_data json)
 RETURNS json
 LANGUAGE sql
AS $function$SELECT game_move(p_data, -1)$function$;

CREATE OR REPLACE FUNCTION game_move(p_data json, p_dx integer)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_state JSONB := game_current(p_data);
    v_x     INT;
BEGIN
    IF v_state IS NULL THEN
        RETURN ui_ok();
    END IF;
    v_x := (v_state->>'x')::INT + p_dx;
    IF game_free(game_rows(v_state), v_x, (v_state->>'y')::INT) THEN
        v_state := jsonb_set(v_state, '{x}', to_jsonb(v_x));
    END IF;
    RETURN game_response(v_state);
END;
$function$;

CREATE OR REPLACE FUNCTION game_pause(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF game_current(p_data) IS NULL THEN
        RETURN ui_ok();
    END IF;
    RETURN ui_ok(ui_set_values(jsonb_build_object(
        'ticker', CASE WHEN ui_text(p_data, 'ticker') IS NULL THEN '1' ELSE '' END)));
END;
$function$;

CREATE OR REPLACE FUNCTION game_response(p_state jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
DECLARE
    v_rows  TEXT[]  := game_rows(p_state);
    v_x     INT     := (p_state->>'x')::INT;
    v_y     INT     := (p_state->>'y')::INT;
    v_over  BOOLEAN := (p_state->>'over')::BOOLEAN;
    v_score TEXT    := p_state->>'score';
BEGIN
    v_rows[v_y + 1] := overlay(v_rows[v_y + 1] PLACING '@' FROM v_x + 1 FOR 1);
    RETURN ui_ok(
        ui_set_values(jsonb_build_object(
            'board', array_to_string(v_rows, '/'),
            'score', v_score,
            'state', CASE WHEN v_over THEN '' ELSE p_state::TEXT END)
            || CASE WHEN v_over THEN jsonb_build_object('ticker', '') ELSE '{}'::jsonb END),
        CASE WHEN v_over THEN ui_message(format('Game over. Score: %s', v_score)) END);
END;
$function$;

CREATE OR REPLACE FUNCTION game_right(p_data json)
 RETURNS json
 LANGUAGE sql
AS $function$SELECT game_move(p_data, 1)$function$;

CREATE OR REPLACE FUNCTION game_rows(p_state jsonb)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    SELECT ARRAY(SELECT jsonb_array_elements_text(p_state->'rows'));
$function$;

CREATE OR REPLACE FUNCTION game_spawn(p_rows text[], p_score integer)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_x INT := floor(random() * game_width())::INT;
BEGIN
    RETURN jsonb_build_object('rows', to_jsonb(p_rows), 'x', v_x, 'y', 0, 'score', p_score,
                              'over', NOT game_free(p_rows, v_x, 0));
END;
$function$;

CREATE OR REPLACE FUNCTION game_start(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_response JSONB := game_response(game_spawn(array_fill(repeat('.', game_width()), ARRAY[game_height()]), 0));
BEGIN
    -- Вместе с полем включается таймер
    RETURN ui_ok(v_response->'ui_instructions', ui_set_values(jsonb_build_object('ticker', '1')));
END;
$function$;

CREATE OR REPLACE FUNCTION game_width()
 RETURNS integer
 LANGUAGE sql
 IMMUTABLE
AS $function$SELECT 8$function$;

CREATE OR REPLACE FUNCTION hello_run(p_data json)
 RETURNS json
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_name VARCHAR := ui_text(p_data, 'user_name');
BEGIN
    PERFORM ui_require(v_name IS NOT NULL, ui_t('Enter a name'));

    RETURN ui_ok(ui_message(format(ui_t('Hello, %s'), v_name)));
END;
$function$;

-- Представления
CREATE OR REPLACE VIEW chat_messages_v AS
 SELECT id,
    author,
    text,
    to_char(created_at, 'DD.MM HH24:MI:SS'::text) AS sent_at
   FROM chat_messages;

-- Метаданные
INSERT INTO pgerp.ui_actions (action_name, function_name, description, everyone) VALUES
    ('chat_announce', 'chat_announce', 'Chat: announcement in all open tabs (ui_push)', 'false'),
    ('chat_page', 'chat_page', 'Chat: messages, newest first', 'false'),
    ('chat_send', 'chat_send', 'Chat: send a message — the table refreshes for everyone (ui_push_to)', 'false'),
    ('division_run', 'division_run', 'Divide a by b, result in the result field', 'false'),
    ('game_down', 'game_down', 'Falling blocks: step down (timer tick)', 'false'),
    ('game_drop', 'game_drop', 'Falling blocks: drop', 'false'),
    ('game_left', 'game_left', 'Falling blocks: left', 'false'),
    ('game_pause', 'game_pause', 'Falling blocks: pause / resume', 'false'),
    ('game_right', 'game_right', 'Falling blocks: right', 'false'),
    ('game_start', 'game_start', 'Falling blocks: new game', 'false'),
    ('hello_run', 'hello_run', 'Greeting by the name in the user_name field', 'false')
ON CONFLICT (action_name) DO UPDATE SET function_name = EXCLUDED.function_name, description = EXCLUDED.description,
    everyone = EXCLUDED.everyone, is_system = FALSE;

INSERT INTO pgerp.forms (form_name, title, cancel_action, folder) VALUES
    ('chat', 'Chat', NULL, 'Examples'),
    ('division', 'Division', NULL, 'Examples'),
    ('falling_blocks', 'Falling blocks', NULL, 'Examples'),
    ('hello_world', 'Hello World', NULL, 'Examples')
ON CONFLICT (form_name) DO UPDATE SET title = EXCLUDED.title, cancel_action = EXCLUDED.cancel_action,
    folder = EXCLUDED.folder, updated_at = now();

DELETE FROM pgerp.form_components WHERE form_name IN ('chat', 'division', 'falling_blocks', 'hello_world');
INSERT INTO pgerp.form_components (form_name, sort_order, component_type, component_name, label, action_event, master_field, tab, options) VALUES
    ('chat', '2', 'grid', 'chat_grid', 'Messages', 'chat_page', NULL, NULL, NULL),
    ('chat', '3', 'input', 'message', 'Message', NULL, NULL, NULL, NULL),
    ('chat', '4', 'button', 'btn_send', 'Send', 'chat_send', NULL, NULL, NULL),
    ('chat', '5', 'button', 'btn_announce', 'Announce to all', 'chat_announce', NULL, NULL, NULL),
    ('chat', '6', 'label', 'help', 'Open the chat in two tabs: a message appears in both at once (NOTIFY). “Announce to all” shows a window in every PgERP tab, on any form.', NULL, NULL, NULL, NULL),
    ('division', '1', 'input', 'a', 'a', NULL, NULL, NULL, NULL),
    ('division', '2', 'input', 'b', 'b', NULL, NULL, NULL, NULL),
    ('division', '3', 'display', 'result', 'Division result', NULL, NULL, NULL, NULL),
    ('division', '4', 'button', 'btn_divide', 'Divide', 'division_run', NULL, NULL, NULL),
    ('falling_blocks', '1', 'hidden', 'state', NULL, NULL, NULL, NULL, NULL),
    ('falling_blocks', '10', 'button', 'btn_pause', 'Pause', 'game_pause', NULL, NULL, '{"hotkey": "KeyP"}'),
    ('falling_blocks', '11', 'label', 'help', 'Keys: ← → move, ↓ step down, Space drop, P pause. A filled row disappears and scores a point.', NULL, NULL, NULL, NULL),
    ('falling_blocks', '2', 'timer', 'ticker', NULL, 'game_down', NULL, NULL, '{"interval": 400}'),
    ('falling_blocks', '3', 'board', 'board', NULL, NULL, NULL, NULL, '{"cols": 8, "rows": 12}'),
    ('falling_blocks', '4', 'display', 'score', 'Score', NULL, NULL, NULL, NULL),
    ('falling_blocks', '5', 'button', 'btn_start', 'New game', 'game_start', NULL, NULL, NULL),
    ('falling_blocks', '6', 'button', 'btn_left', '←', 'game_left', NULL, NULL, '{"hotkey": "ArrowLeft"}'),
    ('falling_blocks', '7', 'button', 'btn_down', '↓', 'game_down', NULL, NULL, '{"hotkey": "ArrowDown"}'),
    ('falling_blocks', '8', 'button', 'btn_right', '→', 'game_right', NULL, NULL, '{"hotkey": "ArrowRight"}'),
    ('falling_blocks', '9', 'button', 'btn_drop', 'Drop', 'game_drop', NULL, NULL, '{"hotkey": "Space"}'),
    ('hello_world', '1', 'input', 'user_name', 'Your name', NULL, NULL, NULL, NULL),
    ('hello_world', '2', 'button', 'btn_run', 'Run', 'hello_run', NULL, NULL, NULL);

DELETE FROM pgerp.grid_columns WHERE action_name IN ('chat_announce', 'chat_page', 'chat_send', 'division_run', 'game_down', 'game_drop', 'game_left', 'game_pause', 'game_right', 'game_start', 'hello_run');
INSERT INTO pgerp.grid_columns (action_name, display_order, field_name, column_title, cell_type, sort_column) VALUES
    ('chat_page', '1', 'sent_at', 'Time', 'datetime', 'id'),
    ('chat_page', '2', 'author', 'Author', 'text', 'author'),
    ('chat_page', '3', 'text', 'Message', 'text', 'text');
DELETE FROM pgerp.grid_row_actions WHERE source_action IN ('chat_announce', 'chat_page', 'chat_send', 'division_run', 'game_down', 'game_drop', 'game_left', 'game_pause', 'game_right', 'game_start', 'hello_run');

SELECT pgerp.solution_menu_apply('Examples', '[
    {
        "form": "hello_world",
        "title": "Hello World"
    },
    {
        "form": "division",
        "title": "Division"
    },
    {
        "form": "falling_blocks",
        "title": "Falling blocks"
    },
    {
        "form": "chat",
        "title": "Chat"
    }
]');

-- Удалённые функции и типы, переводы
INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Hello World, division, falling blocks, chat', 'Hello World, деление, падающие блоки, чат'),
    ('ru', 'a', 'a'),
    ('ru', 'b', 'b'),
    ('ru', '←', '←'),
    ('ru', '→', '→'),
    ('ru', '↓', '↓'),
    ('ru', 'Hello World', 'Hello World'),
    ('ru', 'Division result', 'Результат деления'),
    ('ru', 'Run', 'Запустить'),
    ('ru', 'Author', 'Автор'),
    ('ru', 'Enter a value for field %', 'Введите значение поля %'),
    ('ru', 'Enter a name', 'Введите имя'),
    ('ru', 'Time', 'Время'),
    ('ru', 'Division', 'Деление'),
    ('ru', 'Divide a by b, result in the result field', 'Деление a на b, результат в поле result'),
    ('ru', 'Division by zero is not possible', 'Деление на ноль невозможно'),
    ('ru', 'Game over. Score: %s', 'Игра окончена. Очки: %s'),
    ('ru', 'Your name', 'Имя'),
    ('ru', 'Keys: ← → move, ↓ step down, Space drop, P pause. A filled row disappears and scores a point.', 'Клавиши: ← → — сдвиг, ↓ — шаг вниз, пробел — сбросить, P — пауза. Заполненная строка исчезает и даёт очко.'),
    ('ru', 'Write a message', 'Напишите сообщение'),
    ('ru', 'Write the announcement text', 'Напишите текст объявления'),
    ('ru', 'New game', 'Новая игра'),
    ('ru', 'Announce to all', 'Объявить всем'),
    ('ru', 'Announcement from %s: %s', 'Объявление от %s: %s'),
    ('ru', 'Open the chat in two tabs: a message appears in both at once (NOTIFY). “Announce to all” shows a window in every PgERP tab, on any form.', 'Откройте чат в двух вкладках: сообщение сразу появится в обеих (NOTIFY). «Объявить всем» покажет окно во всех вкладках PgERP, на любой форме.'),
    ('ru', 'Send', 'Отправить'),
    ('ru', 'Score', 'Очки'),
    ('ru', 'Falling blocks', 'Падающие блоки'),
    ('ru', 'Falling blocks: left', 'Падающие блоки: влево'),
    ('ru', 'Falling blocks: right', 'Падающие блоки: вправо'),
    ('ru', 'Falling blocks: new game', 'Падающие блоки: новая игра'),
    ('ru', 'Falling blocks: pause / resume', 'Падающие блоки: пауза / продолжить'),
    ('ru', 'Falling blocks: drop', 'Падающие блоки: сбросить до упора'),
    ('ru', 'Falling blocks: step down (timer tick)', 'Падающие блоки: шаг вниз (такт таймера)'),
    ('ru', 'Pause', 'Пауза'),
    ('ru', 'Field %: "%" is not a number', 'Поле %: "%" — не число'),
    ('ru', 'Hello, %s', 'Привет, %s'),
    ('ru', 'Greeting by the name in the user_name field', 'Приветствие по имени из поля user_name'),
    ('ru', 'Examples', 'Примеры'),
    ('ru', 'Divide', 'Разделить'),
    ('ru', 'Drop', 'Сбросить'),
    ('ru', 'Message', 'Сообщение'),
    ('ru', 'Messages', 'Сообщения'),
    ('ru', 'Chat', 'Чат'),
    ('ru', 'Chat: announcement in all open tabs (ui_push)', 'Чат: объявление во всех открытых вкладках (ui_push)'),
    ('ru', 'Chat: send a message — the table refreshes for everyone (ui_push_to)', 'Чат: отправить сообщение — таблица обновится у всех (ui_push_to)'),
    ('ru', 'Chat: messages, newest first', 'Чат: сообщения, новые сверху')
ON CONFLICT (lang, source) DO UPDATE SET translation = EXCLUDED.translation;
$release$);

