# 11. Диагностика и устранение неисправностей

Документ — для администратора. Все команды выполняются из каталога репозитория на
сервере. Если контейнеры не запущены, начните с `make status` и `make doctor`.

## 1. Порядок действий

```bash
cd /opt/cloudsuite

# 1. что вообще происходит
make status
./scripts/healthcheck.sh

# 2. состояние контейнеров и последние логи
docker compose ps
make logs            # или: docker compose logs --tail=200 <service>

# 3. ресурсы
df -h /; free -m; docker stats --no-stream

# 4. проверка снаружи
curl -sSI "https://$CLOUD_DOMAIN/status.php" | head -n 5
curl -sS  "https://$CLOUD_DOMAIN/status.php" | jq .
```

Здоровый `/status.php` возвращает JSON с `"installed":true`, `"maintenance":false`
и корректным `versionstring`. Если этот эндпоинт отвечает, значит цепочка
NPM → web → app → БД жива, и проблема локальна (файлы, офис, права).

## 2. Где смотреть логи

| Что | Путь на хосте | Внутри контейнера |
|---|---|---|
| Nginx (JSON-доступ) | `logs/nginx/access.json.log` | `/var/log/nginx/access.json.log` |
| Nginx (ошибки) | `logs/nginx/error.log` | `/var/log/nginx/error.log` |
| Nextcloud | `logs/cloudsuite/nextcloud.log` | `/var/log/cloudsuite/nextcloud.log` |
| Аудит | `logs/cloudsuite/audit.log` | `/var/log/cloudsuite/audit.log` |
| ONLYOFFICE | том `onlyoffice_logs` | `/var/log/onlyoffice/` |
| PostgreSQL | `docker compose logs db` | — |
| Redis | `docker compose logs cache` | — |
| SeaweedFS | `docker compose logs s3` | — |
| NPM | `docker compose logs proxy` | — |

Полезные срезы:

```bash
# только ошибки nginx
tail -n 500 logs/nginx/error.log

# 5xx в JSON-логе
jq -c 'select(.status >= 500)' logs/nginx/access.json.log | tail -n 20

# ошибки Nextcloud
docker compose exec -T app tail -n 100 /var/www/html/data/nextcloud.log | jq -c 'select(.level >= 3)'

# PostgreSQL
docker compose logs --tail=100 db
```

## 3. 502 Bad Gateway

**Симптом:** страница NPM «502 Bad Gateway», в браузере пустой экран.

**Причины и проверки (по порядку):**

```bash
# 1) запущен ли web и app
docker compose ps web app
docker compose logs --tail=100 web
docker compose logs --tail=100 app

# 2) отвечает ли nginx внутри сети (обходим NPM)
docker compose exec -T web wget -qO- http://127.0.0.1:8080/healthz

# 3) работает ли PHP в контейнере app
docker compose exec -T app php -r 'echo PHP_VERSION, PHP_EOL;'

# 4) не переполнен ли диск/память
df -h /; free -m
```

**Типичные причины:**

* `app` перезапускается (OOM): `docker inspect -f '{{.State.OOMKilled}}' $(docker compose ps -q app)`
  → увеличить RAM ВМ, уменьшить число PHP-воркеров или `PHP_MEMORY_LIMIT`;
* СУБД недоступна: в логе `app` — `SQLSTATE[08006]`, `could not connect to server`;
* nginx не может достучаться до `app:9000` (сеть/имя): проверить
  `docker compose exec -T web getent hosts app`;
* ошибка конфигурации nginx: `docker compose exec -T web nginx -t`.

**Быстрое лечение:** `docker compose restart app web`. Если не помогло —
смотреть `logs/nginx/error.log` и `nextcloud.log`.

## 4. 504 Gateway Timeout

**Симптом:** долгая загрузка/скачивание обрывается 504.

**Причины:**

* большой файл и таймаут в NPM меньше, чем нужно: в Advanced-конфиге proxy host
  должны быть `proxy_read_timeout 3600s`, `proxy_send_timeout 3600s`,
  `client_max_body_size` = `PHP_UPLOAD_LIMIT`;
