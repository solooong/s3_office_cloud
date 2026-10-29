# Cloud Suite — корпоративное облако на S3

Self-hosted замена Яндекс.Диска для организации: файлы сотрудников хранятся в
**S3-совместимом объектном хранилище** (SeaweedFS), веб-интерфейс и совместная
работа — **Nextcloud 35**, офисные документы редактируются в браузере через
**ONLYOFFICE Docs 8.3.3**, вход и TLS — **Nginx Proxy Manager** с Let's Encrypt.
Всё разворачивается одним `docker compose` на одном Linux-сервере.

```text
Браузер / клиенты ──HTTPS──▶ Nginx Proxy Manager ──▶ nginx ──▶ Nextcloud (PHP-FPM)
                                   │                              │
                                   └──▶ ONLYOFFICE Docs           ├── PostgreSQL (метаданные)
                                                                  ├── Redis (кэш, блокировки)
                                                                  └── SeaweedFS S3 (файлы)
```

## Что умеет

| Требование заказчика | Как реализовано |
|---|---|
| Хранение файлов в S3, а не в Яндекс.Диске | Nextcloud в режиме S3 primary storage на SeaweedFS S3 gateway |
| Веб-интерфейс | Nextcloud 35 (файлы, поиск, превью, корзина, версии) |
| Nginx-авторизация и точка входа с GUI | Nginx Proxy Manager 2.16.0: TLS, Let's Encrypt, access lists, GUI |
| Общие папки между сотрудниками | группы Nextcloud и внутренние шары |
| Публичные ссылки «только чтение» и «с редактированием» | link shares с правами, паролем и сроком действия |
| Настраиваемая ролевая модель | `config/rbac/roles.yaml` и `scripts/rbac-sync.sh` (`make rbac`) |
| Аудит действий пользователей | `admin_audit` в `logs/cloudsuite/audit.log` и JSON-логи nginx |
| До 20 версий файла (настраивается) | `files_versions` и прунер по `VERSIONS_MAX` (`make prune-versions`) |
| Встроенный офис | ONLYOFFICE Docs 8.3.3, JWT-защита, ко-редактирование |
| Промышленная эксплуатация | healthcheck, пины образов, бэкапы и восстановление, DR, CI-валидация |

## Быстрый старт (15 минут)

Требуется: Ubuntu 24.04 LTS (или Debian 12), 4 vCPU / 8 ГБ RAM / 100 ГБ SSD,
публичный IP и два домена, направленных на этот IP.

```bash
# 1. Docker Engine + compose plugin (официальный репозиторий)
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin git make jq openssl

# 2. sysctl для ONLYOFFICE
echo 'vm.max_map_count = 262144' | sudo tee /etc/sysctl.d/99-cloudsuite.conf
sudo sysctl --system

# 3. код и конфигурация
sudo mkdir -p /opt && cd /opt
sudo git clone <URL-репозитория> cloudsuite && cd cloudsuite
cp .env.example .env && chmod 600 .env
# отредактируйте CLOUD_DOMAIN, OFFICE_DOMAIN, ACME_EMAIL, NPM_ADMIN_EMAIL, TZ, SMTP_*
nano .env

# 4. секреты: заполняет пустые значения, ничего не печатает
./scripts/generate-secrets.sh

# 5. проверка окружения и подготовка каталогов
./scripts/preflight.sh
make bootstrap

# 6. запуск (первый старт 3–10 минут: образы и установка Nextcloud)
make up
make status
```

Дальше — три шага, которые нельзя автоматизировать (GUI NPM и настройка коннектора):

1. **Nginx Proxy Manager**: `ssh -L 8181:127.0.0.1:8181 root@IP`, открыть
   `http://127.0.0.1:8181`, войти с `NPM_ADMIN_EMAIL` и `NPM_ADMIN_PASSWORD`,
   сменить пароль.
2. Создать **два proxy host**: `cloud.example.com` на `web:8080` и
   `office.example.com` на `onlyoffice:80`; включить Websockets, Force SSL,
   HTTP/2, HSTS; выпустить Let's Encrypt; вставить Advanced-конфиги из `config/proxy/`.
   Пошагово: `config/proxy/npm-gui-setup.md`.
3. Применить настройки приложений: `make configure`, роли — `make rbac`.

Проверка:

```bash
curl -fsS https://cloud.example.com/status.php | jq '{installed, versionstring}'
curl -fsS https://office.example.com/healthcheck
make doctor
make smoke
```

