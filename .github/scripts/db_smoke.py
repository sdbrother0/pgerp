#!/usr/bin/env python3
"""Проверка собранного jar на настоящем PostgreSQL.

Чистая установка и обновление с опубликованной 0.2.1 через HTTP, как из браузера. Работает во временных базах,
которые сама создаёт и удаляет; приложение — под ролью без прав суперпользователя, созданной скриптом db-init
из compose.yaml. Нужны java, psql, docker compose и PostgreSQL на ERP_SMOKE_HOST:ERP_SMOKE_PORT (localhost:5432, postgres/postgres).

    python3 .github/scripts/db_smoke.py target/pgerp-<версия>.jar
"""
import contextlib
import hashlib
import http.cookiejar
import json
import os
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

BASELINE_URL = "https://github.com/sdbrother0/pgerp/releases/download/v0.2.1/pgerp-0.2.1.jar"
BASELINE_SHA256 = "f6130016605cc6518ec5d2069a8b4195032251a51ed80739a9db8fa12473279a"
HOST = os.environ.get("ERP_SMOKE_HOST", "localhost")
PORT = os.environ.get("ERP_SMOKE_PORT", "5432")
USER = os.environ.get("ERP_DB_USER", "postgres")
PASSWORD = os.environ.get("ERP_DB_PASSWORD", "postgres")
NEW_PASSWORD = "smoke-password-1"


