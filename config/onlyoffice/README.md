# ONLYOFFICE Docs 8.3.3 — конфигурация

## 1. Почему здесь нет `local.json`

Сознательное решение (согласовано с Lead): **файл конфигурации толькоoffice не
поставляется из репозитория и не монтируется в контейнер.**

Причины:

1. **Entrypoint перезаписывает файл.** `/app/ds/run-document-server.sh` при
   каждом старте выполняет `json -I -e ...` по
   `/etc/onlyoffice/documentserver/local.json`, вписывая туда JWT-секрет из
   `ONLYOFFICE_JWT_SECRET`, настройки БД и очередь. Если смонтировать файл
   из репозитория **ro**, запись не произойдёт и JWT перестанет работать
   (редактор откроется, документ — нет). Если смонтировать **rw**, секрет
   окажется записанным в git-файл.
2. **Файл должен быть полным, а не частичным.** Entrypoint читает
   `local.json` (а не слитый с `default.json`) и берёт оттуда
   `services.CoAuthoring.sql.*` и `rabbitmq.url`. Частичный файл без этих
   секций приведёт к зависанию на ожидании «внешней» БД/очереди.
3. **Все нужные настройки уже покрыты переменными окружения** (см. §2),
   которые задаёт `docker-compose.yml`.

Итог: источник истины — `environment:` сервиса `onlyoffice` в
`docker-compose.yml` плюс `.env`. Каталог `config/onlyoffice/` остаётся в
репозитории как место для документации и **не** монтируется.

## 2. Что настраивается переменными окружения

| Переменная | Значение в стеке | Что делает |
|---|---|---|
| `JWT_ENABLED` | `true` | включает проверку JWT (browser/inbox/outbox) |
| `JWT_SECRET` | `${ONLYOFFICE_JWT_SECRET}` | общий секрет с коннектором Nextcloud |
| `JWT_HEADER` | `${ONLYOFFICE_JWT_HEADER:-Authorization}` | заголовок с токеном |
| `JWT_IN_BODY` | `${ONLYOFFICE_JWT_IN_BODY:-true}` | разрешает токен в теле запроса |
| `DS_LOG_LEVEL` | не задан → `WARN` | уровень логов DS (берётся из `log4js/production.json`) |
| `ALLOW_PRIVATE_IP_ADDRESS` | **нужно проверить** (см. §4) | разрешает DS обращаться к приватным IP |
| `ALLOW_META_IP_ADDRESS` | `false` (по умолчанию) | запрет 169.254.0.0/16 |
| `WOPI_ENABLED` | `false` (по умолчанию) | WOPI-режим (не используется) |
| `GENERATE_FONTS` | `true` | переиндексация шрифтов при старте |

Полный список — в официальной документации («Changing the default ONLYOFFICE
Docs parameters»). Порт 80 внутри контейнера задан образом
(`/etc/onlyoffice/documentserver/nginx/ds.conf`), менять его не нужно: NPM
проксирует `http://onlyoffice:80`.

## 3. Как посмотреть/изменить параметры «на живую» (без сохранения)

```bash
# эффективная конфигурация (после entrypoint-правок)
docker compose exec onlyoffice cat /etc/onlyoffice/documentserver/local.json

# прочитать один параметр
docker compose exec onlyoffice \
  /var/www/onlyoffice/documentserver/npm/json -f /etc/onlyoffice/documentserver/local.json \
  services.CoAuthoring.token.enable.browser

# изменить в контейнере (времено, до пересоздания контейнера)
docker compose exec onlyoffice \
  /var/www/onlyoffice/documentserver/npm/json -I -f /etc/onlyoffice/documentserver/local.json \
  -e "this.services.CoAuthoring.server.callbackRequestTimeout.wholeCycle='30m'"
docker compose restart onlyoffice
```

Изменения **не переживут** `docker compose down/up` (файл внутри контейнера).
Если правка нужна постоянно — она должна стать переменной окружения
(`.env` + `docker-compose.yml`, зона Lead) либо отдельным решением Lead о
монтировании **рабочей копии** файла из `data/` (не из репозитория).

## 4. Важно для этой архитектуры: приватный IP Nextcloud

В `docker-compose.yml` у сервиса `onlyoffice` есть

```yaml
extra_hosts:
  - "${CLOUD_DOMAIN}:${PROXY_IP:-172.28.10.10}"
```

то есть DS резолвит `cloud.example.com` в **приватный** адрес NPM.
By default ONLYOFFICE Docs блокирует скачивание документов с приватных адресов
(SSRF-защита, `request-filtering-agent`), поэтому для этой схемы сервису нужен

```yaml
environment:
  ALLOW_PRIVATE_IP_ADDRESS: "true"
```

Без этого симптом такой: редактор открывается, но документ не загружается, а в
`/var/log/onlyoffice/documentserver/docservice/err.log` появляется ошибка
скачивания (`download error`). Альтернатива — убрать `extra_hosts` у
`onlyoffice` и ходить на публичный IP (зависит от hairpin-NAT провайдера),
что менее предсказуемо.

Риск от `ALLOW_PRIVATE_IP_ADDRESS=true`: DS сможет обращаться к приватным
адресам. В этом стенде URL всегда формирует Nextcloud (WOPI + JWT), внешний
пользователь их не задаёт, поэтому риск принят осознанно.

## 5. Логи и диагностика

| Что | Где |
|---|---|
| DocService | `docker compose exec onlyoffice tail -n 100 /var/log/onlyoffice/documentserver/docservice/out.log` (и `err.log`) |
| Converter | `/var/log/onlyoffice/documentserver/converter/{out,err}.log` |
| nginx DS | `docker compose exec onlyoffice tail -n 100 /var/log/nginx/error.log` |
| healthcheck | `docker compose exec onlyoffice curl -fsS http://127.0.0.1/healthcheck` → `true` |
| уровень логов | `log4js/production.json` внутри контейнера, по умолчанию `WARN` |

Ротация: том `onlyoffice_logs`, logrotate внутри контейнера
(`/etc/logrotate.d/`, ежедневно); ограничение размера docker-логов задано в
`x-logging` (`max-size: 20m`, `max-file: 5`).

## 6. Проверка JWT

```bash
# секрет внутри контейнера должен совпадать с ONLYOFFICE_JWT_SECRET из .env
docker compose exec onlyoffice \
  /var/www/onlyoffice/documentserver/npm/json -f /etc/onlyoffice/documentserver/local.json \
  services.CoAuthoring.secret.inbox.string

# включённые проверки: browser/inbox/outbox должны быть true
docker compose exec onlyoffice \
  /var/www/onlyoffice/documentserver/npm/json -f /etc/onlyoffice/documentserver/local.json \
  services.CoAuthoring.token.enable
```

Секрет в выводе — это нормально (контейнер), но **не** копируйте его в тикеты,
логи и git.