* `fastcgi_read_timeout` в `web` меньше времени обработки (для импорта/скана
  файлов нужно до 3600 с);
* долгий запрос к S3 при недоступном хранилище.

**Проверка:**

```bash
docker compose exec -T proxy grep -R "proxy_read_timeout" /data/nginx 2>/dev/null | head
grep -R "fastcgi_read_timeout" config/nginx/ | head
```

**Лечение:** привести таймауты к значениям из `config/proxy/*-advanced.conf` и
перезапустить `proxy`; при зависшем S3 — перезапустить `s3` (см. п. 7).

## 5. 413 Request Entity Too Large

**Симптом:** загрузка файла больше 1–2 ГБ отклоняется.

**Причина:** рассинхрон трёх лимитов: nginx `client_max_body_size`, PHP
`upload_max_filesize`/`post_max_size` и лимит приложения.

```bash
grep -n "client_max_body_size" config/nginx/nginx.conf config/nginx/conf.d/*.conf config/nginx/snippets/*.conf
docker compose exec -T app php -i | grep -E 'upload_max_filesize|post_max_size|memory_limit'
grep -E '^(PHP_UPLOAD_LIMIT|PHP_MEMORY_LIMIT)=' .env
```

**Лечение:** выставить `PHP_UPLOAD_LIMIT` в `.env` (например `10G`),
убедиться, что nginx-конфиг получает это значение и что PHP подхватывает
`config/nextcloud/php.ini`; затем `docker compose up -d web app`. Проверить в
NPM Advanced-конфиге, что `client_max_body_size` тоже задан.

## 6. 500 Internal Server Error

**Симптом:** белая страница/ошибка 500, вход не выполняется.

**Проверки:**

```bash
# 1) последние ошибки приложения
docker compose exec -T app tail -n 200 /var/www/html/data/nextcloud.log | jq -c 'select(.level >= 3)'

# 2) БД
docker compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'select count(*) from oc_users;'

# 3) Redis
docker compose exec -T cache redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping

# 4) S3
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8333/" || true

# 5) права на data
docker compose exec -T app ls -ld /var/www/html/data
```

**Частые причины:**

* PostgreSQL упал или переполнен диск → поднять, проверить `df -h`;
* Redis с неверным паролем: в логе `NOAUTH`/`WRONGPASS` → сверить
  `REDIS_PASSWORD` и `config/redis/redis.conf`;
* включён режим обслуживания: `./scripts/occ.sh maintenance:mode --off`;
* нехватка места в томе `nextcloud_data` или `s3_data`;
* ошибка приложения после обновления — смотреть стектрейс в `nextcloud.log`.

## 7. Проблемы S3 / SeaweedFS

### 7.1 NoSuchBucket

```bash
# логи одноразового создателя бакета
docker compose logs --tail=100 s3-init

# какое имя бакета ожидается
grep -E '^S3_BUCKET=' .env

# отвечает ли S3 API внутри backend-сети
docker compose exec -T app wget -qO- http://s3:8333/ 2>&1 | head -n 3
```

**Причина:** бакет не создан (одноразовый `s3-init` не выполнился) или создан с
другим именем. **Лечение:** `make bootstrap` повторно (идемпотентно) или
`docker compose up -d s3-init`, затем проверить логи. Не переименовывайте бакет
после старта Nextcloud — данные станут недоступны.

### 7.2 AccessDenied / InvalidAccessKeyId

```bash
# ключи в .env заданы и непустые
grep -E '^(S3_ACCESS_KEY|S3_SECRET_KEY|S3_BUCKET)=' .env | sed 's/\(KEY=\|SECRET_KEY=\).*/\1<set>/'

# что реально видит Nextcloud
docker compose exec -T app printenv | grep -E '^OBJECTSTORE_S3_(KEY|SECRET|BUCKET|HOSTNAME|PORT)' | sed 's/\(SECRET=\).*/\1<set>/'

# пересоздать identity и бакет из .env (идемпотентно)
docker compose up -d --force-recreate s3-init
docker compose logs --tail=50 s3-init
```

