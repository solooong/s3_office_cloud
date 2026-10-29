# 02. Развёртывание

Пошаговая установка Cloud Suite на чистый сервер: Ubuntu 24.04 LTS (или Debian 12),
один сервер с публичным IP, `docker compose`. Итог — работающий Nextcloud с
файлами в S3 (SeaweedFS), ONLYOFFICE и Nginx Proxy Manager с Let's Encrypt.

Время: 40–60 минут с учётом загрузки образов. Повторяемость важнее скорости:
**не пропускайте шаги проверки**.

## 1. Предусловия

| Параметр | Минимум | Рекомендуется |
|---|---|---|
| CPU | 4 vCPU | 8 vCPU |
| RAM | 8 ГБ | 16 ГБ |
| Диск | 100 ГБ SSD + место под данные | NVMe, отдельный диск под `s3_data` |
| ОС | Ubuntu 24.04 LTS / Debian 12 | Ubuntu 24.04 LTS |
| Доступ | root или sudo | root по ключу |
| Сеть | публичный IPv4, 80/443 открыты | + IPv6, домен организации |

Дополнительно нужно:

* два DNS-имени (например `cloud.example.com` и `office.example.com`),
  A-записи которых указывают на IP сервера **до** первого запуска NPM;
* рабочий e-mail для Let's Encrypt (`ACME_EMAIL`);
* SMTP-доступ, если нужны приглашения и сброс паролей;
* git (или архив репозитория).

Проверка DNS **с другой машины** (не с сервера):

```bash
dig +short cloud.example.com
dig +short office.example.com
```

Оба ответа должны совпадать с публичным IP сервера.

## 2. Базовая настройка ОС

```bash
sudo apt-get update
sudo apt-get -y upgrade
sudo apt-get install -y ca-certificates curl gnupg jq git make openssl rsync ufw
sudo timedatectl set-timezone Asia/Novosibirsk   # или ваш часовой пояс; TZ в .env должен совпадать
timedatectl status | grep -E 'Time zone|synchronized'
```

Часовой пояс влияет на audit-логи и cron: `TZ` в `.env` и время хоста
должны соответствовать. Внутри Nextcloud аудит пишется в UTC независимо от `TZ`
(см. [05-audit-logging.md](05-audit-logging.md)).

## 3. Docker Engine и Compose

Официальный репозиторий Docker (не snap — snap-версия конфликтует с compose plugin):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version
docker compose version          # нужен v2.20+
sudo systemctl enable --now docker
```

Для Debian 12 замените `ubuntu` на `debian` в URL и в строке репозитория.

Проверка:

```bash
sudo docker run --rm hello-world
```

## 4. Параметры ядра и лимиты

ONLYOFFICE требует `vm.max_map_count` не меньше 262144, Nextcloud и SeaweedFS —
достаточного числа файловых дескрипторов и inotify-часов. Без этого возможны падения
Document Server и ошибки «Too many open files».

```bash
sudo tee /etc/sysctl.d/99-cloudsuite.conf >/dev/null <<'EOF'
# ONLYOFFICE Document Server
vm.max_map_count = 262144
# Nextcloud: много мелких файлов, inotify для синхронизации
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.file-max = 2097152
net.core.somaxconn = 1024
net.ipv4.tcp_fin_timeout = 30
EOF
sudo sysctl --system
sysctl vm.max_map_count fs.inotify.max_user_watches
```

Лимиты для сервисов Docker:

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
sudo tee /etc/systemd/system/docker.service.d/limits.conf >/dev/null <<'EOF'
[Service]
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
EOF
sudo systemctl daemon-reload
sudo systemctl restart docker
```

## 5. Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

Публикуются только 80/443. Админ-интерфейсы (NPM GUI на `127.0.0.1:8181`,
SeaweedFS master/filer на `127.0.0.1:9333`/`8888`) доступны только через SSH-туннель.

Если стек запускается на белом IP без домена (`docs/14-ip-run.md`), вместо 443
открывается порт редактора: `sudo ufw allow 8081/tcp` (или ваш `IP_OFFICE_PORT`),
а `IP_HTTP_PORT` задаётся в `.env.ip`.
SSH-хардненинг и fail2ban — в [03-security-hardening.md](03-security-hardening.md).

## 6. Код и .env

```bash
sudo mkdir -p /opt && cd /opt
sudo git clone <URL-репозитория> cloudsuite
cd /opt/cloudsuite

cp .env.example .env
chmod 600 .env
```

Отредактируйте `.env` (минимум):

