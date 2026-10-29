# Запуск на «белом» IP без домена и хостинга

Дополнительный набор для сервера **с публичным IPv4 и без домена**: ни DNS, ни
Let's Encrypt, ни NPM, ни хостинг-панели. Nextcloud открывается по адресу
`http://PUBLIC_IP/`, ONLYOFFICE — по `http://PUBLIC_IP:8081/`. Всё остальное
(S3-хранилище, PostgreSQL, Redis, версии, аудит, RBAC) работает так же, как в
продакшн-профиле.

Состав файлов:

| Файл | Назначение |
|---|---|
| `docker-compose.ip.yml` | overlay: без NPM, публикует web и ONLYOFFICE на `IP_BIND`, включает http |
| `.env.ip.example` | шаблон окружения (`PUBLIC_IP`, `PUBLIC_HOST`, порты; отдельный compose-проект) |
| `scripts/ip-callback-route.sh` | маршрут callback'ов ONLYOFFICE → web внутри docker-сети |
| `scripts/ip-check.sh` | проверки GUI, редактора и callback-пути |
| `make ip-*` | запуск, остановка, конфигурация, проверки |

## Что поднимается

| Сервис | Адрес | Примечание |
|---|---|---|
| Nextcloud (web-GUI) | `http://PUBLIC_IP/` | порт `IP_HTTP_PORT` (по умолчанию 80) |
| ONLYOFFICE Docs | `http://PUBLIC_IP:8081/` | порт `IP_OFFICE_PORT`; нужен браузеру |
| SeaweedFS (S3) | 127.0.0.1:8333 внутри docker | наружу не публикуется |
| PostgreSQL, Redis | внутри сети backend | наружу не публикуются |
| Nginx Proxy Manager | **не запускается** | профиль `edge`: домена и TLS нет |

Публикуются только два порта: `IP_HTTP_PORT` и `IP_OFFICE_PORT` (оба на
`IP_BIND`, по умолчанию `0.0.0.0`). Админ-порты SeaweedFS остаются на loopback.

## Требования

* сервер с глобально маршрутизируемым IPv4 (VPS/dedicated) и Docker 24+ / compose v2.20+;
* 4 vCPU / 8 ГБ RAM, 20 ГБ свободного диска;
* открытые в файрволе порты `22`, `IP_HTTP_PORT` (80), `IP_OFFICE_PORT` (8081);
* интернет при первом `make ip-configure` — из App Store ставится коннектор ONLYOFFICE;
* `scripts/ip-callback-route.sh` использует одноразовый контейнер с `NET_ADMIN`
  (образ `alpine`) — docker должен уметь это запускать (обычный docker на VPS умеет).

## Быстрый старт

```bash
make ip-env          # .env.ip из шаблона + секреты; затем впишите PUBLIC_IP
make ip-up           # поднять стек (3-10 минут: образы + первичная установка)
make ip-configure    # occ-настройки под публичный IP + маршрут callback'ов
make ip-check        # status.php, /login, редактор, callback
# открыть http://PUBLIC_IP/ и войти под NEXTCLOUD_ADMIN_USER/PASSWORD из .env.ip
```

`make ip-env` проверяет, что `PUBLIC_IP` — действительно публичный адрес:
loopback и приватные диапазоны (10.x, 172.16-31.x, 192.168.x, 127.x, 169.254.x)
отклоняются, потому что браузер до них не дотянется, а callback'и сломаются.

Остановка:

```bash
make ip-down            # остановить, данные сохранить
make ip-down VOLUMES=1  # остановить и удалить данные (чистый старт)
```

## Как устроены URL и callback'и

* `PUBLIC_HOST` — это `PUBLIC_IP`, а при `IP_HTTP_PORT != 80` — `PUBLIC_IP:порт`.
  Из него собираются `overwritehost`/`overwrite.cli.url` (`PUBLIC_BASE_URL`
  должен совпадать с ним).
* `CLOUD_DOMAIN=PUBLIC_IP`, а `OFFICE_DOMAIN` — служебное имя (`office.internal`):
  оно нужно только для `extra_hosts`/nginx и в браузере не используется.
  Домены обязаны различаться — compose не принимает два одинаковых пункта
  `extra_hosts` («extra_hosts must be a mapping»).
* `IP_WEB_IP` (172.28.10.12) — статический адрес `web` в сети `edge`.
* ONLYOFFICE получает от Nextcloud callback-URL вида
  `http://PUBLIC_IP/apps/onlyoffice/...`. Из контейнера публичный IP может быть
  недостижим (1:1 NAT провайдера, отсутствие NAT-loopback, файрвол), поэтому
  `scripts/ip-callback-route.sh` добавляет **одно правило DNAT внутри network
  namespace контейнера onlyoffice**:

```text
PUBLIC_IP:IP_HTTP_PORT (tcp)  ->  IP_WEB_IP:8080   (web)
```

  Правило живёт в netns ONLYOFFICE, на хосте ничего не меняется, хост-iptables не
  трогается. Оно идемпотентно, ставится из `make ip-configure` (или `make ip-route`)
  и исчезает вместе с контейнером; после пересоздания стека выполните `make ip-route`.

