# 05. Аудит и журналирование

Требование заказчика — «аудит-логирование действий пользователей». В Cloud Suite
есть три независимых источника событий: приложение Nextcloud (`admin_audit`),
nginx (JSON-лог доступа) и ONLYOFFICE Document Server. Их показания дополняют друг
друга: приложение знает, *что* сделано с файлом, nginx — *с какого адреса* и *каким
HTTP-запросом*, толькоофис — *как прошло редактирование*.

## 1. Куда пишутся события

| Источник | Путь в контейнере | Путь на хосте | Формат |
|---|---|---|---|
| Аудит Nextcloud (`admin_audit`) | `/var/log/cloudsuite/audit.log` | `logs/cloudsuite/audit.log` | JSON, одна строка = одно событие |
| Лог приложения Nextcloud | `/var/log/cloudsuite/nextcloud.log` | `logs/cloudsuite/nextcloud.log` | JSON |
| Доступ nginx | `/var/log/nginx/access.json.log` | `logs/nginx/access.json.log` | JSON (`log_format json_combined`) |
| Ошибки nginx | `/var/log/nginx/error.log` | `logs/nginx/error.log` | текст |
| ONLYOFFICE | `/var/log/onlyoffice/` | том `onlyoffice_logs` (см. п. 8) | текст/JSON |
| PostgreSQL | — | `docker compose logs db` | текст |
| Docker (все контейнеры) | — | `docker compose logs` | json-file, 20 МБ × 5 |

Настройка аудита — в `config/nextcloud/config/zz-10-cloudsuite.config.php`:

```php
'log_type' => 'file',
'logfile' => '/var/log/cloudsuite/nextcloud.log',
'log_type_audit' => 'file',
'logfile_audit' => '/var/log/cloudsuite/audit.log',
```

Как этот файл попадает в контейнер: каталог `config/nextcloud` монтируется в
`app` как `/opt/cloudsuite:ro`, а `config/nextcloud/hooks` — в
`/docker-entrypoint-hooks.d:ro`. При старте контейнера entrypoint выполняет хуки
(они должны быть исполняемыми):

| Хук | Что делает |
|---|---|
| `10-extra-config.sh` | копирует `/opt/cloudsuite/config/*.config.php` в `/var/www/html/config` |
| `20-permissions.sh` | выставляет права на `/var/www/html/config` |
| `30-enable-audit.sh` | включает приложение `admin_audit`, если оно ещё не включено |

Поэтому источник истины — файл в репозитории, а изменения применяются при
перезапуске `app` и `cron`. Правки напрямую в `/var/www/html/config/config.php`
переживут рестарт контейнера, но потеряются при пересоздании тома.

Каталог `logs/cloudsuite` создаётся `scripts/bootstrap.sh` с владельцем
`33:33` (www-data) и правами `0750` — писать в него может только приложение.

## 2. Формат записи аудита

Каждая строка — самостоятельный JSON-объект (JSON Lines). Поля формирует
стандартный форматтер Nextcloud (`OC\Log\LogDetails`):

| Поле | Тип | Пример | Смысл |
|---|---|---|---|
| `reqId` | string | `"6H2k..."` | идентификатор HTTP-запроса, связывает события |
| `level` | int | `1` | 0 debug, 1 info, 2 warning, 3 error, 4 fatal |
| `time` | string | `"2026-10-25T16:44:23+00:00"` | ISO 8601, **UTC** |
| `remoteAddr` | string | `"203.0.113.24"` | реальный IP клиента (после trusted proxies) |
| `user` | string | `"ivanov"` | кто действовал (`"--"` для анонимных) |
| `app` | string | `"admin_audit"` | источник события |
| `method` | string | `"POST"` | HTTP-метод |
| `url` | string | `"/index.php/apps/files/"` | путь запроса |
| `scriptName` | string | `"/index.php"` | точка входа |
| `message` | string | `"Login successful: \"ivanov\""` | текст события — **и есть действие** |
| `userAgent` | string | `"Mozilla/5.0 ..."` | клиент |
| `version` | string | `"35.0.2.0"` | версия Nextcloud |
| `occ_command` | array | `["occ","user:add"]` | только для CLI-команд |
| `clientReqId` | string | — | если клиент передал `X-Request-Id` |

