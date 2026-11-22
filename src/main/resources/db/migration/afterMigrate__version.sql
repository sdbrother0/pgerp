-- Версия PgERP в базе: SELECT pgerp.pgerp_version();
-- Не миграция, а обратный вызов Flyway: выполняется при каждом запуске, иначе каждой версии нужна была бы своя миграция.
-- Номер — из pom.xml (spring.flyway.placeholders.version). Имя не version(): его перекрыла бы функция PostgreSQL.
CREATE OR REPLACE FUNCTION pgerp.pgerp_version()
RETURNS TEXT AS $$
    SELECT '${version}'::TEXT;
$$ LANGUAGE sql IMMUTABLE;

COMMENT ON FUNCTION pgerp.pgerp_version() IS 'PgERP version of the application that last started on this database';
