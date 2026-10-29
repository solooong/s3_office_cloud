# 07. Резервное копирование и восстановление (DR)

## 1. Стратегия

Принцип 3-2-1: **три** копии данных, на **двух** разных носителях, **одна** — вне
сервера. Для Cloud Suite это:

1. рабочий сервер (тома Docker);
2. локальный бэкап-каталог (переменная `BACKUP_DIR`, по умолчанию `./backups`);
3. offsite-копия через rclone (S3/WebDAV/другой сервер) — `BACKUP_OFFSITE_REMOTE`.

| Параметр | Значение по умолчанию | Комментарий |
|---|---|---|
| RPO (потеря данных) | 24 часа | период запуска `make backup`; для RPO в 1 час запускайте ежечасно |
| RTO (время восстановления) | 1–2 часа на 1 ТБ данных | зависит от размера S3-тома и скорости диска |
| Срок хранения | `BACKUP_RETENTION_DAYS=30` | плюс минимум 3 последних архива сохраняются всегда |
| Шифрование | AES-256-CBC (PBKDF2) | конфигурация и .env; тома и дамп БД защищает LUKS |

## 2. Что входит в бэкап

Скрипт `scripts/backup.sh` создаёт самодостаточный каталог:

```text
BACKUP_DIR/backup-YYYYmmdd-HHMMSS/
├── meta.env             версии образов, компоненты, RPO-якорь (без секретов)
├── db.dump              pg_dump -Fc -Z 6 (транзакционно консистентный)
├── redis.rdb            снимок Redis (пересоздаваемый, но ускоряет RTO)
├── vol-db_data.tar.gz
├── vol-s3_data.tar.gz   ← сами файлы пользователей
├── vol-nextcloud_html.tar.gz
├── vol-nextcloud_data.tar.gz
├── vol-proxy_data.tar.gz
├── vol-proxy_letsencrypt.tar.gz
├── config.tar.gz.enc    .env + config/ + compose-файлы (AES-256, PBKDF2)
└── manifest.sha256      контрольные суммы всех артефактов

# в BACKUP_DIR также обновляется симлинк LATEST -> последний полный бэкап,
# поэтому пути вида backups/LATEST/ работают в скриптах и cron
```

Почему нужны **оба** компонента — БД и S3:

| Компонент | Что содержит | Что будет при потере |
|---|---|---|
| `db.dump` | пользователи, группы, права, дерево файлов, шары, версии, настройки | бакет S3 останется «мусором»: без метаданных дерево файлов не восстановить |
| `vol-s3_data` | сами объекты файлов (`urn:oid:*`) | дамп БД ссылается в пустоту, файлы недоступны |
| `vol-nextcloud_html` | код, `config.php`, приложения | потребуется переустановка и `occ upgrade` |
| `vol-nextcloud_data` | превью, аватары, appdata | пересоздаётся, потери данных нет (первый вход медленнее) |
| `vol-proxy_*` | конфиг NPM, сертификаты | сертификаты перевыпускаются, proxy hosts настраиваются заново |
| `config.tar.gz.enc` | .env, `config/`, compose-файлы | восстановление параметров «на глаз» — часы работы |
| `redis.rdb` | кэш и блокировки | пересоздаётся, критичных потерь нет |

## 3. Запуск

### 3.1 Вручную

```bash
# полный бэкап (прогресс пишется в stderr)
make backup

# то же напрямую, с явным логом
./scripts/backup.sh 2>&1 | tee "/var/log/cloudsuite/backup-$(date +%F).log"
```

Флаги `scripts/backup.sh`:

| Флаг | Назначение |
|---|---|
| `--only db,redis,volumes,config` | выбрать компоненты (по умолчанию все четыре) |
| `--incremental` | тома через rsync с жёсткими ссылками (экономия места; нужен root) |
| `--no-offsite` | не копировать в `BACKUP_OFFSITE_REMOTE` |
| `--keep N` | всегда оставлять N последних архивов (по умолчанию 3) |
| `--dry-run` | напечатать команды, ничего не делать |

