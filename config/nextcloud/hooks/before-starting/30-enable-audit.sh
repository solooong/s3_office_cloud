#!/bin/sh
# =============================================================================
#  Cloud Suite — включение приложения admin_audit (аудит действий пользователей)
#  ---------------------------------------------------------------------------
#  В Nextcloud 35 приложение admin_audit поставляется, но НЕ включено по
#  умолчанию. Аудит — обязательное требование, поэтому включаем его
#  идемпотентно на каждом старте контейнера (после установки Nextcloud).
#
#  Путь и формат аудита задаёт /var/www/html/config/zz-10-cloudsuite.config.php:
#      log_type_audit = file, logfile_audit = /var/log/cloudsuite/audit.log
#
#  Контекст выполнения: entrypoint образа запускает хуки от www-data
#  (run_as -> su -p www-data), поэтому occ вызывается напрямую. Если контейнер
#  запущен иначе (root), привилегии сбрасываются через runuser.
#
#  ВАЖНО: хук не должен ломать запуск контейнера — любая ошибка только
#  печатается в лог, контейнер продолжает старт (exit 0). Дополнительно
#  admin_audit включает scripts/configure-nextcloud.sh при развёртывании.
# =============================================================================
set -u

CONFIG="/var/www/html/config/config.php"
OCC="/var/www/html/occ"

if [ ! -f "$CONFIG" ]; then
    echo "[audit] Nextcloud ещё не установлен — пропускаем"
    exit 0
fi

if [ "$(id -u)" = "0" ] && command -v runuser >/dev/null 2>&1; then
    run_occ() { runuser -u www-data -- php "$OCC" "$@"; }
else
    run_occ() { php "$OCC" "$@"; }
fi

if run_occ app:list --enabled 2>/dev/null | grep -q 'admin_audit'; then
    echo "[audit] admin_audit уже включён"
    exit 0
fi

echo "[audit] включаем admin_audit..."
if run_occ app:enable admin_audit 2>&1; then
    echo "[audit] admin_audit включён"
else
    echo "[audit] WARN: не удалось включить admin_audit — выполните: docker compose exec -u www-data app php occ app:enable admin_audit"
fi

exit 0
