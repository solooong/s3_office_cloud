#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - route ONLYOFFICE callbacks to Nextcloud on a white-IP host
#  ---------------------------------------------------------------------------
#  On a "white IP" deployment the public URL is a bare IP (http://203.0.113.10/),
#  so Nextcloud builds ONLYOFFICE callback URLs with that IP.  A container cannot
#  always reach the host's public IP (1:1 NAT at the provider, firewall, cloud
#  network without NAT loopback).  This helper adds ONE iptables DNAT rule
#  *inside the onlyoffice network namespace*:
#
#      PUBLIC_IP:IP_HTTP_PORT  ->  web:8080   (destination rewritten to IP_WEB_IP)
#
#  Properties:
#    * nothing is changed on the host, in iptables of the host, or in the stack;
#    * needs NET_ADMIN for the helper container only (no --privileged);
#    * the rule is idempotent and disappears with the onlyoffice container.
#
#  Usage:
#    ./scripts/ip-callback-route.sh            # add the rule (idempotent)
#    ./scripts/ip-callback-route.sh --check    # is the rule there? exit 0/1
#    ./scripts/ip-callback-route.sh --verify   # rule + real callback from DS
#    ./scripts/ip-callback-route.sh --remove   # remove the rule
#    ./scripts/ip-callback-route.sh --help
#
#  Environment (from .env.ip unless overridden):
#    PUBLIC_IP, IP_HTTP_PORT (default 80), IP_WEB_IP, IP_ROUTE_IMAGE
#
#  Exit codes: 0 ok, 1 rule missing with --check, 2 usage, 3 routing unavailable.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "ip-callback-route.sh"

IMAGE=${IP_ROUTE_IMAGE:-alpine:3.20}
WEB_PORT=8080
MODE=apply

usage() {
  sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
  case $arg in
    -h|--help) usage; exit 0 ;;
    --check) MODE=check ;;
    --verify) MODE=verify ;;
    --remove|--delete) MODE=remove ;;
    --apply) MODE=apply ;;
    *) die "ip-callback-route.sh: unknown argument: $arg (try --help)" ;;
  esac
done

ensure_env
env_require PUBLIC_IP IP_WEB_IP
PORT=${IP_HTTP_PORT:-80}
require_cmd docker
container="$(compose ps -q onlyoffice 2>/dev/null || true)"
if [[ -z $container ]]; then
  die "onlyoffice container is not running - start the stack first (make ip-up)"
fi

# The rule is created/checked inside a short-lived container that joins the
# onlyoffice network namespace.  busybox ash is enough: no arrays, plain sh.
helper() {
  local op=$1
  docker run --rm --net "container:$container" --cap-add NET_ADMIN \
    -e PUBLIC_IP="$PUBLIC_IP" -e CALLBACK_PORT="$PORT" \
    -e WEB_IP="$IP_WEB_IP" -e WEB_PORT="$WEB_PORT" -e OP="$op" \
    "$IMAGE" sh -c '
      if ! command -v iptables >/dev/null 2>&1; then
        apk add --no-cache iptables >/dev/null 2>&1 || { echo no-iptables >&2; exit 3; }
      fi
      rule="OUTPUT -d $PUBLIC_IP -p tcp --dport $CALLBACK_PORT -j DNAT --to-destination $WEB_IP:$WEB_PORT"
      case $OP in
        add)   iptables -t nat -C $rule 2>/dev/null || iptables -t nat -A $rule ;;
        check) iptables -t nat -C $rule 2>/dev/null ;;
        del)   iptables -t nat -D $rule 2>/dev/null || exit 0 ;;
      esac
    '
}

case $MODE in
  check)
    if helper check; then
      ok "callback route: ${PUBLIC_IP}:${PORT} -> ${IP_WEB_IP}:${WEB_PORT} (inside onlyoffice)"
      exit 0
    fi
    warn "callback route is absent: ${PUBLIC_IP}:${PORT} -> ${IP_WEB_IP}:${WEB_PORT}"
    exit 1
    ;;
  verify)
    if ! helper check >/dev/null 2>&1; then
      warn "callback route is absent: ${PUBLIC_IP}:${PORT} -> ${IP_WEB_IP}:${WEB_PORT}"
      hint "run: make ip-route   (adds the rule inside the onlyoffice namespace)"
    fi
    code=$(docker exec "$container" curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
             "http://${PUBLIC_IP}:${PORT}/status.php" 2>/dev/null || true)
    if [[ $code == 200 ]]; then
      ok "ONLYOFFICE -> Nextcloud callback: http://${PUBLIC_IP}:${PORT}/status.php -> 200"
      exit 0
    fi
    warn "ONLYOFFICE cannot reach Nextcloud at http://${PUBLIC_IP}:${PORT}/status.php (HTTP ${code:-000})"
    hint "make ip-route   - add the in-namespace DNAT route (needs docker NET_ADMIN/loopback)"
    hint "docs/14-ip-run.md, section Troubleshooting - provider NAT / firewall notes"
    exit 1
    ;;
  remove)
    helper del
    ok "callback route removed"
    ;;
  apply)
    if helper check >/dev/null 2>&1; then
      ok "callback route already present: ${PUBLIC_IP}:${PORT} -> ${IP_WEB_IP}:${WEB_PORT}"
      exit 0
    fi
    if helper add; then
      ok "callback route added: ${PUBLIC_IP}:${PORT} -> ${IP_WEB_IP}:${WEB_PORT} (inside onlyoffice)"
      exit 0
    fi
    warn "could not add the callback route (NET_ADMIN / image pull?)"
    hint "ONLYOFFICE must reach http://${PUBLIC_IP}:${PORT}/ ; if this host has NAT loopback"
    hint "for its own public IP the rule is not needed. Otherwise put a domain in front of"
    hint "the stack (production profile) - see docs/14-ip-run.md, section Troubleshooting."
    exit 3
    ;;
esac