Коды возврата: `0` — успех, `1` — фатальная ошибка, `2` — успех с
предупреждениями (например, offsite-копия не удалась). В cron код 2 должен
порождать алерт, но не считать бэкап провалившимся.

Проверка целостности после создания:

```bash
cd backups/LATEST
sha256sum -c manifest.sha256 | tail -n 5
cat meta.env        # версии образов, компоненты, RPO-якорь
```

### 3.2 Расписание (cron)

```bash
sudo tee /etc/cron.d/cloudsuite-backup >/dev/null <<'EOF'
# Полный бэкап ежедневно в 02:30, инкрементальный — каждые 4 часа
30 2 * * *   root cd /opt/cloudsuite && make backup >> /var/log/cloudsuite/backup.log 2>&1
0 */4 * * *  root cd /opt/cloudsuite && ./scripts/backup.sh --incremental >> /var/log/cloudsuite/backup-inc.log 2>&1
EOF
sudo chmod 644 /etc/cron.d/cloudsuite-backup
```

Инкрементальный режим требует запуска от root (читает mountpoint’ы томов
напрямую) и установленного `rsync`.

Если `BACKUP_OFFSITE_REMOTE` задан, offsite-копия выполняется в том же прогоне;
при недоступности remote скрипт завершится кодом 2 и сохранит локальную копию.

## 4. Шифрование и доступ

* `config.tar.gz.enc` шифруется `openssl enc -aes-256-cbc -pbkdf2 -salt` (600000
  итераций PBKDF2) с
  `BACKUP_PASSPHRASE`; пароль передаётся только через переменную окружения и
  **никогда** не попадает в лог;
* `BACKUP_PASSPHRASE` хранится в менеджере паролей или сейфе, отдельно от сервера;
* каталог бэкапов — `700`, владелец root;
* тома и `db.dump` не шифруются на уровне скрипта — их защищает LUKS на диске
  и права доступа. Если политика требует шифровать всё, разместите `BACKUP_DIR` на
  LUKS-томе или добавьте шифрование после прогона:

```bash
tar -C backups/backup-20261026-033000 -czf - . \
  | openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BACKUP_PASSPHRASE \
    -out backups/backup-20261026-033000.full.enc
```

Проверить, что ключ действительно нужен:

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -in backups/backup-*/config.tar.gz.enc -pass pass:wrong 2>&1 | head -n 2
# ожидаемо: bad decrypt
```

## 5. Offsite-копия (rclone)

```bash
# в .env
BACKUP_OFFSITE_REMOTE=remote:cloudsuite-backups
```

Настройка remote (пример для S3-совместимого хранилища):

```bash
rclone config create offsite s3 provider=Other \
  access_key_id=... secret_access_key=... endpoint=https://s3.provider.example \
  --config /root/.config/rclone/rclone.conf
rclone lsd offsite:
```

Скрипт копирует каталог `backup-*` целиком и проверяет размеры
(`rclone check --size-only`). Полное совпадение содержимого проверяется вручную при
учебном восстановлении.

Требования к offsite:

* отдельный аккаунт и учётные данные, не те же, что в работе;
* включённое версионирование или object-lock, если хранилище поддерживает;
* доступ только по ключу, MFA на аккаунт хранилища;
* срок хранения не меньше `BACKUP_RETENTION_DAYS`.

## 6. Восстановление после полной потери сервера

Сценарий: сервер уничтожен или недоступен, есть бэкап (локальный диск уцелел или
взят offsite-архив). Порядок рассчитан на новую ВМ с той же ОС.

### Шаг 1. Подготовка новой ВМ

1. Разверните Ubuntu 24.04 с тем же публичным IP (или обновите DNS на новый IP).
2. Установите Docker и compose plugin (раздел 3 [02-deployment.md](02-deployment.md)),
   sysctl и лимиты (раздел 4).
3. Восстановите DNS-записи `CLOUD_DOMAIN` и `OFFICE_DOMAIN`.

До восстановления NPM не поднимайте: сертификаты вернутся из бэкапа, но ACME-валидация
без DNS работать не будет.

### Шаг 2. Код и бэкап

```bash
sudo mkdir -p /opt && cd /opt
sudo git clone <URL-репозитория> cloudsuite && cd cloudsuite

