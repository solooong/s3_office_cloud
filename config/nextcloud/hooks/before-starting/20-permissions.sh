#!/bin/sh
# =============================================================================
#  Cloud Suite — права на каталог config перед стартом PHP-FPM
#  ---------------------------------------------------------------------------
#  occ и веб-интерфейс работают от www-data (uid 33). Каталог config должен
#  быть доступен этому пользователю на запись: иначе
#  "Не удаётся записать в каталог «config»".
#
#  chown выполняется только для каталога и обычных файлов внутри — рекурсивный
#  chown затронул бы read-only bind-mounts (/opt/cloudsuite/*) и упал бы.
# =============================================================================
set -eu

CONFIG_DIR="/var/www/html/config"

if [ ! -d "$CONFIG_DIR" ]; then
    echo "[permissions] $CONFIG_DIR отсутствует — пропускаем"
    exit 0
fi

chown www-data:www-data "$CONFIG_DIR"
chmod 0750 "$CONFIG_DIR"
find "$CONFIG_DIR" -maxdepth 1 -type f -exec chown www-data:www-data {} + 2>/dev/null || true

if [ -d /var/www/html/data ]; then
    chown www-data:www-data /var/www/html/data
fi

echo "[permissions] /var/www/html/config готов для www-data"
