# Документация Cloud Suite

Единая точка входа в документацию: что читать в зависимости от роли и что
содержит каждый документ. Все документы на русском языке, ссылки относительные.

## С чего начать

| Роль | Порядок чтения |
|---|---|
| Администратор, который ставит систему | [02-deployment.md](02-deployment.md) |
| Администратор, который её эксплуатирует | [09-operations-runbook.md](09-operations-runbook.md), [07-backup-restore-dr.md](07-backup-restore-dr.md), [11-troubleshooting.md](11-troubleshooting.md) |
| Архитектор / ИТ-руководитель | [01-architecture.md](01-architecture.md), [03-security-hardening.md](03-security-hardening.md) |
| ИБ и аудитор | [03-security-hardening.md](03-security-hardening.md), [05-audit-logging.md](05-audit-logging.md) |
| Владелец данных, руководитель отдела | [04-rbac-and-sharing.md](04-rbac-and-sharing.md) |
| Сотрудник | [10-user-guide.md](10-user-guide.md) |
| Принимающая сторона | [12-acceptance-checklist.md](12-acceptance-checklist.md) |
| Тот, кто переносит данные | [08-migration-from-yandex-disk.md](08-migration-from-yandex-disk.md) |
| Тот, кто хочет посмотреть систему локально | [13-local-run.md](13-local-run.md) |

Краткий обзор и быстрый старт — в корневом [README.md](../README.md).

## Состав

| Документ | Содержание |
|---|---|
| [01-architecture.md](01-architecture.md) | компоненты, потоки данных, сети, тома, отказоустойчивость, ресурсы |
| [02-deployment.md](02-deployment.md) | установка на чистый сервер, NPM, Let's Encrypt, ONLYOFFICE, первые пользователи |
| [03-security-hardening.md](03-security-hardening.md) | модель угроз, TLS, заголовки, хардненинг контейнеров, секреты и их ротация |
| [04-rbac-and-sharing.md](04-rbac-and-sharing.md) | роли и квоты, матрица прав, общие папки, публичные ссылки |
| [05-audit-logging.md](05-audit-logging.md) | что и куда пишется, форматы, jq-рецепты, ротация, SIEM, 152-ФЗ/GDPR |
| [06-versioning-and-retention.md](06-versioning-and-retention.md) | версии файлов, прунер, корзина, расчёт ёмкости, конфликты |
| [07-backup-restore-dr.md](07-backup-restore-dr.md) | стратегия 3-2-1, бэкап, offsite, восстановление, DR-drill |
| [08-migration-from-yandex-disk.md](08-migration-from-yandex-disk.md) | перенос данных из Яндекс.Диска через rclone |
| [09-operations-runbook.md](09-operations-runbook.md) | регламенты день/неделя/месяц, cron, инцидент-плейбуки, обновление |
| [10-user-guide.md](10-user-guide.md) | инструкция для сотрудников: вход, файлы, шаринг, офис, восстановление |
| [11-troubleshooting.md](11-troubleshooting.md) | диагностика: логи, типовые ошибки, конфликты подсетей, ONLYOFFICE |
| [12-acceptance-checklist.md](12-acceptance-checklist.md) | чек-лист приёмки и протокол, включая результаты живого прогона |
| [13-local-run.md](13-local-run.md) | локальный запуск без домена и TLS: web-GUI на `cloud.local`, редактор, диагностика |
| [14-ip-run.md](14-ip-run.md) | запуск на белом IP без домена и хостинга: `http://PUBLIC_IP/`, маршрут callback'ов, TLS-ограничения |

Дополнительно:

* [CONTRACT.md](../CONTRACT.md) — внутренний контракт: имена сервисов, порты, сети,
  тома и критерии приёмки;
* [LICENSES.md](../LICENSES.md) — лицензии всех образов, отсутствие платных
  редакций и лицензионных ключей;
* [config/proxy/npm-gui-setup.md](../config/proxy/npm-gui-setup.md) — пошаговая
  настройка Nginx Proxy Manager;
* [config/nginx/README.md](../config/nginx/README.md) — заметки по edge-nginx;
* [config/onlyoffice/README.md](../config/onlyoffice/README.md) — как настраивается
  Document Server (переменные окружения, без local.json в репозитории);
* [CHANGELOG.md](../CHANGELOG.md) — история версий.

## Соглашения

* домены в примерах: `cloud.example.com` и `office.example.com`;
* часовой пояс примеров — `Asia/Novosibirsk`, в audit-логе время в UTC;
* роли: `admins`, `management`, `employees`, `contractors`, `auditors`;
* квоты: 500 / 100 / 20 / 5 ГБ, по умолчанию 10 ГБ;
* команды выполняются из каталога `/opt/cloudsuite` (корень репозитория).

## Проверка документации

`make test` запускает `tests/validate.py`: он проверяет наличие документов,
разрешение относительных ссылок, корректность `.env.example`, compose-файлов и
nginx-конфигурации. Битые ссылки и отсутствующие файлы — ошибка сборки.