def check(ok, what, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {what}: {detail}")
    print(f"ok   {what}", flush=True)


def psql(database, sql, user=USER, password=PASSWORD):
    result = subprocess.run(
        ["psql", "-X", "-q", "-h", HOST, "-p", PORT, "-U", user, "-d", database, "-v", "ON_ERROR_STOP=1", "-Atc", sql],
        env={**os.environ, "PGPASSWORD": password}, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(f"FAIL psql: {sql}\n{result.stderr}")
    return result.stdout.strip()


def provision(database, role):
    """Роль приложения — тем же SQL, что db-init в compose, кроме строк compose-only (пароль postgres нужен тесту)."""
    compose = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "compose.yaml")
    config = json.loads(subprocess.run(["docker", "compose", "-f", compose, "config", "--format", "json"],
                                       check=True, capture_output=True, text=True).stdout)
    service = config["services"]["db-init"]
    lines = service["command"][0].replace("$$", "$").strip().splitlines()
    script = "\n".join(line for line in lines[1:-1] if "compose-only" not in line) + "\n"
    result = subprocess.run(
        ["psql", "-X", "-q", "-h", HOST, "-p", PORT, "-U", USER, "-d", database, "-v", "ON_ERROR_STOP=1"], input=script,
        env={**os.environ, "PGPASSWORD": PASSWORD, "APP_ROLE": role, "APP_PASSWORD": role,
             "PGOPTIONS": service["environment"]["PGOPTIONS"]}, capture_output=True, text=True)
    check(result.returncode == 0, "db-init script", result.stderr)


@contextlib.contextmanager
def temporary_database():
    name = "pgerp_smoke_" + uuid.uuid4().hex[:12]
    psql("postgres", f"CREATE DATABASE {name}")
    try:
        yield name
    finally:
        # Имя роли то же, что у базы: настоящую роль pgerp тест не трогает
        psql("postgres", f"DROP DATABASE {name} WITH (FORCE)")
        psql("postgres", f"DROP ROLE IF EXISTS {name}")


class Client:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}/"
        self.cookies = http.cookiejar.CookieJar()
        self.http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cookies))

    def request(self, path, body=None, form=False, token=None):
        headers, data = {}, None
        if body is not None:
            data = (urllib.parse.urlencode(body) if form else json.dumps(body)).encode()
            headers["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
            headers.update({"X-XSRF-TOKEN": c.value for c in self.cookies if c.name == "XSRF-TOKEN"})
        if token:
            headers["Authorization"] = f"Bearer {token}"
        try:
            with self.http.open(urllib.request.Request(self.base + path, data, headers), timeout=180) as response:
                status, text = response.status, response.read().decode()
        except urllib.error.HTTPError as error:
            status, text = error.code, error.read().decode()
        try:
            return status, json.loads(text)
        except ValueError:
            return status, text

    def login(self, password):
        self.request("login.html")
        result = self.request("api/auth/login", {"username": "admin", "password": password}, form=True)
        # После входа токен CSRF меняется: новый приходит со следующим ответом
        self.request("login.html")
        return result

    def other(self):
        """Другой браузер: без cookie этого."""
        return Client(int(self.base.rstrip("/").rsplit(":", 1)[1]))

    def action(self, name, body=None):
        return self.request(f"api/ui/event?action={name}", body or {})

    def change_password(self):
        return self.action("password_change", {"old_password": "admin", "new_password": NEW_PASSWORD,
                                              "new_password_repeat": NEW_PASSWORD})

    def install(self, name, schema=None, reset=False):
        return self.request("api/dev/solutions/install", {"name": name, "schema": schema, "reset": reset})


@contextlib.contextmanager
def application(jar, database, role=None):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {**os.environ, "ERP_DB_URL": f"jdbc:postgresql://{HOST}:{PORT}/{database}", "ERP_DB_USER": role or USER,
           "ERP_DB_PASSWORD": role or PASSWORD, "SERVER_PORT": str(port), "SERVER_ADDRESS": "127.0.0.1"}
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen(["java", "-jar", jar], env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            deadline = time.time() + 120
            while True:
                try:
                    if Client(port).request("login.html")[0] == 200:
                        break
                except OSError:
                    pass  # ещё не слушает порт
                if process.poll() is not None or time.time() > deadline:
                    log.seek(0)
                    raise SystemExit("FAIL application did not start:\n" + log.read().decode()[-8000:])
                time.sleep(1)
            yield Client(port)
        finally:
            process.terminate()
            try:
                process.wait(60)
            except subprocess.TimeoutExpired:
                process.kill()


def baseline(folder):
    path = os.path.join(folder, "baseline.jar")
    urllib.request.urlretrieve(BASELINE_URL, path)
    with open(path, "rb") as file:
        check(hashlib.sha256(file.read()).hexdigest() == BASELINE_SHA256, "baseline 0.2.1 checksum")
    return path


def fresh_install(jar, version):
    print("## fresh installation", flush=True)
    with temporary_database() as db:
        provision(db, db)
        with application(jar, db, db) as app:
            fresh_checks(app, db, version)


def fresh_checks(app, db, version):
    check(app.request("api/version")[0] == 401, "version is hidden before sign-in")
    result = app.login("admin")
    check(result[0] == 200, "admin signs in", result)
    result = app.request("api/version")
    check(result == (200, {"version": version}), "version is shown", result)

    psql(db, "CREATE SCHEMA victim; CREATE TABLE victim.data AS SELECT 42 AS n")
    result = app.request("api/dev/solutions")
    check(result[0] == 403, "admin API needs a password change", result)
    second = app.other()
    check(second.login("admin")[0] == 200, "second session signs in")
    for reset in (False, True):
        result = app.install("examples", "victim", reset)
        check(result[0] == 403, f"installation needs a password change (reset={reset})", result)
    result = app.change_password()
    check(result[0] == 200, "password changed", result)
    check(app.action("session_get")[0] == 200, "session that changed the password stays")
    check(second.action("session_get")[0] == 401, "second session is closed by the password change")

    result = app.install("examples", "victim", True)
    check(result[0] == 422 and "is not empty" in str(result[1]), "foreign schema is not dropped", result)
    result = app.install("examples", " VICTIM ", True)
    check(result[0] == 422, "schema name case and spaces do not bypass the check", result)
    check(psql(db, "SELECT n FROM victim.data") == "42", "foreign data is intact")

    psql(db, "CREATE SCHEMA only_function; CREATE FUNCTION only_function.f() RETURNS int LANGUAGE sql AS 'SELECT 1'")
    result = app.install("examples", "only_function", True)
    check(result[0] == 422, "schema with only a function is not empty", result)
    for schema in ("pgerp", "information_schema", "pg_catalog"):
        result = app.install("examples", schema, True)
        check(result[0] == 422, f"system schema {schema} is protected", result)

    psql(db, "UPDATE pgerp.users SET lang = 'ru' WHERE login = 'admin'")
    result = app.install("examples", "victim", True)
    check("не пуста" in str(result[1]), "error is translated", result)
    psql(db, "UPDATE pgerp.users SET lang = 'en' WHERE login = 'admin'")

    psql(db, f"CREATE SCHEMA empty_one AUTHORIZATION {db}")
    result = app.install("examples", "empty_one", True)
    check(result[0] == 200, "clean installation into an empty schema", result)
    result = app.install("crm", "crm", True)
    check(result[0] == 200, "clean installation into a missing schema", result)
    psql(db, "CREATE TABLE crm.marker (n int)")
    result = app.install("crm", "victim", True)
    check(result[0] == 200, "installed solution is reinstalled", result)
    check(psql(db, "SELECT to_regclass('crm.marker') IS NULL") == "t", "reinstall drops its own schema")
    check(psql(db, "SELECT n FROM victim.data") == "42", "reinstall leaves other schemas alone")

    status, body = app.action("mcp_token_create", {"title": "smoke"})
    check(status == 200 and body.get("token"), "MCP token issued", body)
    psql(db, "UPDATE pgerp.users SET must_change_password = TRUE WHERE login = 'admin'")
    result = app.request("mcp", {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                                 "params": {"name": "solution_install", "arguments": {"name": "crm"}}},
                         token=body["token"])
    check(result[0] == 200 and result[1]["result"]["isError"] and "password" in str(result[1]).lower(),
          "MCP installation needs a password change", result)

    security_checks(app, db)


def security_checks(app, db):
    print("## sessions, MCP, sign-in", flush=True)
    psql(db, "UPDATE pgerp.users SET must_change_password = FALSE WHERE login = 'admin'")

    psql(db, """INSERT INTO pgerp.users (login, password_hash, must_change_password)
                VALUES ('helper', pgerp.auth_hash('helper-password'), FALSE);
                INSERT INTO pgerp.user_roles (user_id, role_id)
                SELECT u.id, r.id FROM pgerp.users u, pgerp.roles r WHERE u.login = 'helper' AND r.role_name = 'admin'""")
    helper = app.other()
    helper.request("login.html")
    result = helper.request("api/auth/login", {"username": "helper", "password": "helper-password"}, form=True)
    helper.request("login.html")
    check(result[0] == 200, "second administrator signs in", result)
    check(helper.request("api/dev/settings")[0] == 200, "administrator uses the admin API")
    status, body = helper.action("mcp_token_create", {"title": "helper", "login": "helper"})
    check(status == 200, "helper token issued", body)
    token = body["token"]
    ping = {"jsonrpc": "2.0", "id": 1, "method": "ping"}
    check(helper.request("mcp", [ping, {**ping, "id": 2}], token=token)[0] == 200, "MCP batch works")
    installed = psql(db, "SELECT count(*) FROM pgerp.solutions")
    result = helper.request("mcp", {"jsonrpc": "2.0", "method": "tools/call",
                                    "params": {"name": "solution_install", "arguments": {"name": "sample"}}}, token=token)
    check(result[0] == 202 and psql(db, "SELECT count(*) FROM pgerp.solutions") == installed,
          "MCP notification installs nothing", result)
    psql(db, "DELETE FROM pgerp.user_roles ur USING pgerp.users u WHERE u.id = ur.user_id AND u.login = 'helper'")
    check(helper.request("api/dev/settings")[0] == 403, "removed role stops working at once")
    psql(db, "UPDATE pgerp.users SET password_hash = pgerp.auth_hash('reset-password') WHERE login = 'helper'")
    check(helper.action("session_get")[0] == 401, "password reset closes sessions")
    check(app.request("mcp", ping, token=token)[0] == 401, "password reset revokes MCP tokens")

    psql(db, "UPDATE pgerp.users SET lang = 'ru' WHERE login = 'admin'")
    stranger = app.other()
    stranger.request("login.html")
    answers = {}
    for login in ("admin", "no-such-user"):
        answers[login] = [stranger.request("api/auth/login", {"username": login, "password": "wrong"}, form=True)
                          for _ in range(7)]
    check(answers["admin"] == answers["no-such-user"], "same answers for existing and unknown logins", answers)
    check("Too many" in str(answers["admin"][5]), "guessing is limited", answers["admin"])
    check(app.other().login(NEW_PASSWORD)[0] == 401, "limited source cannot continue guessing")
    check(app.login(NEW_PASSWORD)[0] == 200, "known browser is not locked out by a stranger")
    check("locked" in psql(db, "SELECT status FROM pgerp.users_v WHERE login = 'admin'"), "lock is visible to administrators")
    psql(db, "UPDATE pgerp.users SET locked_until = NULL WHERE login = 'admin'")
    check(app.other().login(NEW_PASSWORD)[0] == 200, "saving the user card unlocks sign-in")

    check(psql(db, "SELECT rolsuper OR rolcreaterole OR rolcreatedb OR rolbypassrls FROM pg_roles WHERE rolname = current_user",
               db, db) == "f", "application role is not privileged")
    check(psql(db, "SELECT pg_has_role('pg_execute_server_program', 'member')", db, db) == "f",
          "application role cannot run server programs")


def upgrade(old_jar, jar, version):
    print("## upgrade from 0.2.1", flush=True)
    with temporary_database() as db:
        with application(old_jar, db) as app:
            check(app.login("admin")[0] == 200, "0.2.1: admin signs in")
            check(app.change_password()[0] == 200, "0.2.1: password changed")
            result = app.install("crm")
            check(result[0] == 200, "0.2.1: CRM installed", result)
            psql(db, "CREATE TABLE crm.user_data AS SELECT 7 AS n")
            psql(db, """CREATE TYPE crm.state AS ENUM ('a', 'b');
                        CREATE DOMAIN crm.positive AS int CHECK (VALUE > 0);
                        CREATE TYPE crm.pair AS (a int, b int);
                        CREATE TYPE crm.span AS RANGE (subtype = int8);
                        CREATE SEQUENCE crm.free_seq;
                        CREATE TABLE crm.numbered (id int GENERATED ALWAYS AS IDENTITY, n serial);
                        CREATE TABLE crm.parts (id int) PARTITION BY RANGE (id);
                        CREATE TABLE crm.parts_1 PARTITION OF crm.parts FOR VALUES FROM (0) TO (10);
                        CREATE MATERIALIZED VIEW crm.totals AS SELECT 1 AS n;
                        CREATE PROCEDURE crm.noop() LANGUAGE sql AS 'SELECT 1';
                        CREATE AGGREGATE crm.total(int) (SFUNC = int4pl, STYPE = int);
                        CREATE FUNCTION crm.on_ddl() RETURNS event_trigger LANGUAGE plpgsql AS 'BEGIN END';
                        CREATE EVENT TRIGGER smoke_ddl ON ddl_command_end EXECUTE FUNCTION crm.on_ddl()""")
        provision(db, db)
        provision(db, db)
        check(psql(db, "SELECT evtenabled FROM pg_event_trigger WHERE evtname = 'smoke_ddl'") == "D",
              "event triggers of the superuser are disabled")
        left = psql(db, """SELECT string_agg(x, ', ') FROM (
            SELECT c.oid::regclass::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname IN ('public', 'pgerp', 'crm') AND c.relowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
            UNION ALL
            SELECT p.oid::regprocedure::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname IN ('public', 'pgerp', 'crm') AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
            UNION ALL
            SELECT t.oid::regtype::text FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname IN ('public', 'pgerp', 'crm') AND t.typowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
              AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = t.oid AND d.deptype = 'e')
            ) o(x)""")
        check(left == "", "everything is owned by the application role", left)
        with application(jar, db, db) as app:
            for number in ("2", "3"):
                check(psql(db, f"SELECT success FROM flyway_schema_history WHERE version = '{number}'") == "t",
                      f"migration V{number} applied")
            check(app.login(NEW_PASSWORD)[0] == 200, "password survives the upgrade")
            result = app.request("api/version")
            check(result == (200, {"version": version}), "version is shown after the upgrade", result)
            result = app.action("menu_get")
            check(result[0] == 200 and result[1]["items"], "menu works", result)
            check(psql(db, "SELECT n FROM crm.user_data") == "7", "data survives the upgrade")
            result = app.install("examples")
            check(result[0] == 200, "another solution installs after the upgrade", result)
            result = app.install("crm", None, True)
            check(result[0] == 200, "solution of an old installation is reinstalled by the new role", result)
        with application(jar, db, db) as app:
            check(app.login(NEW_PASSWORD)[0] == 200, "restart on the migrated database")


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    jar = os.path.abspath(sys.argv[1])
    version = re.fullmatch(r"pgerp-(.+)\.jar", os.path.basename(jar)).group(1)
    with tempfile.TemporaryDirectory() as folder:
        old_jar = baseline(folder)
        fresh_install(jar, version)
        upgrade(old_jar, jar, version)
    print("database smoke test passed")


if __name__ == "__main__":
    main()