Важно: в Nextcloud 35 у `admin_audit` **нет отдельного поля `action`** — тип
действия закодирован в тексте `message` (шаблоны сообщений перечислены в п. 3).
Фильтрация строится на префиксах сообщений, а не на гипотетическом поле.

Время в аудите — UTC (ключ `logtimezone` в конфигурации не переопределяется).
Время в nginx-логе — локальное время контейнера (`TZ`, по умолчанию
`Asia/Novosibirsk`). При сопоставлении событий учитывайте сдвиг; в отчётах
`scripts/audit-report.sh` время приводится к ISO 8601.

## 3. Какие действия фиксируются

Ниже — фактические шаблоны сообщений, которые формирует `admin_audit` в
Nextcloud 35, и события, их порождающие.

### 3.1 Аутентификация

| Событие | Сообщение |
|---|---|
| попытка входа | `Login attempt: "<логин>"` |
| успешный вход | `Login successful: "<логин>"` |
| неуспешный вход | `Login failed: "<логин>"` |
| вход по «запомнить меня» | `Login successful: "<логин>"` |
| выход | `Logout occurred` |
| удачный второй фактор | `Successful two factor attempt by user <UID> (<DisplayName>) with provider <Provider>` |
| неудачный второй фактор | сообщение о неуспешной попытке провайдера 2FA |

### 3.2 Файлы

| Событие | Сообщение |
|---|---|
| чтение/скачивание | `File with id "<id>" accessed: "<путь>"` |
| создание | `File with id "<id>" created: "<путь>"` |
| запись/перезапись | `File with id "<id>" written to: "<путь>"` |
| удаление | `File with id "<id>" deleted: "<путь>"` |
| переименование/перемещение | `File renamed with id "<id>" from "<старый>" to "<новый>"` |
| копирование | `File id copied from: "<id>" to "<id2>", path from "<путь>" to "<путь2>"` |
| предпросмотр | событие `BeforePreviewFetched` |

Скачивание файла через веб/WebDAV попадает в категорию `accessed`; скачивание
из интерфейса «Поделиться» дополнительно даёт событие доступа к шаре (п. 3.3).

### 3.3 Общий доступ

| Событие | Сообщение |
|---|---|
| ссылка создана | `The <тип> "<путь>" with ID "<id>" has been shared via link with permissions "<права>" (Share ID: <id>)` |
| доступ пользователю | `The <тип> "<путь>" with ID "<id>" has been shared to the user "<логин>" with permissions "<права>" (Share ID: <id>)` |
| доступ группе | `... shared to the group "<группа>" ...` |
| доступ по email | `... shared to the email recipient "<адрес>" ...` |
| шара отозвана | `The <тип> "<путь>" with ID "<id>" has been unshared (Share ID: <id>)` (для ссылки) / `... has been unshared from the user "<логин>" ...` |
| изменены права | `The permissions of the shared <тип> "<путь>" with ID "<id>" have been changed to "<права>"` |
| изменён пароль ссылки | `The password of the publicly shared <тип> "<путь>" with ID "<id>" has been changed` |
| изменён/снят срок | `The expiration date of the publicly shared <тип> with ID "<id>" has been changed to "<дата>"` |
| открыта публичная ссылка | `The shared <тип> with the token "<токен>" by "<владелец>" has been accessed.` |

### 3.4 Пользователи, группы, роли

| Событие | Сообщение |
|---|---|
| пользователь создан | `User created: "<логин>"` |
| пользователь удалён | `User deleted: "<логин>"` |
| пользователь отключён | `User disabled: "<логин>"` |
| пользователь включён | сообщение о включении учётной записи |
| смена пароля | событие `PasswordUpdated` |
| добавлен в группу | `User "<логин>" added to group "<группа>"` |
| удалён из группы | `User "<логин>" removed from group "<группа>"` |
| группа создана | `Group created: "<группа>"` |
| группа удалена | `Group deleted: "<группа>"` |

Это и есть «изменение роли»: роли в Cloud Suite — группы (`employees`,
`management`, `contractors`, `auditors`), поэтому смена роли
отражается как добавление/удаление из группы.

### 3.5 Корзина, версии, приложения