**Причина:** ключи в `.env` не совпадают с identity в SeaweedFS (например, `.env`
правили после первого запуска). Файла `s3.json` в репозитории нет: identity
создаёт сервис `s3-init` командами `s3.configure` и `s3.bucket.create`.
**Лечение:** `docker compose up -d --force-recreate s3-init`, затем
`docker compose restart app cron`.

### 7.3 S3 отвечает, но медленно или с ошибками 503

* проверить место: `df -h` и `docker compose exec -T s3 df -h /data`;
* проверить логи `docker compose logs --tail=200 s3` (частые `volume not found`,
  `no free volumes`);
* при слишком малом `SEAWEEDFS_VOLUME_SIZE_MB` загрузки дробятся на много объектов —
  не критично, но увеличивает накладные расходы;
* **не поднимайте `SEAWEEDFS_VOLUME_SIZE_MB` выше 30720**: master падает с ошибкой
  `master.volumeSizeLimitMB should not exceed 30720` (значение по умолчанию — 30720,
  то есть 30 ГиБ);
* перезапуск `docker compose restart s3` безопасен: метаданные и объекты на томе.

### 7.5 Nextcloud не подключается к S3 (SSL/TLS)

Внутренний S3 работает по HTTP, поэтому в compose у `app` задано
`OBJECTSTORE_S3_SSL: "false"`. Образ Nextcloud читает именно
`OBJECTSTORE_S3_SSL` (не `OBJECTSTORE_S3_USE_SSL`); если переменную переименовать,
хранилище молча уйдёт на HTTPS и файлы перестанут читаться. Проверка:

```bash
docker compose exec -T app printenv | grep OBJECTSTORE_S3_SSL
docker compose exec -T app grep -i 'use_ssl' /var/www/html/config/config.php | head -n 3
```

### 7.4 Прямая проверка кластера SeaweedFS

```bash
# статус master изнутри backend-сети
docker compose exec -T s3 wget -qO- http://127.0.0.1:9333/cluster/status | head
```

## 8. Redis и блокировки файлов

**Симптом:** «File is locked», «Redis connection refused», ошибки при загрузке.

```bash
docker compose exec -T cache redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
docker compose exec -T cache redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info clients | head
docker compose exec -T app php -r 'echo extension_loaded("redis") ? "redis ext OK\n" : "NO redis ext\n";'
```

**Лечение:**

* `NOAUTH`/`WRONGPASS` — пароль в `.env` и `config/redis/redis.conf`
  должны совпадать; после правки: `docker compose up -d cache app cron`;
* «file is locked» после падения `app` — блокировка с TTL истечёт сама (обычно
  до 30 минут); принудительно: `./scripts/occ.sh maintenance:repair` и перезапуск;
* потеря Redis не критична: кэш и блокировки пересоздаются, файлы не страдают.

## 9. PostgreSQL

```bash
docker compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c 'select version();'
docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c \
  "select count(*), state from pg_stat_activity group by state;"
docker compose logs --tail=100 db
```

| Симптом | Причина | Действие |
|---|---|---|
| `too many connections` | мало `max_connections` или утечка соединений | увеличить лимит, перезапустить `app` |
| долгие транзакции, блокировки | зависший запрос | найти в `pg_stat_activity`, при необходимости `pg_terminate_backend` |
| `No space left on device` | диск | освободить место, проверить том `db_data` |
| не стартует после смены пароля | том `db_data` инициализирован старым паролем | менять пароль через `ALTER USER`, а не только в `.env` |

## 10. Диск заполнен

```bash
df -h /
du -sh data logs backups 2>/dev/null
docker system df
```

Что делать:

1. очистить старые бэкапы: `ls -lt backups | tail`, удалить лишние (соблюдая
   `BACKUP_RETENTION_DAYS`);