# скопируйте каталог бэкапа с локального диска или с offsite
sudo rsync -a backup-20261026-033000/ /opt/cloudsuite/backups/backup-20261026-033000/
```

### Шаг 3. Восстановление

```bash
# 1) план: проверяет manifest, печатает RPO и последовательность, ничего не меняет
./scripts/restore.sh --dir backups/backup-20261026-033000 --dry-run

# 2) восстановление
./scripts/restore.sh --dir backups/backup-20261026-033000 --confirm

# 3) без интерактивного подтверждения (автоматизация)
./scripts/restore.sh --dir backups/backup-20261026-033000 --confirm --yes
```

Что делает `restore.sh`:

1. проверяет `sha256sum -c manifest.sha256`;
2. останавливает контейнеры (тома не удаляются);
3. расшифровывает `config.tar.gz.enc` и восстанавливает `.env` и `config/`;
4. восстанавливает именованные тома (`db_data`, `s3_data`, `nextcloud_*`,
   `proxy_*`);
5. пересоздаёт базу (`DROP DATABASE ... WITH (FORCE)` + `createdb`) и выполняет
   `pg_restore`;
6. по флагу `--with-redis` восстанавливает снимок Redis;
7. поднимает стек и ждёт состояния `healthy`;
8. выполняет `occ status`, снимает режим обслуживания, запускает
   `occ files:scan --all` и `scripts/healthcheck.sh`;
9. печатает RPO (возраст бэкапа) и RTO (фактическая длительность).

По умолчанию восстанавливаются `db,volumes,config` (Redis — только с `--with-redis`).
Флаги: `--only db,volumes,config`, `--with-compose` (вернуть и compose-файлы),
`--safety-backup` (сделать бэкап текущего состояния перед восстановлением),
`--no-verify` (не рекомендуется), `--dry-run`.

### Шаг 4. Проверка после восстановления

```bash
make status
./scripts/healthcheck.sh
./scripts/occ.sh status
./scripts/occ.sh files:scan --all
./scripts/occ.sh maintenance:mode --off
curl -fsS https://cloud.example.com/status.php | jq .
```

Проверьте вручную: вход администратором, открытие файла, скачивание, открытие
документа в OnlyOffice, работу ранее созданной публичной ссылки, наличие версий и
корзины.

### Шаг 5. После восстановления

1. смените `NEXTCLOUD_ADMIN_PASSWORD` и `NPM_ADMIN_PASSWORD`, если бэкап мог быть
   скомпрометирован;
2. проверьте сертификаты в NPM (Renew), если бэкап старый;
3. запустите `make backup` — зафиксируйте новую точку;
4. запишите фактический RTO в DR-журнал.

## 7. Ситуационные сценарии

| Сценарий | Что восстанавливать | Команда | Ожидаемый RTO |
|---|---|---|---|
| Потеря только БД | `db.dump` | `./scripts/restore.sh --only db --confirm` | 20–40 мин |
| Повреждён или удалён том S3 | `vol-s3_data` и БД (для консистентности) | `./scripts/restore.sh --only volumes,db --confirm` | 1–3 ч |
| Случайно удалён файл (в корзине нет) | `vol-s3_data` и БД на отдельный стенд, забрать один файл | восстановление на staging, затем копирование через WebDAV | 2–4 ч |
| Потеря конфигурации (.env, config/) | `config.tar.gz.enc` | `./scripts/restore.sh --only config --confirm` | 10 мин |
| Потеря сертификатов и конфига NPM | `proxy_data`, `proxy_letsencrypt` | `./scripts/restore.sh --only volumes --confirm` | 20 мин |
| Шифровальщик зашифровал тома | последний чистый бэкап целиком | полный restore на новую ВМ | 1–3 ч |
| Провалился `occ upgrade` | БД, тома и `nextcloud_html` из бэкапа **до** обновления | полный restore | 1–2 ч |
| Умер диск, ВМ цела | новые диски и последний бэкап | полный restore | 1–2 ч |

После любого восстановления обязательно `occ files:scan --all`: файловый кэш в
БД должен совпадать с объектами S3.

## 8. Учебное восстановление (drill)

Проводится **раз в квартал** (и после каждого крупного обновления) на отдельной ВМ,
не на продакшене. Занимает 2–4 часа, оформляется протоколом.

- [ ] Выбран бэкап не старше 7 дней (или специально «старый» — для проверки).
- [ ] `manifest.sha256` проверен: все файлы `OK`.
- [ ] `restore.sh --dry-run` показывает корректные RPO и состав.
- [ ] Полное восстановление выполнено на чистую ВМ.
- [ ] `occ status`: `installed: true`, `maintenance: false`.
- [ ] `occ files:scan --all` без ошибок.
- [ ] Вход администратором и обычным пользователем.
- [ ] Файлы открываются, размеры совпадают (выборочно 10 файлов).
- [ ] Публичная ссылка из «прошлой жизни» работает.
- [ ] OnlyOffice открывает и сохраняет документ.
- [ ] Сертификаты: сайт доступен по HTTPS без ошибок TLS.
- [ ] Замерен и записан RTO и RPO.
- [ ] Найденные расхождения оформлены как задачи с приоритетом.
- [ ] Протокол подписан, факт drill занесён в журнал эксплуатации.

## 9. Мониторинг бэкапов

Минимальный набор проверок (ежедневно):

```bash
# 1) свежий бэкап существует и не пустой
ls -1dt backups/backup-* | head -n 1
du -sh "$(ls -1dt backups/backup-* | head -n 1)"

