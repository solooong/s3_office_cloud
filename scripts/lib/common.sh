#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - shared bash library for the operational tooling
#  ---------------------------------------------------------------------------
#  Sourced by every script under scripts/. Provides:
#    * strict mode + structured logging (all log output goes to stderr)
#    * safe .env loading (values are parsed, never evaluated as shell code)
#    * docker compose wrapper with a stable project name and env file
#    * dry-run aware execution, retries, waits, advisory locks, exit traps
#
#  Contract:
#    * scripts MUST run as:  set -Eeuo pipefail  +  source lib/common.sh
#    * log/ok/warn/error/die write to stderr so machine output (--json, --csv)
#      stays clean on stdout
#    * nothing in this file assumes the caller's working directory
# =============================================================================
set -Eeuo pipefail

if [[ -n ${CLOUDSUITE_COMMON_SH:-} ]]; then
  # Library already sourced - keep the first copy (functions are stable).
  return 0
fi
CLOUDSUITE_COMMON_SH=1

# --- paths -------------------------------------------------------------------
CLOUDSUITE_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CLOUDSUITE_ROOT="$(cd -- "${CLOUDSUITE_LIB_DIR}/../.." && pwd -P)"
readonly CLOUDSUITE_LIB_DIR CLOUDSUITE_ROOT
export CLOUDSUITE_ROOT

# --- tunables (all overridable from the environment) -------------------------
CLOUDSUITE_DRY_RUN=${CLOUDSUITE_DRY_RUN:-0}
CLOUDSUITE_ASSUME_YES=${CLOUDSUITE_ASSUME_YES:-0}
CLOUDSUITE_ENV_FILE=${CLOUDSUITE_ENV_FILE:-}
CLOUDSUITE_ENV_KEEP_EXISTING=${CLOUDSUITE_ENV_KEEP_EXISTING:-1}
CLOUDSUITE_COMPOSE_FILES=${CLOUDSUITE_COMPOSE_FILES:-docker-compose.yml}
CLOUDSUITE_OCC_USER=${CLOUDSUITE_OCC_USER:-www-data}
CLOUDSUITE_LOCK_FD=""
CLOUDSUITE_LOCK_DIR=""
CLOUDSUITE_CLEANUP_CMDS=()
CLOUDSUITE_ENV_KEYS=()
CLOUDSUITE_CURRENT_SCRIPT=""

# Backup encryption parameters - MUST stay identical in backup.sh and restore.sh.
# 600000 PBKDF2 iterations (OWASP recommendation for AES-256) slow down guessing
# of BACKUP_PASSPHRASE; the value is also recorded in backup meta.env.
export CLOUDSUITE_BACKUP_PBKDF2_ITER=600000

# --- terminal / colours ------------------------------------------------------
_cs_colours_enabled() {
  [[ -z ${NO_COLOR:-} ]] || return 1
  [[ ${TERM:-dumb} != dumb ]] || return 1
  [[ -t 2 ]]
}
if _cs_colours_enabled; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""
fi

# --- logging -----------------------------------------------------------------
_cs_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

log() {
  printf '%s %s\n' "$(_cs_ts)" "$*" >&2
}

info() {
  printf '%s %s==>%s %s\n' "$(_cs_ts)" "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*" >&2
}

ok() {
  printf '%s %sOK%s    %s\n' "$(_cs_ts)" "${C_GREEN}" "${C_RESET}" "$*" >&2
}