| Событие | Сообщение |
|---|---|
| удаление из корзины | `File "<путь>" deleted from trash bin.` |
| восстановление из корзины | `File "<путь>" restored from trash bin.` |
| удаление версии | событие версии `delete` |
| восстановление версии | событие `VersionRestored` |
| включение/выключение приложения | события app management |
| критическое действие | событие `CriticalActionPerformed` |

### 3.6 Признак действия в CLI

Команды `occ` (включая `make rbac`, `make configure`) выполняются в
контейнере и логируются с полем `occ_command`, например
`["occ","group:adduser"]`. Это позволяет отличить действия администратора
через CLI от действий в веб-интерфейсе.

## 4. Формат nginx-лога

`config/nginx/nginx.conf` определяет `log_format json_combined`; одна строка —
один запрос. Поля (имена стабильны, на них опираются рецепты и SIEM):

```json
{
  "time": "2026-10-25T23:44:23+07:00",
  "remote_addr": "203.0.113.24",
  "x_forwarded_for": "203.0.113.24",
  "realip_remote_addr": "172.28.10.10",
  "host": "cloud.example.com",
  "server_port": 8080,
  "scheme": "http",
  "request_method": "GET",
  "uri": "/index.php/apps/files/",
  "request_uri": "/index.php/apps/files/?dir=/Документы",
  "protocol": "HTTP/1.1",
  "status": 200,
  "body_bytes_sent": 34812,
  "request_length": 1204,
  "request_time": 0.421,
  "upstream_addr": "172.28.10.11:9000",
  "upstream_status": "200",
  "upstream_response_time": "0.418",
  "http_referer": "https://cloud.example.com/apps/files/",
  "http_user_agent": "Mozilla/5.0 ...",
  "request_id": "9f1d2c3b4a5e6f70"
}
```

Замечания:

* `remote_addr` — **реальный адрес клиента**: модуль realip восстанавливает его из
  `X-Forwarded-For`, доверяя только NPM (`set_real_ip_from 172.28.10.0/24`);
* `realip_remote_addr` — адрес, откуда запрос физически пришёл, то есть NPM
  (172.28.10.10). Если `remote_addr` не меняется при смене клиента — смотрите
  `realip_remote_addr` и `x_forwarded_for`;
* `uri` — URI после внутренних rewrite (обычно `/index.php`), `request_uri` — то,
  что запросил клиент, вместе с query string;
* `request_id` совпадает с `X-Request-Id`, который NPM передаёт дальше; при разборе
  инцидента начинайте с него;
* `request_time` и `upstream_response_time` — в секундах (может быть список через
  запятую при нескольких апстримах);
* строковые значения экранируются (`escape=json`), буфер записи — 64k с flush раз
  в секунду;
* `status: 444` — запрос с неизвестным `Host` закрыт без ответа (так работает
  default-server); для статики и локальных ответов `upstream_*` пустые.

## 5. Рецепты разбора (jq)

### 5.1 Кто входил и с какого адреса

```bash
jq -c 'select(.message | startswith("Login successful")) | {time, user, remoteAddr, userAgent}' \
  logs/cloudsuite/audit.log | tail -n 20
```

### 5.2 Неуспешные входы (подбор пароля)

```bash
jq -r 'select(.message | startswith("Login failed")) | [.time, .remoteAddr, .message] | @tsv' \
  logs/cloudsuite/audit.log | tail -n 50

# агрегированно по IP — топ источников
jq -r 'select(.message | startswith("Login failed")) | .remoteAddr' \
  logs/cloudsuite/audit.log | sort | uniq -c | sort -rn | head -n 10
```

### 5.3 Кто скачивал файл

```bash
jq -c 'select(.message | test("accessed:")) | {time, user, remoteAddr, message}' \
  logs/cloudsuite/audit.log | grep -i 'договор' | tail -n 20
```

### 5.4 Публичные ссылки: создание и открытие

```bash
# ссылки созданы
jq -r 'select(.message | test("shared via link")) | [.time, .user, .message] | @tsv' \
  logs/cloudsuite/audit.log | tail -n 20

# публичные ссылки открывали (токен + владелец)
jq -r 'select(.message | test("has been accessed")) | [.time, .message] | @tsv' \
  logs/cloudsuite/audit.log | tail -n 50
```

### 5.5 Удаления

```bash
jq -c 'select(.message | test("deleted:")) | {time, user, remoteAddr, message}' \
  logs/cloudsuite/audit.log | tail -n 50
```

