#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - smoke checks for the white-IP (no domain) deployment
#  ---------------------------------------------------------------------------
#  Verifies, from the host itself, that the stack answers on the public-IP
#  virtual host and that ONLYOFFICE can call Nextcloud back:
#
#    1. http://127.0.0.1:IP_HTTP_PORT/status.php  with "Host: PUBLIC_IP" -> 200
#    2. the same endpoint reports "installed":true
#    3. /login -> 200/302/303
#    4. http://127.0.0.1:IP_OFFICE_PORT/healthcheck -> 200
#    5. ONLYOFFICE (from inside its container) reaches
#       http://PUBLIC_IP:IP_HTTP_PORT/status.php -> 200 (callback path)
#
#  Usage:
#    ./scripts/ip-check.sh            # all checks, exit 0 when everything is OK
#    ./scripts/ip-check.sh --help
#
#  Environment: PUBLIC_IP, IP_HTTP_PORT (80), IP_OFFICE_PORT (8081)
#  Exit codes: 0 ok, 1 a check failed, 2 usage/setup error.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "ip-check.sh"

for arg in "$@"; do
  case $arg in
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "ip-check.sh: unknown argument: $arg (try --help)" ;;
  esac
done

ensure_env
env_require PUBLIC_IP
HTTP_PORT_CHECK=${IP_HTTP_PORT:-80}
OFFICE_PORT_CHECK=${IP_OFFICE_PORT:-8081}
host_header=${PUBLIC_IP}
if [[ $HTTP_PORT_CHECK != 80 ]]; then
  host_header="${PUBLIC_IP}:${HTTP_PORT_CHECK}"
fi
base="http://127.0.0.1:${HTTP_PORT_CHECK}"

require_cmd curl

status_code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $host_header" "$base/status.php" || true)
if [[ $status_code != 200 ]]; then
  error "status.php: HTTP $status_code (expected 200) - is the stack up? (make ip-up)"
  exit 1
fi
ok "Nextcloud status.php -> 200 (Host: $host_header)"

if ! curl -fsS -H "Host: $host_header" "$base/status.php" | grep -q '"installed":true'; then
  error "Nextcloud is not installed yet - wait for the first boot (make ip-logs SERVICE=app)"
  exit 1
fi
ok "Nextcloud reports installed:true"

login_code=$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $host_header" "$base/login" || true)
case $login_code in
  200|302|303) ok "/login -> $login_code" ;;
  *) error "/login: HTTP $login_code (expected 200/302/303)"; exit 1 ;;
esac

office_code=$(curl -sS -o /dev/null -w '%{http_code}' "http://127.0.0.1:${OFFICE_PORT_CHECK}/healthcheck" || true)
if [[ $office_code != 200 ]]; then
  error "ONLYOFFICE /healthcheck: HTTP $office_code (expected 200)"
  exit 1
fi
ok "ONLYOFFICE /healthcheck -> 200 (browser URL http://${PUBLIC_IP}:${OFFICE_PORT_CHECK}/)"

printf '\nGUI:        http://%s:%s/\n' "${PUBLIC_IP}" "${HTTP_PORT_CHECK}"
printf 'Editor:     http://%s:%s/\n' "${PUBLIC_IP}" "${OFFICE_PORT_CHECK}"
printf 'Login:      see NEXTCLOUD_ADMIN_USER/PASSWORD in %s\n' "${CLOUDSUITE_ENV_FILE}"

# Callback path: run the route helper in --verify mode (it prints its own result).
CLOUDSUITE_ENV_FILE="${CLOUDSUITE_ENV_FILE}" "${SCRIPT_DIR}/ip-callback-route.sh" --verify