Откройте `https://cloud.example.com`, войдите как `NEXTCLOUD_ADMIN_USER` с паролем
из `.env`, загрузите файл и откройте DOCX — должен запуститься редактор.

Полная установка с объяснением каждого шага — [02-deployment.md](docs/02-deployment.md).

## Локальный запуск без домена (демо и отладка)

Тот же стек можно поднять на ноутбуке без домена, DNS и TLS — только для
проверки и демонстрации:

```bash
sudo make local-hosts # один раз: cloud.local/office.local -> 127.0.0.1
make local-env        # .env.local из шаблона + секреты (свой compose-проект)
make local-up         # Nextcloud на 127.0.0.1:8080, ONLYOFFICE на 127.0.0.1:8081
make local-configure  # occ-настройки под локальные URL
make local-check      # status.php 200, /login 200/302, /healthcheck 200
```

Откройте http://cloud.local:8080 и войдите под учёткой из `.env.local`. Имена
`cloud.local`/`office.local` добавляются в hosts один раз (`make local-hosts`):
зона `*.localhost` не подходит — curl и glibc/musl принудительно шлют её
в loopback, и ONLYOFFICE не смог бы обратиться к Nextcloud по callback-URL.
NPM, Let's Encrypt и почта в этом режиме не используются, порты слушают только
loopback. Остановка — `make local-down` (`VOLUMES=1` удаляет данные).
Подробности и диагностика — [13-local-run.md](docs/13-local-run.md).

## Запуск на белом IP без домена и хостинга

Сервер с публичным IPv4, без домена, DNS и TLS: Nextcloud открывается по
`http://PUBLIC_IP/`, ONLYOFFICE — по `http://PUBLIC_IP:8081/`.

```bash
make ip-env          # .env.ip из шаблона + секреты; впишите PUBLIC_IP
make ip-up           # поднять стек (профиль cloudsuite-ip, свои тома)
make ip-configure    # occ под публичный IP + маршрут callback'ов ONLYOFFICE
make ip-check        # status.php, /login, редактор, callback из ONLYOFFICE
```

`make ip-env` отвергает приватные и loopback-адреса. Между Nextcloud и
ONLYOFFICE callback'и идут на публичный IP, поэтому `make ip-route` (входит в
`ip-configure`) добавляет одно DNAT-правило внутри сетевого namespace
редактора — работает и на VPS с 1:1 NAT, где NAT-loopback нет.

Режим работает по **http**: для публичного доступа с TLS нужен домен
(продакшн-профиль) или внешний TLS-прокси. Подробности, ограничения и переезд
на домен — [14-ip-run.md](docs/14-ip-run.md).

## Требования

| Параметр | Минимум | Рекомендуется |
|---|---|---|
| CPU / RAM | 4 vCPU / 8 ГБ | 8 vCPU / 16 ГБ |
| Диск | 100 ГБ SSD плюс место под данные | NVMe, отдельный диск под S3 |
| ОС | Ubuntu 24.04 LTS / Debian 12 | Ubuntu 24.04 LTS |
| ПО | Docker 24+, compose v2.20+ | актуальные стабильные версии |
| Сеть | публичный IPv4, порты 80/443 | домен, IPv6, SMTP |

Расчёт диска и профили нагрузки — [01-architecture.md](docs/01-architecture.md).

## Документация

| Документ | О чём |
|---|---|
| [01-architecture.md](docs/01-architecture.md) | компоненты, потоки данных, сети, масштабирование |
| [02-deployment.md](docs/02-deployment.md) | установка с нуля, NPM, OnlyOffice, приёмка |
| [03-security-hardening.md](docs/03-security-hardening.md) | модель угроз, TLS, хардненинг, секреты |
| [04-rbac-and-sharing.md](docs/04-rbac-and-sharing.md) | роли, квоты, матрица прав, шаринг, ссылки |
| [05-audit-logging.md](docs/05-audit-logging.md) | аудит, форматы логов, jq-рецепты, SIEM |
| [06-versioning-and-retention.md](docs/06-versioning-and-retention.md) | версии файлов, корзина, ёмкость |
| [07-backup-restore-dr.md](docs/07-backup-restore-dr.md) | бэкапы, offsite, восстановление, DR-drill |
| [08-migration-from-yandex-disk.md](docs/08-migration-from-yandex-disk.md) | перенос данных из Яндекс.Диска |
| [09-operations-runbook.md](docs/09-operations-runbook.md) | регламенты, cron, инцидент-плейбуки |
| [10-user-guide.md](docs/10-user-guide.md) | инструкция для сотрудников |
| [11-troubleshooting.md](docs/11-troubleshooting.md) | диагностика типовых сбоев |
| [12-acceptance-checklist.md](docs/12-acceptance-checklist.md) | чек-лист приёмки в эксплуатацию |
| [13-local-run.md](docs/13-local-run.md) | локальный запуск без домена: GUI на cloud.local |
| [LICENSES.md](LICENSES.md) | лицензии всех образов, отсутствие платных редакций |
| [CONTRACT.md](CONTRACT.md) | внутренний контракт: сервисы, порты, сети, тома |