### 5.6 Изменения прав и ролей

```bash
jq -r 'select(.message | test("added to group|removed from group|permissions of the shared"))
  | [.time, .user, .message] | @tsv' logs/cloudsuite/audit.log | tail -n 50
```

### 5.7 Действия администратора через CLI

```bash
jq -c 'select(.occ_command != null) | {time, user, command: .occ_command}' \
  logs/cloudsuite/audit.log | tail -n 20
```

### 5.8 HTTP 5xx и медленные запросы (nginx)

```bash
# ошибки сервера
jq -c 'select(.status >= 500) | {time, remote_addr, request_method, request_uri, status, request_time}' \
  logs/nginx/access.json.log | tail -n 50

# запросы дольше 30 секунд
jq -c 'select(.request_time > 30) | {time, uri, status, request_time}' \
  logs/nginx/access.json.log | tail -n 50

# всё по конкретному request_id
jq -c 'select(.request_id == "9f1d2c3b4a5e6f70")' logs/nginx/access.json.log
```

### 5.9 Отчёт по пользователю

```bash
./scripts/audit-report.sh --from 2026-10-01 --to 2026-10-31 --user ivanov
make audit-report ARGS="--from 2026-10-01 --user ivanov"

# CSV: time,user,action,remoteAddr,method,url,message,app,reqId
./scripts/audit-report.sh --from 2026-10-01 --to 2026-10-31 --csv > audit.csv

# уникальные действия и пользователи
./scripts/audit-report.sh --from 2026-10-01 --list

# машинная сводка (JSON) для отчёта или передачи в SIEM
./scripts/audit-report.sh --from 2026-10-01 --to 2026-10-31 --json > audit.json

# другой файл (например, копия с другого сервера) и фильтры
./scripts/audit-report.sh --file /mnt/audit.log --from 2026-10-01 --ip 203.0.113.24 --limit 100
```

Источник данных выбирается так: `--file` → `AUDIT_LOG_FILE` →
`logs/cloudsuite/audit.log` → `docker compose exec -T app cat /var/log/cloudsuite/audit.log`.
Флаг `--action` фильтрует по полю `action`; штатный `admin_audit` в Nextcloud 35 это
поле не пишет (действие в `message`), поэтому для типовых событий используйте
`jq`-рецепты выше, а `--action` — для записей, где поле присутствует.

## 6. Ротация и срок хранения

| Лог | Ротация | Хранение |
|---|---|---|
| `audit.log` | logrotate `config/logrotate/cloudsuite`: weekly, rotate 12, compress, **copytruncate** | не менее 6 месяцев онлайн, далее архив/SIEM |
| `nextcloud.log` | `log_rotate_size = 100 МБ` (встроенная ротация) | 30–90 дней |
| `logs/nginx/*.log` | logrotate (`config/logrotate/cloudsuite`): еженедельно, 12 копий, сжатие | 12 недель |
| docker json-file | `max-size: 20m`, `max-file: 5` | ~100 МБ на контейнер |
| ONLYOFFICE | внутри тома, ротация средствами DS | 30 дней |

Проверить/применить logrotate:

```bash
sudo install -m 644 config/logrotate/cloudsuite /etc/logrotate.d/cloudsuite
sudo logrotate --debug /etc/logrotate.d/cloudsuite   # ожидаемо: «Handling 3 logs»
sudo logrotate -f /etc/logrotate.d/cloudsuite
ls -la logs/nginx/ logs/cloudsuite/
```

`copytruncate` обязателен: Nextcloud держит файл `audit.log` открытым и после
внешнего переименования продолжал бы писать в старый inode.

Ручная чистка (если диск заполнен):

```bash
# только сжатые/старые файлы, не текущие
find logs/nginx -name '*.gz' -mtime +30 -delete
```

Требования комплаенса (уточняются политикой организации):

* 152-ФЗ: факты обработки персональных данных и доступ к ним — хранить не меньше
  срока обработки + 6 месяцев (типовая практика), обеспечивать конфиденциальность
  и целостность журналов;
* GDPR (если применимо): ст. 30 (records of processing) и ст. 32 (security of
  processing) — журналы доступа к данным, срок хранения по политике, минимизация
  (в аудите нет содержимого файлов, только пути — это соответствует принципу
  минимизации).

