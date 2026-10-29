# 09. Эксплуатация (runbook)

Регламент ежедневной, еженедельной и ежемесячной эксплуатации Cloud Suite,
инцидент-плейбуки и процедура обновления. Диагностика технических сбоев —
в [11-troubleshooting.md](11-troubleshooting.md); здесь — «что и когда делать».

## 1. Ответственность и окна

| Роль | Зона |
|---|---|
| Администратор Cloud Suite | сервис целиком: доступность, бэкапы, обновления, инциденты |
| ИБ / аудитор | аудит-логи, доступы, проверка политик |
| Руководитель отдела | состав групп и квоты своего подразделения |

Окна обслуживания: ночь 01:00–05:00 по часовому поясу организации. Nextcloud
выполняет тяжёлые фоновые задачи в окне с 01:00 (`maintenance_window_start = 1`),
поэтому обновления и ручные работы планируйте после 02:00.

## 2. Ежедневно (утром, 10–15 минут)

```bash
cd /opt/cloudsuite

# 1) состояние сервисов и healthcheck
make status
./scripts/healthcheck.sh

# 2) ошибки за сутки
jq -c 'select(.status >= 500)' logs/nginx/access.json.log | tail -n 20
tail -n 100 logs/cloudsuite/nextcloud.log | jq -c 'select(.level >= 3)'

# 3) диск и память
df -h /; free -m; docker system df

# 4) свежесть бэкапа (ожидаем вчерашний каталог)
ls -1dt backups/backup-* 2>/dev/null | head -n 1

# 5) неуспешные входы
./scripts/audit-report.sh --from "$(date -d '-1 day' +%F)" --limit 50
```

Чек-лист дня:

- [ ] Все контейнеры `healthy` (кроме `s3-init` — он одноразовый, код 0).
- [ ] `healthcheck.sh` без ошибок.
- [ ] Нет роста 5xx и ошибок уровня error в логах.
- [ ] Свободно больше 20 % диска; том `s3_data` растёт предсказуемо.
- [ ] Бэкап за последние 26 часов существует и не пуст.
- [ ] Нет аномалий в неуспешных входах (одно-два — норма, десятки с одного IP — инцидент).
- [ ] Сертификаты действительны больше 14 дней.

## 3. Еженедельно (30 минут)

```bash
# прунер версий (если не вынесен в ежедневный cron)
make prune-versions

# проверка бэкапа: контрольные суммы и метаданные
newest=$(ls -1dt backups/backup-* | head -n 1)
( cd "$newest" && sha256sum -c manifest.sha256 | tail -n 3 )

# ротация логов
sudo install -m 644 config/logrotate/cloudsuite /etc/logrotate.d/cloudsuite
sudo logrotate --debug /etc/logrotate.d/cloudsuite

# обновления ОС и хоста
sudo apt-get update && apt-get -s upgrade | grep -c '^Inst' || true

# состояние S3/БД/Redis
docker compose exec -T db pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB"
docker compose exec -T cache redis-cli -a "$REDIS_PASSWORD" --no-auth-warning info memory | head -n 5
```

- [ ] Отчёт прунера: `errors=0`, `versions_deleted` соответствует ожиданиям.
- [ ] Бэкап проверен, offsite-копия обновлена (если включена).
- [ ] Логи ротированы, архивы на месте, места хватает.
- [ ] Нет критичных обновлений безопасности, требующих немедленной установки.
- [ ] Список пользователей и групп соответствует кадровым изменениям (сверка с HR).
- [ ] Публичные ссылки без пароля или с истёкшим сроком — нет (политика).

## 4. Ежемесячно (2–3 часа)

```bash
# 1) обновление образов (в окно, с бэкапом)
make backup
make update

# 2) проверка версий и логики удаления
docker compose ps --format 'table {{.Name}}\t{{.Status}}\t{{.Image}}'

# 3) ёмкость
df -h /; docker compose exec -T s3 df -h /data 2>/dev/null || true
du -sh backups logs

# 4) ревизия доступов
./scripts/occ.sh user:list --output=json | jq -r '.[].uid' | head -n 50
./scripts/occ.sh group:list
```

