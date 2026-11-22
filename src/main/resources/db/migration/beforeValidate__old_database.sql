-- До 0.4.0 ядро состояло из других миграций. Обновления с них нет, а совет Flyway (repair) испортил бы такую базу:
-- останавливаемся с понятным сообщением. Базу не меняем.
DO $$
BEGIN
    IF to_regclass('pgerp.ui_actions') IS NOT NULL AND to_regclass('pgerp.core_objects') IS NULL THEN
        RAISE EXCEPTION 'This database was created by PgERP before 0.4.0 and cannot be upgraded: install into an empty database. The database was not changed. Do not run flyway repair';
    END IF;
END;
$$;
