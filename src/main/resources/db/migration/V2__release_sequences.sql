-- =====================================================================
-- Первый выпуск решения терял его последовательности
-- =====================================================================
-- В первом выпуске (и в «Полном скрипте») прошлого снимка нет: v_old = '{}', v_old->'sequences' — NULL,
-- условие NOT (NULL ? имя) — тоже NULL, и CREATE SEQUENCE в выпуск не попадал. Код решения, вызывающий
-- nextval такой последовательности, на другой установке падал. Функция заменяется целиком, отличие от
-- V1 — одна строка в разделе «Последовательности»: отсутствие прошлого снимка значит «последовательность новая».

CREATE OR REPLACE FUNCTION pgerp.solution_script(p_new JSONB, p_old JSONB, p_since TIMESTAMPTZ)
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
        IF NOT COALESCE(v_old->'sequences' ? v_name, FALSE) THEN
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
            v_warnings := v_warnings || format('Column %s.%s will be deleted with its data. If this is a rename, do it in the table designer — the release will rename the column', v_name, v_oc->>'name');
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
        (1, 'Solution', ARRAY[p_new->'sql'->>'solution']),  -- no i18n
        (2, 'Renames', v_renames),  -- no i18n
        (3, 'Views: drop before re-creation', v_drop_views),  -- no i18n
        (4, 'Foreign keys: drop changed ones', v_drop_fk),  -- no i18n
        (5, 'Constraints, indexes and triggers: drop changed ones', v_drop_parts),  -- no i18n
        (6, 'Dropped tables', v_drop_tables),  -- no i18n
        (7, 'Types and sequences', v_types),  -- no i18n
        (8, 'Tables', v_tables),  -- no i18n
        (9, 'Constraints', v_constraints),  -- no i18n
        (10, 'Functions', v_functions),  -- no i18n
        (11, 'Views', v_views),  -- no i18n
        (12, 'Foreign keys', v_fk),  -- no i18n
        (13, 'Indexes', v_indexes),  -- no i18n
        (14, 'Triggers', v_triggers),  -- no i18n
        (15, 'Comments', v_comments),  -- no i18n
        (16, 'Data', v_data),  -- no i18n
        (17, 'Metadata', v_meta),  -- no i18n
        (18, 'Dropped metadata', v_drop_meta),  -- no i18n
        (19, 'Dropped functions and types, translations', v_drop_last)) AS s(n, title, parts)  -- no i18n
    WHERE cardinality(array_remove(parts, NULL)) > 0;

    RETURN jsonb_build_object(
        'script', v_script,
        'full', v_full,
        'empty', NOT v_full AND cardinality(v_changes) = 0,
        'changes', to_jsonb(v_changes),
        'warnings', to_jsonb(v_warnings));
END;
$$ LANGUAGE plpgsql STABLE;