2. ротировать логи: `logs/nginx/*.log` и архивы журналов (см.
   [05-audit-logging.md](05-audit-logging.md)); `audit.log` и `nextcloud.log`
   ротируются встроенным механизмом Nextcloud;
3. очистить корзины пользователей: `./scripts/occ.sh trashbin:cleanup --all-users`;
4. удалить неиспользуемые образы: `docker image prune`;
5. если растёт том `s3_data` — это данные пользователей: расширять диск/том, а не
   удалять.

`Никогда` не удаляйте файлы из `s3_data` напрямую — S3 потеряет индекс.

## 11. Сертификаты и TLS

**Симптом:** браузер показывает истёкший сертификат, Let's Encrypt не выпускается.

```bash
# что отдаёт сервер
echo | openssl s_client -servername "$CLOUD_DOMAIN" -connect "$CLOUD_DOMAIN":443 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates

# доступность ACME извне (порт 80)
curl -sI "http://$CLOUD_DOMAIN/.well-known/acme-challenge/test" | head -n 3

# логи NPM
docker compose logs --tail=200 proxy
```

Причины: A-запись не на этот сервер; порт 80 закрыт firewall; домен уже имеет
активный лимит Let's Encrypt; неверный e-mail. **Лечение:** исправить DNS/фаервол,
в NPM нажать «Renew Certificate»; при устойчивой ошибке — временно выпустить
сертификат другим методом или использовать самоподписанный на время разбора.

## 12. ONLYOFFICE

### 12.1 Документ не открывается («Download failed»)

Редактор запустился, но файл не загрузился в Document Server.

```bash
# доступен ли cloud.example.com из контейнера onlyoffice
docker compose exec -T onlyoffice sh -c 'curl -sS -o /dev/null -w "%{http_code}\n" https://cloud.example.com/status.php'

# резолвится ли имя во внутренний IP NPM (extra_hosts)
docker compose exec -T onlyoffice getent hosts cloud.example.com

# логи DS
docker compose logs --tail=200 onlyoffice
# файлы DS лежат в томе onlyoffice_logs
docker compose exec -T onlyoffice tail -n 50 /var/log/onlyoffice/documentserver/docservice/err.log
```

**Причины:**

* из контейнера `onlyoffice` не резолвится или недоступен `$CLOUD_DOMAIN` →
  проверить `extra_hosts` и что NPM слушает 443 на `172.28.10.10`;
* сертификат сайта не доверен внутри контейнера (самоподписанный) — использовать
  валидный сертификат Let's Encrypt;
* JWT не совпадает: DS отклоняет конфиг (в логах `invalid token`);
* **самая частая причина:** DS блокирует скачивание с приватных IP. В этой схеме
  `extra_hosts` указывает `$CLOUD_DOMAIN` на приватный адрес NPM
  (`172.28.10.10`), поэтому в `docker-compose.yml` у сервиса `onlyoffice` задано
  `ALLOW_PRIVATE_IP_ADDRESS: "true"`. Если эту переменную убрать или переопределить,
  редактор открывается, но документ не загружается, а в
  `/var/log/onlyoffice/documentserver/docservice/err.log` появляется сообщение о
  запрещённом адресе. Проверить и включить:

  ```bash
  docker compose exec -T onlyoffice printenv | grep -i ALLOW_PRIVATE_IP_ADDRESS
  docker compose exec -T onlyoffice tail -n 100 /var/log/onlyoffice/documentserver/docservice/err.log
  ```

### 12.2 JWT-ошибки

```bash
grep -E '^ONLYOFFICE_JWT_SECRET=' .env | sed 's/=.*/=<set>/'
./scripts/occ.sh config:app:get onlyoffice jwt_secret | head -c 8; echo "…"
docker compose exec -T onlyoffice printenv | grep -i jwt | sed 's/=.*/=<set>/'
```

Секрет в `.env`, в настройках коннектора и в окружении контейнера должен быть
одинаковым. После смены: `docker compose up -d onlyoffice` и обновление настроек
коннектора Nextcloud (/settings/admin/onlyoffice).