## Проверка встроенного офиса

1. Войдите в Nextcloud, загрузите `.docx`/`.xlsx`.
2. Откройте файл — он откроется в редакторе ONLYOFFICE по адресу
   `http://PUBLIC_IP:8081/`; изменения сохраняются автоматически.
3. `make ip-check` проверяет ещё и callback-путь: из контейнера ONLYOFFICE
   запрашивается `http://PUBLIC_IP:IP_HTTP_PORT/status.php` и ожидается 200.

## Отличия от продакшн-профиля

| | Продакшн (домен) | Белый IP |
|---|---|---|
| Домены | реальные `CLOUD_DOMAIN`/`OFFICE_DOMAIN` | IP + служебное `office.internal` |
| TLS | Let's Encrypt на NPM, Force SSL, HSTS | **нет**, обычный http |
| Точка входа | NPM :443 → web:8080 | web:80 напрямую |
| NPM GUI | 127.0.0.1:8181 | не запускается (профиль `edge`) |
| Ссылки | `https://cloud.example.com/...` | `http://PUBLIC_IP/...` |
| Проект compose | `cloudsuite` | `cloudsuite-ip` (свои тома) |

### Про TLS

Без домена Let's Encrypt не выдаст сертификат, поэтому режим работает по **http**.
Это значит, что логины и файлы идут по сети в открытом виде: используйте режим
для внутренней сети, демонстрации или под защитой VPN, либо терминируйте TLS
внешним прокси/балансировщиком. Если нужен публичный доступ с TLS и NPM GUI —
используйте продакшн-профиль с доменом (см. [02-deployment.md](02-deployment.md));
переезд с IP-режима на домен описан в разделе ниже.

## Переезд с белого IP на домен

1. Направьте A-запись домена на тот же IP.
2. Остановите IP-стек: `make ip-down` (данные остаются в томах `cloudsuite-ip_*`).
3. Поднимите продакшн-профиль (`make up`) — это отдельный проект и отдельные тома.
4. Перенесите данные штатным `make backup` / `make restore`
   (см. [05-backup-restore.md](05-backup-restore.md)) либо продолжайте работать
   на IP-стеке, добавив TLS-прокси перед ним.

## Команды

| Команда | Что делает |
|---|---|
| `make ip-env` | `.env.ip` из шаблона, генерация секретов (идемпотентно) |
| `make ip-up` | поднять стек на белом IP |
| `make ip-ps` | состояние контейнеров проекта `cloudsuite-ip` |
| `make ip-logs` | логи (`make ip-logs SERVICE=onlyoffice`) |
| `make ip-configure` | occ-настройки + маршрут callback'ов |
| `make ip-route` | (пере)создать маршрут callback'ов |
| `make ip-check` | GUI, `/login`, ONLYOFFICE `/healthcheck`, callback |
| `make ip-down` | остановить (`VOLUMES=1` — удалить данные) |

Скрипты работают с IP-окружением через
`CLOUDSUITE_ENV_FILE=.env.ip` и
`CLOUDSUITE_COMPOSE_FILES="docker-compose.yml docker-compose.ip.yml"`;
в целях Makefile это задано, вручную выставлять не нужно.

## Диагностика

| Симптом | Причина и решение |
|---|---|
| `PUBLIC_IP=... is not a public (white) IPv4 address` | в `.env.ip` приватный/loopback-адрес: укажите публичный IPv4 сервера |
| `port is already allocated` (80/8081) | порт занят: измените `IP_HTTP_PORT`/`IP_OFFICE_PORT`, не забудьте порт в `PUBLIC_HOST`/`PUBLIC_BASE_URL` и `make ip-configure` |
| `Pool overlaps with other one on this address space` | сеть 172.28.10.0/24 занята другим docker-проектом/VPN: см. [11-troubleshooting.md](11-troubleshooting.md) |
| `extra_hosts must be a mapping` | `CLOUD_DOMAIN` и `OFFICE_DOMAIN` совпали: `OFFICE_DOMAIN` должен быть служебным именем (`office.internal`) |
| Браузер открывает `status.php`, редактор не грузит документ | не выполнен `make ip-route` / `make ip-configure`; проверьте `make ip-check` |
| `ONLYOFFICE cannot reach Nextcloud at http://PUBLIC_IP/...` | провайдерский 1:1 NAT без loopback: `make ip-route`; если не помогло — внешний TLS/прокси или доменный профиль |
| `installed:false` | первичная установка ещё идёт: `make ip-logs SERVICE=app` |
| `status.php` 444 | запрос без публичного Host: открывайте `http://PUBLIC_IP/` |

Логи: `make ip-logs`; файлы Nextcloud и аудита — `logs/cloudsuite/`.

## Удаление

```bash
make ip-down VOLUMES=1
```

Каталоги `logs/` и `backups/` остаются на хосте; продакшн-стек и его тома не
затрагиваются (другой `COMPOSE_PROJECT_NAME`).