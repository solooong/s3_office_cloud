# web tier — nginx 1.29 front controller (Nextcloud 35)

Операторские заметки к каталогу `config/nginx`. Архитектура и поток запросов —
в `CONTRACT.md` (раздел 5) и `docs/01-architecture.md`.

## 1. Файлы

| Файл | Роль |
|---|---|
| `nginx.conf` | http-уровень: JSON access log, gzip, транспортные таймауты, resolver Docker DNS, включение `conf.d/*.conf` |
| `conf.d/00-default-server.conf` | guard-сервер `default_server` на :8080: неизвестный Host → `444`; `/healthz` → 200; `/status` → stub_status (только 127.0.0.1) |
| `conf.d/10-nextcloud.conf` | виртуальный хост Nextcloud: PHP-FPM `app:9000`, статика, well-known, `.php`-роутинг, запреты |
| `snippets/realip.conf` | доверенный прокси NPM (172.28.10.0/24) → реальный IP клиента |
| `snippets/security-headers.conf` | hardening-заголовки (без HSTS/CSP/COEP — см. §5) |
| `snippets/block-sensitive.conf` | 404 на `/data` `/config` `/lib` `/db_storage` `/3rdparty` `/templates` `/tests`, dotfiles, `/occ` |
| `snippets/static-cache.conf` | immutable-кеш для `/core` `/apps` `/dist` `/build` и статических расширений |
| `snippets/fastcgi-nextcloud.conf` | FastCGI: `SCRIPT_FILENAME`, `PATH_INFO`, `HTTPS`, `SERVER_NAME`, `X-Forwarded-*`, таймауты 3600s, `fastcgi_request_buffering off` |
| `snippets/upload-limit.conf` | статический дефолт `client_max_body_size 10G` (страховка, если шаблон не отрендерен) |
| `templates/cloudsuite/upload-limit.conf.template` | `client_max_body_size ${PHP_UPLOAD_LIMIT};` — рендерится в `/var/run/cloudsuite/` и подключается на уровне server |
| `templates/cloudsuite/server-names.conf.template` | `server_name ${CLOUD_DOMAIN} ${OFFICE_DOMAIN};` — тот же механизм |

## 2. Монтирование (ровно как в `docker-compose.yml`)

```
./config/nginx/nginx.conf  -> /etc/nginx/nginx.conf   ro
./config/nginx/conf.d      -> /etc/nginx/conf.d       ro
./config/nginx/snippets    -> /etc/nginx/snippets     ro
./config/nginx/templates   -> /etc/nginx/templates    ro   (источник envsubst)
logs/nginx                 -> /var/log/nginx          rw   (uid 101 = nginx)
```

Каталог `conf.d` монтируется **только целиком** (не отдельными файлами): официальный
entrypoint рендерит шаблоны в `$NGINX_ENVSUBST_OUTPUT_DIR`, поэтому в compose
задано `NGINX_ENVSUBST_OUTPUT_DIR=/var/run` (tmpfs). Если оставить значение по
умолчанию (`/etc/nginx/conf.d`), запись в ro-каталог завершит старт контейнера
ошибкой `Read-only file system`.

## 3. Переменные окружения сервиса `web`

| Переменная | Назначение |
|---|---|
| `CLOUD_DOMAIN` | имя, добавляемое в `server_name` (рендер шаблона) |
| `OFFICE_DOMAIN` | второе имя (server-side callbacks ONLYOFFICE) |
| `PHP_UPLOAD_LIMIT` | `client_max_body_size` (server level), должно совпадать с PHP |
| `NGINX_ENVSUBST_TEMPLATE_DIR` | `/etc/nginx/templates` |
| `NGINX_ENVSUBST_OUTPUT_DIR` | `/var/run` (tmpfs, writable) |

Если `CLOUD_DOMAIN`/`OFFICE_DOMAIN` не заданы, nginx **не стартует** (в конфиг
попадёт литерал `${CLOUD_DOMAIN}`) — это осознанный fail-fast.

