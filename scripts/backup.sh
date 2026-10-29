#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - full backup (database + volumes + configuration)
#  ---------------------------------------------------------------------------
#  Produces one self-describing directory per run:
#
#    ${BACKUP_DIR}/backup-YYYYmmdd-HHMMSS/
#      meta.env              non-secret metadata (versions, sizes, RPO anchor)
#      db.dump               PostgreSQL custom-format dump (pg_dump -Fc)
#      redis.rdb             Redis snapshot (rebuildable, but restored for RTO)
#      vol-*.tar.gz          named volumes (s3_data, nextcloud_*, proxy_*)
#      config.tar.gz.enc     .env + config/ + compose files, AES-256/PBKDF2
#      manifest.sha256       SHA-256 of every artefact
#
#  Redirect stderr to a file if you want a per-run log:
#      make backup 2>&1 | tee "/var/log/cloudsuite/backup-$(date +%F).log"
#
#  Volumes are read through their docker mountpoints when the script runs as
#  root (fast) and through a throw-away container otherwise.
#  --incremental switches volumes to rsync hardlink snapshots (space saving).
#
#  Exit codes: 0 = success, 1 = fatal error, 2 = completed with warnings.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "backup.sh"

PROJECT_VOLUMES=("db_data" "s3_data" "nextcloud_html" "nextcloud_data" "proxy_data" "proxy_letsencrypt")
COMPONENTS="db,redis,volumes,config"
DO_OFFSITE=1
INCREMENTAL=0
KEEP_MIN=3
WARN_COUNT=0
BACKUP_DIR_ABS=""
STAGING=""
FINAL_DIR=""
STARTED_AT=""

usage() {
  cat <<'USAGE'
backup.sh - create a consistent backup of the Cloud Suite stack

Usage:
  ./scripts/backup.sh [options]

Options:
  --only LIST         comma separated components: db,redis,volumes,config
                      (default: all four)
  --incremental       use rsync hardlink snapshots for volumes instead of
                      tar.gz (needs root; unchanged files are hardlinked)
  --no-offsite        do not copy the result to BACKUP_OFFSITE_REMOTE
  --keep N            keep at least N newest backups regardless of retention
                      (default: 3)
  -n, --dry-run       print every command, change nothing
  -h, --help          show this help and exit

Consistency:
  * PostgreSQL is dumped with pg_dump -Fc (transactionally consistent)
  * Redis is snapshotted with SAVE before the read
  * volumes are read after the database dump, so files never reference rows
    that are missing from the dump
  * config/.env are encrypted with BACKUP_PASSPHRASE (never written in clear)

Exit codes: 0 success, 1 fatal, 2 completed with warnings (e.g. offsite copy
failed).  Retention: BACKUP_RETENTION_DAYS, newest --keep are always kept.
USAGE
}

bump_warn() { WARN_COUNT=$(( WARN_COUNT + 1 )); }

# Never leave a half-written staging directory behind on failure/interrupt.
# shellcheck disable=SC2329 # invoked through the register_cleanup trap chain
cleanup_staging() {
  if [[ -n ${STAGING:-} && -d ${STAGING:-} ]]; then
    warn "removing incomplete staging directory ${STAGING}"
    rm -rf -- "$STAGING"
  fi
}

component_enabled() {
  local item
  IFS=',' read -r -a items <<< "$COMPONENTS"
  for item in "${items[@]}"; do
    [[ $item == "$1" ]] && return 0
  done
  return 1
}

# --- volume helpers ----------------------------------------------------------
volume_mountpoint() {
  local project=${COMPOSE_PROJECT_NAME:-cloudsuite}
  docker volume inspect -f '{{ .Mountpoint }}' "${project}_${1}" 2>/dev/null || true
}

