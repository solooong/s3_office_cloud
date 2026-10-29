#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - fill every empty secret in .env with a strong random value
#  ---------------------------------------------------------------------------
#  Idempotent: only empty values are generated, existing values are kept.
#  The script never prints a secret; it prints which keys were generated and
#  the resulting file permissions.  Always finishes with chmod 600.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "generate-secrets.sh"

TARGET_FILE=""
FORCE=0

# KEY:BYTES - 2 hex chars per byte from openssl rand -hex.
SECRET_SPECS=(
  "POSTGRES_PASSWORD:32"
  "REDIS_PASSWORD:32"
  "S3_ACCESS_KEY:20"
  "S3_SECRET_KEY:40"
  "ONLYOFFICE_JWT_SECRET:32"
  "NEXTCLOUD_ADMIN_PASSWORD:24"
  "NPM_ADMIN_PASSWORD:24"
  "BACKUP_PASSPHRASE:32"
)

usage() {
  cat <<'USAGE'
generate-secrets.sh - fill empty secrets in .env (idempotent)

Usage:
  ./scripts/generate-secrets.sh [options]

Options:
  -f, --file PATH   environment file to update (default: ./.env)
      --force       regenerate values that are already set
  -n, --dry-run     show what would be generated, change nothing
  -h, --help        show this help and exit

Generated keys (only when empty):
  POSTGRES_PASSWORD, REDIS_PASSWORD, S3_ACCESS_KEY, S3_SECRET_KEY,
  ONLYOFFICE_JWT_SECRET, NEXTCLOUD_ADMIN_PASSWORD, NPM_ADMIN_PASSWORD,
  BACKUP_PASSPHRASE

Notes:
  * the file is chmod 600 and never printed
  * copy BACKUP_PASSPHRASE into your password manager: without it the
    encrypted config/.env backup cannot be restored
USAGE
}

parse_args() {
  while (( $# > 0 )); do
    case $1 in
      -f|--file) TARGET_FILE=${2:?--file needs a value}; shift 2 ;;
      --force) FORCE=1; shift ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done
}

# Read the raw value of KEY from the env file (last assignment wins).
env_file_get() {
  local file=$1 key=$2 line value=""
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line == "$key="* ]]; then
      value=${line#*=}
    fi
  done < "$file"
  printf '%s' "$value"
}

# Replace KEY=... in the file, preserving comments, order and blank lines.
env_file_set() {
  local file=$1 key=$2 value=$3 line tmp
  tmp=$(mktemp "${file}.XXXXXX")
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line == "$key="* ]]; then
      printf '%s=%s\n' "$key" "$value"
    else
      printf '%s\n' "$line"
    fi
  done < "$file" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$file"
}

main() {
  parse_args "$@"

  local file=${TARGET_FILE:-${CLOUDSUITE_ROOT}/.env}
  if [[ ! -f $file ]]; then
    error "environment file not found: ${file}"
    if [[ -f ${CLOUDSUITE_ROOT}/.env.example ]]; then
      hint "create it first: cp .env.example .env"
    fi
    exit 1
  fi
  require_cmd openssl

  log "environment file: ${file}"
  local generated=() kept=() spec key bytes current value
  local tmp
  tmp=$(mktemp)
  printf '%s\n' "KEY|STATUS|BYTES" > "$tmp"

  for spec in "${SECRET_SPECS[@]}"; do
    key=${spec%%:*}
    bytes=${spec##*:}
    current=$(env_file_get "$file" "$key")
    if [[ -n $current && $FORCE -eq 0 ]]; then
      kept+=("$key")
      printf '%s|kept|%s\n' "$key" "${#current}" >> "$tmp"
      continue
    fi
    if is_dry_run; then
      generated+=("$key")
      printf '%s|would-generate|%s\n' "$key" "$(( bytes * 2 ))" >> "$tmp"
      continue
    fi
    value=$(openssl rand -hex "$bytes") || die "openssl rand failed for ${key}"
    env_file_set "$file" "$key" "$value"
    generated+=("$key")
    printf '%s|generated|%s\n' "$key" "$(( bytes * 2 ))" >> "$tmp"
  done

  if (( ${#generated[@]} > 0 )) && ! is_dry_run; then
    chmod 600 "$file"
  fi

  printf '\n%-28s %-14s %s\n' "KEY" "STATUS" "CHARS"
  local line
  while IFS= read -r line; do
    [[ $line == "KEY|STATUS|BYTES" ]] && continue
    local k s b
    IFS='|' read -r k s b <<< "$line"
    printf '%-28s %-14s %s\n' "$k" "$s" "$b"
  done < "$tmp"
  rm -f "$tmp"

  local perm
  if is_dry_run; then
    warn "dry-run: no file was modified"
    exit 0
  fi
  perm=$(stat -c '%a' "$file" 2>/dev/null || stat -f '%Lp' "$file" 2>/dev/null || echo unknown)
  if [[ $perm != 600 && $perm != unknown ]]; then
    warn "permissions of ${file} are ${perm}, expected 600 - fixing"
    chmod 600 "$file"
    perm=600
  fi

  section "summary"
  printf 'generated : %d\n' "${#generated[@]}"
  printf 'kept      : %d\n' "${#kept[@]}"
  printf 'file mode : %s\n' "$perm"
  if (( ${#generated[@]} > 0 )); then
    printf 'generated keys: %s\n' "${generated[*]}"
    hint "values are not printed on purpose"
    hint "store BACKUP_PASSPHRASE in your password manager"
  else
    ok "nothing to do - every secret is already set"
  fi
  hint "next: edit CLOUD_DOMAIN / OFFICE_DOMAIN / ACME_EMAIL / SMTP_* then ./scripts/bootstrap.sh"
}

main "$@"
