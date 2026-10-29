#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - restore from a backup created by scripts/backup.sh
#  ---------------------------------------------------------------------------
#  Procedure (each step is logged and verified):
#    1. verify the SHA-256 manifest of the backup directory
#    2. stop the stack (containers only, named volumes are kept)
#    3. restore .env + config/ (decrypted with BACKUP_PASSPHRASE)
#    4. restore named volumes (db_data, s3_data, nextcloud_*, proxy_*)
#    5. restore PostgreSQL (drop + create + pg_restore)
#    6. optionally restore the Redis snapshot
#    7. start the stack, wait for health, run occ status + files:scan
#    8. run the health check and print the RPO/RTO report
#
#  RPO = the age of the chosen backup (data loss window).
#  RTO = measured duration of this restore run.
#  Nothing is written unless --confirm is given; --dry-run prints the plan.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "restore.sh"

BACKUP_SOURCE=""
COMPONENTS="db,volumes,config"
CONFIRMED=0
VERIFY=1
WITH_REDIS=0
WITH_COMPOSE=0
SAFETY_BACKUP=0
STARTED_AT=$(date +%s)
BACKUP_EPOCH=""
BACKUP_STAMP=""

usage() {
  cat <<'USAGE'
restore.sh - restore the Cloud Suite stack from a backup directory

Usage:
  ./scripts/restore.sh [options] --confirm

Options:
  --dir PATH          backup directory (default: newest backup in BACKUP_DIR)
  --only LIST         components to restore: db,redis,volumes,config
                      (default: db,volumes,config; redis only with --with-redis)
  --with-redis        also restore the Redis snapshot (locks/cache rebuild anyway)
  --with-compose      also restore docker-compose*.yml from the backup
                      (default: only .env and config/ are restored)
  --safety-backup     run scripts/backup.sh before touching anything
  --no-verify         skip "sha256sum -c manifest.sha256" (not recommended)
  --confirm           really do it (required for anything destructive)
  --yes               do not ask for interactive confirmation (with --confirm)
  -n, --dry-run       verify + print the plan, change nothing
  -h, --help          show this help and exit

RPO/RTO:
  RPO equals the age of the backup you restore (the data written after it is
  lost).  RTO is printed at the end and should be recorded in the DR log.
USAGE
}

component_enabled() {
  local item
  IFS=',' read -r -a items <<< "$COMPONENTS"
  for item in "${items[@]}"; do
    [[ $item == "$1" ]] && return 0
  done
  return 1
}

