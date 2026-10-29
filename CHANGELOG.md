# Changelog

Формат: [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
версионирование — [Semantic Versioning](https://semver.org/lang/ru/).
Проект внутренний; нумерация отражает этапы внедрения.

## [1.2.0] — 2026-10-28

Запуск на «белом» IP без домена и хостинга.

### Добавлено

* **Режим белого IP:** `docker-compose.ip.yml` и `.env.ip.example` поднимают
  Nextcloud на `http://PUBLIC_IP/` и ONLYOFFICE на `http://PUBLIC_IP:8081/`
  без домена, DNS, ACME и NPM (профиль `edge`), отдельным compose-проектом
  `cloudsuite-ip` со своими томами.
* `scripts/ip-callback-route.sh` — идемпотентное правило DNAT внутри network
  namespace ONLYOFFICE (`PUBLIC_IP:IP_HTTP_PORT -> IP_WEB_IP:8080`), чтобы
  callback'и редактора работали там, где нет NAT loopback на публичный IP;
  режимы `--check`, `--verify`, `--remove`, нужен только `NET_ADMIN`.
* `scripts/ip-check.sh` — проверки GUI (`status.php`, `/login`), редактора
  (`/healthcheck`) и реального callback-пути из контейнера ONLYOFFICE.
* Цели `make ip-env`, `ip-up`, `ip-down`, `ip-ps`, `ip-logs`, `ip-configure`,
  `ip-route`, `ip-check`; `make ip-env` отклоняет приватные/loopback-значения
  `PUBLIC_IP`.
* `docs/14-ip-run.md` — быстрый старт, схема URL и callback'ов, ограничения
  plain-HTTP, файрвол, диагностика, переезд на домен.
* `LICENSES.md`: служебный образ `alpine:3.20` (одноразовый init-контейнер для
  iptables) — тоже свободные лицензии, вне рантайм-стека.

### Изменено

* `tests/validate.py`: раздел `docker-compose.ip.yml (white IP, no domain, no
  hosting)` — проверяет оверрайды, `.env.ip.example` (публичный IP, отдельный
  `OFFICE_DOMAIN`, `PROXY_IP == IP_WEB_IP`, http-URL), цели `ip-*` и helper'ы.
* `tests/compose_render.sh`: рендер base + IP overlay и его инварианты.
* `CONTRACT.md`: §3.2 (оверлей белого IP), правила `.env.ip` в §4, гейты 9-10,
  дефекты 14-16, живой прогон в §10.2.
* `Makefile`: переменные `IP_ENV_FILE`, `IP_COMPOSE_FILES`, `IP_COMPOSE_CMD`.
* `.gitignore`: исключение для `.env.ip.example`.
* `README.md`, `docs/README.md`: раздел и ссылка на режим белого IP.

### Важно

* Режим работает по обычному **http**: сертификат на «голый» IP не выдаётся,
  поэтому логины и файлы идут в открытом виде. Для публичного доступа с TLS
  нужен домен (продакшн-профиль) или внешний TLS-прокси.
## [1.1.0] — 2026-10-27

Локальный запуск без домена и TLS, инвентаризация лицензий образов.

### Добавлено

* **Локальный запуск (без домена):** `docker-compose.local.yml` и
  `.env.local.example` поднимают тот же стек на одной машине с web-GUI по
  `http://cloud.local:8080` и только loopback-портами. NPM вынесен в профиль
  `edge` и не запускается, TLS/ACME/почта не используются, локальный стек — это
  отдельный compose-проект `cloudsuite-local` со своими томами.
* Цели `make local-env`, `local-up`, `local-down`, `local-ps`, `local-logs`,
  `local-configure`, `local-check` (последняя проверяет `status.php`, `/login`
  и ONLYOFFICE `/healthcheck` по HTTP).
* `scripts/configure-nextcloud.sh` учитывает `PUBLIC_BASE_URL` (схема/хост/
  `overwrite.cli.url`) и `DOCUMENT_SERVER_URL` (адрес редактора для браузера):
  http-режим без домена настраивается без правки скрипта.
* `docs/13-local-run.md` — быстрый старт, схема работы `cloud.local`, проверка
  редактора, диагностика, отличия от продакшна.
* `LICENSES.md` — таблица лицензий всех образов (SPDX), отсутствие платных
  редакций и лицензионных ключей, обязательства AGPL, задокументированные
  альтернативы (Valkey вместо Redis, Collabora Online вместо ONLYOFFICE).

### Изменено

* `tests/validate.py`: новые разделы `docker-compose.local.yml` и
  `licenses` — проверяют loopback-порты, http-режим, наличие local-целей и
  совпадение образов в compose с таблицей `LICENSES.md`; запрещены теги
  `-ee`/`enterprise`/`plus`/`trial` и переменные лицензионных ключей.
* `tests/compose_render.sh`: добавлена проверка рендера base + local overlay.
* `Makefile`: переменные `LOCAL_ENV_FILE`, `LOCAL_COMPOSE_FILES`,
  `LOCAL_COMPOSE_CMD`; `make help` показывает локальные цели.
* `.gitignore`: исключение для `.env.local.example`.
* `scripts/local-hosts.sh` + `make local-hosts`: одноразовая запись
  `cloud.local`/`office.local` в `/etc/hosts` (скрипт отказывается от зоны
  `*.localhost`). Локальные имена — `cloud.local`/`office.local`, потому что
  браузеры, glibc/musl и curl принудительно резолвят `*.localhost` в loopback,
  игнорируя `/etc/hosts`, и ONLYOFFICE не смог бы обратиться к Nextcloud по
  callback-URL.

### Исправлено

Дефекты, найденные живым прогоном локального стека (проявляются и в продакшне):

* `scripts/configure-nextcloud.sh`: `app_enabled` падал ложно ("app … is not
  enabled") из-за `grep -q` + `set -o pipefail` (SIGPIPE); теперь сравнение
  строк без конвейера. То же исправление в `scripts/rbac-sync.sh`.
* `scripts/configure-nextcloud.sh`: вложенные ключи Redis записывались как
  `config:system:set redis --value=host --type=cache` и падали с "Invalid type";
  добавлены `occ_set_system_nested`/`occ_get_system_nested`/`verify_system_nested`
  и корректная запись `redis host|port|password|dbindex|timeout`.
* `scripts/configure-nextcloud.sh`: сравнение значений было glob-шаблоном
  (`[[ x == $(...) ]]`), из-за чего значения с обратными слэшами
  (`\OC\Memcache\Redis`) считались несовпадающими; обе стороны сравнения
  взяты в кавычки.
* `scripts/configure-nextcloud.sh`: проверка блокировок ожидала
  `RedisLockingProvider`, а Nextcloud 33+ использует
  `MemcacheLockingProvider`; проверка принимает оба варианта.
* `scripts/configure-nextcloud.sh`: PHP-проба кэша использовала удалённый
  `OC\Server::getMemCacheFactory()`; теперь `OCP\Server::get(ICacheFactory::class)`
  и `OCP\Lock\ILockingProvider::class`.
* `scripts/configure-nextcloud.sh`: `federatedfilesharing` в Nextcloud 35
  отключить нельзя ("can't be disabled"), из-за чего `make configure` падал на
  любом стенде, где приложение включено; федеративные шары теперь гасятся
  настройками `files_sharing.outgoing_server2server_share_enabled`/
  `incoming_server2server_share_enabled` = no (документация обновлена).

## [1.0.0] — 2026-10-26

Первая промышленная версия: self-hosted замена Яндекс.Диска на Nextcloud с
объектным хранилищем S3, ONLYOFFICE и Nginx Proxy Manager.

### Добавлено

**Платформа**

* Nextcloud 35.0.2 (PHP-FPM) как основной файловый сервис; файлы — в S3
  primary storage (SeaweedFS), метаданные — PostgreSQL 17, кэш и блокировки —
  Redis 8 с паролем.
* SeaweedFS с S3 gateway: сервисы `s3` (master/volume/filer/s3) и одноразовый
  `s3-init`, который идемпотентно создаёт S3-идентичность и бакет из `.env`.
* ONLYOFFICE Docs 8.3.3 с JWT-защитой и ко-редактированием; адрес Document Server
  и секрет передаются коннектору Nextcloud.
* Nginx Proxy Manager 2.16.0: два proxy host, Let's Encrypt, Force SSL, HTTP/2,
  HSTS, Websockets; GUI на loopback + SSH-туннель.
* edge-nginx (web tier): JSON access log (`json_combined`, стабильные имена полей),
  realip от NPM, защита от доступа к служебным путям, `/healthz`, `/status` только
  изнутри, 413 при превышении `PHP_UPLOAD_LIMIT`, лимиты загрузки.
* Две сети: `edge` (172.28.10.0/24, proxy с фиксированным IP для `extra_hosts`) и
  `backend` (172.28.20.0/24, `internal: true`).
* Конфигурация Nextcloud применяется entrypoint-хуками (`config/nextcloud/hooks`):
  `10-extra-config.sh` копирует `*.config.php` в `/var/www/html/config`,
  `20-permissions.sh` правит права, `30-enable-audit.sh` включает `admin_audit`.
* S3-хранилище подключено как primary storage с `OBJECTSTORE_S3_SSL=false`
  (внутренний HTTP в изолированной сети), объекты — `urn:oid:<fileid>`.

**Функциональность**

* Общие папки через группы и внутренние шары; конвенция `share_folder = /Общие`.
* Публичные ссылки: пароль обязателен (`enforce_link_password`), срок действия
  (`link_expire_days`), разрешение публичного редактирования и решаринга
  настраиваются политикой.
* Ролевая модель в `config/rbac/roles.yaml`: `admins` (без лимита),
  `management` (500 ГБ), `employees` (100 ГБ), `contractors` (20 ГБ,
  срок, без редактирования и решаринга), `auditors` (5 ГБ, без ссылок);
  применение — `make rbac` (идемпотентно, `DRY_RUN=1` для плана).
* Версии файлов: до 20 на файл (`VERSIONS_MAX`) с прунером
  `scripts/prune-versions.sh` и политика автоудаления по времени;
  корзина — 30 дней.

**Аудит и наблюдаемость**

* `admin_audit`: входы и выходы, доступ к файлам, создание/удаление/переименование,
  шары и публичные ссылки, изменения прав, состав групп, действия через `occ`.
* JSON-логи nginx с `request_id`, `realip_remote_addr`, `upstream_response_time`.
* `scripts/audit-report.sh`: сводка, CSV, `--list` и JSON по периоду, пользователю,
  IP; источник — `--file`, `AUDIT_LOG_FILE` или `logs/cloudsuite/audit.log`.
* `scripts/smoke-test.sh`: end-to-end проверка WebDAV, публичной ссылки, версий,
  корзины и audit-лога на временном пользователе.
* `scripts/healthcheck.sh`: проверка всех сервисов, HTTP-эндпоинтов, S3, Redis, БД.

**Эксплуатация**

* `scripts/bootstrap.sh` — идемпотентная подготовка (проверка `.env`, каталоги, права,
  `docker compose config`); `scripts/preflight.sh` — проверка предусловий.
* `scripts/backup.sh` — консистентный бэкап (pg_dump, Redis SAVE, тома, конфиг
  с шифрованием AES-256), манифест SHA-256, retention, offsite через rclone.
* `scripts/restore.sh` — проверка манифеста, восстановление конфигурации, томов и БД,
  `occ files:scan`, healthcheck, отчёт RPO/RTO; требует `--confirm`.
* `scripts/update.sh` — обслуживание, `pull`, `up -d`, ожидание healthy, `occ upgrade`.
* Единая точка входа `Makefile` (`make help` — список целей), cron-примеры и
  systemd-таймеры для бэкапов и прунера.
* `config/logrotate/cloudsuite` — ротация логов nginx, Nextcloud и ONLYOFFICE
  (`copytruncate`, weekly, 12 архивов, сжатие).
* `docker-compose.admin.yml` — публикация админ-портов только на loopback;
  `docker-compose.observability.yml` — профиль Loki + Promtail (`--profile observability`).

**Безопасность**

* Все секреты генерируются `scripts/generate-secrets.sh`, `.env` — 600, значения не
  печатаются; секретов в git нет.
* `no-new-privileges`, ограничение логов (20 МБ × 5), `internal` сеть, отсутствие
  лишних публикуемых портов, `server_tokens off`.
* Внутренний nginx намеренно не отправляет HSTS и CSP/COEP/COOP/CORP:
  HSTS ставит только NPM (иначе дубли заголовков), CSP ломает iframe ONLYOFFICE.
* Парольная политика (минимум 12 символов), 2FA (`twofactor_totp`), защита от подбора
  паролей, ограничение сессий, принудительный HTTPS, trusted proxies.
* Redis: `requirepass`, `maxmemory 1gb` с `noeviction` (блокировки нельзя вытеснять),
  переименованы `FLUSHALL`/`FLUSHDB`/`SHUTDOWN`. Команда `CONFIG` намеренно **не**
  переименована: на Redis 8.4.7 это приводит к падению при старте.

**Документация**

* `README.md` — быстрый старт и обзор.
* `docs/01`–`docs/12`: архитектура, развёртывание, хардненинг, RBAC и шаринг,
  аудит, версии, бэкап и DR, миграция из Яндекс.Диска, runbook, руководство
  пользователя, troubleshooting, чек-лист приёмки.
* `config/proxy/npm-gui-setup.md` — пошаговая настройка NPM.
* `CONTRACT.md` — контракт стека (имена сервисов, порты, сети, тома, критерии приёмки).

**Инструменты качества**

* `tests/validate.py`: проверка YAML/JSON, контракта `.env`, ссылок в nginx-конфигах и
  резолвинга кросс-ссылок в документации.
* `make lint` (`shellcheck`, `bash -n`, `php -l`, `python -m py_compile`) и
  `make test`; `nginx -t` для edge-nginx и server-level конфигов NPM.

### Известные ограничения версии

* RPO по умолчанию — 24 часа (период полного бэкапа); для меньшего RPO включайте
  инкрементальные прогоны каждые 4 часа и offsite-копию.
* Стек рассчитан на один сервер; отказоустойчивость требует внешнего S3/БД и
  нескольких app-узлов (см. [docs/01-architecture.md](docs/01-architecture.md)).
* Версионирование объектов на стороне SeaweedFS не включено: история файлов
  обеспечивается Nextcloud, откат «объекта S3» — только из бэкапа.
* ONLYOFFICE в конфигурации с частными IP требует `ALLOW_PRIVATE_IP_ADDRESS=true`
  (см. [docs/11-troubleshooting.md](docs/11-troubleshooting.md)).
* Миграция из Яндекс.Диска выполняется полуавтоматически (скрипт + ручная сверка),
  см. [docs/08-migration-from-yandex-disk.md](docs/08-migration-from-yandex-disk.md).

### Приёмочные правки (итоги живого прогона)

* `S3_USER` вынесен в `.env`/`.env.example`: одноразовый сервис `s3-init` берёт из него
  имя S3-идентичности (раньше было жёстко задано в compose).
* `OBJECTSTORE_S3_USEPATH_STYLE` теперь берётся из `S3_USE_PATH_STYLE`, а не жёстко `true`.
* `.env.example`: добавлены переменные overlay-файлов (`NPM_ADMIN_BIND_LAN`,
  `SEAWEEDFS_ADMIN_BIND_LAN`, `LOKI_VERSION`, `LOKI_BIND`, `LOKI_PORT`,
  `LOKI_RETENTION`, `PROMTAIL_VERSION`), убрано упоминание `config/seaweedfs/s3.json`
  (файла больше нет), уточнён лимит `SEAWEEDFS_VOLUME_SIZE_MB <= 30720`.
* Шапка `config/nextcloud/custom/prune-versions.php` ссылается на актуальный путь
  `/opt/cloudsuite/custom/prune-versions.php`.
* NPM: первичный администратор создаётся из `NPM_ADMIN_EMAIL`/`NPM_ADMIN_PASSWORD`
  (`INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD`), поэтому вход в GUI детерминирован,
  без мастера первичной настройки и пароля `changeme`.
* В git-индексе выставлены режимы `100755` для `scripts/*.sh`, `scripts/lib/*.sh`,
  `config/nextcloud/hooks/before-starting/*.sh`, `tests/*.sh`.

### Связанные документы

* [README.md](README.md)
* [CONTRACT.md](CONTRACT.md)
* [docs/12-acceptance-checklist.md](docs/12-acceptance-checklist.md)
