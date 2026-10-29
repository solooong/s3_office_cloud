#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - migrate a Yandex.Disk account into Nextcloud
#  ---------------------------------------------------------------------------
#  Reads an rclone source remote (rclone supports Yandex.Disk natively) and
#  writes into the target user's files through the Nextcloud WebDAV endpoint,
#  so every file gets a file id, a version history entry and an audit record.
#
#  The target user's password is used for WebDAV authentication; it is read
#  from NC_PASSWORD or an interactive prompt, obscured with "rclone obscure" and
#  written to a mode-600 temporary rclone config - never to argv or the log.
#
#  Exit codes: 0 success, 1 transfer/verification error, 2 setup error.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "migrate-yandex-disk.sh"

SOURCE_REMOTE=""
NC_USER=""
TARGET_DIR="YandexDisk"
BASE_URL=""
TRANSFERS=8
CHECKERS=16
TPSLIMIT=20
VERIFY_MODE="size"
INCLUDE_PATTERNS=()
EXCLUDE_PATTERNS=()
EXTRA_ARGS=()
VERIFY_ONLY=0
SUM_CHECKSUM=0
CONFIG_DIR=""
LOG_FILE=""
STARTED_AT=$(date +%s)
OBSCURED_PASS=""

usage() {
  cat <<'USAGE'
migrate-yandex-disk.sh - copy a Yandex.Disk account into a Nextcloud user

Usage:
  ./scripts/migrate-yandex-disk.sh --source REMOTE:PATH --user UID [options]

Required:
  --source REMOTE:PATH  rclone source, e.g. yandex:disk or yandex:disk/folder
  --user UID            existing Nextcloud user that receives the files

Options:
      --target-dir NAME target folder inside the user's home (default: YandexDisk)
      --base-url URL    public base URL (default: https://CLOUD_DOMAIN)
      --transfers N     parallel uploads (default: 8)
      --checkers N      parallel checks (default: 16)
      --tpslimit N      requests per second against Nextcloud (default: 20)
      --include GLOB    include only matching paths (repeatable)
      --exclude GLOB    skip matching paths (repeatable)
      --checksum        use --checksum mode while copying (needs server support)
      --verify MODE     post-copy verification: size (default) or download
      --verify-only     only verify an earlier migration, copy nothing
      --rclone-arg ARG  extra rclone argument (repeatable)
      --insecure        do not verify TLS certificates (staging only)
      --yes             do not ask for a final confirmation
  -n, --dry-run         rclone dry-run: show what would be copied
  -h, --help            show this help and exit

Authentication:
  The password of the target user is read from NC_PASSWORD or prompted for.
  Generate an app password in the Nextcloud UI (Settings > Security) and use
  that instead of the login password where possible.

Examples:
  NC_PASSWORD=... ./scripts/migrate-yandex-disk.sh --source yandex:disk --user alice
  ./scripts/migrate-yandex-disk.sh --source yandex:disk/photos --user alice   --target-dir Photos --include 'IMG_*' --dry-run
USAGE
}

require_rclone() {
  require_cmd rclone
  local version
  version=$(rclone version 2>/dev/null | head -n 1 || true)
  [[ -n $version ]] || die "rclone does not run - reinstall it (https://rclone.org/install/)"
  debug "${version}"
}

check_source() {
  section "source: ${SOURCE_REMOTE}"
  if ! rclone lsd "${SOURCE_REMOTE}" >/dev/null 2>&1; then
    local error_output
    error_output=$(rclone lsd "${SOURCE_REMOTE}" 2>&1 | head -n 3 || true)
    error "cannot read ${SOURCE_REMOTE}: ${error_output}"
    hint "configure the remote once: rclone config  (choose 'yandex')"
    hint "then verify: rclone lsd ${SOURCE_REMOTE%%:*}:"
    exit 2
  fi
  ok "source is readable"
  local size_json
  if command -v python3 >/dev/null 2>&1; then
    size_json=$(rclone size "${SOURCE_REMOTE}" --json 2>/dev/null || true)
    if [[ -n $size_json ]]; then
      local bytes count
      bytes=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("bytes",0))' <<< "$size_json" 2>/dev/null || true)
      count=$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("count",0))' <<< "$size_json" 2>/dev/null || true)
      if [[ -n $bytes && -n $count ]]; then
        printf 'source size: %s in %s object(s)\n' "$(human_bytes "$bytes")" "$count"
      fi
    fi
  fi
}

