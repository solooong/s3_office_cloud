#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - generate a throw-away .env.ci for tests and CI
#  ---------------------------------------------------------------------------
#  The production .env holds real secrets and must never be used by the
#  validation gates.  This script builds .env.ci from .env.example:
#
#    * every empty secret is filled with a random throw-away value, so that
#      "docker compose config" can render;
#    * COMPOSE_PROJECT_NAME is set to cloudsuite-ci, so the render can never
#      collide with a running production project;
#    * everything else (domains, versions, limits) is copied verbatim, which
#      keeps the render representative of a real deployment.
#
#  Usage:
#    ./tests/generate-ci-env.sh [SOURCE] [OUTPUT]
#
#  Defaults: SOURCE=.env.example, OUTPUT=.env.ci (relative to the repo root).
#  Exit codes: 0 ok, 1 the source is missing or a secret stayed empty.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

SOURCE="${1:-${ROOT}/.env.example}"
OUTPUT="${2:-${ROOT}/.env.ci}"
PROJECT_NAME=cloudsuite-ci

SECRET_KEYS=(
  POSTGRES_PASSWORD
  REDIS_PASSWORD
  S3_ACCESS_KEY
  S3_SECRET_KEY
  ONLYOFFICE_JWT_SECRET
  NEXTCLOUD_ADMIN_PASSWORD
  NPM_ADMIN_PASSWORD
  BACKUP_PASSPHRASE
)

die() { printf "generate-ci-env: %s\n" "$*" >&2; exit 1; }

random_hex() {
  od -An -tx1 -N 16 /dev/urandom | tr -d ' \n'
}

is_secret() {
  local key=$1 candidate
  for candidate in "${SECRET_KEYS[@]}"; do
    [[ $key == "$candidate" ]] && return 0
  done
  return 1
}

main() {
  [[ -f $SOURCE ]] || die "source template not found: $SOURCE"
  command -v od >/dev/null 2>&1 || die "od is required (coreutils)"

  local tmp line key value keys=0 filled=0
  tmp=$(mktemp)
  trap 'rm -f -- "$tmp"' EXIT

  while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      keys=$(( keys + 1 ))
      if [[ $key == "COMPOSE_PROJECT_NAME" ]]; then
        value=$PROJECT_NAME
      elif is_secret "$key" && [[ -z $value ]]; then
        value="ci-$(random_hex)"
        filled=$(( filled + 1 ))
      fi
      printf '%s=%s\n' "$key" "$value" >> "$tmp"
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$SOURCE"

  (( keys > 0 )) || die "no KEY=VALUE lines in $SOURCE"

  # Refuse to emit a file that cannot render: every secret must be non-empty.
  local secret
  for secret in "${SECRET_KEYS[@]}"; do
    grep -qE "^$secret=.+$" "$tmp" || die "secret $secret is empty in $SOURCE"
  done

  chmod 600 "$tmp"
  mv -f "$tmp" "$OUTPUT"
  trap - EXIT

  printf 'generate-ci-env: wrote %s (%d keys, %d secrets filled with throw-away values)\n' "$OUTPUT" "$keys" "$filled"
  printf 'generate-ci-env: project name %s - safe for "docker compose config -q"\n' "$PROJECT_NAME"
}

main "$@"