warn() {
  printf '%s %sWARN%s  %s\n' "$(_cs_ts)" "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

error() {
  printf '%s %sERROR%s %s\n' "$(_cs_ts)" "${C_RED}" "${C_RESET}" "$*" >&2
}

debug() {
  [[ ${LOG_LEVEL:-info} == debug || ${CLOUDSUITE_DEBUG:-0} == 1 ]] || return 0
  printf '%s %sDBG%s   %s\n' "$(_cs_ts)" "${C_DIM}" "${C_RESET}" "$*" >&2
}

section() {
  printf '\n%s%s== %s ==%s\n' "${C_BOLD}" "${C_BLUE}" "$*" "${C_RESET}" >&2
}

hint() {
  printf '%s        %s\n' "${C_DIM}" "$*" >&2
}

die() {
  local message=$1 code=${2:-1}
  error "$message"
  exit "$code"
}

# --- error trap --------------------------------------------------------------
_cs_on_error() {
  local status=$1 line=$2 cmd=$3
  error "unexpected failure (exit ${status}) at ${CLOUDSUITE_CURRENT_SCRIPT:-${BASH_SOURCE[0]}}:${line}"
  error "failing command: ${cmd}"
  exit "$status"
}
trap '_cs_on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

# Marks the script name used in error messages (set by each entry script).
cs_set_script_name() { CLOUDSUITE_CURRENT_SCRIPT=$1; }

# --- dry-run -----------------------------------------------------------------
is_dry_run() { (( CLOUDSUITE_DRY_RUN == 1 )); }

set_dry_run() { CLOUDSUITE_DRY_RUN=1; }

assume_yes() { CLOUDSUITE_ASSUME_YES=1; }

quote_cmd() {
  local out="" arg
  for arg in "$@"; do
    printf -v arg '%q' "$arg"
    out+="${out:+ }${arg}"
  done
  printf '%s' "$out"
}

# run: execute a mutating command unless --dry-run was requested.
run() {
  if is_dry_run; then
    printf '%s[dry-run]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "$@")" >&2
    return 0
  fi
  debug "exec: $(quote_cmd "$@")"
  "$@"
}

# --- preconditions -----------------------------------------------------------
require_cmd() {
  local missing=() cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if (( ${#missing[@]} > 0 )); then
    die "required command(s) not found: ${missing[*]}"
  fi
}

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    die "this operation needs root (re-run with sudo)"
  fi
}

is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

require_file() {
  local file
  for file in "$@"; do
    [[ -f $file ]] || die "required file not found: ${file}"
  done
}

# confirm <question> [default:no]
confirm() {
  local prompt=$1 default=${2:-no} answer
  if (( CLOUDSUITE_ASSUME_YES == 1 )); then
    log "auto-confirmed (--yes): ${prompt}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    die "refusing to continue without a terminal; re-run with --yes: ${prompt}"
  fi
  if [[ $default == yes ]]; then
    read -r -p "${prompt} [Y/n] " answer
    answer=${answer:-yes}
  else
    read -r -p "${prompt} [y/N] " answer
    answer=${answer:-no}
  fi
  [[ $answer =~ ^([Yy]([Ee][Ss])?|[Дд]а)$ ]]
}

# --- retry / wait ------------------------------------------------------------
retry() {
  local attempts=$1 interval=$2
  shift 2
  if [[ ${1:-} == -- ]]; then shift; fi
  local i
  for (( i = 1; i <= attempts; i++ )); do
    if "$@"; then return 0; fi
    if (( i < attempts )); then
      warn "attempt ${i}/${attempts} failed: $(quote_cmd "$@"); retrying in ${interval}s"
      sleep "$interval"
    fi
  done
  return 1
}

wait_for() {
  local timeout=$1 interval=$2
  shift 2
  if [[ ${1:-} == -- ]]; then shift; fi
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$interval"
  done
  return 1
}

# --- advisory lock -----------------------------------------------------------
acquire_lock() {
  local name=${1:-cloudsuite}
  local lock_root=${TMPDIR:-/tmp}
  local lock_file="${lock_root}/cloudsuite-${name}.lock"
  mkdir -p "$lock_root"
  if command -v flock >/dev/null 2>&1; then
    exec {CLOUDSUITE_LOCK_FD}>"$lock_file"
    if ! flock -n "$CLOUDSUITE_LOCK_FD"; then
      die "another instance is already running (lock: ${lock_file}); wait for it or remove a stale lock" 2
    fi
    printf '%s\n' "$$" >"$lock_file" 2>/dev/null || true
    debug "acquired flock ${lock_file}"
    return 0
  fi
  # Portable fallback for hosts without flock(1).
  CLOUDSUITE_LOCK_DIR="${lock_file}.d"
  if ! mkdir "$CLOUDSUITE_LOCK_DIR" 2>/dev/null; then
    local holder
    holder=$(cat "${CLOUDSUITE_LOCK_DIR}/pid" 2>/dev/null || echo unknown)
    if [[ $holder =~ ^[0-9]+$ ]] && kill -0 "$holder" 2>/dev/null; then
      die "another instance is already running (pid ${holder}, lock: ${CLOUDSUITE_LOCK_DIR})" 2
    fi
    warn "removing stale lock ${CLOUDSUITE_LOCK_DIR} (pid ${holder} is gone)"
    rm -rf -- "$CLOUDSUITE_LOCK_DIR"
    mkdir "$CLOUDSUITE_LOCK_DIR"
  fi
  printf '%s\n' "$$" >"${CLOUDSUITE_LOCK_DIR}/pid"
  debug "acquired mkdir lock ${CLOUDSUITE_LOCK_DIR}"
}

release_lock() {
  if [[ -n ${CLOUDSUITE_LOCK_FD:-} ]]; then
    flock -u "$CLOUDSUITE_LOCK_FD" 2>/dev/null || true
    exec {CLOUDSUITE_LOCK_FD}>&-
    CLOUDSUITE_LOCK_FD=""
  fi
  if [[ -n ${CLOUDSUITE_LOCK_DIR:-} ]]; then
    rm -rf -- "$CLOUDSUITE_LOCK_DIR"
    CLOUDSUITE_LOCK_DIR=""
  fi
}

# --- cleanup trap chain ------------------------------------------------------
# register_cleanup <command...> - runs (LIFO) on script exit, success or not.
register_cleanup() {
  local quoted
  quoted=$(printf '%q ' "$@")
  CLOUDSUITE_CLEANUP_CMDS+=("$quoted")
}

_cs_run_cleanup() {
  local index
  for (( index=${#CLOUDSUITE_CLEANUP_CMDS[@]}-1; index>=0; index-- )); do
    # shellcheck disable=SC2294 # the array stores pre-quoted, trusted commands
    eval "${CLOUDSUITE_CLEANUP_CMDS[index]}" || warn "cleanup command failed: ${CLOUDSUITE_CLEANUP_CMDS[index]}"
  done
  CLOUDSUITE_CLEANUP_CMDS=()
  release_lock
}
trap '_cs_run_cleanup' EXIT

# --- .env handling -----------------------------------------------------------
# load_env [file] - parse KEY=VALUE lines without evaluating them as shell.
# Existing non-empty environment variables win over the file unless
# CLOUDSUITE_ENV_KEEP_EXISTING=0 (docker compose has the same precedence).
load_env() {
  local file=${1:-${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env}}
  [[ -f $file ]] || die "environment file not found: ${file} (run: cp .env.example .env && ./scripts/generate-secrets.sh)"
  local line key value
  local lineno=0
  while IFS= read -r line || [[ -n $line ]]; do
    lineno=$(( lineno + 1 ))
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    line=${line#"${line%%[![:space:]]*}"}
    if [[ $line == export\ * ]]; then
      line=${line#export }
      line=${line#"${line%%[![:space:]]*}"}
    fi
    if [[ $line != *=* ]]; then
      debug "skipping non-assignment line ${lineno} in ${file}"
      continue
    fi
    key=${line%%=*}
    value=${line#*=}
    key=${key%"${key##*[![:space:]]}"}
    if [[ ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      warn "ignoring malformed variable name on line ${lineno} of ${file}"
      continue
    fi
    # Strip an inline comment only for unquoted values: " # comment".
    if [[ $value != \"* && $value != \'* ]]; then
      value=${value%%[[:space:]]#*}
      value=${value%"${value##*[![:space:]]}"}
    fi
    if (( ${#value} >= 2 )); then
      if [[ $value == \"*\" ]]; then value=${value:1:${#value}-2}; fi
      if [[ $value == \'*\' ]]; then value=${value:1:${#value}-2}; fi
    fi
    if [[ $CLOUDSUITE_ENV_KEEP_EXISTING == 1 && ${!key:-} != "" ]]; then
      debug "keeping existing environment value for ${key}"
      continue
    fi
    export "${key}=${value}"
    CLOUDSUITE_ENV_KEYS+=("$key")
  done < "$file"
  CLOUDSUITE_ENV_FILE=$file
  debug "loaded ${#CLOUDSUITE_ENV_KEYS[@]} variables from ${file}"
}

ensure_env() {
  local file=${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env}
  if [[ ! -f $file ]]; then
    error "no environment file at ${file}"
    hint "cp .env.example .env"
    hint "./scripts/generate-secrets.sh"
    hint "then edit CLOUD_DOMAIN / OFFICE_DOMAIN / ACME_EMAIL / SMTP_* and re-run"
    exit 1
  fi
  if (( ${#CLOUDSUITE_ENV_KEYS[@]} == 0 )); then
    load_env "$file"
  fi
  CLOUDSUITE_ENV_FILE=$file
}

env_get() {
  local key=$1 default=${2:-}
  printf '%s' "${!key:-$default}"
}

env_has() { [[ ${!1:-} != "" ]]; }

env_require() {
  local key missing=()
  for key in "$@"; do
    [[ ${!key:-} != "" ]] || missing+=("$key")
  done
  if (( ${#missing[@]} > 0 )); then
    die "required variable(s) empty or missing in ${CLOUDSUITE_ENV_FILE:-.env}: ${missing[*]}"
  fi
}

env_is_true() {
  case ${!1:-} in
    1|true|TRUE|True|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

# --- docker compose ----------------------------------------------------------
compose() {
  local env_file=${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env}
  local -a args=(--project-directory "$CLOUDSUITE_ROOT" -p "${COMPOSE_PROJECT_NAME:-cloudsuite}")
  if [[ -f $env_file ]]; then
    args+=(--env-file "$env_file")
  fi
  local file
  # shellcheck disable=SC2086 # allow a space separated list of -f overlays
  for file in ${CLOUDSUITE_COMPOSE_FILES}; do
    [[ -f "${CLOUDSUITE_ROOT}/${file}" ]] || die "compose file not found: ${file}"
    args+=(-f "$file")
  done
  docker compose "${args[@]}" "$@"
}

compose_exec() { compose exec -T "$@"; }

# occ: run an occ command inside the app container as the web user.
occ() { compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ "$@"; }

# Wait until the app container can answer occ (useful right after "make up").
# Usage: wait_for_occ [timeout_seconds]
wait_for_occ() {
  local timeout=${1:-180}
  local deadline=$(( SECONDS + timeout ))
  while (( SECONDS < deadline )); do
    if occ status >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done
  return 1
}

service_running() {
  local service=$1 ids
  ids=$(compose ps -q --status running "$service" 2>/dev/null || true)
  [[ -n $ids ]]
}

service_container_id() {
  compose ps -q "$1" 2>/dev/null | head -n 1
}

wait_for_service_healthy() {
  local service=$1 timeout=${2:-180} interval=${3:-3}
  local deadline=$(( SECONDS + timeout )) id status
  while (( SECONDS < deadline )); do
    id=$(service_container_id "$service")
    if [[ -n $id ]]; then
      status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || echo unknown)
      case $status in
        healthy) return 0 ;;
        running) warn "service ${service} has no healthcheck; assuming ready because it is running"; return 0 ;;
      esac
    fi
    sleep "$interval"
  done
  return 1
}

# resolve_volume_mountpoint <logical volume name> -> host path (needs root)
resolve_volume_mountpoint() {
  local volume=$1 project=${COMPOSE_PROJECT_NAME:-cloudsuite}
  docker volume inspect -f '{{ .Mountpoint }}' "${project}_${volume}" 2>/dev/null
}

# --- misc helpers ------------------------------------------------------------
abs_path() {
  local path=$1
  if [[ ! -e $path ]]; then
    printf '%s' "$path"
    return 0
  fi
  (cd -- "$(dirname -- "$path")" && printf '%s/%s' "$(pwd -P)" "$(basename -- "$path")")
}

make_dirs() {
  local mode=${1:?mode required}
  shift
  local dir
  for dir in "$@"; do
    [[ -d $dir ]] || run mkdir -p "$dir"
    if [[ -d $dir ]]; then chmod "$mode" "$dir"; fi
  done
}

human_bytes() {
  local bytes=${1:-0}
  awk -v b="$bytes" 'BEGIN{
    split("B KiB MiB GiB TiB PiB", u, " "); i = 1
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) { printf "%d %s", b, u[i] } else { printf "%.1f %s", b, u[i] }
  }'
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

json_bool() { if "$@"; then printf true; else printf false; fi; }

validate_identifier() {
  local label=$1 value=$2
  local pattern=${3:-^[A-Za-z0-9][A-Za-z0-9_.@-]*$}
  [[ $value =~ $pattern ]] || die "${label} has an invalid value: '${value}' (expected ${pattern})"
}

host_os() {
  case "$(uname -s 2>/dev/null || echo unknown)" in
    Linux) printf 'linux' ;;
    Darwin) printf 'darwin' ;;
    MINGW*|MSYS*|CYGWIN*) printf 'windows' ;;
    *) printf 'unknown' ;;
  esac
}

timestamp_compact() { date '+%Y%m%d-%H%M%S'; }
timestamp_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

print_version() {
  printf '%s %s\n' "${0##*/}" "${CLOUDSUITE_SCRIPT_VERSION:-1.0.0}"
}

usage_exit() {
  printf '%s\n' "$1"
  exit 0
}

# --- machine-readable output helpers ----------------------------------------
# JSON object accumulator used by healthcheck.sh / audit-report.sh:
# json_obj_open / json_obj_add / json_obj_close keep hand-built JSON valid.
json_obj_open() { printf '{'; }
json_obj_close() { printf '}'; }