## 4. JSON access log

Файл `/var/log/nginx/access.json.log`, формат `json_combined` (`escape=json`),
одна строка — один запрос. Поля (стабильные, используются в
`docs/05-audit-logging.md`):

`time, remote_addr, x_forwarded_for, realip_remote_addr, host, server_port,
scheme, request_method, uri, request_uri, protocol, status, body_bytes_sent,
request_length, request_time, upstream_addr, upstream_status,
upstream_response_time, http_referer, http_user_agent, request_id`

* `remote_addr` — реальный IP клиента (после `realip`), `realip_remote_addr` —
  адрес, с которого пришёл запрос (NPM, 172.28.10.x);
* `uri` — URI после внутренних rewrite (`/index.php`), `request_uri` — то, что
  запросил клиент;
* `status` / `body_bytes_sent` / `request_time` — числа, остальное строки.

Запись буферизуется (`buffer=64k flush=1s`): последние ~1 с может отсутствовать
в файле, это нормально.

## 5. Осознанные решения

* **HSTS не здесь.** NPM добавляет `Strict-Transport-Security` (вкладка SSL);
  дублирование дало бы два STS-заголовка.
* **Нет CSP/COEP/COOP/CORP.** Редактор ONLYOFFICE открывается в cross-origin
  iframe; жёсткая изоляция ломает редактирование.
* `absolute_redirect off` — иначе редиректы уходили бы на
  `http://cloud.example.com:8080/...` (внутренний порт).
* `resolver 127.0.0.11` + `fastcgi_pass $php_fpm` — конфиг валиден без
  запущенного `app` (`nginx -t`), а пересоздание контейнера `app` не требует
  reload nginx.
* Ошибки PHP не перехватываются (`fastcgi_intercept_errors on` + страницы
  Nextcloud), а статика отдаётся только из whitelisted-префиксов.

## 6. Проверка

```bash
# синтаксис + рендер (как в CI; контейнер одноразовый)
docker run --rm \
  -v "$PWD/config/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
  -v "$PWD/config/nginx/conf.d:/etc/nginx/conf.d:ro" \
  -v "$PWD/config/nginx/snippets:/etc/nginx/snippets:ro" \
  -v "$PWD/config/nginx/templates:/etc/nginx/templates:ro" \
  -e NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/templates \
  -e NGINX_ENVSUBST_OUTPUT_DIR=/var/run \
  -e CLOUD_DOMAIN=cloud.example.com -e OFFICE_DOMAIN=office.example.com \
  -e PHP_UPLOAD_LIMIT=10G \
  nginx:1.29-alpine nginx -t

# живой контейнер
docker compose exec web nginx -T | grep -E 'client_max_body_size|server_name'
docker compose exec web wget -qO- http://127.0.0.1:8080/healthz   # ok
docker compose exec web wget -qO- http://127.0.0.1:8080/status    # stub_status
docker compose logs web | grep -iE 'emerg|warn'
```

Без `-e NGINX_ENVSUBST_OUTPUT_DIR=/var/run` одноразовый `nginx -t` тоже проходит
(используется статический дефолт из `snippets/upload-limit.conf`, блок Nextcloud
остаётся без публичных `server_name`), но проверять нужно именно
production-вариант — с рендером.

## 7. Симптомы

| Симптом | Причина / действие |
|---|---|
| все запросы получают reset (444) | не отрендерены шаблоны: проверьте env `CLOUD_DOMAIN`/`OFFICE_DOMAIN` и `docker compose logs web | grep envsubst` |
| `413` при загрузке | `PHP_UPLOAD_LIMIT` занижен (и/или NPM Advanced) |
| редирект на `:8080` | потерян `absolute_redirect off` |
| 502 при открытии | `app` не healthy (`docker compose ps`) |
| `/status` 403 снаружи | так и должно быть: stub_status только с 127.0.0.1 |
| нет `access.json.log` | `./logs/nginx` не writable для uid 101 |