| Переменная | Значение |
|---|---|
| `CLOUD_DOMAIN` | `cloud.example.com` |
| `OFFICE_DOMAIN` | `office.example.com` |
| `ACME_EMAIL` | `admin@example.com` |
| `NPM_ADMIN_EMAIL` | адрес администратора NPM |
| `TZ` | `Asia/Novosibirsk` (как на хосте) |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `cloud.example.com office.example.com web` |
| `SMTP_*` | параметры почтового сервера (если есть) |
| `NEXTCLOUD_ADMIN_USER` | `admin` (или корпоративный логин) |

Секреты **не вписывайте вручную** — их сгенерирует скрипт:

```bash
./scripts/generate-secrets.sh
```

Скрипт заполняет пустые значения (`POSTGRES_PASSWORD`, `REDIS_PASSWORD`,
`S3_ACCESS_KEY`, `S3_SECRET_KEY`, `ONLYOFFICE_JWT_SECRET`,
`NEXTCLOUD_ADMIN_PASSWORD`, `NPM_ADMIN_PASSWORD`, `BACKUP_PASSPHRASE`),
выставляет `.env` права `600` и **не печатает** значения. Идемпотентен:
повторный запуск ничего не меняет; `--dry-run` показывает план, `--force`
перегенерирует существующие секреты.

**Сохраните `BACKUP_PASSPHRASE` в менеджере паролей** — без него зашифрованный
бэкап конфигурации не восстановить.

## 7. Проверка предусловий

```bash
./scripts/preflight.sh          # ОС, docker, ресурсы, порты, DNS, sysctl
```

Скрипт проверяет версии docker/compose, CPU/RAM/диск, свободны ли 80/443, резолвятся
ли домены, `vm.max_map_count`, inotify, синхронизацию часов, наличие обязательных
файлов. Любая ошибка — повод исправить до следующего шага.

## 8. Bootstrap

```bash
./scripts/bootstrap.sh
# или: make bootstrap
```

Что делает скрипт (идемпотентно):

1. сверяет `.env` с `.env.example` (все ключи на месте, лишних нет);
2. проверяет, что все секреты непустые, домены — валидные FQDN и различаются,
   S3-ключи достаточной длины;
3. создаёт `data/`, `backups/` (0700) и каталоги журналов
   `logs/nginx`, `logs/onlyoffice`, `logs/cloudsuite`, `logs/npm`; каталог
   `logs/cloudsuite` получает владельца `33:33` и права 0750, потому что в него
   пишет www-data;
4. нормализует переводы строк в `.env` (CRLF в LF);
5. проверяет наличие обязательных файлов репозитория;
6. выполняет `docker compose config -q` — конфигурация должна рендериться без ошибок.

Флаги: `--dry-run` (только план), `--skip-preflight`, `--skip-compose`.

Bootstrap **не запускает** контейнеры и не создаёт бакет — это делают compose-сервисы
при старте.

## 9. Первый запуск

```bash
make up
# эквивалент: docker compose up -d
```

Первый запуск занимает 3–10 минут:

* загружаются образы (суммарно около 4 ГБ, самый большой — ONLYOFFICE);
* `db` и `cache` поднимаются и проходят healthcheck;
* `s3` стартует master/volume/filer/S3 gateway;
* `s3-init` создаёт S3-идентичность и бакет `$S3_BUCKET` (идемпотентно);
* `app` устанавливает Nextcloud (start_period healthcheck — 300 с, это нормально),
  затем entrypoint-хуки копируют `*.config.php` из `/opt/cloudsuite/config` в
  `/var/www/html/config` и включают `admin_audit`;
* `web` ждёт `app`, `proxy` ждёт `web` и `onlyoffice`.

Для внутреннего S3 схема намеренно без TLS: в compose задано
`OBJECTSTORE_S3_SSL: "false"` (Nextcloud читает именно `OBJECTSTORE_S3_SSL`, а не
`OBJECTSTORE_S3_USE_SSL`). Трафик до `s3:8333` идёт по изолированной сети
`backend`, наружу этот порт не публикуется; TLS терминируется на NPM.

Контроль:

```bash
make status
# или
docker compose ps
./scripts/healthcheck.sh
```

Ожидаемо: `db`, `cache`, `s3`, `app`, `web`, `proxy` и `onlyoffice`
в состоянии `healthy`; `s3-init` — `exited (0)`; `cron` — `running`.

Если `app` перезапускается — смотреть `docker compose logs app` и
[11-troubleshooting.md](11-troubleshooting.md).

## 10. Nginx Proxy Manager: два proxy host и Let's Encrypt

Полная пошаговая инструкция с полями всех вкладок — в
[config/proxy/npm-gui-setup.md](../config/proxy/npm-gui-setup.md). Кратко.

### 10.1 Вход

```bash
ssh -L 8181:127.0.0.1:8181 root@<IP-сервера>
```

В браузере: `http://127.0.0.1:8181`, логин `NPM_ADMIN_EMAIL`, пароль
`NPM_ADMIN_PASSWORD`. **Смените пароль** (Users → Edit → Change Password) и включите
2FA.

