# 03. Безопасность и хардненинг

Документ описывает модель угроз, принятые меры защиты и регулярные действия
администратора. Все команды предполагают, что вы находитесь в каталоге репозитория
на сервере и `.env` уже заполнен (`make bootstrap` выполнен).

## 1. Что защищаем

| Актив | Где находится | Почему важен |
|---|---|---|
| Содержимое файлов сотрудников | S3 (SeaweedFS), том `s3_data` | коммерческая тайна, персональные данные |
| Метаданные (кто, что, когда) | PostgreSQL `db_data` | права доступа, аудит, версии |
| Учётные записи и сессии | PostgreSQL + Redis | компрометация аккаунта = доступ к файлам |
| Секреты (`.env`) | файловая система хоста | пароли БД, Redis, S3, JWT |
| Аудит-лог | `logs/cloudsuite/audit.log` | доказательная база, разбор инцидентов |
| Сертификаты и ключи TLS | тома NPM | доверие к сервису |

## 2. Модель угроз

| Угроза | Вектор | Мера защиты | Остаточный риск |
|---|---|---|---|
| Подбор пароля к веб-интерфейсу | `https://cloud.example.com/login` | bruteforce protection Nextcloud, fail2ban на NPM-логах, 2FA, политика паролей | слабый пароль у сотрудника; закрывается 2FA |
| Перехват трафика | сеть между клиентом и сервером | TLS 1.2/1.3 только, HSTS, редирект HTTP→HTTPS | компрометация CA/клиента |
| Кража сессии | XSS, украденный cookie | HttpOnly/SameSite cookie Nextcloud, security-заголовки, CSP-политика | расширения браузера |
| Утечка через публичную ссылку | ссылка ушла не туда | пароль на ссылке, срок действия, права read-only по умолчанию | человек отправил пароль вместе со ссылкой |
| Прямой доступ к S3/БД/Redis | сканирование портов | публикуются только 80/443; `backend` — `internal: true` | доступ к docker-хосту |
| Компрометация контейнера | RCE в PHP/DS | `no-new-privileges`, read-only конфиги, отсутствие docker.sock, непривилегированные пользователи | kernel-эксплойт |
| Кража бэкапа | бэкапы на диске/offsite | шифрование `openssl enc -aes-256-cbc -pbkdf2`, права 700 | слабый `BACKUP_PASSPHRASE` |
| Кража диска/ВМ | физический доступ, снапшот гипервизора | LUKS на диске данных, шифрование бэкапов | снимок RAM |
| Инсайдер-администратор | доступ к `.env`, `docker exec` | аудит действий админов (`admin_audit`), разделение ролей, ротация секретов | администратор всегда сильнее |
| Подмена офисного документа | MITM между Nextcloud и DS | JWT на всех запросах, `extra_hosts` на внутренний IP, TLS-сертификат на `office.example.com` | компрометация `ONLYOFFICE_JWT_SECRET` |
| Утечка секретов в git | коммит `.env` | `.gitignore` исключает `.env`, `data/`, `logs/`, `backups/`; в репозитории только `.env.example` | человеческий фактор |

Вне периметра (осознанно): защита от физического доступа к гипервизору,
DLP/антивирус внутри файлов, защита от целевой атаки на ядро Linux, юридический
контроль носителей.

## 3. Периметр и TLS

### 3.1 Сертификаты

Оба домена обслуживает NPM через Let's Encrypt (HTTP-01). Требования:

* A/AAAA-записи `$CLOUD_DOMAIN` и `$OFFICE_DOMAIN` указывают на публичный IP
  сервера **до** первого запуска;
* порт 80 доступен из интернета хотя бы на время выпуска/продления (ACME);
* для каждого proxy host включены `Force SSL` и `HTTP/2 Support`;
* HSTS включается **после** успешной проверки, что весь трафик идёт по HTTPS.

Проверка:

```bash
# срок действия сертификата, выданного NPM
echo | openssl s_client -servername "$CLOUD_DOMAIN" -connect "$CLOUD_DOMAIN":443 2>/dev/null \
  | openssl x509 -noout -subject -dates

# редирект с HTTP на HTTPS
curl -sI "http://$CLOUD_DOMAIN/" | head -n 3        # ожидаем 301
curl -sI "https://$CLOUD_DOMAIN/" | grep -i strict-transport
```

