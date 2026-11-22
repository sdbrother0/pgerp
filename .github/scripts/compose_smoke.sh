#!/bin/sh
# compose целиком: том, созданный 0.2.2 (приложение — postgres), обновляется текущим compose.yaml и образом из
# исходников. Свой проект, порт и том; в конце всё это удаляется. Нужны docker и curl.
set -eu

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
PROJECT="pgerp-smoke-$$"
export ERP_PORT=18199 ERP_BIND=127.0.0.1 ERP_DB_PASSWORD=smoke-db-password
URL="http://127.0.0.1:$ERP_PORT"

new() { ERP_VERSION=smoke-local docker compose -p "$PROJECT" -f "$ROOT/compose.yaml" "$@"; }
cleanup() {
	code=$?
	[ "$code" = 0 ] || new logs --tail 60 || true
	new down -v --remove-orphans >/dev/null 2>&1 || true
	rm -rf "$TMP"
	exit "$code"
}
trap cleanup EXIT

wait_app() {
	i=0
	until curl -fsS -o /dev/null "$URL/login.html" 2>/dev/null; do
		i=$((i + 1))
		[ "$i" -lt 90 ] || { echo "FAIL application did not start"; exit 1; }
		sleep 2
	done
}

# psql суперпользователем — только через сокет
su_sql() { new exec -T db psql -X -U postgres -d erp -Atc "$1"; }

login() {
	rm -f "$TMP/cookies"
	curl -fsS -o /dev/null -c "$TMP/cookies" "$URL/login.html"
	token=$(awk '$6 == "XSRF-TOKEN" {print $7}' "$TMP/cookies")
	curl -fsS -o /dev/null -b "$TMP/cookies" -c "$TMP/cookies" -H "X-XSRF-TOKEN: $token" \
		-d 'username=admin&password=admin' "$URL/api/auth/login"
}

curl -fsS -o "$TMP/compose.yaml" https://raw.githubusercontent.com/sdbrother0/pgerp/v0.2.2/compose.yaml
ERP_VERSION=0.2.2 docker compose -p "$PROJECT" -f "$TMP/compose.yaml" up -d --no-build
wait_app
login
su_sql "CREATE TABLE public.kept AS SELECT 7 AS n"
echo "ok   0.2.2 is running"

new build app
new up -d --no-build
wait_app
login
echo "ok   sign-in after the upgrade"

[ "$(su_sql "SELECT n FROM public.kept")" = 7 ] || { echo "FAIL data lost"; exit 1; }
[ "$(su_sql "SELECT rolsuper FROM pg_roles WHERE rolname = 'pgerp'")" = f ] || { echo "FAIL pgerp is a superuser"; exit 1; }
[ "$(su_sql "SELECT count(*) FROM pg_stat_activity WHERE client_addr IS NOT NULL AND usename <> 'pgerp'")" = 0 ] ||
	{ echo "FAIL application is connected not as pgerp"; exit 1; }
[ "$(su_sql "SELECT rolpassword IS NULL FROM pg_authid WHERE rolname = 'postgres'")" = t ] ||
	{ echo "FAIL postgres still has a password"; exit 1; }
echo "ok   application role, data, no postgres password"

new down
new up -d --no-build
wait_app
login
echo "ok   restart"
echo "compose smoke test passed"