snapshot_volume_tar() {
  local volume=$1 target=$2 mountpoint src
  mountpoint=$(volume_mountpoint "$volume")
  if [[ -n $mountpoint && -d $mountpoint && -r $mountpoint ]]; then
    debug "reading ${volume} from ${mountpoint}"
    run tar -C "$mountpoint" --numeric-owner -czf "$target" .
    return 0
  fi
  src="${COMPOSE_PROJECT_NAME:-cloudsuite}_${volume}"
  warn "mountpoint of ${volume} is not readable by $(id -un); using a throw-away container"
  bump_warn
  run compose run --rm --no-deps -T --entrypoint tar \
    -v "${src}:/src:ro" -v "${STAGING}:/dst" app \
    -C /src --numeric-owner -czf "/dst/${target##*/}" .
}

snapshot_volume_rsync() {
  local volume=$1 target=$2 mountpoint previous
  mountpoint=$(volume_mountpoint "$volume")
  if [[ -z $mountpoint || ! -r $mountpoint ]]; then
    die "--incremental needs root access to the volume mountpoints (run with sudo, or drop --incremental)"
  fi
  require_cmd rsync
  mkdir -p "$target"
  previous=$(find "${BACKUP_DIR_ABS}" -maxdepth 1 -type d -name 'backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk '{print $2}' | sed -n 2p || true)
  if [[ -n $previous && -d "${previous}/volumes/${volume}" ]]; then
    run rsync -aH --numeric-ids --delete --link-dest="${previous}/volumes/${volume}" "${mountpoint}/" "${target}/"
  else
    run rsync -aH --numeric-ids --delete "${mountpoint}/" "${target}/"
  fi
}

# --- artefacts ---------------------------------------------------------------
backup_database() {
  section "postgres (pg_dump -Fc)"
  if ! service_running db; then
    die "the db service is not running - start the stack or skip the db component (--only volumes,config)"
  fi
  local target=${STAGING}/db.dump
  if is_dry_run; then
    log "[dry-run] docker compose exec -T db pg_dump -U ${POSTGRES_USER} -d ${POSTGRES_DB} -Fc -Z 6 > ${target}"
    return 0
  fi
  if ! compose exec -T db pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -Fc -Z 6 > "$target"; then
    die "pg_dump failed (see the message above)"
  fi
  [[ -s $target ]] || die "pg_dump produced an empty file"
  ok "database dump: $(human_bytes "$(stat -c '%s' "$target")")"
}

backup_redis() {
  section "redis snapshot"
  if ! service_running cache; then
    warn "the cache service is not running - skipping the redis snapshot"
    bump_warn
    return 0
  fi
  local target=${STAGING}/redis.rdb
  if is_dry_run; then
    log "[dry-run] docker compose exec -T cache redis-cli -a *** --no-auth-warning SAVE"
    log "[dry-run] docker compose exec -T cache cat /data/dump.rdb > ${target}"
    return 0
  fi
  if ! compose exec -T cache redis-cli -a "${REDIS_PASSWORD:-}" --no-auth-warning SAVE >/dev/null 2>&1; then
    warn "redis SAVE failed - the cache is rebuildable, continuing"
    bump_warn
    return 0
  fi
  if ! compose exec -T cache cat /data/dump.rdb > "$target" 2>/dev/null || [[ ! -s $target ]]; then
    warn "could not read /data/dump.rdb - the cache is rebuildable, continuing"
    rm -f "$target"
    bump_warn
    return 0
  fi
  ok "redis snapshot: $(human_bytes "$(stat -c '%s' "$target")")"
}

backup_volumes() {
  section "volumes"
  local volume target
  for volume in "${PROJECT_VOLUMES[@]}"; do
    if [[ -z $(volume_mountpoint "$volume") ]]; then
      warn "volume ${COMPOSE_PROJECT_NAME:-cloudsuite}_${volume} does not exist yet - skipped"
      bump_warn
      continue
    fi
    if (( INCREMENTAL == 1 )); then
      target="${STAGING}/volumes/${volume}"
      snapshot_volume_rsync "$volume" "$target"
      if is_dry_run; then
        log "[dry-run] rsync snapshot of ${volume} -> ${target}"
      else
        ok "${volume}: $(human_bytes "$(du -sb "$target" | awk '{print $1}')") (hardlink incremental)"
      fi
    else
      target="${STAGING}/vol-${volume}.tar.gz"
      snapshot_volume_tar "$volume" "$target"
      if is_dry_run; then
        log "[dry-run] tar snapshot of ${volume} -> ${target}"
      else
        ok "${volume}: $(human_bytes "$(stat -c '%s' "$target")")"
      fi
    fi
  done
}

backup_config() {
  section "configuration (encrypted)"
  local target=${STAGING}/config.tar.gz.enc
  local files=(".env" "config" "docker-compose.yml" "docker-compose.admin.yml" "docker-compose.observability.yml")
  local file existing=()
  for file in "${files[@]}"; do
    [[ -e "${CLOUDSUITE_ROOT}/${file}" ]] && existing+=("$file")
  done
  if (( ${#existing[@]} == 0 )); then
    warn "nothing to archive in the configuration component"
    bump_warn
    return 0
  fi
  if is_dry_run; then
    log "[dry-run] tar -czf - ${existing[*]} | openssl enc -aes-256-cbc -pbkdf2 -iter ${CLOUDSUITE_BACKUP_PBKDF2_ITER} -salt -pass env:BACKUP_PASSPHRASE > ${target}"
    return 0
  fi
  tar -C "${CLOUDSUITE_ROOT}" -czf - "${existing[@]}" \
    | openssl enc -aes-256-cbc -pbkdf2 -iter "${CLOUDSUITE_BACKUP_PBKDF2_ITER}" -salt \
        -pass env:BACKUP_PASSPHRASE -out "$target"
  [[ -s $target ]] || die "configuration archive is empty"
  ok "configuration archive: $(human_bytes "$(stat -c '%s' "$target")") (AES-256, PBKDF2 ${CLOUDSUITE_BACKUP_PBKDF2_ITER} iterations)"
}

write_meta() {
  local target=${STAGING}/meta.env
  {
    printf 'BACKUP_FORMAT=1\n'
    printf 'BACKUP_TIMESTAMP=%s\n' "$(timestamp_iso)"
    printf 'BACKUP_EPOCH=%s\n' "$(date +%s)"
    printf 'BACKUP_HOST=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'BACKUP_PROJECT=%s\n' "${COMPOSE_PROJECT_NAME:-cloudsuite}"
    printf 'BACKUP_COMPONENTS=%s\n' "$COMPONENTS"
    printf 'BACKUP_INCREMENTAL=%s\n' "$INCREMENTAL"
    printf 'BACKUP_PBKDF2_ITER=%s\n' "${CLOUDSUITE_BACKUP_PBKDF2_ITER}"
    printf 'POSTGRES_DB=%s\n' "${POSTGRES_DB:-}"
    printf 'POSTGRES_USER=%s\n' "${POSTGRES_USER:-}"
    printf 'NEXTCLOUD_VERSION=%s\n' "${NEXTCLOUD_VERSION:-}"
    printf 'ONLYOFFICE_VERSION=%s\n' "${ONLYOFFICE_VERSION:-}"
    printf 'SEAWEEDFS_VERSION=%s\n' "${SEAWEEDFS_VERSION:-}"
    printf 'POSTGRES_VERSION=%s\n' "${POSTGRES_VERSION:-}"
    printf 'REDIS_VERSION=%s\n' "${REDIS_VERSION:-}"
    printf 'NGINX_VERSION=%s\n' "${NGINX_VERSION:-}"
    printf 'NPM_VERSION=%s\n' "${NPM_VERSION:-}"
    printf 'VERSIONS_MAX=%s\n' "${VERSIONS_MAX:-}"
    printf 'BACKUP_OFFSITE_REMOTE=%s\n' "${BACKUP_OFFSITE_REMOTE:-}"
    if (( INCREMENTAL == 1 )); then
      printf 'BACKUP_VOLUME_MODE=rsync-hardlink\n'
    else
      printf 'BACKUP_VOLUME_MODE=tar.gz\n'
    fi
  } > "$target"
}

write_manifest() {
  local target=${STAGING}/manifest.sha256
  if is_dry_run; then
    log "[dry-run] sha256sum every artefact > ${target}"
    return 0
  fi
  ( cd "${STAGING}" && find . -type f ! -name 'manifest.sha256' -print0 \
      | sort -z | xargs -0 sha256sum > "$target" )
  ok "manifest: $(grep -c . "$target") file(s)"
}

check_free_space() {
  local free_gb probe="${BACKUP_DIR_ABS}"
  while [[ ! -d $probe && $probe != / ]]; do probe=$(dirname -- "$probe"); done
  free_gb=$(df -Pk "$probe" | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if (( free_gb < 5 )); then
    die "only ${free_gb} GiB free in ${BACKUP_DIR_ABS} - a backup needs at least 5 GiB"
  fi
  if (( free_gb < 20 )); then
    warn "${free_gb} GiB free in ${BACKUP_DIR_ABS} - consider pruning old backups"
    bump_warn
  fi
  ok "free space in backup directory: ${free_gb} GiB"
}

apply_retention() {
  section "retention"
  local keep=${BACKUP_RETENTION_DAYS:-30} dir removed=0
  local -a candidates=()
  while IFS= read -r dir; do
    [[ -n $dir ]] && candidates+=("$dir")
  done < <(find "${BACKUP_DIR_ABS}" -maxdepth 1 -type d -name 'backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR>${KEEP_MIN} {print $2}')
  local target
  for target in "${candidates[@]:-}"; do
    [[ -n $target ]] || continue
    if [[ $(find "$target" -maxdepth 0 -mtime "+${keep}" 2>/dev/null) == "" ]]; then
      debug "keeping ${target} (younger than ${keep} days)"
      continue
    fi
    if is_dry_run; then
      log "[dry-run] rm -rf ${target}"
    else
      rm -rf -- "$target"
      log "removed expired backup ${target##*/}"
    fi
    removed=$(( removed + 1 ))
  done
  ok "retention: kept ${KEEP_MIN}+ newest, removed ${removed} backup(s) older than ${keep} days"
}

copy_offsite() {
  local source_dir=$1
  if (( DO_OFFSITE == 0 )); then
    log "offsite copy disabled (--no-offsite)"
    return 0
  fi
  if [[ -z ${BACKUP_OFFSITE_REMOTE:-} ]]; then
    log "no BACKUP_OFFSITE_REMOTE configured - local backup only"
    return 0
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    warn "BACKUP_OFFSITE_REMOTE=${BACKUP_OFFSITE_REMOTE} but rclone is not installed - skipping the offsite copy"
    bump_warn
    return 0
  fi
  section "offsite copy"
  local remote="${BACKUP_OFFSITE_REMOTE}"; remote=${remote%%:*}
  local path=${BACKUP_OFFSITE_REMOTE}; path=${path#*:}
  [[ -n $path ]] || path="cloudsuite-backups"
  if ! rclone listremotes 2>/dev/null | grep -qx "${remote}:"; then
    warn "rclone remote '${remote}' is not configured - skipping the offsite copy"
    bump_warn
    return 0
  fi
  if is_dry_run; then
    log "[dry-run] rclone copy ${source_dir} ${remote}:${path}/${source_dir##*/} --transfers 4 --checkers 8"
    return 0
  fi
  if rclone copy "$source_dir" "${remote}:${path}/${source_dir##*/}" --transfers 4 --checkers 8 --stats-one-line 2>&1 | tail -n 3; then
    ok "offsite copy: ${remote}:${path}/${source_dir##*/}"
    if rclone check "$source_dir" "${remote}:${path}/${source_dir##*/}" --size-only >/dev/null 2>&1; then
      ok "offsite copy verified with rclone check"
    else
      warn "rclone check could not verify the offsite copy"
      bump_warn
    fi
  else
    warn "offsite copy FAILED - the local backup is intact"
    bump_warn
  fi
}

print_summary() {
  local dir=$1
  section "backup summary"
  printf 'directory : %s\n' "$dir"
  if [[ -d $dir ]]; then
    printf 'artefacts :\n'
    local artefact
    while IFS= read -r artefact; do
      printf '  %-28s %s\n' "${artefact##*/}" "$(human_bytes "$(stat -c '%s' "$artefact")")"
    done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f ! -name 'backup.log' | sort)
    printf 'total     : %s\n' "$(human_bytes "$(du -sb "$dir" | awk '{print $1}')")"
  fi
  printf 'restore   : ./scripts/restore.sh --dir %s --confirm\n' "$dir"
  printf 'verify    : (cd %s && sha256sum -c manifest.sha256)\n' "$dir"
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --only) COMPONENTS=${2:?--only needs db,redis,volumes,config}; shift 2 ;;
      --incremental) INCREMENTAL=1; shift ;;
      --no-offsite) DO_OFFSITE=0; shift ;;
      --keep) KEEP_MIN=${2:?--keep needs a number}; shift 2 ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done
  local component
  IFS=',' read -r -a requested <<< "$COMPONENTS"
  for component in "${requested[@]}"; do
    case $component in
      db|redis|volumes|config) ;;
      *) die "unknown component '${component}' in --only (db,redis,volumes,config)" 2 ;;
    esac
  done
  [[ $KEEP_MIN =~ ^[0-9]+$ ]] || die "--keep expects a number" 2

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker tar sha256sum openssl df
  env_require POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD
  if component_enabled config; then
    if [[ -z ${BACKUP_PASSPHRASE:-} ]]; then
      die "BACKUP_PASSPHRASE is empty - run ./scripts/generate-secrets.sh (it is required to encrypt .env/config)"
    fi
    export BACKUP_PASSPHRASE
  fi

  BACKUP_DIR_ABS=$(abs_path "${BACKUP_DIR:-./backups}")
  if [[ $BACKUP_DIR_ABS != /* ]]; then BACKUP_DIR_ABS="${CLOUDSUITE_ROOT}/${BACKUP_DIR_ABS#./}"; fi
  STARTED_AT=$(date +%s)
  acquire_lock backup

  if is_dry_run; then
    section "backup (dry-run) into ${BACKUP_DIR_ABS}"
  else
    section "backup into ${BACKUP_DIR_ABS}"
    mkdir -p "$BACKUP_DIR_ABS"
    chmod 700 "$BACKUP_DIR_ABS"
    STAGING=$(mktemp -d "${BACKUP_DIR_ABS}/.staging-XXXXXX")
    FINAL_DIR="${BACKUP_DIR_ABS}/backup-$(timestamp_compact)"
    register_cleanup cleanup_staging
  fi
  check_free_space

  local started_component
  for started_component in db redis volumes config; do
    component_enabled "$started_component" || continue
    case $started_component in
      db) backup_database ;;
      redis) backup_redis ;;
      volumes) backup_volumes ;;
      config) backup_config ;;
    esac
  done

  if is_dry_run; then
    section "summary"
    warn "dry-run: nothing was written"
    print_summary "${BACKUP_DIR_ABS}/backup-<timestamp>"
    exit 0
  fi

  write_meta
  write_manifest
  mv "$STAGING" "$FINAL_DIR"
  ln -sfn "${FINAL_DIR##*/}" "${BACKUP_DIR_ABS}/LATEST"
  apply_retention
  copy_offsite "$FINAL_DIR"
  print_summary "$FINAL_DIR"

  local elapsed=$(( $(date +%s) - STARTED_AT ))
  if (( WARN_COUNT > 0 )); then
    warn "backup finished with ${WARN_COUNT} warning(s) in ${elapsed}s"
    exit 2
  fi
  ok "backup finished in ${elapsed}s"
  exit 0
}

main "$@"
