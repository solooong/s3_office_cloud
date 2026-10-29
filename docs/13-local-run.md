# Локальный запуск без домена и TLS (web-GUI на localhost)

Дополнительный набор для запуска **всего стека на одной машине без домена,
DNS и сертификатов**: Nextcloud открывается в браузере по локальному имени,
ONLYOFFICE редактирует документы, S3-хранилище, PostgreSQL и Redis работают
локально. Нужен для демонстрации, отладки, проверки обновлений и обучения —
это не продакшн-профиль.

Состав файлов:

| Файл | Назначение |
|---|---|
| `docker-compose.local.yml` | overlay: отключает NPM, публикует web и ONLYOFFICE на loopback, включает http |
| `.env.local.example` | шаблон окружения локального запуска (отдельный compose-проект) |
| `scripts/local-hosts.sh` | одноразовая запись локальных имён в `/etc/hosts` |
| `make local-*` | команды запуска/остановки/настройки/проверки |

## Что поднимается

| Сервис | Куда смотреть | Примечание |
|---|---|---|
| Nextcloud (web-GUI) | http://cloud.local:8080 | имя из `/etc/hosts` (см. ниже) |
| ONLYOFFICE Docs | http://cloud.local:8081 | редактор для браузера |
| SeaweedFS (S3) | 127.0.0.1:8333 внутри docker | админ-порты 9333/8888 — только loopback |
| PostgreSQL, Redis | внутри сети backend | наружу не публикуются |
| Nginx Proxy Manager | **не запускается** | профиль `edge`, домены и TLS не нужны |

Все публикуемые порты привязаны к `127.0.0.1`: с другой машины стек не виден.

## Требования

* Docker Engine 24+ (или Docker Desktop) с compose v2.20+;
* 4 vCPU / 8 ГБ RAM, 20 ГБ свободного диска;
* свободные порты **8080** (Nextcloud), **8081** (ONLYOFFICE), 9333 и 8888 (SeaweedFS);
* права администратора **один раз** — добавить две строки в hosts (см. ниже);
* интернет при первом `make local-configure` — из App Store ставится коннектор
  ONLYOFFICE (дальше всё работает офлайн).

## Быстрый старт

```bash
sudo make local-hosts  # один раз: cloud.local/office.local -> 127.0.0.1
make local-env         # создать .env.local из шаблона и заполнить секреты
make local-up          # поднять стек (3-10 минут: образы + первичная установка)
make local-configure   # применить occ-настройки под локальные URL
make local-check       # status.php, /login, ONLYOFFICE /healthcheck
```

`make local-hosts` без прав root печатает точную строку и команду для вашей ОС;
с `sudo` — добавляет запись сам (идемпотентно, повторный запуск ничего не дублирует).

`make local-env` печатает логин и пароль администратора Nextcloud
(они лежат в `.env.local`: `NEXTCLOUD_ADMIN_USER`, `NEXTCLOUD_ADMIN_PASSWORD`).
Откройте http://cloud.local:8080 и войдите.

Остановка:

```bash
make local-down            # остановить, данные сохранить
make local-down VOLUMES=1  # остановить и удалить данные (чистый старт)
```

## Почему `cloud.local`, а не `cloud.localhost`

Имена в зоне `*.localhost` **жёстко** считаются loopback: браузеры, glibc и musl
(и даже `curl`) не смотрят в `/etc/hosts` для таких имён и всегда идут на
127.0.0.1. Браузеру это удобно, но серверу ONLYOFFICE нужно скачивать документ
по адресу callback'а `http://cloud.localhost:8080/...` — внутри контейнера такой
запрос уходит в сам контейнер, и редактор не может открыть файл.

Поэтому локальные имена — обычные `cloud.local` и `office.local` (домена нет,
DNS нет, есть одна строка в hosts). Внутри Docker те же имена резолвятся
автоматически через `extra_hosts` (base `docker-compose.yml`), поэтому
callback'и ONLYOFFICE доходят до контейнера `web` без правки hosts в контейнерах.

Одна строка на рабочей машине (нужен администратор один раз):

```text
127.0.0.1 cloud.local office.local
```

* Linux/macOS: `sudo make local-hosts` (или `sudo sh -c 'echo "127.0.0.1 cloud.local office.local" >> /etc/hosts'`);
* Windows (PowerShell от имени администратора):
  `Add-Content -Path "$env:WINDIR\System32\drivers\etc\hosts" -Value "127.0.0.1 cloud.local office.local"`.

