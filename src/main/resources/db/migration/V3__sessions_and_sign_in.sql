-- =====================================================================
-- Сессии и вход.
--
-- 1. У пользователя есть отметка сессии: смена пароля, логина или состояния её меняет. Шлюз сверяет отметку
--    на каждом запросе и берёт роли из базы, а не из сессии. Открытые WebSocket закрывает сообщение revoked_users.
--    Смена пароля отзывает и токены MCP пользователя.
-- 2. Неудачные попытки входа считаются по паре «логин + источник» одинаково для любых логинов, есть ли они или нет.
--    Источник — известный браузер (cookie после удачного входа), иначе адрес. От перебора со многих адресов —
--    общий предел на логин; известных браузеров он не касается, поэтому владельца посторонний не заблокирует.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Сессии
-- ---------------------------------------------------------------------
ALTER TABLE pgerp.users ADD COLUMN session_stamp UUID NOT NULL DEFAULT gen_random_uuid();

CREATE FUNCTION pgerp.auth_session_rotate()
RETURNS TRIGGER AS $$
BEGIN
    IF (NEW.password_hash, NEW.login, NEW.is_active) IS DISTINCT FROM (OLD.password_hash, OLD.login, OLD.is_active) THEN
        NEW.session_stamp := gen_random_uuid();
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_session_rotate BEFORE UPDATE ON pgerp.users
    FOR EACH ROW EXECUTE FUNCTION pgerp.auth_session_rotate();

CREATE FUNCTION pgerp.auth_session_revoked()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' THEN
        IF NEW.session_stamp = OLD.session_stamp THEN
            RETURN NULL;
        END IF;
        IF NEW.password_hash IS DISTINCT FROM OLD.password_hash THEN
            DELETE FROM pgerp.mcp_tokens WHERE user_id = NEW.id;
        END IF;
    END IF;
    PERFORM pg_notify('erp_ui', json_build_object('revoked_users', json_build_array(OLD.login))::TEXT);
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_session_revoked AFTER UPDATE OR DELETE ON pgerp.users
    FOR EACH ROW EXECUTE FUNCTION pgerp.auth_session_revoked();

-- Текущее состояние вошедшего: нет строки — пользователь отключён или удалён
CREATE FUNCTION pgerp.auth_session(p_login VARCHAR)
RETURNS TABLE (stamp TEXT, user_roles VARCHAR[], must_change BOOLEAN) AS $$
    SELECT u.session_stamp::TEXT,
           ARRAY(SELECT r.role_name FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
                 WHERE ur.user_id = u.id ORDER BY r.role_name)::VARCHAR[],
           u.must_change_password
    FROM pgerp.users u
    WHERE u.login = lower(trim(p_login)) AND u.is_active;
$$ LANGUAGE sql STABLE;

