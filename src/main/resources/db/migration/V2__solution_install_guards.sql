-- =====================================================================
-- Защита установки решений.
--
-- 1. Пока пароль не сменён, решения не ставятся и не переустанавливаются: установка идёт мимо
--    маршрутизатора handle_ui_event, поэтому проверка нужна здесь.
-- 2. Чистая установка удаляет схему с содержимым, только если это схема самого установленного решения.
--    Для ещё не установленного решения схема должна отсутствовать или быть пустой: чужие данные не удаляются.
-- =====================================================================

CREATE OR REPLACE FUNCTION pgerp.solution_install_begin(p_login VARCHAR, p_solution VARCHAR, p_schema VARCHAR,
                                                        p_reset BOOLEAN DEFAULT FALSE)
RETURNS INT AS $$
DECLARE
    v_user   pgerp.users%ROWTYPE;
    v_schema VARCHAR := lower(trim(COALESCE(p_schema, '')));
    v_target VARCHAR;
BEGIN
    IF p_login IS NOT NULL THEN
        SELECT * INTO v_user FROM pgerp.users WHERE login = p_login AND is_active;
        -- Маршрутизатора здесь нет — язык ошибок задаём сами
        IF v_user.lang IS NOT NULL THEN
            PERFORM set_config('pgerp.lang', v_user.lang, TRUE);
        END IF;
        IF v_user.id IS NULL OR NOT pgerp.auth_is_admin(v_user.id) THEN
            RAISE EXCEPTION USING ERRCODE = 'U0003', MESSAGE = pgerp.ui_t('Only an administrator can install solutions');
        END IF;
        IF v_user.must_change_password THEN
            RAISE EXCEPTION USING ERRCODE = 'U0003', MESSAGE = pgerp.ui_t('Change your password to continue');
        END IF;
        PERFORM set_config('pgerp.user', p_login, TRUE);
    END IF;
    PERFORM ui_require(p_solution ~ '^[a-z][a-z0-9_]*$' AND p_solution <> 'core', format('Invalid solution name: %s', p_solution));
    IF p_reset THEN
        PERFORM ui_require(p_login IS NOT NULL, 'A clean installation is started only by an administrator');
        v_target := COALESCE(NULLIF(v_schema, ''), p_solution);
        -- В public solution_reset удаляет только объекты установленного решения. В остальных схемах
        -- pg_depend видит любое содержимое: таблицы, функции, типы, расширения
        IF v_target <> 'public' AND NOT EXISTS (SELECT 1 FROM pgerp.solutions WHERE name = p_solution) THEN
            IF EXISTS (SELECT 1
                       FROM pg_depend d
                       JOIN pg_namespace n ON n.oid = d.refobjid
                       WHERE d.refclassid = 'pg_namespace'::regclass AND n.nspname = v_target) THEN
                RAISE EXCEPTION USING MESSAGE = pgerp.ui_t(format(
                    'Schema “%s” is not empty and does not belong to solution “%s”: choose another schema or drop it manually',
                    v_target, p_solution));
            END IF;
        END IF;
        PERFORM pgerp.solution_reset(p_solution, v_target);
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

INSERT INTO pgerp.translations (lang, source, translation) VALUES
    ('ru', 'Schema “%s” is not empty and does not belong to solution “%s”: choose another schema or drop it manually',
           'Схема «%s» не пуста и не принадлежит решению «%s»: выберите другую схему или удалите её вручную')
ON CONFLICT (lang, source) DO NOTHING;