### 10.2 Host для Nextcloud

*Hosts → Proxy Hosts → Add Proxy Host*:

| Вкладка | Поле | Значение |
|---|---|---|
| Details | Domain Names | `cloud.example.com` |
| Details | Scheme | `http` |
| Details | Forward Hostname / IP | `web` |
| Details | Forward Port | `8080` |
| Details | Cache Assets | выключено |
| Details | Block Common Exploits | включено |
| Details | Websockets Support | **включено** |
| SSL | SSL Certificate | Request a new SSL Certificate → Let's Encrypt |
| SSL | Force SSL / HTTP/2 / HSTS | все включены |
| SSL | I Agree to the ToS | галочка |
| Advanced | Custom Nginx Configuration | активная часть [nextcloud-advanced.conf](../config/proxy/nextcloud-advanced.conf) |

### 10.3 Host для ONLYOFFICE

То же, но:

| Поле | Значение |
|---|---|
| Domain Names | `office.example.com` |
| Forward Hostname / IP | `onlyoffice` |
| Forward Port | `80` |
| Websockets Support | **обязательно включено** (ко-редактирование) |
| Advanced | активная часть [onlyoffice-advanced.conf](../config/proxy/onlyoffice-advanced.conf) |

Ключевые значения Advanced-конфигов: `client_max_body_size` равен
`PHP_UPLOAD_LIMIT` (`10G`), таймауты 3600 с, `proxy_request_buffering off`
для Nextcloud, буферы 64k для офиса. HSTS настраивается **только** на вкладке SSL:
не дублируйте его в Advanced и в `config/nginx`.

### 10.4 Проверка

```bash
curl -sI http://cloud.example.com/ | head -n 3            # 301 -> https
curl -sI https://cloud.example.com/ | grep -i strict-transport
curl -fsS https://office.example.com/healthcheck          # true
curl -fsS https://cloud.example.com/status.php | jq '{installed, versionstring}'
```

## 11. Настройка Nextcloud и ONLYOFFICE

```bash
make configure
# или: ./scripts/configure-nextcloud.sh
```

Скрипт идемпотентен: повторный запуск ничего не ломает. Через `occ` применяется:

* `trusted_domains`, `trusted_proxies`, `overwriteprotocol = https`,
  `overwrite.cli.url` — чтобы Nextcloud генерировал правильные внешние ссылки;
* `background:cron`, `memcache.local = APCu`, `memcache.distributed` и `memcache.locking = Redis`;
* SMTP (если задан `SMTP_HOST`), политика шаринга (пароль, срок, публичная загрузка),
  решаринг, запрет перечисления пользователей;
* парольная политика: минимум 12 символов;
* квота по умолчанию (`files default_quota`);
* коннектор ONLYOFFICE: `DocumentServerUrl`, `InternalUrl`, `StorageUrl`,
  `jwt_secret = $ONLYOFFICE_JWT_SECRET` (тот же секрет, что у контейнера);
* приложения: включить `admin_audit`, `onlyoffice`, `twofactor_totp`, `password_policy`;
  отключить `federation` и выключить федеративные шары в обе стороны
  (`files_sharing.outgoing_server2server_share_enabled`/`incoming_server2server_share_enabled` = no;
  сам `federatedfilesharing` — core-приложение, Nextcloud 35 не даёт его отключить).

Проверяется (и при расхождении скрипт падает с ошибкой), потому что владелец этих
значений — `config/nextcloud/config/zz-10-cloudsuite.config.php`: окно обслуживания,
`default_phone_region`, отключение демо-файлов, пути логов приложения и аудита, уровень
логирования, политика версий и корзины, превью, защита от подбора паролей.

Флаги: `--enforce-2fa` (обязательный TOTP для всех), `--skip-apps`, `--skip-mail`,
`--skip-share`, `--skip-cache`, `-n/--dry-run`. Код возврата 1 — хотя бы одна проверка
не прошла.

### 11.1 Как конфиги Nextcloud попадают в контейнер

Каталог `config/nextcloud` монтируется в `app` как `/opt/cloudsuite:ro`, а
`config/nextcloud/hooks` — как `/docker-entrypoint-hooks.d:ro`. При каждом старте
контейнера entrypoint выполняет хуки (файлы должны быть исполняемыми):

| Хук | Действие |
|---|---|
| `10-extra-config.sh` | копирует `/opt/cloudsuite/config/*.config.php` в `/var/www/html/config` |
| `20-permissions.sh` | выставляет корректные права на `/var/www/html/config` |
| `30-enable-audit.sh` | включает приложение `admin_audit`, если оно выключено |

Смысл схемы: источник истины — файлы в репозитории, изменения применяются
перезапуском `app` (и `cron`), а прямой bind-mount отдельных файлов в
`/var/www/html/config` ломал первый запуск (Docker создавал каталог `root:root`
раньше, чем стартовал образ).