Если сертификат не продлился — сайт отдаёт ошибку TLS; аварийная процедура в
[11-troubleshooting.md](11-troubleshooting.md).

### 3.2 Заголовки

Security-заголовки задаются на двух уровнях:

* NPM (proxy host → Advanced): HSTS, `X-Content-Type-Options`,
  `Referrer-Policy`, `X-Frame-Options: SAMEORIGIN`;
* `web`-nginx (`config/nginx/snippets/security-headers.conf`): те же
  заголовки для статики и PHP-ответов, без дублирования HSTS.

Ограничение: нельзя ставить жёсткий `Content-Security-Policy` и
`Cross-Origin-Embedder-Policy`, которые ломают встраивание редактора
ONLYOFFICE и загрузку шрифтов. Поэтому CSP не форсируется; это осознанный
компромисс «работающий офис» vs «максимально строгий CSP».

Проверка:

```bash
curl -sI "https://$CLOUD_DOMAIN/" | grep -Ei 'strict-transport|x-content-type|x-frame|referrer'
curl -sI "https://$OFFICE_DOMAIN/healthcheck" | head -n 5
```

### 3.3 Публикация портов

Публично должны быть только 80 и 443:

```bash
docker compose ps --format 'table {{.Name}}\t{{.Ports}}'
ss -tlnp | grep -E ':(80|443|5432|6379|8333|9000|8888|9333)\s'
```

Ожидаемо: `0.0.0.0:80`, `0.0.0.0:443` (или `[::]`), `127.0.0.1:8181`.
**Не должно быть** слушателей на 5432, 6379, 8333, 9000, 8888, 9333 с внешних
адресов. Если появились — проверить `docker compose ps` и `docker ps --format`.

### 3.4 Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose
```

Правила Docker обходят UFW для опубликованных портов — поэтому важно, чтобы
compose публиковал только 80/443, а админ-порты биндились на `127.0.0.1`
(`NPM_ADMIN_BIND`, `SEAWEEDFS_FILER_PORT`). Проверка внешним сканером
обязательна на приёмке.

## 4. Хардненинг хоста

### 4.1 SSH

```bash
sudo sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo sed -i 's/^#\?KbdInteractiveAuthentication.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl restart ssh
```

До перезапуска убедитесь, что вход по ключу работает в отдельной сессии.

### 4.2 fail2ban

```bash
sudo apt-get update && sudo apt-get install -y fail2ban
sudo tee /etc/fail2ban/jail.d/cloudsuite.local >/dev/null <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true

