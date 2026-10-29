# Лицензии образов Cloud Suite

Документ фиксирует лицензионную модель **всех** контейнерных образов, которые
использует проект, и доказывает, что стек не требует покупки лицензий,
подписок или лицензионных ключей. Проверяется автоматически:
`tests/validate.py` (раздел `licenses`) сверяет таблицу с `image:` в compose-файлах
и падает, если появился образ вне списка или тег платной редакции.

## Сводная таблица

| Компонент | Образ | Лицензия (SPDX) | Платно / ключ | Источник |
|---|---|---|---|---|
| Файловый сервис | `nextcloud:35.0.2-fpm` | AGPL-3.0 | нет | https://github.com/nextcloud/server/blob/master/COPYING |
| База данных | `postgres:17.11-alpine` | PostgreSQL License | нет | https://www.postgresql.org/about/licence/ |
| Кэш и блокировки | `redis:8.4.7-alpine` | AGPL-3.0 (тройная: RSALv2 / SSPLv1 / AGPL-3.0) | нет | https://github.com/redis/redis/blob/unstable/LICENSE.txt |
| Объектное хранилище S3 | `chrislusf/seaweedfs:latest` | Apache-2.0 | нет | https://github.com/seaweedfs/seaweedfs/blob/master/LICENSE |
| Web-tier | `nginx:1.29-alpine` | BSD-2-Clause | нет | https://nginx.org/LICENSE |
| Обратный прокси + GUI | `jc21/nginx-proxy-manager:2.16.0` | MIT | нет | https://github.com/NginxProxyManager/nginx-proxy-manager/blob/develop/LICENSE |
| Офис (редактор) | `onlyoffice/documentserver:8.3.3` | AGPL-3.0 (Community Edition) | нет | https://github.com/ONLYOFFICE/DocumentServer/blob/master/LICENSE |
| Наблюдаемость (опция) | `grafana/loki:3.5.1` | AGPL-3.0 | нет | https://github.com/grafana/loki/blob/main/LICENSE |
| Наблюдаемость (опция) | `grafana/promtail:3.5.1` | AGPL-3.0 | нет | https://github.com/grafana/loki/blob/main/LICENSE |

Все лицензии выше — OSI-approved (кроме тройной модели Redis, где выбран вариант
AGPL-3.0). Ни один образ не является trial, «community с ограничением по
подключениям, требующим покупки», или enterprise-редакцией.

## Что сознательно НЕ используется

| Платная редакция | Почему не подходит |
|---|---|
| `onlyoffice/documentserver-ee` (Enterprise) | требует коммерческой лицензии |
| `nextcloud:*-enterprise` / Nextcloud Enterprise | подписка |
| `nginx:plus` / NGINX Plus | подписка |
| Nginx Proxy Manager Pro / Cloud | подписка |
| Redis Enterprise / Redis Stack Pro | подписка |

В compose-файлах запрещены теги/образы с `-ee`, `enterprise`, `plus`,
`-pro`, `trial`; валидатор это проверяет.

## Служебные образы инструментов (не входят в рантайм-стек)

Эти образы запускаются только на время операции и не являются частью рабочего
стека. Они тоже свободные и не требуют лицензий/ключей.

| Образ | Где используется | Лицензия | Примечание |
|---|---|---|---|
| `alpine:3.20` | `scripts/ip-callback-route.sh` (режим белого IP) | Alpine Linux: свободные лицензии пакетов (MIT / BSD / GPL / Apache-2.0 и др.) | одноразовый init-контейнер: ставит `iptables` и добавляет DNAT-правило внутри netns ONLYOFFICE |

## Обязательства AGPL-3.0 (Nextcloud, ONLYOFFICE, Redis, Loki)

Для внутренней эксплуатации (сотрудники организации, без публикации наружу)
AGPL не накладывает дополнительных обязанностей: код не распространяется.
Если вы **модифицируете** AGPL-компонент и предоставляете к нему сетевой доступ
третьим лицам, изменения нужно опубликовать (AGPL §13). Ссылки на исходники —
в таблице выше; версии закреплены тегами в `.env`.

## Альтернативы с пермиссивными лицензиями (не используются)

Если политика организации запрещает AGPL-подобные лицензии, проект допускает
замену без изменения архитектуры (решение зафиксировано: текущий набор оставлен):

* **Redis → Valkey** (`valkey/valkey:8.1-alpine`, BSD-3-Clause, Linux Foundation):
  drop-in замена — тот же протокол, конфиг и ACL; меняется только образ и
  команда запуска.
* **ONLYOFFICE Docs → Collabora Online (CODE)** (`collabora/code`, MPL-2.0,
  на базе LibreOffice): требует замены коннектора `onlyoffice` на
  `richdocuments` и настройки WOPI вместо JWT.

Обе замены затрагивают compose, `scripts/configure-nextcloud.sh`, документацию и
приёмочные проверки, поэтому выполняются отдельной задачей.

## Как поддерживать таблицу

1. Меняя образ в любом `docker-compose*.yml`, обновите строку в таблице.
2. `python3 tests/validate.py` (или `make test`) — раздел `licenses` покажет
   расхождение: образ без строки в таблице, строка без образа, запрещённый тег.
3. Новые образы допускаются только с лицензией OSI-approved и без лицензионных
   ключей; для AGPL-компонентов добавьте ссылку на исходники.
