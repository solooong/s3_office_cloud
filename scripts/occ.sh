#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - occ wrapper
#  ---------------------------------------------------------------------------
#  Runs Nextcloud's occ console inside the running app container as www-data,
#  with the project compose files and env file.  Exit code is passed through.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "occ.sh"

usage() {
  cat <<'USAGE'
occ.sh - run an occ command inside the app container

Usage:
  ./scripts/occ.sh [--tty] <occ-command> [occ-options...]

Examples:
  ./scripts/occ.sh status
  ./scripts/occ.sh user:list --output=json
  ./scripts/occ.sh config:system:get trusted_domains
  ./scripts/occ.sh --tty user:resetpassword alice

Options:
  --tty        allocate a TTY (needed by interactive commands)
  -h, --help   show this help

The command runs as the "www-data" user (override with CLOUDSUITE_OCC_USER).
Exit code and stdout/stderr of occ are passed through unchanged.
USAGE
}

main() {
  local want_tty=0
  while (( $# > 0 )); do
    case $1 in
      --tty) want_tty=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      --) shift; break ;;
      -*) die "unknown option: $1 (occ options must follow the occ command; try --help)" 2 ;;
      *) break ;;
    esac
  done
  if (( $# == 0 )); then
    usage
    exit 2
  fi

  ensure_env
  require_cmd docker
  if ! service_running app; then
    die "the app container is not running - start the stack first (make up)"
  fi

  if (( want_tty == 1 )); then
    compose exec -u "${CLOUDSUITE_OCC_USER}" app php occ "$@"
  else
    compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ "$@"
  fi
}

main "$@"