-- ---------------------------------------------------------------------
-- Вход
-- ---------------------------------------------------------------------
CREATE TABLE pgerp.auth_failures (
    id        BIGSERIAL PRIMARY KEY,
    login     TEXT NOT NULL,
    bucket    TEXT NOT NULL,
    failed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX auth_failures_login_idx ON pgerp.auth_failures (login, failed_at);
CREATE INDEX auth_failures_failed_at_idx ON pgerp.auth_failures (failed_at);
COMMENT ON TABLE pgerp.auth_failures IS 'Failed sign-in attempts of the last minutes, for existing and unknown logins alike';

CREATE TABLE pgerp.auth_devices (
    token_hash TEXT PRIMARY KEY,
    user_id    BIGINT NOT NULL REFERENCES pgerp.users(id) ON DELETE CASCADE,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX auth_devices_user_id_idx ON pgerp.auth_devices (user_id);
COMMENT ON TABLE pgerp.auth_devices IS 'Browsers that signed in successfully: they have their own failed attempt counter';

-- Известный браузер: вызывает шлюз после удачного входа. Токен каждый раз новый, прежний удаляется
CREATE FUNCTION pgerp.auth_device_remember(p_login VARCHAR, p_token TEXT, p_previous TEXT)
RETURNS VOID AS $$
BEGIN
    DELETE FROM pgerp.auth_devices d
    USING pgerp.users u
    WHERE u.id = d.user_id AND u.login = p_login
      AND d.token_hash = encode(sha256(convert_to(p_previous, 'UTF8')), 'hex');
    DELETE FROM pgerp.auth_devices WHERE expires_at <= now();
    INSERT INTO pgerp.auth_devices (token_hash, user_id, expires_at)
    SELECT encode(sha256(convert_to(p_token, 'UTF8')), 'hex'), u.id, now() + INTERVAL '180 days'
    FROM pgerp.users u
    WHERE u.login = p_login;
END;
$$ LANGUAGE plpgsql;

DROP FUNCTION pgerp.auth_login(VARCHAR, TEXT, VARCHAR);

-- Вход. Ошибка — в error_message, иначе логин и роли. До проверки пароля ответ не зависит от того, есть ли
-- логин: ни текстом, ни языком (только язык запроса), ни блокировкой.
CREATE FUNCTION pgerp.auth_login(p_login VARCHAR, p_password TEXT, p_lang VARCHAR DEFAULT NULL,
                                 p_address TEXT DEFAULT NULL, p_device TEXT DEFAULT NULL)
RETURNS TABLE (user_login VARCHAR, user_roles VARCHAR[], error_message TEXT) AS $$
DECLARE
    c_attempts     CONSTANT INT      := 5;
    c_attempts_all CONSTANT INT      := 50;
    c_window       CONSTANT INTERVAL := '5 minutes';
    v_login  TEXT := left(lower(trim(COALESCE(p_login, ''))), 100);
    v_user   pgerp.users%ROWTYPE;
    v_known  BOOLEAN;
    v_bucket TEXT;
    v_ok     BOOLEAN;
BEGIN
    PERFORM set_config('pgerp.lang', COALESCE(pgerp.i18n_resolve(p_lang), ''), TRUE);

    v_known := EXISTS (SELECT 1
                       FROM pgerp.auth_devices d
                       JOIN pgerp.users u ON u.id = d.user_id
                       WHERE u.login = v_login AND d.expires_at > now()
                         AND d.token_hash = encode(sha256(convert_to(p_device, 'UTF8')), 'hex'));
    v_bucket := CASE WHEN v_known THEN 'device:' || encode(sha256(convert_to(p_device, 'UTF8')), 'hex')
                     ELSE 'address:' || left(COALESCE(p_address, ''), 100) END;

    -- Параллельные попытки одного источника идут по очереди, иначе они обходят счётчик
    PERFORM pg_advisory_xact_lock(hashtextextended(v_login || chr(10) || v_bucket, 0));
    DELETE FROM pgerp.auth_failures f
    WHERE f.id IN (SELECT o.id FROM pgerp.auth_failures o
                   WHERE o.failed_at <= now() - c_window
                   FOR UPDATE SKIP LOCKED);

    IF (SELECT count(*) FROM pgerp.auth_failures f
        WHERE f.login = v_login AND f.bucket = v_bucket AND f.failed_at > now() - c_window) >= c_attempts
       OR (NOT v_known AND
           (SELECT count(*) FROM pgerp.auth_failures f
            WHERE f.login = v_login AND f.bucket LIKE 'address:%' AND f.failed_at > now() - c_window) >= c_attempts_all)
    THEN
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[], pgerp.ui_t(
            format('Too many failed sign-in attempts. Try again in %s min.', 5));
        RETURN;
    END IF;

    SELECT * INTO v_user FROM pgerp.users u WHERE u.login = v_login;
    IF FOUND THEN
        v_ok := pgerp.auth_password_ok(p_password, v_user.password_hash);
    ELSE
        -- Время ответа как у существующего логина
        PERFORM pgerp.auth_hash(COALESCE(p_password, ''));
        v_ok := FALSE;
    END IF;

    IF v_ok IS NOT TRUE THEN
        INSERT INTO pgerp.auth_failures (login, bucket) VALUES (v_login, v_bucket);
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[], pgerp.ui_t('Invalid login or password');
        RETURN;
    END IF;

    -- Пароль верен: дальше язык и состояние пользователя уже не секрет
    IF v_user.lang IS NOT NULL THEN
        PERFORM set_config('pgerp.lang', v_user.lang, TRUE);
    END IF;
    IF NOT v_user.is_active THEN
        RETURN QUERY SELECT NULL::VARCHAR, NULL::VARCHAR[],
            pgerp.ui_t('The account is disabled — contact the administrator');
        RETURN;
    END IF;

    DELETE FROM pgerp.auth_failures f WHERE f.login = v_login AND f.bucket = v_bucket;
    UPDATE pgerp.users u SET last_login_at = now() WHERE u.id = v_user.id;

    RETURN QUERY
    SELECT v_user.login,
           ARRAY(SELECT r.role_name FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
                 WHERE ur.user_id = v_user.id ORDER BY r.role_name)::VARCHAR[],
           NULL::TEXT;
END;
$$ LANGUAGE plpgsql;

-- Сохранение карточки пользователя снимает блокировку: user_save записывает locked_until
CREATE FUNCTION pgerp.auth_failures_clear()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM pgerp.auth_failures WHERE login = NEW.login;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_failures_clear AFTER UPDATE OF locked_until ON pgerp.users
    FOR EACH ROW EXECUTE FUNCTION pgerp.auth_failures_clear();

CREATE OR REPLACE VIEW pgerp.users_v AS
SELECT u.id, u.login, u.full_name,
       (SELECT string_agg(pgerp.ui_t_exact(r.title), ', ' ORDER BY r.title)
        FROM pgerp.user_roles ur JOIN pgerp.roles r ON r.id = ur.role_id
        WHERE ur.user_id = u.id) AS roles,
       pgerp.ui_t_exact(CASE WHEN NOT u.is_active          THEN 'Disabled'
                             WHEN EXISTS (SELECT 1 FROM pgerp.auth_failures f
                                          WHERE f.login = u.login AND f.failed_at > now() - INTERVAL '5 minutes'
                                          GROUP BY f.bucket HAVING count(*) >= 5) THEN 'Sign-in locked'
                             WHEN u.must_change_password   THEN 'Must change password'
                             ELSE 'Active' END) AS status,
       to_char(u.last_login_at, 'DD.MM.YYYY HH24:MI') AS last_login,
       u.last_login_at
FROM pgerp.users u;
