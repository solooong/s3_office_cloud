#!/bin/sh
# =============================================================================
#  Cloud Suite — копирование дополнительных config-файлов Nextcloud
#  ---------------------------------------------------------------------------
#  Почему не bind-mount напрямую в /var/www/html/config:
#  Docker создаёт отсутствующий каталог для файлового bind-mount как root:root
#  0755 ДО старта образа. Из-за этого первый запуск Nextcloud (установка,
#  запись config.php от www-data) ломается: "Не удаётся записать в каталог
#  «config»", Nextcloud остаётся неустановленным.
#
#  Поэтому держим исходники в /opt/cloudsuite/config (read-only bind) и
#  копируем их в /var/www/html/config на каждом старте контейнера:
#  обновление файла в репозитории + рестарт = применено.
# =============================================================================
set -eu

SRC_DIR="/opt/cloudsuite/config"
DST_DIR="/var/www/html/config"

if [ ! -d "$SRC_DIR" ]; then
    echo "[extra-config] $SRC_DIR отсутствует — пропускаем"
    exit 0
fi

mkdir -p "$DST_DIR"

for f in "$SRC_DIR"/*.config.php; do
    [ -e "$f" ] || continue
    target="$DST_DIR/$(basename "$f")"
    # Копируем всегда: файл в репозитории — источник истины
    cp -f "$f" "$target"
    chown www-data:www-data "$target"
    chmod 0640 "$target"
    echo "[extra-config] применён $(basename "$f")"
done