## 7. Примеры событий (что видно в логе)

Пример записи о входе (одна строка, отформатирована для читаемости):

```json
{
  "reqId": "6H2kQm9xT3pL",
  "level": 1,
  "time": "2026-10-25T16:44:23+00:00",
  "remoteAddr": "203.0.113.24",
  "user": "ivanov",
  "app": "admin_audit",
  "method": "POST",
  "url": "/login",
  "scriptName": "/index.php",
  "message": "Login successful: \"ivanov\"",
  "userAgent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ...",
  "version": "35.0.2.0"
}
```

Пример создания публичной ссылки:

```json
{
  "reqId": "a8Kd2LmQ",
  "level": 1,
  "time": "2026-10-25T16:51:02+00:00",
  "remoteAddr": "203.0.113.24",
  "user": "ivanov",
  "app": "admin_audit",
  "method": "POST",
  "url": "/ocs/v2.php/apps/files_sharing/api/v1/shares",
  "scriptName": "/ocs/v2.php",
  "message": "The file \"/ivanov/files/Документы/договор.pdf\" with ID \"4711\" has been shared via link with permissions \"1\" (Share ID: 918)",
  "userAgent": "Mozilla/5.0 ...",
  "version": "35.0.2.0"
}
```

Пример открытия публичной ссылки гостем:

```json
{
  "reqId": "p3Jx9Q",
  "level": 1,
  "time": "2026-10-25T17:02:11+00:00",
  "remoteAddr": "198.51.100.7",
  "user": "--",
  "app": "admin_audit",
  "method": "GET",
  "url": "/s/AbCdEf123",
  "scriptName": "/index.php",
  "message": "The shared file with the token \"AbCdEf123\" by \"ivanov\" has been accessed.",
  "userAgent": "Mozilla/5.0 ...",
  "version": "35.0.2.0"
}
```

Пример связанного запроса в nginx (скачивание файла, 200, 2,4 с):

```json
{"time":"2026-10-25T23:57:33+07:00","remote_addr":"203.0.113.24","x_forwarded_for":"203.0.113.24","realip_remote_addr":"172.28.10.10","host":"cloud.example.com","server_port":8080,"scheme":"http","request_method":"GET","uri":"/remote.php","request_uri":"/remote.php/dav/files/ivanov/Документы/договор.pdf","protocol":"HTTP/1.1","status":200,"body_bytes_sent":248311,"request_length":812,"request_time":2.401,"upstream_addr":"172.28.10.11:9000","upstream_status":"200","upstream_response_time":"2.395","http_referer":"https://cloud.example.com/apps/files/","http_user_agent":"Mozilla/5.0 ...","request_id":"9f1d2c3b4a5e6f70"}
```

Пример изменения прав и роли:

```bash
# права на шару
"The permissions of the shared dir \"/ivanov/files/Общие/Проект\" with ID \"4210\" have been changed to \"3\""
# добавление пользователя в группу (смена роли)
"User \"petrov\" added to group \"management\""
```

## 8. Пересылка в SIEM

### 8.1 rsyslog (файл → центральный сервер)

```bash
sudo apt-get install -y rsyslog
sudo tee /etc/rsyslog.d/50-cloudsuite.conf >/dev/null <<'EOF'
module(load="imfile" PollingInterval="10")

input(type="imfile"
      File="/opt/cloudsuite/logs/cloudsuite/audit.log"
      Tag="cloudsuite-audit"
      Severity="info"
      Facility="local6"
      addMetadata="on")

input(type="imfile"
      File="/opt/cloudsuite/logs/nginx/access.json.log"
      Tag="cloudsuite-nginx"
      Severity="info"
      Facility="local6"
      addMetadata="on")

# локальный буфер на случай недоступности SIEM
action(type="omfwd" target="siem.example.com" port="514" protocol="tcp"
       queue.type="linkedList" queue.size="50000" queue.diskmaxspace="1g"
       queue.filename="cloudsuite-fwd" action.resumeRetryCount="-1")
EOF
sudo systemctl restart rsyslog
sudo logger -p local6.info -t cloudsuite-test "rsyslog forwarding test"
```