Проверка коннектора:

```bash
./scripts/occ.sh config:app:get onlyoffice DocumentServerUrl
./scripts/occ.sh app:list | grep -E 'onlyoffice|admin_audit|twofactor_totp'
docker compose exec -T onlyoffice printenv | grep -E 'JWT_ENABLED|JWT_SECRET' | sed 's/SECRET=.*/SECRET=<set>/'
```

Затем откройте любой файл DOCX в веб-интерфейсе — должен открыться редактор.

## 12. Первые пользователи и роли

```bash
# применить ролевую модель (группы, квоты, политики)
make rbac

# создать пользователя (пароль запрашивается интерактивно)
./scripts/occ.sh user:add --display-name "Иван Иванов" ivanov

# добавить в группу
./scripts/occ.sh group:adduser employees ivanov

# проверить
./scripts/occ.sh user:info ivanov | head -20
```

Роли, квоты и матрица прав — [04-rbac-and-sharing.md](04-rbac-and-sharing.md).

## 13. Приёмка и передача в эксплуатацию

```bash
make doctor      # полная проверка окружения
make status      # состояние сервисов
make smoke       # end-to-end: WebDAV PUT/GET/DELETE, шара, публичная ссылка, версия
make test        # валидация репозитория (python tests/validate.py)
```

Пройдите [12-acceptance-checklist.md](12-acceptance-checklist.md) полностью:
функциональные тесты, нефункциональные, безопасность, бэкап и восстановление.

Сразу после приёмки:

1. настройте расписания `make backup` и `make prune-versions`
   ([07-backup-restore-dr.md](07-backup-restore-dr.md),
   [06-versioning-and-retention.md](06-versioning-and-retention.md));
2. включите пересылку audit-логов, если это требуется политикой
   ([05-audit-logging.md](05-audit-logging.md));
3. проведите учебное восстановление ([07-backup-restore-dr.md](07-backup-restore-dr.md));
4. выдайте сотрудникам [10-user-guide.md](10-user-guide.md).

## 14. Шпаргалка по эксплуатации

| Задача | Команда |
|---|---|
| Статус | `make status` |
| Логи | `make logs` или `docker compose logs -f app` |
| Перезапуск | `make restart` |
| Остановить / поднять | `make down` / `make up` |
| Бэкап | `make backup` |
| Восстановление | `make restore` (с `--confirm`) |
| Обновление | `make update` |
| occ | `./scripts/occ.sh <команда>` |
| Прунер версий | `make prune-versions` / `make prune-versions-dry-run` |
| Роли | `make rbac` |
| Аудит | `make audit-report ARGS="--from <дата>"` |
| Тесты и линтеры | `make test` / `make lint` |
| Shell в БД | `make shell-db` |
| Миграция | `make migrate ARGS="--source yandex:disk --user ivanov"` |

Полный регламент — [09-operations-runbook.md](09-operations-runbook.md).

## 15. Что где лежит после установки

| Объект | Где |
|---|---|
| Код и конфиги | `/opt/cloudsuite` |
| Секреты | `/opt/cloudsuite/.env` (600, не в git) |
| Логи nginx | `/opt/cloudsuite/logs/nginx/` |
| Аудит и лог Nextcloud | `/opt/cloudsuite/logs/cloudsuite/` |
| Бэкапы | `/opt/cloudsuite/backups/` (или `BACKUP_DIR`) |
| Данные S3 | том `cloudsuite_s3_data` |
| БД | том `cloudsuite_db_data` |
| Код Nextcloud | том `cloudsuite_nextcloud_html` |
| Сертификаты NPM | тома `cloudsuite_proxy_data`, `cloudsuite_proxy_letsencrypt` |

## 16. Связанные документы

* [01-architecture.md](01-architecture.md) — архитектура и потоки данных.
* [03-security-hardening.md](03-security-hardening.md) — хардненинг после установки.
* [04-rbac-and-sharing.md](04-rbac-and-sharing.md) — роли и шаринг.
* [07-backup-restore-dr.md](07-backup-restore-dr.md) — бэкапы и DR.
* [09-operations-runbook.md](09-operations-runbook.md) — эксплуатация.
* [11-troubleshooting.md](11-troubleshooting.md) — если что-то не поднялось.
* [12-acceptance-checklist.md](12-acceptance-checklist.md) — приёмка.
* [13-local-run.md](13-local-run.md) — запуск без домена на одной машине (`cloud.local`).
* [14-ip-run.md](14-ip-run.md) — запуск на белом IP без домена и хостинга (`http://PUBLIC_IP/`).
* [config/proxy/npm-gui-setup.md](../config/proxy/npm-gui-setup.md) — детальная настройка NPM.