check_user() {
  section "target user: ${NC_USER}"
  if ! occ user:info "${NC_USER}" >/dev/null 2>&1; then
    die "Nextcloud user '${NC_USER}' does not exist - create it first (occ user:add ${NC_USER})"
  fi
  ok "user ${NC_USER} exists"
  local quota
  quota=$(occ user:setting "${NC_USER}" files quota 2>/dev/null || true)
  log "user quota: ${quota:-<default>}"
}

read_password() {
  if [[ -n $OBSCURED_PASS ]]; then
    return 0
  fi
  local password=${NC_PASSWORD:-}
  if [[ -z $password ]]; then
    [[ -t 0 ]] || die "no terminal: set NC_PASSWORD (an app password is recommended)"
    printf 'Password or app password for Nextcloud user %s: ' "${NC_USER}" >&2
    read -r -s password
    printf '\n' >&2
  fi
  [[ -n $password ]] || die "empty password"
  OBSCURED_PASS=$(rclone obscure "$password")
  password=""
  ok "credentials prepared (the password is not stored in clear)"
}

write_rclone_config() {
  local url="${BASE_URL}/remote.php/dav/files/${NC_USER}"
  CONFIG_DIR=$(mktemp -d)
  register_cleanup cleanup
  umask 077
  {
    printf '[cloudsuite]\n'
    printf 'type = webdav\n'
    printf 'url = %s\n' "$url"
    printf 'vendor = nextcloud\n'
    printf 'user = %s\n' "${NC_USER}"
    printf 'pass = %s\n' "$OBSCURED_PASS"
  } > "$CONFIG_DIR/rclone.conf"
  chmod 600 "$CONFIG_DIR/rclone.conf"
  ok "temporary rclone remote 'cloudsuite' -> ${url}"
}

# shellcheck disable=SC2329 # invoked through the register_cleanup trap chain
cleanup() {
  if [[ -n $CONFIG_DIR && -d $CONFIG_DIR ]]; then
    rm -rf -- "$CONFIG_DIR"
  fi
}

build_filters() {
  local pattern
  for pattern in "${INCLUDE_PATTERNS[@]:-}"; do
    [[ -n $pattern ]] || continue
    EXTRA_ARGS+=(--include "$pattern")
  done
  for pattern in "${EXCLUDE_PATTERNS[@]:-}"; do
    [[ -n $pattern ]] || continue
    EXTRA_ARGS+=(--exclude "$pattern")
  done
  if (( SUM_CHECKSUM == 1 )); then
    EXTRA_ARGS+=(--checksum)
  fi
}

rclone_base_args() {
  printf '%s\0' \
    --config "$CONFIG_DIR/rclone.conf" \
    --transfers "$TRANSFERS" \
    --checkers "$CHECKERS" \
    --tpslimit "$TPSLIMIT" \
    --create-empty-src-dirs \
    --stats 30s \
    --stats-one-line
}

run_copy() {
  section "copy into ${NC_USER}:/${TARGET_DIR}"
  local -a args=(copy "${SOURCE_REMOTE}" "cloudsuite:${TARGET_DIR}")
  local arg
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(rclone_base_args)
  args+=("${EXTRA_ARGS[@]:-}")
  if is_dry_run; then args+=(--dry-run); fi
  args+=(--log-file "$LOG_FILE" --log-level INFO)
  info "rclone ${args[*]}"
  local rc=0
  rclone "${args[@]}" || rc=$?
  if (( rc != 0 )); then
    error "rclone copy failed (exit ${rc}) - see ${LOG_FILE}"
    hint "re-run the same command: rclone resumes where it stopped"
    exit 1
  fi
  ok "copy finished"
}

run_verify() {
  section "verify (mode: ${VERIFY_MODE})"
  case $VERIFY_MODE in
    size|download) ;;
    none) log "verification skipped"; return 0 ;;
    *) die "unknown --verify mode '${VERIFY_MODE}' (size or download)" 2 ;;
  esac
  local -a args=(check "${SOURCE_REMOTE}" "cloudsuite:${TARGET_DIR}" --one-way)
  local arg
  while IFS= read -r -d '' arg; do args+=("$arg"); done < <(rclone_base_args)
  case $VERIFY_MODE in
    size) args+=(--size-only) ;;
    download) args+=(--download) ;;
  esac
  info "rclone ${args[*]}"
  local rc=0
  rclone "${args[@]}" --log-file "$LOG_FILE" --log-level INFO || rc=$?
  if (( rc != 0 )); then
    error "verification found differences (exit ${rc}) - see ${LOG_FILE}"
    exit 1
  fi
  ok "verification passed"
}