resolve_backup_dir() {
  local requested=$1 base
  base=$(abs_path "${BACKUP_DIR:-./backups}")
  [[ $base == /* ]] || base="${CLOUDSUITE_ROOT}/${BACKUP_DIR:-./backups}"
  if [[ -n $requested ]]; then
    [[ -d $requested ]] || die "backup directory not found: ${requested}"
    printf '%s' "$(abs_path "$requested")"
    return 0
  fi
  if [[ -d $base/LATEST ]]; then
    printf '%s' "$base/LATEST"
    return 0
  fi
  local newest
  newest=$(find "$base" -maxdepth 1 -type d -name 'backup-*' -printf '%T@ %p\n' 2>/dev/null | sort -rn | awk 'NR==1 {print $2}')
  [[ -n $newest ]] || die "no backup found in ${base} - pass --dir PATH"
  printf '%s' "$newest"
}

verify_backup() {
  local dir=$1
  [[ -f $dir/manifest.sha256 ]] || die "${dir} is not a Cloud Suite backup (manifest.sha256 is missing)"
  section "verify backup integrity"
  local failures
  failures=$( cd "$dir" && sha256sum -c manifest.sha256 2>&1 | grep -vc ': OK$' || true )
  if [[ $failures != 0 ]]; then
    ( cd "$dir" && sha256sum -c manifest.sha256 2>&1 | grep -v ': OK$' | head -n 10 ) >&2 || true
    die "backup verification failed - ${failures} file(s) do not match the manifest"
  fi
  ok "all artefacts match manifest.sha256"
}

read_meta() {
  local dir=$1 key value
  [[ -f $dir/meta.env ]] || { warn "meta.env is missing (old backup?)"; return 0; }
  while IFS='=' read -r key value; do
    case $key in
      BACKUP_TIMESTAMP) BACKUP_STAMP=$value ;;
      BACKUP_EPOCH) BACKUP_EPOCH=$value ;;
      BACKUP_PROJECT)
        if [[ $value != "${COMPOSE_PROJECT_NAME:-cloudsuite}" ]]; then
          warn "backup was taken from project '${value}', this host uses '${COMPOSE_PROJECT_NAME:-cloudsuite}' - volume names differ, review before restoring"
        fi
        ;;
    esac
  done < "$dir/meta.env"
}

artefact_of() {
  local dir=$1 volume=$2
  if [[ -f $dir/vol-${volume}.tar.gz ]]; then printf '%s' "$dir/vol-${volume}.tar.gz"; return 0; fi
  if [[ -d $dir/volumes/${volume} ]]; then printf '%s' "$dir/volumes/${volume}"; return 0; fi
  return 1
}

volume_mountpoint() {
  local project=${COMPOSE_PROJECT_NAME:-cloudsuite}
  docker volume inspect -f '{{ .Mountpoint }}' "${project}_${1}" 2>/dev/null || true
}

ensure_volume() {
  local volume=$1 name
  name="${COMPOSE_PROJECT_NAME:-cloudsuite}_${volume}"
  if [[ -z $(docker volume inspect -f '{{ .Name }}' "$name" 2>/dev/null) ]]; then
    run docker volume create "$name" >/dev/null
  fi
}

print_plan() {
  local dir=$1
  section "restore plan"
  printf 'backup       : %s\n' "$dir"
  [[ -n $BACKUP_STAMP ]] && printf 'created      : %s\n' "$BACKUP_STAMP"
  if [[ -n $BACKUP_EPOCH ]]; then
    printf 'RPO (age)    : %s\n' "$(human_seconds $(( $(date +%s) - BACKUP_EPOCH )))"
  fi
  printf 'components   : %s\n' "$COMPONENTS"
  printf 'project      : %s\n' "${COMPOSE_PROJECT_NAME:-cloudsuite}"
  printf 'artefacts    :\n'
  local file
  while IFS= read -r file; do
    printf '  %-28s %s\n' "${file##*/}" "$(human_bytes "$(stat -c '%s' "$file")")"
  done < <(find "$dir" -maxdepth 1 -mindepth 1 -type f | sort)
  printf '\nsequence:\n'
  local step=1
  printf '  %d) docker compose stop\n' "$step"; step=$(( step + 1 ))
  if component_enabled config; then
    printf '  %d) decrypt + restore .env and config/\n' "$step"; step=$(( step + 1 ))
  fi
  if component_enabled volumes; then
    printf '  %d) restore named volumes (db_data, s3_data, nextcloud_*, proxy_*)\n' "$step"; step=$(( step + 1 ))
  fi
  if (( WITH_REDIS == 1 )) && component_enabled redis; then
    printf '  %d) restore redis_data/dump.rdb\n' "$step"; step=$(( step + 1 ))
  fi
  if component_enabled db; then
    printf '  %d) drop + recreate PostgreSQL database, pg_restore db.dump\n' "$step"; step=$(( step + 1 ))
  fi
  printf '  %d) docker compose up -d, wait for healthy\n' "$step"; step=$(( step + 1 ))
  printf '  %d) occ status, maintenance:mode --off, files:scan --all\n' "$step"; step=$(( step + 1 ))
  printf '  %d) scripts/healthcheck.sh\n' "$step"
}

human_seconds() {
  local seconds=${1:-0} days hours minutes
  days=$(( seconds / 86400 ))
  hours=$(( (seconds % 86400) / 3600 ))
  minutes=$(( (seconds % 3600) / 60 ))
  if (( days > 0 )); then printf '%dd %dh %dm' "$days" "$hours" "$minutes"
  elif (( hours > 0 )); then printf '%dh %dm' "$hours" "$minutes"
  else printf '%dm %ds' "$minutes" "$(( seconds % 60 ))"
  fi
}

confirm_restore() {
  local dir=$1
  (( CONFIRMED == 1 )) || die "refusing to restore without --confirm (this overwrites the database and volumes)"
  if (( CLOUDSUITE_ASSUME_YES == 1 )); then
    warn "confirmation skipped (--yes)"
    return 0
  fi
  [[ -t 0 ]] || die "no terminal for the interactive confirmation - pass --yes together with --confirm"
  local answer
  printf '\nType "restore" to overwrite the live stack from %s: ' "$dir" >&2
  read -r answer
  [[ $answer == restore ]] || die "aborted by the operator"
}

restore_config() {
  local dir=$1
  section "restore configuration"
  local archive=$dir/config.tar.gz.enc
  if [[ ! -f $archive ]]; then
    warn "no config.tar.gz.enc in the backup - skipped"
    return 0
  fi
  [[ -n ${BACKUP_PASSPHRASE:-} ]] || die "BACKUP_PASSPHRASE is empty - it is required to decrypt config.tar.gz.enc"
  export BACKUP_PASSPHRASE
  local extract_dir
  extract_dir=$(mktemp -d)
  register_cleanup rm -rf -- "$extract_dir"
  if is_dry_run; then
    log "[dry-run] openssl enc -d ... | tar -C ${extract_dir} -xzf -"
    log "[dry-run] install .env + config/ into ${CLOUDSUITE_ROOT}"
    return 0
  fi
  if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter "${CLOUDSUITE_BACKUP_PBKDF2_ITER}" \
        -pass env:BACKUP_PASSPHRASE -in "$archive" | tar -C "$extract_dir" -xzf -; then
    die "cannot decrypt ${archive} - wrong BACKUP_PASSPHRASE?"
  fi
  if [[ ! -d $extract_dir/config ]]; then
    die "the configuration archive does not contain config/ - refusing to continue"
  fi
  if [[ -f $extract_dir/.env ]]; then
    install -m 600 "$extract_dir/.env" "${CLOUDSUITE_ROOT}/.env"
    ok "restored .env (mode 600)"
  else
    warn "the configuration archive has no .env - keeping the current one"
  fi
  run rsync -a --delete "$extract_dir/config/" "${CLOUDSUITE_ROOT}/config/"
  ok "restored config/"
  if (( WITH_COMPOSE == 1 )); then
    local file
    for file in docker-compose.yml docker-compose.admin.yml docker-compose.observability.yml; do
      if [[ -f $extract_dir/$file ]]; then
        install -m 644 "$extract_dir/$file" "${CLOUDSUITE_ROOT}/${file}"
        ok "restored ${file}"
      fi
    done
  else
    log "compose files kept as-is (use --with-compose to restore them too)"
  fi
  chmod 700 "${CLOUDSUITE_ROOT}/data" 2>/dev/null || true
}

restore_volume() {
  local dir=$1 volume=$2 artefact mountpoint
  artefact=$(artefact_of "$dir" "$volume") || return 1
  if is_dry_run; then
    log "[dry-run] restore ${volume} from ${artefact##*/}"
    return 0
  fi
  ensure_volume "$volume"
  mountpoint=$(volume_mountpoint "$volume")
  if [[ -n $mountpoint && -d $mountpoint && -w $mountpoint ]]; then
    if [[ -d $artefact ]]; then
      require_cmd rsync
      rsync -aH --numeric-ids --delete "${artefact}/" "${mountpoint}/"
    elif [[ $artefact == *.tar.gz ]]; then
      tar -C "$mountpoint" --numeric-owner -xzf "$artefact"
    else
      tar -C "$mountpoint" --numeric-owner -xf "$artefact"
    fi
    ok "${volume} restored from ${artefact##*/}"
    return 0
  fi
  if [[ -d $artefact ]]; then
    die "cannot write to the mountpoint of ${volume} and rsync snapshots need root access - re-run with sudo (tar artefacts can be restored through a helper container)"
  fi
  warn "cannot write to the mountpoint of ${volume}; using a throw-away container"
  run compose run --rm --no-deps -T --entrypoint sh \
    -v "${COMPOSE_PROJECT_NAME:-cloudsuite}_${volume}:/dst" -v "${dir}:/backup:ro" app \
    -c "tar -C /dst --numeric-owner -xzf /backup/${artefact##*/}"
  ok "${volume} restored from ${artefact##*/} (helper container)"
}

restore_volumes() {
  local dir=$1 volume restored=0
  section "restore volumes"
  for volume in db_data s3_data nextcloud_html nextcloud_data proxy_data proxy_letsencrypt; do
    if restore_volume "$dir" "$volume"; then
      restored=$(( restored + 1 ))
    else
      log "no artefact for ${volume} - skipped"
    fi
  done
  if (( restored == 0 )); then
    warn "no volume artefacts were restored"
  fi
}

restore_database() {
  local dir=$1
  local dump=$dir/db.dump
  section "restore postgres"
  if [[ ! -f $dump ]]; then
    warn "no db.dump in the backup - skipped"
    return 0
  fi
  wait_for 180 3 -- service_running db || die "the db container did not start"
  if ! wait_for_service_healthy db 180; then
    die "the db container did not become healthy"
  fi
  if is_dry_run; then
    log "[dry-run] psql -c 'DROP DATABASE IF EXISTS ${POSTGRES_DB} WITH (FORCE)'"
    log "[dry-run] createdb -O ${POSTGRES_USER} ${POSTGRES_DB}"
    log "[dry-run] pg_restore -Fc -d ${POSTGRES_DB} < ${dump}"
    return 0
  fi
  compose exec -T db psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${POSTGRES_DB}\" WITH (FORCE);" >/dev/null
  compose exec -T db createdb -U "${POSTGRES_USER}" -O "${POSTGRES_USER}" "${POSTGRES_DB}"
  ok "database ${POSTGRES_DB} recreated"
  if ! compose exec -T db pg_restore -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
        --no-owner --role="${POSTGRES_USER}" -Fc < "$dump"; then
    die "pg_restore failed - the database may be incomplete, inspect the output above"
  fi
  ok "database restored from db.dump"
}

restore_redis() {
  local dir=$1
  local rdb=$dir/redis.rdb
  section "restore redis"
  if [[ ! -f $rdb ]]; then
    warn "no redis.rdb in the backup - skipped"
    return 0
  fi
  if is_dry_run; then
    log "[dry-run] copy redis.rdb into the redis_data volume and chown redis:redis"
    return 0
  fi
  run compose stop cache >/dev/null 2>&1 || true
  local mountpoint
  mountpoint=$(volume_mountpoint redis_data)
  if [[ -n $mountpoint && -d $mountpoint && -w $mountpoint ]]; then
    install -m 644 "$rdb" "${mountpoint}/dump.rdb"
    chown 999:999 "${mountpoint}/dump.rdb" 2>/dev/null || warn "could not chown dump.rdb to 999:999"
    ok "redis snapshot installed into redis_data"
  else
    run compose run --rm --no-deps -T --entrypoint sh \
      -v "${COMPOSE_PROJECT_NAME:-cloudsuite}_redis_data:/data" -v "${dir}:/backup:ro" cache \
      -c "cp /backup/redis.rdb /data/dump.rdb && chown redis:redis /data/dump.rdb"
    ok "redis snapshot installed into redis_data (helper container)"
  fi
  run compose up -d cache >/dev/null
}

start_stack() {
  section "start the stack"
  if is_dry_run; then
    log "[dry-run] docker compose up -d"
    return 0
  fi
  compose up -d db cache s3 >/dev/null
  wait_for_service_healthy s3 180 || warn "s3 did not report healthy in 180s"
  compose up -d >/dev/null
  ok "containers started"
  local service
  for service in db cache s3 app web onlyoffice proxy; do
    if wait_for_service_healthy "$service" 300; then
      ok "${service} is healthy"
    else
      warn "${service} is not healthy after 300s"
    fi
  done
}

verify_nextcloud() {
  section "verify nextcloud"
  if is_dry_run; then
    log "[dry-run] occ status && occ maintenance:mode --off && occ files:scan --all"
    return 0
  fi
  local out
  if ! out=$(compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ status --output=json 2>&1); then
    error "occ status failed: ${out}"
    return 1
  fi
  if ! grep -q '"installed":true' <<< "$out"; then
    error "Nextcloud reports installed=false after the restore"
    return 1
  fi
  ok "occ status: installed=true"
  compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ maintenance:mode --off >/dev/null
  ok "maintenance mode disabled"
  local scan_start=${SECONDS}
  if compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ files:scan --all >/dev/null 2>&1; then
    ok "files:scan --all completed in $(( SECONDS - scan_start ))s"
  else
    warn "files:scan --all reported errors - run it manually and check the output"
  fi
  compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ files:cleanup >/dev/null 2>&1 || true
  return 0
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --dir) BACKUP_SOURCE=${2:?--dir needs a path}; shift 2 ;;
      --only) COMPONENTS=${2:?--only needs db,redis,volumes,config}; shift 2 ;;
      --with-redis) WITH_REDIS=1; COMPONENTS="${COMPONENTS},redis"; shift ;;
      --with-compose) WITH_COMPOSE=1; shift ;;
      --safety-backup) SAFETY_BACKUP=1; shift ;;
      --no-verify) VERIFY=0; shift ;;
      --confirm) CONFIRMED=1; shift ;;
      --yes) assume_yes; shift ;;
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

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker tar openssl sha256sum
  if component_enabled config; then
    [[ -n ${BACKUP_PASSPHRASE:-} ]] || die "BACKUP_PASSPHRASE is empty - cannot decrypt the configuration archive"
    export BACKUP_PASSPHRASE
  fi
  command -v rsync >/dev/null 2>&1 || debug "rsync not installed (only needed for incremental backups)"

  local dir
  dir=$(resolve_backup_dir "$BACKUP_SOURCE")
  read_meta "$dir"
  if (( VERIFY == 1 )); then
    verify_backup "$dir"
  else
    warn "manifest verification skipped (--no-verify)"
  fi

  section "Cloud Suite restore"
  print_plan "$dir"

  if is_dry_run; then
    warn "dry-run: nothing was restored"
    exit 0
  fi

  confirm_restore "$dir"
  require_cmd docker
  acquire_lock restore

  if (( SAFETY_BACKUP == 1 )); then
    section "safety backup of the current state"
    if "${SCRIPT_DIR}/backup.sh" --no-offsite; then
      ok "safety backup created"
    else
      warn "safety backup failed - continuing because the restore was requested explicitly"
    fi
  fi

  section "stop the stack"
  compose stop >/dev/null
  ok "containers stopped (volumes untouched)"

  component_enabled config  && restore_config "$dir"
  component_enabled volumes && restore_volumes "$dir"
  if (( WITH_REDIS == 1 )) && component_enabled redis; then
    restore_redis "$dir"
  fi

  if component_enabled db; then
    start_stack_services db cache s3
    restore_database "$dir"
  fi

  start_stack
  local verify_ok=1
  verify_nextcloud || verify_ok=0

  section "post-restore health check"
  if [[ -x "${SCRIPT_DIR}/healthcheck.sh" ]]; then
    "${SCRIPT_DIR}/healthcheck.sh" || warn "health check reported failures - review the output above"
  fi

  local elapsed=$(( $(date +%s) - STARTED_AT ))
  section "restore report"
  printf 'backup      : %s\n' "$dir"
  [[ -n $BACKUP_STAMP ]] && printf 'created     : %s\n' "$BACKUP_STAMP"
  if [[ -n $BACKUP_EPOCH ]]; then
    printf 'RPO         : %s of data may be missing (backup age)\n' "$(human_seconds $(( $(date +%s) - BACKUP_EPOCH )))"
  fi
  printf 'RTO         : %s (this restore run)\n' "$(human_seconds "$elapsed")"
  printf 'next steps  : run "make healthcheck" and "make smoke"; re-index if files:scan failed\n'
  if (( verify_ok == 0 )); then
    error "restore finished with verification errors"
    exit 1
  fi
  ok "restore completed successfully"
  exit 0
}

# Bring up only the infrastructure services needed by a single restore step.
start_stack_services() {
  if is_dry_run; then
    log "[dry-run] docker compose up -d $*"
    return 0
  fi
  compose up -d "$@" >/dev/null
}

main "$@"
