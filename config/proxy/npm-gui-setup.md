# Настройка Nginx Proxy Manager (пошагово)

Документ описывает **ручные шаги в веб-интерфейсе NPM**, которые делаются один
раз после первого `make up`. Всё, что можно было вынести в файлы, уже лежит в
`config/proxy/*.conf` и `config/nginx/**` — здесь только то, что NPM хранит в
своей базе (SQLite в томе `proxy_data`).

> Значения доменов берите из `.env`: `CLOUD_DOMAIN`, `OFFICE_DOMAIN`,
> `ACME_EMAIL`, `NPM_ADMIN_EMAIL`, `NPM_ADMIN_PASSWORD`.
> В примерах ниже используются `cloud.example.com` и `office.example.com`.

## 0. Предусловия

1. Оба имени (`CLOUD_DOMAIN`, `OFFICE_DOMAIN`) уже резолвятся в публичный IP
   сервера (A/AAAA). Проверка **с другой машины**, не с сервера:

   ```bash
   dig +short cloud.example.com
   dig +short office.example.com
   curl -s -o /dev/null -w '%{http_code}\n' http://cloud.example.com/   # 404/502 = NPM отвечает
   ```

2. Порты 80 и 443 свободны и опубликованы (их занимает сервис `proxy`):
   `HTTP_PORT=80`, `HTTPS_PORT=443` в `.env`. HTTP-01 challenge Let's Encrypt
   проверяется именно по порту 80.
3. Стек поднят и здоров:

   ```bash
   docker compose ps                 # proxy/web/app/db/cache/s3 healthy, onlyoffice running
   docker compose exec web wget -qO- http://127.0.0.1:8080/healthz   # ok
   ```

## 1. Вход в панель

Панель по умолчанию слушает только loopback (`NPM_ADMIN_BIND=127.0.0.1`,
`NPM_ADMIN_PORT=8181`), поэтому подключайтесь через SSH-туннель:

```bash
ssh -L 8181:127.0.0.1:8181 root@server
# затем в браузере: http://127.0.0.1:8181
```

Логин — `NPM_ADMIN_EMAIL`, пароль — `NPM_ADMIN_PASSWORD` из `.env`
(NPM создаёт этого пользователя при первом старте).
**Сразу после входа смените пароль**: *Users → ваш пользователь → Edit → Change Password*.

## 2. Proxy Host для Nextcloud

*Hosts → Proxy Hosts → Add Proxy Host.*

### Вкладка Details

| Поле | Значение |
|---|---|
| Domain Names | `cloud.example.com` (можно добавить `www.cloud.example.com`) |
| Scheme | `http` |
| Forward Hostname / IP | `web` |
| Forward Port | `8080` |
| Cache Assets | **выключено** (Nextcloud сам управляет кешированием; кеш NPM ломает WebDAV) |
| Block Common Exploits | **включено** |
| **Websockets Support** | **включено** |
| Access List | `Public` (или пусто) |

### Вкладка SSL

1. *SSL Certificate → Request a new SSL Certificate*.
2. **Force SSL** — включить (301 с http на https).
3. **HTTP/2 Support** — включить.
4. **HSTS Enabled** — включить.
5. **HSTS Subdomains** — включайте только если ВСЕ поддомены домена
   обслуживаются этим сервером по HTTPS (для `cloud.example.com` обычно
   выключено, чтобы не «залипить» другие сервисы домена на два года).
6. *I Agree to the Let's Encrypt Terms of Service* — галочка, `ACME_EMAIL`
   подставляется автоматически.
7. **Save**. NPM выпустит сертификат по HTTP-01 (challenge обслуживает сам NPM
   на порту 80 — ничего дополнительно открывать не нужно).

Если выпуск не удался: проверьте, что `http://cloud.example.com/.well-known/acme-challenge/`
доступен снаружи (не блокируется firewall/CDN) и что порт 80 ведёт именно на NPM.

### Вкладка Advanced