### 12.3 Ко-редактирование «отваливается»

* WebSocket включается **переключателем** «Websockets Support» на вкладке Details
  proxy host `office.example.com`. В Advanced-конфиге `proxy_set_header` на
  server-level бесполезен: NPM 2.16.0 подключает свой `include proxy.conf` внутри
  `location /`, и его заголовки перебивают server-level. Заголовки `Host`,
  `X-Forwarded-Proto`, `X-Forwarded-For`, `X-Real-IP` NPM отдаёт сам;
* таймауты в Advanced (`proxy_read_timeout 3600s`, `proxy_send_timeout 3600s`)
  должны быть на месте — иначе долгие сессии редактирования обрываются;
* проверить в браузере DevTools → Network → WS: соединение
  `wss://office.example.com/...` должно быть 101 Switching Protocols;
* корпоративный прокси/антивирус может рвать WS — проверить из другой сети.

### 12.4 «The document could not be saved»

* DS не может вызвать callback на `cloud.example.com` (см. 12.1);
* истёк или недействителен JWT для callback;
* на сервере нет места или ошибка S3 — проверить `nextcloud.log` и логи
  ONLYOFFICE.

## 13. NPM и маршрутизация

| Симптом | Проверка | Лечение |
|---|---|---|
| 502 от NPM | `docker compose logs proxy`, доступность upstream | проверить имя сервиса и порт в proxy host (`web:8080`, `onlyoffice:80`) |
| «Welcome to nginx» вместо Nextcloud | proxy host указывает не туда или перехвачен default | исправить upstream, удалить лишние hosts |
| Неизвестный Host → 444 | так и должно быть (защита) | использовать правильный домен |
| Нет доступа к GUI NPM | порт привязан к `127.0.0.1:8181` | SSH-туннель: `ssh -L 8181:127.0.0.1:8181 root@server` |
| Правки в Advanced не применяются | не сохранены или NPM не перезапущен | сохранить, `docker compose restart proxy` |

## 14. Nextcloud: обслуживание и обновления

```bash
# режим обслуживания
./scripts/occ.sh maintenance:mode --on
./scripts/occ.sh maintenance:mode --off
./scripts/occ.sh status

# после обновления
./scripts/occ.sh upgrade
./scripts/occ.sh maintenance:repair

# фоновые задачи
./scripts/occ.sh background-job:list
```

| Симптом | Причина | Действие |
|---|---|---|
| «System is in maintenance mode» | не выключили после обновления | `occ maintenance:mode --off` |
| «Update needed» после рестарта | образ новее схемы БД | `occ upgrade` |
| background jobs не идут | `cron` не запущен | `docker compose ps cron`, логи |
| «App update is required» | несовместимое приложение | `occ app:update --all` |

## 15. Файлы, права, конфликты

```bash
# пересканировать файлы (после восстановления из бэкапа или ручных операций)
./scripts/occ.sh files:scan --all

# проверить конкретного пользователя
./scripts/occ.sh files:scan --path="/ivanov/files"

# проверить права на data
docker compose exec -T app ls -ld /var/www/html/data
docker compose exec -T app ls -l /var/www/html/data/ivanov/files | head
```

Конфликтные копии (conflicted copy) не удаляются автоматически — это нормальное
поведение, разбирает пользователь. Массовые конфликты обычно означают проблемы
со временем на клиенте или несколько клиентов на одну папку.

## 16. Клиенты

| Симптом | Причина | Действие |
|---|---|---|
| «Ошибка синхронизации 401» | истёк пароль приложения | создать новый пароль приложения |
| «413» при синхронизации большого файла | лимит размера | см. п. 5 |
| «SSL handshake failed» | самоподписанный/невалидный сертификат | использовать валидный сертификат |
| Медленная синхронизация | много мелких файлов | уменьшить число папок, проверить канал |
| Клиент показывает «нет прав» | нет прав на запись в шару | проверить права шары |

## 17. Аудит