- [ ] Обновления применены, `make doctor` и `make smoke` зелёные.
- [ ] Бэкап после обновления создан.
- [ ] Ёмкость: прогноз заполнения диска больше 3 месяцев (иначе — расширение).
- [ ] Отчёт по квотам: нет пользователей на 95 %+ (согласовать расширение или чистку).
- [ ] Уволенные/подрядчики с истёкшим сроком — отключены, сессии отозваны.
- [ ] Проверено, что `ROTATE` и `admin_audit` пишут, архивы аудита сохранены.

## 5. Ежеквартально

- [ ] Учебное восстановление на отдельной ВМ по
      [07-backup-restore-dr.md](07-backup-restore-dr.md) (протокол).
- [ ] Пересмотр матрицы ролей и квот ([04-rbac-and-sharing.md](04-rbac-and-sharing.md)).
- [ ] Проверка парольной политики и обязательности 2FA.
- [ ] Сканирование портов снаружи (только 80/443).
- [ ] Обновление документации при изменениях конфигурации.
- [ ] Проверка срока хранения audit-логов и выгрузки в SIEM.

## 6. Команды эксплуатации

| Задача | Команда | Комментарий |
|---|---|---|
| Справка | `make help` | список всех целей |
| Статус | `make status` | `docker compose ps` + healthcheck |
| Логи | `make logs` | все сервисы; можно `make logs SERVICE=app` |
| Проверка окружения | `make doctor` | preflight + healthcheck |
| Первичная настройка | `make bootstrap` | идемпотентно |
| Запуск/остановка | `make up` / `make down` | `down` не удаляет тома |
| Перезапуск | `make restart` | без простоя данных |
| Настройка Nextcloud | `make configure` | идемпотентно |
| Роли | `make rbac` | по `config/rbac/roles.yaml`; `DRY_RUN=1` для плана |
| Прунер версий | `make prune-versions` | сначала `make prune-versions-dry-run` |
| Бэкап | `make backup` | см. [07](07-backup-restore-dr.md) |
| Восстановление | `make restore` | требует `--confirm` |
| Обновление | `make update` | бэкап + pull + up + `occ upgrade` |
| occ | `./scripts/occ.sh <команда>` | от имени www-data |
| Shell в контейнере | `make shell-app` / `make shell-db` | отладка app и psql |
| Дымовые тесты | `make smoke` | end-to-end проверка |
| Валидация репозитория | `make test` | python tests/validate.py |
| Линтеры | `make lint` | shellcheck + py_compile |
| Миграция | `make migrate` | прокси к migrate-yandex-disk.sh |
| Аудит-отчёт | `./scripts/audit-report.sh` | см. [05](05-audit-logging.md) |
| Очистка | `make clean` | останавливает стек и убирает временные файлы, **тома сохраняются** |
| Полное удаление | `make nuke FORCE=yes` | **разрушительно**: удаляет контейнеры и тома |

## 7. Расписания (cron хоста)

| Задача | Расписание | Команда |
|---|---|---|
| Бэкап полный | ежедневно 02:30 | `make backup` |
| Бэкап инкрементальный | каждые 4 часа | `./scripts/backup.sh --incremental` |
| Прунер версий | ежечасно (с flock) | `flock -n /var/lock/cloudsuite-prune.lock make prune-versions` |
| healthcheck в лог | каждые 5 минут | `./scripts/healthcheck.sh --quiet` |
| Ротация логов | ежедневно | системный logrotate (`config/logrotate/cloudsuite`) |

Пример `/etc/cron.d/cloudsuite`:

```bash
# /etc/cron.d/cloudsuite (root)
30 2 * * *      root cd /opt/cloudsuite && make backup >> /var/log/cloudsuite/backup.log 2>&1
0 */4 * * *     root cd /opt/cloudsuite && ./scripts/backup.sh --incremental --keep 24 >> /var/log/cloudsuite/backup-inc.log 2>&1
17 * * * *      root cd /opt/cloudsuite && flock -n /var/lock/cloudsuite-prune.lock make prune-versions >> /var/log/cloudsuite/prune.log 2>&1
*/5 * * * *     root cd /opt/cloudsuite && ./scripts/healthcheck.sh --json >> /var/log/cloudsuite/health.log 2>&1
15 3 * * 0      root cd /opt/cloudsuite && ./scripts/prune-versions.sh --quiet >> /var/log/cloudsuite/prune.log 2>&1
```

Вместо cron можно использовать systemd-timer (пример для бэкапа):