Вставьте **активную часть** файла
[`nextcloud-advanced.conf`](nextcloud-advanced.conf) (всё, что до баннера
`COPY-PASTE BLOCK`) → **Save**.

Ключевое: `client_max_body_size 10G` (должно совпадать с `PHP_UPLOAD_LIMIT`),
таймауты 3600s, `proxy_request_buffering off`, `proxy_buffering off`.

### Почему HSTS/Force SSL только здесь

Сертификат, HSTS и редирект http→https — зона ответственности NPM. Внутренний
nginx (`web`) намеренно **не** отправляет `Strict-Transport-Security`
(см. `config/nginx/snippets/security-headers.conf`): иначе ответ приходил бы с
двумя заголовками HSTS. Не добавляйте `add_header Strict-Transport-Security` в
Advanced — NPM уже сделал это на вкладке SSL.

## 3. Proxy Host для ONLYOFFICE Docs

*Hosts → Proxy Hosts → Add Proxy Host.*

### Вкладка Details

| Поле | Значение |
|---|---|
| Domain Names | `office.example.com` |
| Scheme | `http` |
| Forward Hostname / IP | `onlyoffice` |
| Forward Port | `80` |
| Cache Assets | **выключено** |
| Block Common Exploits | **включено** |
| **Websockets Support** | **включено** (обязательно: совместное редактирование держит websocket `/doc/`) |
| Access List | `Public` |

### Вкладка SSL

То же, что для Nextcloud: Let's Encrypt, **Force SSL**, **HTTP/2**, **HSTS
Enabled**; **HSTS Subdomains** — по той же логике.

### Вкладка Advanced

Вставьте активную часть файла
[`onlyoffice-advanced.conf`](onlyoffice-advanced.conf) → **Save**.

## 4. Проверка после настройки

```bash
# 1. Редирект http -> https и сертификат
curl -sI http://cloud.example.com/ | head -n 3          # 301 Location: https://...
curl -sI https://cloud.example.com/ | grep -iE 'strict-transport-security|server'
#    -> ровно ОДИН Strict-Transport-Security, Server: nginx (без версии)

# 2. Офис отвечает
curl -fsS https://office.example.com/healthcheck          # true

# 3. Серверная доступность офиса из контейнера
docker compose exec onlyoffice curl -fsS http://127.0.0.1/healthcheck

# 4. Nextcloud видит правильный внешний адрес
curl -fsS https://cloud.example.com/status.php            # "installed":true,"version":"35..."
```

Затем в Nextcloud: *Settings → Administration → ONLYOFFICE* — адрес
`https://office.example.com/`, тот же JWT-секрет, что `ONLYOFFICE_JWT_SECRET`
(настройка коннектора автоматизирована в `scripts/configure-nextcloud.sh`).
Откройте любой `.docx` — редактор должен открыться в iframe и сохранить файл.

## 5. Обслуживание

* **Продление сертификатов** — автоматически (ACME renew раз в сутки); состояние:
  *SSL Certificates* в GUI.
* **Резервная копия NPM** — том `proxy_data` (SQLite) + `proxy_letsencrypt`;
  входит в `scripts/backup.sh`.
* **Изменение Advanced-конфига** — только через GUI (файлы в
  `/data/nginx/proxy_host/*.conf` генерируются NPM и будут перезаписаны).
* **Логи** — `docker compose exec proxy tail -n 50 /data/logs/proxy-host-1_error.log`
  (номер соответствует id хоста в GUI).

## 6. Чего делать НЕ нужно

* не добавлять CSP / `Cross-Origin-*` заголовки — они ломают iframe редактора
  ONLYOFFICE;
* не дублировать HSTS и не отключать Force SSL;
* не включать *Cache Assets* для этих двух хостов;
* не менять `client_max_body_size` только в одном месте: NPM, PHP
  (`PHP_UPLOAD_LIMIT`) и `config/nginx` должны совпадать.