Проверить: `make local-hosts ARGS=--check` (внутри scripts/local-hosts.sh есть
`--print`, `--check`, `--help`).

## Проверка встроенного офиса

1. Войдите в Nextcloud, создайте или загрузите файл `.docx`/`.xlsx`.
2. Нажмите на него — документ откроется в редакторе ONLYOFFICE
   (адрес редактора: http://cloud.local:8081).
3. Изменения сохраняются автоматически; версии видны в меню файла.

Если редактор открывается, но документ не загружается: проверьте, что
`make local-configure` выполнен (он задаёт `DocumentServerUrl`,
`DocumentServerInternalUrl` и `StorageUrl`), что в `.env.local`
`PROXY_IP == LOCAL_WEB_IP`, и что имя `cloud.local` добавлено в hosts.

## Отличия от продакшн-профиля

| | Продакшн | Локальный запуск |
|---|---|---|
| Домены | реальные `CLOUD_DOMAIN`/`OFFICE_DOMAIN` | `cloud.local`/`office.local` |
| TLS | Let's Encrypt на NPM, Force SSL, HSTS | нет, обычный http |
| Точка входа | NPM :443 → web:8080 | web:8080 напрямую на 127.0.0.1:8080 |
| NPM GUI | 127.0.0.1:8181 | не запускается (профиль `edge`) |
| Ссылки | `https://cloud.example.com/...` | `http://cloud.local:8080/...` |
| Почта | SMTP из `.env` | выключена (SMTP пуст, письма не уходят) |
| Проект compose | `cloudsuite` | `cloudsuite-local` (свои тома) |
| Данные | боевые | демонстрационные, удаляются `make local-down VOLUMES=1` |

Локальный профиль **не заменяет** приёмку: перед продакшном выполняются
`make doctor`, `make test`, `make smoke` на реальных доменах и TLS
(см. [02-deployment.md](02-deployment.md) и
[12-acceptance-checklist.md](12-acceptance-checklist.md)).

## Команды

| Команда | Что делает |
|---|---|
| `make local-hosts` | показать/добавить `cloud.local`, `office.local` в hosts |
| `make local-env` | `.env.local` из шаблона, генерация секретов (идемпотентно) |
| `make local-up` | поднять стек без домена, напечатать адреса |
| `make local-ps` | состояние контейнеров локального проекта |
| `make local-logs` | логи (`make local-logs SERVICE=app`) |
| `make local-configure` | occ-настройки: домены, прокси, офис, кэш, шары |
| `make local-check` | `status.php` 200, `/login` 200/302, ONLYOFFICE `/healthcheck` 200 |
| `make local-down` | остановить, данные сохранить (`VOLUMES=1` — удалить) |

Скрипты работают с локальным окружением через переменные
`CLOUDSUITE_ENV_FILE=.env.local` и
`CLOUDSUITE_COMPOSE_FILES="docker-compose.yml docker-compose.local.yml"`;
в целях Makefile это уже сделано, вручную задавать не нужно.

## Диагностика

| Симптом | Причина и решение |
|---|---|
| `port is already allocated` (8080/8081) | порт занят: измените `LOCAL_HTTP_PORT`/`LOCAL_OFFICE_PORT` в `.env.local`, затем `make local-up` |
| `Pool overlaps with other one on this address space` | сеть 172.28.10.0/24 занята другим docker-проектом/VPN: поменяйте `PROXY_IP`/`LOCAL_WEB_IP` и подсети в `docker-compose.yml` (см. [11-troubleshooting.md](11-troubleshooting.md), раздел про конфликт подсетей) |
| Браузер не открывает `cloud.local` | нет записи в hosts: `sudo make local-hosts`, затем `make local-hosts ARGS=--check` |
| Редактор открылся, документ «крутится» | не выполнен `make local-configure`; либо `PROXY_IP != LOCAL_WEB_IP`; либо имя из зоны `*.localhost` (так нельзя) |
| `status.php` 200, но `installed:false` | первичная установка ещё идёт: `make local-logs SERVICE=app`, подождите 1-2 минуты |
| `status.php` 404/444 | запрос без локального Host: открывайте именно `http://cloud.local:8080` |

Логи: `make local-logs`; файлы Nextcloud и аудита — `logs/cloudsuite/`.

## Удаление

```bash
make local-down VOLUMES=1   # контейнеры + тома локального проекта
```

Каталоги `logs/` и `backups/` остаются на хосте; продовый `.env` и его тома
не затрагиваются (другой `COMPOSE_PROJECT_NAME`).