rescan() {
  section "index the new files"
  if is_dry_run; then
    log "[dry-run] occ files:scan --path=${NC_USER}/files/${TARGET_DIR}"
    return 0
  fi
  if occ files:scan --path="${NC_USER}/files/${TARGET_DIR}" >/dev/null 2>&1; then
    ok "occ files:scan completed for ${TARGET_DIR}"
  else
    warn "occ files:scan reported errors - run it manually: occ files:scan --path=${NC_USER}/files/${TARGET_DIR}"
  fi
}

print_report() {
  section "migration report"
  printf 'source        : %s\n' "${SOURCE_REMOTE}"
  printf 'target        : %s:/%s\n' "${NC_USER}" "${TARGET_DIR}"
  printf 'verify mode   : %s\n' "$VERIFY_MODE"
  printf 'duration      : %s\n' "$(human_seconds $(( $(date +%s) - STARTED_AT )))"
  printf 'rclone log    : %s\n' "$LOG_FILE"
  if (( VERIFY_ONLY == 1 )); then
    printf 'mode          : verify only\n'
  fi
  hint "check the result in the web UI, then remove the source data only after"
  hint "the user has confirmed that everything is present (docs/08-migration-from-yandex-disk.md)"
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --source) SOURCE_REMOTE=${2:?--source needs REMOTE:PATH}; shift 2 ;;
      --user) NC_USER=${2:?--user needs a uid}; shift 2 ;;
      --target-dir) TARGET_DIR=${2:?--target-dir needs a name}; shift 2 ;;
      --base-url) BASE_URL=${2:?--base-url needs a URL}; shift 2 ;;
      --transfers) TRANSFERS=${2:?--transfers needs a number}; shift 2 ;;
      --checkers) CHECKERS=${2:?--checkers needs a number}; shift 2 ;;
      --tpslimit) TPSLIMIT=${2:?--tpslimit needs a number}; shift 2 ;;
      --include) INCLUDE_PATTERNS+=("${2:?--include needs a pattern}"); shift 2 ;;
      --exclude) EXCLUDE_PATTERNS+=("${2:?--exclude needs a pattern}"); shift 2 ;;
      --checksum) SUM_CHECKSUM=1; shift ;;
      --verify) VERIFY_MODE=${2:?--verify needs size or download}; shift 2 ;;
      --verify-only) VERIFY_ONLY=1; shift ;;
      --rclone-arg) EXTRA_ARGS+=("${2:?--rclone-arg needs a value}"); shift 2 ;;
      --insecure) EXTRA_ARGS+=(--no-check-certificate); shift ;;
      --yes) assume_yes; shift ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  [[ -n $SOURCE_REMOTE ]] || die "--source is required (try --help)" 2
  [[ -n $NC_USER ]] || die "--user is required (try --help)" 2
  [[ $SOURCE_REMOTE == *:* ]] || die "--source must look like remote:path (e.g. yandex:disk)" 2
  [[ $TRANSFERS =~ ^[0-9]+$ && $CHECKERS =~ ^[0-9]+$ && $TPSLIMIT =~ ^[0-9]+$ ]] \
    || die "--transfers/--checkers/--tpslimit must be numbers" 2

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker
  require_rclone
  if [[ -z $BASE_URL ]]; then
    [[ -n ${CLOUD_DOMAIN:-} ]] || die "CLOUD_DOMAIN is empty - pass --base-url"
    BASE_URL="https://${CLOUD_DOMAIN}"
  fi
  BASE_URL=${BASE_URL%/}
  [[ $BASE_URL == https://* || $BASE_URL == http://* ]] || die "--base-url must start with http(s)://" 2
  if ! service_running app; then
    die "the app container is not running (make up)"
  fi

  mkdir -p "${CLOUDSUITE_ROOT}/logs"
  LOG_FILE="${CLOUDSUITE_ROOT}/logs/migration-$(timestamp_compact).log"
  build_filters

  section "Cloud Suite migration: Yandex.Disk -> Nextcloud"
  check_source
  check_user
  read_password
  write_rclone_config

  if (( VERIFY_ONLY == 0 )); then
    if ! is_dry_run && (( CLOUDSUITE_ASSUME_YES == 0 )); then
      confirm "Copy ${SOURCE_REMOTE} into ${NC_USER}:/${TARGET_DIR} now?" || die "aborted by the operator"
    fi
    run_copy
    rescan
  fi
  run_verify
  print_report
  if is_dry_run; then
    warn "dry-run: nothing was copied"
  fi
  ok "migration finished"
}

main "$@"