```ini
# /etc/systemd/system/cloudsuite-backup.service
[Unit]
Description=Cloud Suite backup
[Service]
Type=oneshot
WorkingDirectory=/opt/cloudsuite
ExecStart=/opt/cloudsuite/scripts/backup.sh

# /etc/systemd/system/cloudsuite-backup.timer
[Unit]
Description=Daily Cloud Suite backup
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cloudsuite-backup.timer
```

## 8. Инцидент-плейбуки

Общий порядок: зафиксировать время и симптом → проверить `make status` →
локализовать слой (NPM / web / app / db / cache / s3 / onlyoffice) → устранить →
записать в журнал инцидентов.

### 8.1 Сайт не открывается (502/503/таймаут)

1. `docker compose ps` — кто не `healthy`;
2. `docker compose logs --tail=100 proxy web app`;
3. `curl -sSI https://$CLOUD_DOMAIN/status.php` изнутри/снаружи;
4. перезапуск проблемного сервиса: `docker compose restart <сервис>`;
5. если не помогло — [11-troubleshooting.md](11-troubleshooting.md), разделы 3–6.

### 8.2 Вход работает, файлы не открываются

Признак проблемы S3 (500/503 на скачивании): проверить
`docker compose ps s3`, логи `docker compose logs --tail=200 s3`, место на
диске. Перезапуск `s3` безопасен. Если бакет «пропал» — `NoSuchBucket`,
см. [11](11-troubleshooting.md#71-nosuchbucket).

### 8.3 OnlyOffice: «Download failed» / не открывается документ

1. из контейнера `onlyoffice` проверить доступность `$CLOUD_DOMAIN`
   (`docker compose exec onlyoffice curl -sS -o /dev/null -w '%{http_code}' https://cloud.example.com/status.php`);
2. сверить JWT: `.env` ↔ настройки коннектора;
3. `docker compose logs --tail=200 onlyoffice`;
4. перезапуск `onlyoffice`; при повторении — [11](11-troubleshooting.md#12-onlyoffice).

### 8.4 Ко-редактирование обрывается

Проверить WebSocket через NPM: `proxy_http_version 1.1`, `Upgrade`/`Connection`,
таймауты 3600 с в Advanced-конфиге `office.example.com`; в браузере —
DevTools → WS → 101. Корпоративный прокси/антивирус может рвать WS: проверить из
другой сети.

### 8.5 «File is locked» / ошибки блокировок

1. `docker compose exec cache redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping`;
2. проверить пароль Redis в `.env` и `config/redis/redis.conf`;
3. перезапустить `cache` и `app`;
4. при массовых блокировках — `./scripts/occ.sh maintenance:repair`.

### 8.6 Диск заполнен

1. `df -h`, `du -sh data logs backups`;
2. очистить старые бэкапы (соблюдая retention) и сжатые логи;
3. `./scripts/occ.sh trashbin:cleanup --all-users`;
4. `docker image prune`;
5. если растёт `s3_data` — это данные: расширять том/диск, не удалять.

### 8.7 Не продлевается сертификат

1. проверить A-запись и доступность порта 80 снаружи;
2. `docker compose logs --tail=100 proxy` (сообщения ACME);
3. в NPM — Renew Certificate; при повторной ошибке временно использовать
   самоподписанный сертификат и разбираться (лимиты LE, DNS, firewall).

### 8.8 Обновление сломало сервис

1. не паниковать: `make down`, восстановить бэкап
   (`./scripts/restore.sh --confirm`);
2. сохранить логи и версии образов для разбора;
3. вернуть предыдущие теги в `.env` (`NEXTCLOUD_VERSION`, `ONLYOFFICE_VERSION` и др.),
   `make up`, при необходимости `occ upgrade`.

## 9. Процедура обновления

Обновление всегда в окно обслуживания, всегда с бэкапом.

```bash
cd /opt/cloudsuite

# 1) зафиксировать текущее состояние
make status > /tmp/before.txt
docker compose ps --format 'table {{.Name}}\t{{.Image}}' > /tmp/images-before.txt

# 2) бэкап
make backup

# 3) обновление (скрипт: pull образов, up -d, ожидание healthy, occ upgrade)
make update
# или напрямую
./scripts/update.sh

# 4) проверка
make doctor
make smoke
```

Что делает `scripts/update.sh`:

1. проверяет, что стек здоров и бэкап свежий;
2. включает режим обслуживания Nextcloud;
3. делает `docker compose pull` для образов с плавающими тегами;
4. поднимает новые контейнеры и ждёт `healthy`;
5. выполняет `occ upgrade`, `occ maintenance:repair`, отключает режим
   обслуживания;
6. запускает healthcheck.

Правила:

* major-обновление Nextcloud (35 → 36) — только после теста на staging и чтения
  upgrade-notes; пропускать major-версии нельзя;
* ONLYOFFICE обновляется отдельно: проверьте, что коннектор совместим;
* PostgreSQL major-обновление требует `pg_upgrade` — это отдельная процедура,
  не «pull нового образа»;
* откат — восстановление бэкапа, а не «pull предыдущего тега» (схема БД уже
  обновлена).

## 10. Масштабирование и ёмкость

Порядок действий при росте нагрузки:

| Симптом | Действие |
|---|---|
| CPU php-fpm 90 %+ | увеличить vCPU; поднять `PHP_MEMORY_LIMIT`; проверить медленные запросы |
| RAM 90 %+ | вынести ONLYOFFICE на отдельную ВМ (сменить `OFFICE_DOMAIN` и настройку коннектора) |
| Диск под S3 заканчивается | добавить диск и перенести том, либо добавить volume-сервер SeaweedFS |
| Много одновременных редакторов | реплики Document Server за балансировщиком (нужен общий Redis для DS) |
| Медленная БД | отдельная ВМ PostgreSQL, `shared_buffers` 25 % RAM, регулярный `VACUUM` |
| Нужна отказоустойчивость | второй `app`-узел за NPM, общие S3/БД/Redis |

Ёмкость: см. формулу в [01-architecture.md](01-architecture.md#11-требования-к-ресурсам)
и [06-versioning-and-retention.md](06-versioning-and-retention.md#8-расчёт-ёмкости).
Держите заполнение диска ниже 80 %: S3 и PostgreSQL деградируют при нехватке места.

## 11. Логи и наблюдаемость

| Что | Где | Как читать |
|---|---|---|
| Аудит | `logs/cloudsuite/audit.log` | `./scripts/audit-report.sh`, jq |
| Приложение | `logs/cloudsuite/nextcloud.log` | jq по `.level` |
| nginx | `logs/nginx/access.json.log`, `error.log` | jq по `.status` |
| ONLYOFFICE | том `onlyoffice_logs` | `docker compose logs onlyoffice` |
| Docker | json-file 20 МБ × 5 | `docker compose logs` |

Обязательные алерты: 5xx > 1 % за 5 минут, healthcheck failed, диск < 20 %,
бэкап старше 26 часов, сертификат < 14 дней, всплеск неуспешных входов.

Опциональный профиль наблюдаемости (Loki + Promtail) включается оверлеем:

```bash
make COMPOSE="docker compose -f docker-compose.yml -f docker-compose.observability.yml --profile observability" up
```

Loki слушает только loopback (`LOKI_BIND=127.0.0.1`, порт 3100, ретенция `LOKI_RETENTION=720h`),
Promtail читает `./logs` и stdout контейнеров проекта. Без профиля базовый стек не
меняется. Подключение rsyslog — в [05-audit-logging.md](05-audit-logging.md).

## 12. Передача смены

Перед уходом в отпуск/передачей дежурства:

- [ ] `make status` и `make doctor` — зелёные.
- [ ] Последний бэкап создан и проверен, offsite обновлён.
- [ ] Нет незавершённых обновлений/миграций.
- [ ] Активные инциденты и их статус записаны.
- [ ] Доступы (SSH, NPM, .env, парольная фраза бэкапа) есть у принимающего.

## 13. Журнал эксплуатации

Ведите файл `docs/operations-log.md` (вне репозитория или в закрытом вики):
дата, тип работ, кто, что сделано, результат, ссылки на тикеты. Для аудита
достаточно записи «кто, когда, что менял», подкреплённой audit-логом и историей git.

## 14. Связанные документы

* [02-deployment.md](02-deployment.md) — установка.
* [03-security-hardening.md](03-security-hardening.md) — безопасность.
* [05-audit-logging.md](05-audit-logging.md) — аудит.
* [06-versioning-and-retention.md](06-versioning-and-retention.md) — версии.
* [07-backup-restore-dr.md](07-backup-restore-dr.md) — бэкапы и DR.
* [11-troubleshooting.md](11-troubleshooting.md) — диагностика.
* [12-acceptance-checklist.md](12-acceptance-checklist.md) — приёмка.