[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
sudo systemctl enable --now fail2ban
sudo fail2ban-client status
```

Для защиты формы логина Nextcloud используйте встроенный mechanism
(`auth.bruteforce.protection.enabled`, включён по умолчанию). Дополнительно
можно подключить фильтр по JSON-логу `logs/nginx/access.json.log`; пример
фильтра — в [05-audit-logging.md](05-audit-logging.md#8-мониторинг-и-пересылка-в-siem).

### 4.3 Автоматические обновления ОС

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades   # выбрать "Yes"
sudo systemctl status unattended-upgrades --no-pager | head -n 5
```

Docker и прикладные образы обновляются **не** автоматически — см. п. 9
(регламент обновлений).

### 4.4 Шифрование диска (рекомендация)

Для соответствия требованию «данные на диске зашифрованы» рекомендуется LUKS:

* корень ВМ — LUKS (задаётся при установке Ubuntu, «Encrypt the new Ubuntu
  installation»), либо
* отдельный LUKS-том под `/srv/cloudsuite-s3`, смонтированный в каталог, куда
  указывает `s3_data` (bind-mount или отдельный диск).

Проверка:

```bash
lsblk -o NAME,FSTYPE,MOUNTPOINT | grep -i crypt
sudo cryptsetup status <имя-тома> || true
```

Ограничение: если ключ LUKS вводится вручную, сервер не поднимется после
перезагрузки без оператора. Для продакшена используется либо автоматическая
разблокировка через TPM/keyfile на отдельном носителе, либо явный регламент
перезагрузки с дежурным администратором.

### 4.5 Часы

JWT ONLYOFFICE и audit-логи чувствительны к времени:

```bash
timedatectl status | grep -E 'synchronized|NTP'
```

## 5. Хардненинг контейнеров

В compose для всех сервисов задано:

* `security_opt: [no-new-privileges:true]` — запрет повышения привилегий;
* `restart: unless-stopped`;
* лимиты логирования (ротация без переполнения диска);
* отсутствие `privileged: true` и монтирования `/var/run/docker.sock`;
* конфиги монтируются **read-only** (`config/nginx/`, `config/nextcloud/`,
  `config/redis/`, `config/rbac/`); каталог `config/nextcloud` виден в контейнере как
  `/opt/cloudsuite:ro`, а `config/nextcloud/config/*.config.php` копируются в
  `/var/www/html/config` entrypoint-хуком `10-extra-config.sh` (файловый bind-mount
  в `config/` ломает первый запуск); S3-идентичность создаётся сервисом `s3-init`
  из `.env` (файла `s3.json` в репозитории нет), JWT ONLYOFFICE задаётся только
  переменными окружения
* `app` не публикует портов, `backend`-сеть изолирована.

Проверка:

```bash
docker compose config | grep -c 'no-new-privileges'          # > 0
docker inspect --format '{{.Name}}: {{.HostConfig.Privileged}}' $(docker compose ps -q) | grep -v 'false' || echo "privileged: нет"
docker inspect --format '{{.Name}}: exposed={{len .Config.ExposedPorts}}' $(docker compose ps -q)
```

Дополнительно:

* не ставьте на хост постороннее ПО;
* не подключайтесь к контейнерам `root`-шеллом без необходимости, для
  Nextcloud используйте `-u www-data`;
* не публикуйте в интернет админ-панель SeaweedFS (порт 8888) — доступ только
  через SSH-туннель:
  `ssh -L 8888:127.0.0.1:8888 root@server` → `http://127.0.0.1:8888`.

### 5.1 Доступ к админ-панелям NPM

Порт `127.0.0.1:8181` доступен только по SSH-туннелю. Для самой панели:

1. включите 2FA (TOTP) для учётной записи NPM;
2. смените пароль `NPM_ADMIN_PASSWORD` после первого входа;
3. если админ-панель когда-либо публикуется (не рекомендуется), закройте её
   NPM Access List с basic auth и ограничением по IP — образец в
   [`config/proxy/access-list-s3.md`](../config/proxy/access-list-s3.md).

## 6. Идентификация и доступ

### 6.1 Учётные записи

| Роль | Права | Кто владеет |
|---|---|---|
| Глобальный администратор Nextcloud | всё | ИТ-администратор |
| Администратор группы (руководитель отдела) | управление своей группой | руководитель подразделения |
| Сотрудник | файлы, шары, публичные ссылки | каждый сотрудник |
| Внешний гость | доступ только к выданным шарам | подрядчик/партнёр |
| Аудитор | чтение аудит-логов, без доступа к файлам | ИБ/комплаенс |

Модель ролей, квоты и матрица прав — в [04-rbac-and-sharing.md](04-rbac-and-sharing.md).

### 6.2 Пароли и 2FA

Политика (задаётся приложением `password_policy`):

* минимум 12 символов, смешение регистров, цифры и спецсимволы;
* запрет распространённых паролей;
* срок действия пароля — по политике организации (по умолчанию не форсируется:
  ротация пароля без причины снижает стойкость).

2FA:

* администраторы **обязаны** использовать TOTP;
* для остальных — включение рекомендовано, приказом может быть сделано
  обязательным (`occ twofactorauth:enforce --on`);
* для десктоп-клиентов используются app-пароли (создаются в
  «Настройки → Безопасность»), а не основной пароль.

Проверка:

```bash
docker compose exec -u www-data app php occ twofactorauth:state
docker compose exec -u www-data app php occ config:system:get auth.bruteforce.protection.enabled
docker compose exec -u www-data app php occ config:app:get password_policy minLength
```

### 6.3 Сессии

* `remember_login_cookie_lifetime` ограничен (по умолчанию 15 дней);
* при увольнении сотрудника — деактивация учётной записи и отзыв app-паролей
  (`occ user:disable`, `occ user:auth-tokens:delete`), см.
  [04-rbac-and-sharing.md](04-rbac-and-sharing.md#7-onboarding-и-offboarding).

## 7. Секреты

### 7.1 Где лежат

| Секрет | Переменная | Потребители |
|---|---|---|
| Пароль БД | `POSTGRES_PASSWORD` | `db`, `app`, `cron` |
| Пароль Redis | `REDIS_PASSWORD` | `cache`, `app` |
| Ключи S3 | `S3_ACCESS_KEY` / `S3_SECRET_KEY` | `s3`, `app`, `s3-init` |
| JWT ONLYOFFICE | `ONLYOFFICE_JWT_SECRET` | `onlyoffice`, коннектор Nextcloud |
| Админ Nextcloud | `NEXTCLOUD_ADMIN_PASSWORD` | первичное создание админа |
| Админ NPM | `NPM_ADMIN_PASSWORD` | первичный вход в GUI |
| Парольная фраза бэкапа | `BACKUP_PASSPHRASE` | `scripts/backup.sh`, `scripts/restore.sh` |

`.env` создаётся из `.env.example`, секреты заполняет
`scripts/generate-secrets.sh` (`openssl rand -hex 32`), права `600`.

Проверка:

```bash
stat -c '%a %U:%G %n' .env
grep -c '=$' .env || true   # пустых значений быть не должно (кроме необязательных)
```

`.env` **никогда** не коммитится (см. `.gitignore`), не копируется в
чаты и тикеты, не попадает в бэкап в открытом виде — только внутри
зашифрованного архива.

### 7.2 Ротация

| Секрет | Как ротировать | Что сломается в процессе |
|---|---|---|
| `POSTGRES_PASSWORD` | `ALTER USER` в БД → обновить `.env` → `docker compose up -d` | краткий 502 у `app` |
| `REDIS_PASSWORD` | новый пароль в `.env` → перезапуск `cache` и `app` | кэш теряется, сессии не рвутся |
| `S3_ACCESS_KEY/SECRET` | новые ключи в `.env` → `docker compose up -d s3-init` (пересоздаёт identity в SeaweedFS) → `docker compose restart app` | короткая недоступность S3 |
| `ONLYOFFICE_JWT_SECRET` | новый секрет в `.env` **и** в настройках коннектора → перезапуск `onlyoffice` | открытые редакторы теряют сессию, несохранённое — потеряется |
| `BACKUP_PASSPHRASE` | только вместе со сменой всех архивов; храните старую фразу до истечения срока хранения | старые бэкапы без старой фразы не читаются |

Правило: любая ротация — через `make backup` **до** изменений.

### 7.3 Компрометация ключа

1. Немедленно ротировать затронутый секрет (таблица выше).
2. Проверить audit-лог за период (`scripts/audit-report.sh`).
3. Отозвать сессии: `occ user:auth-tokens:delete --all` для подозрительных
   учётных записей, сменить пароли.
4. Если скомпрометирован `BACKUP_PASSPHRASE` — считать все архивы
   прочитанными; сменить фразу, перевыпустить бэкапы, уведомить ИБ.

## 8. Защита данных

* **В транзите:** TLS 1.2/1.3 на всём внешнем периметре; внутренние вызовы
  Nextcloud↔OnlyOffice идут по HTTPS на публичные имена, разрешённые в
  `172.28.10.10`.
* **В покое:** LUKS на хосте (п. 4.4), шифрование бэкапов.
* **Изоляция:** S3 и БД недоступны из интернета; административные интерфейсы — на
  loopback.
* **Минимизация:** в публичную ссылку не попадают имена других файлов; гость видит
  только то, что ему расшарили.
* **Удаление:** файл сначала попадает в корзину (`TRASH_RETENTION_DAYS`), затем
  удаляется безвозвратно; для требований «удалить немедленно» используйте
  `occ trashbin:cleanup <user>`. Учтите: версии в S3 удаляются
  прунером не мгновенно — см. [06-versioning-and-retention.md](06-versioning-and-retention.md).

## 9. Регламент обновлений

| Что | Частота | Процедура |
|---|---|---|
| ОС (security) | еженедельно, автоматически | `unattended-upgrades`, перезагрузка по окну |
| Образы контейнеров (patch) | ежемесячно | `make update` (бэкап → pull → up → `occ upgrade` → healthcheck) |
| Nextcloud major (35 → 36) | 1–2 раза в год, по плану | тест на staging, окно обслуживания, `occ upgrade` |
| ONLYOFFICE | по мере выхода | только фиксированные версии, проверка ко-редактирования после |
| PostgreSQL/Redis | по необходимости | с бэкапом, в окно обслуживания |
| NPM | по необходимости | бэкап томов `proxy_data`/`proxy_letsencrypt` |

Перед обновлением: `make backup`, `make status`, прочитать CHANGELOG
компонента. После: `make doctor`, `make smoke`, проверить
[12-acceptance-checklist.md](12-acceptance-checklist.md) в объёме smoke.

## 10. Аудит и мониторинг безопасности

Минимальный набор сигналов:

* серия неуспешных входов (`login` с результатом `false`) — рост в 5 раз;
* вход администратора;
* создание публичной ссылки без пароля (если политика запрещает);
* изменение групп/ролей;
* удаление большого числа файлов;
* 5xx и 429 на `/login` в nginx-логе;
* истечение сертификата < 14 дней.

Как читать логи — [05-audit-logging.md](05-audit-logging.md).

## 11. Безопасность резервных копий

* бэкап-каталог `BACKUP_DIR` — `700`, владелец root;
* архивы шифруются (`BACKUP_PASSPHRASE`), ключ хранится отдельно от сервера
  (менеджер паролей/сейф);
* offsite-копия (`BACKUP_OFFSITE_REMOTE`) — отдельный аккаунт, не тот же,
  что используется для работы;
* раз в квартал — проверка восстановления (drill), см.
  [07-backup-restore-dr.md](07-backup-restore-dr.md#6-учебное-восстановление-drill).

## 12. Чек-лист безопасности

Отметьте каждый пункт перед вводом в эксплуатацию; команды проверки приведены в
соответствующих разделах.

- [ ] Порты 5432/6379/8333/9000/8888/9333 не видны из интернета.
- [ ] UFW включён, разрешены только 22/80/443.
- [ ] SSH: только ключи, root-пароль запрещён, fail2ban активен.
- [ ] Сертификаты Let's Encrypt валидны на обоих доменах, Force SSL + HSTS включены.
- [ ] `.env` с правами 600, не в git, секреты не пустые.
- [ ] Пароль NPM сменён, 2FA на NPM включена, порт 8181 — только loopback.
- [ ] Пароль администратора Nextcloud сменён, 2FA включена, `twofactorauth:enforce` — по политике.
- [ ] Политика паролей 12+ символов, bruteforce protection включён.
- [ ] `admin_audit` пишет события, лог ротируется.
- [ ] `ONLYOFFICE_JWT_SECRET` задан одинаково в `.env` и коннекторе, пустой JWT отклоняется.
- [ ] Публичные ссылки по умолчанию с паролем и сроком действия.
- [ ] Бэкап создан, зашифрован, восстановление проверено.
- [ ] LUKS включён (или задокументирован отказ с подписью ИБ).
- [ ] Мониторинг неуспешных входов и срока сертификата настроен.

## 13. Связанные документы

* [02-deployment.md](02-deployment.md) — установка, включая NPM и OnlyOffice.
* [04-rbac-and-sharing.md](04-rbac-and-sharing.md) — роли, шары, публичные ссылки.
* [05-audit-logging.md](05-audit-logging.md) — журналирование.
* [07-backup-restore-dr.md](07-backup-restore-dr.md) — бэкапы и DR.
* [09-operations-runbook.md](09-operations-runbook.md) — эксплуатация.
* [11-troubleshooting.md](11-troubleshooting.md) — диагностика инцидентов.

