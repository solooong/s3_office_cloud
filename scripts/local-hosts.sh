#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - one-time hosts entry for the local (no-domain) run
#  ---------------------------------------------------------------------------
#  Browsers resolve normal names through DNS; the local stack has no DNS, so
#  the two local names must be mapped to 127.0.0.1 once.  Docker containers get
#  the same mapping automatically (extra_hosts in docker-compose.yml), so only
#  the workstation that runs the browser needs this file.
#
#  Why not *.localhost: browsers, musl and glibc/curl treat any *.localhost
#  name as loopback and ignore /etc/hosts, so the ONLYOFFICE server could not
#  reach Nextcloud by the callback URL.  The local run therefore uses
#  cloud.local / office.local (see docs/13-local-run.md).
#
#  Usage:
#    ./scripts/local-hosts.sh            show what to add, apply when root
#    sudo ./scripts/local-hosts.sh       append the entries now
#    ./scripts/local-hosts.sh --check    exit 0 when the entries exist
#    ./scripts/local-hosts.sh --print    print the exact hosts line
#    ./scripts/local-hosts.sh --help
#
#  Environment:
#    CLOUDSUITE_ENV_FILE   env file (default: .env.local)
#    HOSTS_FILE            hosts file (default: /etc/hosts)
#
#  Exit codes: 0 ok, 1 failure / missing entry with --check.
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

ENV_FILE=${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env.local}
HOSTS_FILE=${HOSTS_FILE:-/etc/hosts}
MODE=apply

usage() {
  sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    --check) MODE=check ;;
    --print) MODE=print ;;
    --apply) MODE=apply ;;
    *) die "local-hosts: unknown argument: $arg (try --help)" ;;
  esac
done

file_local_host=
file_office_host=
if [[ -f $ENV_FILE ]]; then
  while IFS='=' read -r key value; do
    value=${value%$'\r'}
    value=${value%\"}
    case $key in
      LOCAL_HOST) file_local_host=$value ;;
      LOCAL_OFFICE_HOST) file_office_host=$value ;;
    esac
  done < "$ENV_FILE"
fi
# shell environment wins over the file (handy for one-off overrides and tests)
local_host=${LOCAL_HOST:-${file_local_host:-cloud.local}}
office_host=${LOCAL_OFFICE_HOST:-${file_office_host:-office.local}}

for name in "$local_host" "$office_host"; do
  case $name in
    *.localhost|localhost)
      warn "local-hosts: $name is in the *.localhost zone - browsers, glibc/musl and curl force it to loopback and ignore /etc/hosts"
      warn "local-hosts: set LOCAL_HOST/LOCAL_OFFICE_HOST to a normal name (defaults: cloud.local, office.local) in $ENV_FILE"
      exit 1
      ;;
  esac
done

entry="127.0.0.1 ${local_host} ${office_host}"
hosts_file=$HOSTS_FILE
os_name=$(uname -s)
is_windows=0
case $os_name in
  MINGW*|MSYS*|CYGWIN*) is_windows=1; hosts_file='C:\Windows\System32\drivers\etc\hosts' ;;
esac

entry_present() {
  [[ -f "$1" ]] && grep -qE "^[[:space:]]*127\.0\.0\.1[[:space:]]+([^#]*[[:space:]])?${local_host}([[:space:]]|$)" "$1"
}

case $MODE in
  print)
    printf '%s\n' "$entry"
    ;;
  check)
    if entry_present "$hosts_file"; then
      ok "local-hosts: $local_host is already mapped in $hosts_file"
      exit 0
    fi
    warn "local-hosts: $local_host is NOT mapped in $hosts_file"
    exit 1
    ;;
  apply)
    [[ -f $hosts_file ]] || die "local-hosts: hosts file not found: $hosts_file"
    if entry_present "$hosts_file"; then
      ok "local-hosts: $local_host is already mapped in $hosts_file - nothing to do"
      exit 0
    fi
    printf 'Добавьте в %s одну строку:\n\n    %s\n\n' "$hosts_file" "$entry"
    if (( is_windows == 1 )); then
      printf 'Windows (PowerShell от имени администратора):\n'
      printf '    Add-Content -Path "$env:WINDIR\\System32\\drivers\\etc\\hosts" -Value "%s"\n\n' "$entry"
      exit 1
    fi
    if [[ $(id -u) -eq 0 ]]; then
      printf '\n%s\n' "$entry" >> "$hosts_file"
      ok "local-hosts: запись добавлена в $hosts_file"
      exit 0
    fi
    printf 'Затем повторите с правами root:\n    sudo %s/scripts/local-hosts.sh\n\n' "$CLOUDSUITE_ROOT"
    exit 1
    ;;
esac