Дополнительно: [config/proxy/npm-gui-setup.md](config/proxy/npm-gui-setup.md) — настройка
Nginx Proxy Manager, [config/nginx/README.md](config/nginx/README.md) — edge-nginx,
[config/onlyoffice/README.md](config/onlyoffice/README.md) — ONLYOFFICE,
[CHANGELOG.md](CHANGELOG.md) — история версий.

## Эксплуатация

```bash
make help                     # все цели
make status                   # состояние сервисов и healthcheck
make logs                     # логи (SERVICE=app — конкретный сервис)
make backup                   # бэкап БД, томов и конфигурации
make prune-versions           # оставить не более VERSIONS_MAX версий на файл
make prune-versions-dry-run   # показать, что будет удалено
make audit-report ARGS="--from 2026-01-01"   # отчёт по audit-логу
make rbac                     # применить роли из config/rbac/roles.yaml
make configure                # идемпотентная настройка Nextcloud
make update                   # обновление образов с бэкапом и occ upgrade
make doctor                   # preflight + healthcheck
make smoke                    # end-to-end проверка
make test                     # валидация репозитория
```

Регламенты и инцидент-плейбуки — [09-operations-runbook.md](docs/09-operations-runbook.md).

## Структура репозитория

```text
├── docker-compose.yml                основной стек
├── docker-compose.admin.yml          публикация админ-портов на loopback (опционально)
├── docker-compose.observability.yml  профиль Loki + Promtail (опционально)
├── .env.example                  шаблон конфигурации (все переменные)
├── config/
│   ├── nextcloud/                php.ini, config/*.config.php, custom/, hooks/
│   ├── nginx/                    edge-nginx: vhost, сниппеты, шаблоны env
│   ├── proxy/                    Advanced-конфиги и инструкция для NPM
│   ├── rbac/roles.yaml           ролевая модель (источник истины)
│   ├── redis/redis.conf          requirepass, лимиты памяти, политика
│   ├── logrotate/cloudsuite      ротация логов (copytruncate, 12 недель)
│   └── onlyoffice/README.md      как настраивается Document Server (env)
├── scripts/                      bootstrap, preflight, backup, restore, rbac-sync,
│                                 configure-nextcloud, prune-versions, audit-report,
│                                 healthcheck, smoke-test, update, migrate, occ
├── tests/                        валидаторы (validate.py)
├── .github/workflows/            CI: статические проверки + рендер compose
├── docs/                         01–12, документация
├── Makefile                      единая точка входа
├── CONTRACT.md                   контракт стека
├── README.md
└── CHANGELOG.md
```

## Безопасность (кратко)

* наружу открыты только 80/443; админ-интерфейсы — на loopback и через SSH-туннель;
* TLS только от NPM (Let's Encrypt), HSTS и Force SSL — там же;
* JWT между Nextcloud и ONLYOFFICE, секрет — только в `.env`;
* внутренняя сеть `backend` с `internal: true`: у сервисов нет исходящего доступа в интернет
  (кроме прокси-слоя);
* секреты генерируются скриптом, `.env` — 600, бэкап конфигурации шифруется;
* действия пользователей фиксируются в audit-логе, входы и 5xx — в JSON-логе nginx;
* образы закреплены по версиям, обновление — осознанная процедура.

Подробно — [03-security-hardening.md](docs/03-security-hardening.md).

## Поддержка

Порядок диагностики: [11-troubleshooting.md](docs/11-troubleshooting.md). Если
проблема не описана — соберите вывод `make doctor`, `make status`,
`docker compose logs --tail=200` и audit-лог за период инцидента.

## Лицензия и статус

Внутренний проект организации. Компоненты распространяются под своими лицензиями
(Nextcloud — AGPLv3, ONLYOFFICE Docs — AGPLv3, Nginx Proxy Manager — MIT,
SeaweedFS — Apache-2.0, PostgreSQL — PostgreSQL License, Redis — RSALv2/SSPLv1);
условия использования проверяются при внедрении.
#   s 3 _ o f f i c e _ c l o u d  
 