# 2) возраст последнего бэкапа не больше 26 часов
newest=$(ls -1dt backups/backup-* | head -n 1)
find "$newest" -maxdepth 0 -mmin -1560 | grep -q . || echo "ALERT: backup older than 26h"

# 3) свободное место под бэкапы
df -h "$(dirname "$newest")" | tail -n 1

# 4) offsite: последние каталоги на удалённой стороне
rclone lsf "$BACKUP_OFFSITE_REMOTE/" --dirs-only | tail -n 3
```

Алерты: возраст бэкапа больше 26 ч, ошибки в `/var/log/cloudsuite/backup.log`,
код возврата 1, свободное место меньше 20 ГиБ, offsite не обновлялся больше 48 ч.

## 10. Ограничения

* бэкап делается «на живую»: `pg_dump` консистентен, тома снимаются после дампа,
  но файл, записанный в момент снятия тома, может попасть или не попасть в копию —
  для строгой консистентности остановите запись (`make down`) на время бэкапа;
* открытые сессии ONLYOFFICE при восстановлении теряются;
* восстановление поверх работающего стека перезаписывает данные — всегда начинайте
  с `--dry-run` и при сомнениях используйте `--safety-backup`;
* бэкап не заменяет версии файлов: чтобы вернуть отдельную версию, используйте
  [06-versioning-and-retention.md](06-versioning-and-retention.md).

## 11. Связанные документы

* [01-architecture.md](01-architecture.md) — что где хранится.
* [02-deployment.md](02-deployment.md) — установка с нуля.
* [03-security-hardening.md](03-security-hardening.md) — защита бэкапов.
* [06-versioning-and-retention.md](06-versioning-and-retention.md) — версии файлов.
* [09-operations-runbook.md](09-operations-runbook.md) — ежедневные проверки.
* [11-troubleshooting.md](11-troubleshooting.md) — диагностика.
* [12-acceptance-checklist.md](12-acceptance-checklist.md) — приёмка (раздел B).
