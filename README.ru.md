[English](README.md) · **Русский**

# PgERP

Платформа Data-Driven UI в архитектуре SmartDB: бизнес-логика и описание интерфейса живут в PostgreSQL. Java-сервер —
тонкий шлюз, браузер — универсальный отрисовщик форм, который выполняет инструкции базы данных. Формы, меню, права
и обработчики создаются во встроенном редакторе (или ИИ-агентом через MCP) и выпускаются пакетами решений — без
изменения Java.

![Список дел, сделанный в редакторе](docs/img/todo/ru/15-app-list.png)

**Стек:** Java 25 · Spring Boot 4 · PostgreSQL 18 / PL/pgSQL · Flyway · WebSocket · JasperReports · HTML + ES modules

## Быстрый старт

В Docker — приложение и PostgreSQL 18:

```bash
docker compose up -d --build
```

Откройте http://localhost:8080 и войдите как **admin / admin** (при первом входе пароль нужно сменить). Затем
администратор выбирает решения для установки: в комплекте CRM и примеры.

Без Docker — PostgreSQL с базой `erp` и Java 25:

```bash
psql -h localhost -U postgres -c "create database erp"
ERP_DB_PASSWORD=<пароль> ./mvnw spring-boot:run
```

Настройки (адрес базы, порт, путь за обратным прокси, MCP) — переменные окружения, см.
[Развёртывание](ARCHITECTURE.ru.md#развёртывание).

## Документация

- [ARCHITECTURE.ru.md](ARCHITECTURE.ru.md) — ядро платформы: слои, контракт базы и браузера, разработка решений,
  MCP-сервер, вход и права, переводы, темы, миграции и пакеты решений, развёртывание
- [docs/tutorial-todo.ru.md](docs/tutorial-todo.ru.md) — по шагам: приложение «Список дел» с нуля в редакторе

## Лицензия

Copyright 2026 S. Demin. Распространяется по лицензии [Apache License 2.0](LICENSE).
