#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - enforce VERSIONS_MAX versions per file
#  ---------------------------------------------------------------------------
#  Runs config/nextcloud/custom/prune-versions.php (shipped by the repository,
#  bind-mounted read-only at /opt/cloudsuite/custom) inside the app container
#  as www-data.  The PHP script is the single implementation; this wrapper only
#  validates the environment and forwards flags.
#
#  Prints the JSON summary produced by the pruner on stdout.
#  Exit codes: 0 = ok, 1 = individual deletions failed, 2 = usage/setup error.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "prune-versions.sh"

# The repository is mounted read-only at /opt/cloudsuite inside app and cron
# (docker-compose.yml).  /var/www/html/custom is kept as a fallback for older
# layouts where the custom directory was mounted directly.
REMOTE_SCRIPT=""
REMOTE_SCRIPT_CANDIDATES=(
  /opt/cloudsuite/custom/prune-versions.php
  /var/www/html/custom/prune-versions.php
)
MAX_VERSIONS=""
QUIET=0

usage() {
  cat <<'USAGE'
prune-versions.sh - keep at most VERSIONS_MAX versions per file

Usage:
  ./scripts/prune-versions.sh [options]

Options:
  --max N        override VERSIONS_MAX for this run (default: VERSIONS_MAX from .env)
  --quiet        suppress the per-file output (JSON summary only)
  -n, --dry-run  show what would be deleted, delete nothing
  -h, --help     show this help and exit

The pruner runs as www-data inside the app container:
  php /opt/cloudsuite/custom/prune-versions.php --max=N

Schedule it hourly from the host (flock protects against overlapping runs):
  17 * * * * cd /opt/cloudsuite && flock -n /var/lock/cloudsuite-prune.lock \
             make prune-versions >> /var/log/cloudsuite/prune.log 2>&1

Exit codes: 0 success, 1 some deletions failed, 2 usage or setup error.
USAGE
}

# resolve_pruner - pick the first readable candidate inside the app container
resolve_pruner() {
  local candidate
  for candidate in "${REMOTE_SCRIPT_CANDIDATES[@]}"; do
    if compose exec -T app test -r "$candidate" >/dev/null 2>&1; then
      REMOTE_SCRIPT=$candidate
      return 0
    fi
  done
  return 1
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --max) MAX_VERSIONS=${2:?--max needs a value}; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker

  if [[ -z $MAX_VERSIONS ]]; then
    MAX_VERSIONS=${VERSIONS_MAX:-20}
  fi
  [[ $MAX_VERSIONS =~ ^[0-9]+$ ]] || die "VERSIONS_MAX must be a positive integer (got '${MAX_VERSIONS}')" 2
  if (( MAX_VERSIONS < 1 )); then
    die "VERSIONS_MAX must be >= 1 (got ${MAX_VERSIONS})" 2
  fi

  if ! service_running app; then
    die "the app container is not running - start the stack first (make up)"
  fi

  # The pruner is shipped in the repository and mounted read-only; a missing
  # file means the checkout is incomplete, not that the operation is optional.
  if ! resolve_pruner; then
    error "pruner not found in the app container"
    hint "expected at config/nextcloud/custom/prune-versions.php inside the repository"
    hint "docker-compose.yml mounts ./config/nextcloud at /opt/cloudsuite:ro"
    hint "checked: ${REMOTE_SCRIPT_CANDIDATES[*]}"
    exit 2
  fi

  local -a args=("$REMOTE_SCRIPT" "--max=${MAX_VERSIONS}")
  if is_dry_run; then args+=("--dry-run"); fi
  if (( QUIET == 1 )); then args+=("--quiet"); fi

  section "prune versions (max ${MAX_VERSIONS} per file)"
  if is_dry_run; then
    log "dry-run: no version will be deleted"
  fi

  local output rc=0
  output=$(compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php "${args[@]}" 2>&1) || rc=$?
  printf '%s\n' "$output"

  if command -v python3 >/dev/null 2>&1; then
    local summary_line
    summary_line=$(printf '%s' "$output" | python3 -c '
import json, sys
raw = sys.stdin.read()
for line in reversed(raw.strip().splitlines()):
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        data = json.loads(line)
    except ValueError:
        continue
    parts = ["max=%(max_versions)s", "scanned=%(files_scanned)s", "pruned=%(files_pruned)s", "versions_deleted=%(versions_deleted)s", "errors=%(errors)s"]
    if data.get("dry_run"):
        parts.insert(0, "DRY-RUN")
    print(" ".join(part % data for part in parts))
    break
' 2>/dev/null || true)
    if [[ -n $summary_line ]]; then
      log "summary: ${summary_line}"
    fi
  fi

  if (( rc != 0 )); then
    error "the pruner reported errors (exit ${rc}) - review the output above"
    exit 1
  fi
  ok "prune completed (max ${MAX_VERSIONS} versions per file)"
}

main "$@"