```bash
# последние события
./scripts/audit-report.sh --from "$(date -d '-1 day' +%F)"

# неуспешные входы (тип действия в NC 35 закодирован в тексте message)
jq -c 'select(.message | startswith("Login failed")) | {time, remoteAddr, message}' \
  logs/cloudsuite/audit.log | tail -n 20

# действия администратора: создание пользователей и групп
jq -r 'select(.message | test("User created|Group created|added to group")) | [.time, .user, .message] | @tsv' \
  logs/cloudsuite/audit.log | tail -n 20

# только сводка по типам (поле action в NC 35 отсутствует, поэтому смотрите message)
./scripts/audit-report.sh --from "$(date -d '-7 day' +%F)" --limit 200 | head -n 30
```

Учтите: в Nextcloud 35 запись `admin_audit` не содержит поля `action` — действие
закодировано в `message` (см. [05-audit-logging.md](05-audit-logging.md#2-формат-записи-аудита)).
Поэтому фильтр `--action` у `audit-report.sh` срабатывает только для записей, где
это поле всё же присутствует (критические действия); для остального используйте
`jq`-рецепты выше.

Если `logs/cloudsuite/audit.log` пуст: проверить, что приложение `admin_audit`
включено (`./scripts/occ.sh app:list | grep admin_audit`), что в конфиге задан
`logfile_audit = /var/log/cloudsuite/audit.log` и что каталог `logs/cloudsuite`
доступен контейнеру на запись (владелец `33:33`, права 0750).

## 18. Что приложить к обращению в поддержку

1. время инцидента с часовым поясом;
2. `make status` и полный вывод `./scripts/healthcheck.sh`;
3. `docker compose ps`;
4. релевантные строки `logs/nginx/error.log`, `logs/cloudsuite/nextcloud.log`
   и `docker compose logs --tail=200 onlyoffice`;
5. что делал пользователь и с каким файлом;
6. изменения конфигурации за последние сутки.

Не прикладывайте к обращениям `.env`, дампы БД и содержимое файлов
пользователей. Секреты и персональные данные передаются только по защищённому
каналу в соответствии с политикой ИБ.

## 19. Конфликт подсетей Docker и VPN

**Симптом:** `make up` падает с ошибкой
`invalid pool request: Pool overlaps with other one on this address space`,
или контейнеры поднимаются, но не видят друг друга.

**Причина:** подсети `edge` (`172.28.10.0/24`) и `backend` (`172.28.20.0/24`)
пересекаются с уже существующими docker-сетями на хосте или с маршрутами VPN
(частый случай — корпоративный VPN на 172.16–172.31).

**Диагностика:**

```bash
docker network ls
docker network inspect $(docker network ls -q) --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}'
ip route | grep 172.28
```

**Лечение:** выбрать свободные подсети и согласованно поменять их в
`docker-compose.yml`, `.env` и конфигурации Nextcloud:

1. в `docker-compose.yml` — `ipam.config[].subnet` для сетей `edge` и `backend`
   (например, `172.30.10.0/24` и `172.30.20.0/24`);
2. в `.env` — `PROXY_IP=172.30.10.10` (фиксированный адрес NPM) и
   `TRUSTED_PROXIES=172.30.10.0/24`;
3. `docker compose down` (тома сохраняются), затем `make up`;
4. применить `make configure`, чтобы `trusted_proxies` в Nextcloud обновился;
5. проверить: `docker compose exec -T app wget -qO- http://web:8080/healthz`.

На живом стенде этот конфликт реально возникал и решался переносом на
`172.30.10.0/24` / `172.30.20.0/24`. Не меняйте подсети «на ходу» без
предварительного `make backup`.

## 20. Связанные документы

* [02-deployment.md](02-deployment.md) — установка и первичная настройка.
* [03-security-hardening.md](03-security-hardening.md) — безопасность.
* [07-backup-restore-dr.md](07-backup-restore-dr.md) — восстановление.
* [09-operations-runbook.md](09-operations-runbook.md) — регламентные работы.
* [12-acceptance-checklist.md](12-acceptance-checklist.md) — приёмка.