Файлы должны быть читаемы пользователю `syslog`; проще всего добавить группу
`adm` или скопировать конфиг rsyslog с `FileCreateMode="0640"` и владельцем
`root:adm` для каталога `logs/cloudsuite` (по умолчанию каталог принадлежит
`33:33` с правами 0750 — rsyslog запущен от root и сможет прочитать файл).

### 8.2 Loki + Promtail (опциональный профиль)

Если в вашей инсталляции включён профиль наблюдаемости (отдельный compose-файл
со стеком Loki/Promtail из состава ops-поставки), логи подключаются как
дополнительные тома:

```bash
# пример: compose-файл профиля монтирует logs/cloudsuite и logs/nginx в Promtail
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d
# UI Grafana/Loki публикуется только на loopback, доступ — через SSH-туннель
```

Если профиля в поставке нет, используйте rsyslog (п. 8.1) или Promtail на хосте:
он читает те же файлы `logs/cloudsuite/audit.log` и `logs/nginx/access.json.log`.

Минимальный конфиг Promtail для этих логов:

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: cloudsuite-audit
    static_configs:
      - targets: [localhost]
        labels:
          job: cloudsuite-audit
          __path__: /var/log/cloudsuite/audit.log
    pipeline_stages:
      - json:
          expressions:
            user: user
            remote_addr: remoteAddr
            message: message
      - labels:
          user:

  - job_name: cloudsuite-nginx
    static_configs:
      - targets: [localhost]
        labels:
          job: cloudsuite-nginx
          __path__: /var/log/nginx/access.json.log
    pipeline_stages:
      - json:
          expressions:
            status: status
            uri: uri
            request_time: request_time
      - labels:
          status:
```

Правило алерта (пример для Loki): более 20 неуспешных входов с одного IP за 10 минут.

```yaml
groups:
  - name: cloudsuite-security
    rules:
      - alert: BruteForceSuspicion
        expr: |
          sum by (remote_addr) (
            count_over_time({job="cloudsuite-audit"} |= "Login failed" [10m])
          ) > 20
        for: 5m
        labels:
          severity: high
        annotations:
          summary: "Более 20 неуспешных входов с {{ $labels.remote_addr }}"
```

## 9. Целостность журналов

Ограничения, которые нужно понимать:

* файлы логов принадлежат `www-data` и доступны администратору хоста — при полном
  доступе к серверу журналы можно изменить или удалить;
* Nextcloud пишет события **после** выполнения действия; при аварии питания
  последние секунды могут быть потеряны.

Меры, повышающие доверие к журналам:

1. **немедленная пересылка** в удалённый syslog/SIEM (п. 8) — копия хранится вне
   сервера и недоступна локальному администратору;
2. **права**: `logs/cloudsuite` — 0750 `33:33`; `logs/nginx` — только
   пользователь сервиса и `adm`;
3. **ротация с сохранением**: не удаляйте архивы, пока не истёк срок хранения;
4. **сверка**: ежедневный отчёт `scripts/audit-report.sh` и контроль непрерывности
   (нет «дыр» по времени);
5. **NTP**: без синхронизации часов коррелировать события nginx и Nextcloud
   невозможно (см. [03-security-hardening.md](03-security-hardening.md)).

## 10. Чек-лист аудита

- [ ] `logfile_audit` задан, файл `logs/cloudsuite/audit.log` создаётся и растёт.
- [ ] `admin_audit` включён (`./scripts/occ.sh app:list`).
- [ ] В логе есть записи login, file accessed/written/deleted, share created.
- [ ] nginx пишет `access.json.log` с полями `remote_addr` (реальный клиент) и `request_id`.
- [ ] logrotate настроен и проверен (`logrotate --debug`).
- [ ] Пересылка в SIEM (если требуется) работает, тестовое сообщение доставлено.
- [ ] Срок хранения определён политикой и покрывается архивами.
- [ ] Доступ к `logs/cloudsuite` только у www-data и администратора.

## 11. Связанные документы

* [03-security-hardening.md](03-security-hardening.md) — реагирование на инциденты.
* [04-rbac-and-sharing.md](04-rbac-and-sharing.md) — роли и публичные ссылки.
* [09-operations-runbook.md](09-operations-runbook.md) — ежедневные проверки.
* [11-troubleshooting.md](11-troubleshooting.md) — диагностика пустого аудита.

