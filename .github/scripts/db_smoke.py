#!/usr/bin/env python3
"""Проверка собранного jar на настоящем PostgreSQL.

Чистая установка и обновление с опубликованной 0.2.1 через HTTP, как из браузера. Работает во временных базах,
которые сама создаёт и удаляет. Нужны java, psql и PostgreSQL на ERP_SMOKE_HOST (localhost:5432, postgres/postgres).

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
USER = os.environ.get("ERP_DB_USER", "postgres")
PASSWORD = os.environ.get("ERP_DB_PASSWORD", "postgres")
NEW_PASSWORD = "smoke-password-1"


def check(ok, what, detail=""):
    if not ok:
        raise SystemExit(f"FAIL {what}: {detail}")
    print(f"ok   {what}", flush=True)


def psql(database, sql):
    return subprocess.run(
        ["psql", "-X", "-h", HOST, "-U", USER, "-d", database, "-v", "ON_ERROR_STOP=1", "-Atc", sql],
        env={**os.environ, "PGPASSWORD": PASSWORD}, check=True, capture_output=True, text=True).stdout.strip()


@contextlib.contextmanager
def temporary_database():
    name = "pgerp_smoke_" + uuid.uuid4().hex[:12]
    psql("postgres", f"CREATE DATABASE {name}")
    try:
        yield name
    finally:
        psql("postgres", f"DROP DATABASE {name} WITH (FORCE)")


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

    def action(self, name, body=None):
        return self.request(f"api/ui/event?action={name}", body or {})

    def change_password(self):
        return self.action("password_change", {"old_password": "admin", "new_password": NEW_PASSWORD,
                                              "new_password_repeat": NEW_PASSWORD})

    def install(self, name, schema=None, reset=False):
        return self.request("api/dev/solutions/install", {"name": name, "schema": schema, "reset": reset})


@contextlib.contextmanager
def application(jar, database):
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    env = {**os.environ, "ERP_DB_URL": f"jdbc:postgresql://{HOST}:5432/{database}", "ERP_DB_USER": USER,
           "ERP_DB_PASSWORD": PASSWORD, "SERVER_PORT": str(port), "SERVER_ADDRESS": "127.0.0.1"}
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
    with temporary_database() as db, application(jar, db) as app:
        check(app.request("api/version")[0] == 401, "version is hidden before sign-in")
        result = app.login("admin")
        check(result[0] == 200, "admin signs in", result)
        result = app.request("api/version")
        check(result == (200, {"version": version}), "version is shown", result)

        psql(db, "CREATE SCHEMA victim; CREATE TABLE victim.data AS SELECT 42 AS n")
        for reset in (False, True):
            result = app.install("examples", "victim", reset)
            check(result[0] == 403, f"installation needs a password change (reset={reset})", result)
        result = app.change_password()
        check(result[0] == 200, "password changed", result)

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

        psql(db, "CREATE SCHEMA empty_one")
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


def upgrade(old_jar, jar, version):
    print("## upgrade from 0.2.1", flush=True)
    with temporary_database() as db:
        with application(old_jar, db) as app:
            check(app.login("admin")[0] == 200, "0.2.1: admin signs in")
            check(app.change_password()[0] == 200, "0.2.1: password changed")
            result = app.install("crm")
            check(result[0] == 200, "0.2.1: CRM installed", result)
            psql(db, "CREATE TABLE crm.user_data AS SELECT 7 AS n")
        with application(jar, db) as app:
            check(psql(db, "SELECT success FROM flyway_schema_history WHERE version = '2'") == "t", "migration V2 applied")
            check(app.login(NEW_PASSWORD)[0] == 200, "password survives the upgrade")
            result = app.request("api/version")
            check(result == (200, {"version": version}), "version is shown after the upgrade", result)
            result = app.action("menu_get")
            check(result[0] == 200 and result[1]["items"], "menu works", result)
            check(psql(db, "SELECT n FROM crm.user_data") == "7", "data survives the upgrade")
            result = app.install("examples")
            check(result[0] == 200, "another solution installs after the upgrade", result)
        with application(jar, db) as app:
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
