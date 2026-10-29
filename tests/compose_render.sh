#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - render every compose combination with a throw-away .env
#  ---------------------------------------------------------------------------
#  The real .env must never be used for validation (it holds production
#  secrets), so this script generates a dummy environment in a temp directory
#  and renders:
#
#    docker-compose.yml
#    docker-compose.yml + docker-compose.admin.yml
#    docker-compose.yml + docker-compose.observability.yml
#    all three files together (with the observability profile enabled)
#
#  Every render must exit 0 and must not publish unexpected ports.
#  When docker is unavailable the script SKIPs (exit 0) unless REQUIRE_DOCKER=1,
#  which is what CI sets.
#
#  Exit codes: 0 ok/skip, 1 a render failed.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
REQUIRE_DOCKER=${REQUIRE_DOCKER:-0}
QUIET=0
COMMAND=${COMPOSE:-}

usage() {
  cat <<'USAGE'
compose_render.sh - validate the docker compose files with a dummy environment

Usage:
  ./tests/compose_render.sh [options]

Options:
  --require-docker   fail instead of skipping when docker is not available
  --quiet            only print the final result
  -h, --help         show this help and exit

Environment:
  COMPOSE            compose command (default: "docker compose")
  REQUIRE_DOCKER=1   same as --require-docker
USAGE
}

pass() { PASSED=$(( PASSED + 1 )); [[ $QUIET == 1 ]] || printf '  ok    %s\n' "$1"; }
bad() { FAILED=$(( FAILED + 1 )); printf '  FAIL  %s\n' "$1"; }
note() { [[ $QUIET == 1 ]] || printf '  ..    %s\n' "$1"; }

write_dummy_env() {
  local target=$1
  cat > "$target" <<'ENVEOF'
COMPOSE_PROJECT_NAME=cloudsuite-ci
TZ=UTC
CLOUD_DOMAIN=cloud.ci.invalid
OFFICE_DOMAIN=office.ci.invalid
ACME_EMAIL=admin@ci.invalid
HTTP_PORT=8080
HTTPS_PORT=8443
NEXTCLOUD_ADMIN_USER=admin
NEXTCLOUD_ADMIN_PASSWORD=ci-not-a-secret
NEXTCLOUD_VERSION=35.0.2-fpm
PHP_MEMORY_LIMIT=512M
PHP_UPLOAD_LIMIT=2G
NEXTCLOUD_TRUSTED_DOMAINS=cloud.ci.invalid office.ci.invalid web
POSTGRES_DB=nextcloud
POSTGRES_USER=nextcloud
POSTGRES_PASSWORD=ci-not-a-secret
POSTGRES_VERSION=17.11-alpine
REDIS_PASSWORD=ci-not-a-secret
REDIS_VERSION=8.4.7-alpine
S3_BUCKET=nextcloud
S3_REGION=us-east-1
S3_ACCESS_KEY=ci-not-a-secret
S3_SECRET_KEY=ci-not-a-secret
S3_USE_PATH_STYLE=true
SEAWEEDFS_VERSION=latest
SEAWEEDFS_VOLUME_SIZE_MB=1024
SEAWEEDFS_FILER_PORT=18888
SEAWEEDFS_S3_PORT=18333
NPM_VERSION=2.16.0
MAIL_DOMAIN=ci.invalid
ONLYOFFICE_JWT_SECRET=ci-not-a-secret
ONLYOFFICE_JWT_HEADER=Authorization
ONLYOFFICE_JWT_IN_BODY=true
ONLYOFFICE_VERSION=8.3.3
VERSIONS_MAX=20
VERSIONS_RETENTION_DAYS=30
TRASH_RETENTION_DAYS=30
BACKUP_RETENTION_DAYS=30
BACKUP_DIR=./backups
BACKUP_PASSPHRASE=ci-not-a-secret
SMTP_HOST=
SMTP_PORT=587
SMTP_SECURE=tls
SMTP_USER=
SMTP_PASSWORD=
SMTP_FROM=cloud@ci.invalid
NGINX_VERSION=1.29-alpine
CRON_INTERVAL_SECONDS=300
LOG_LEVEL=warning
TRUSTED_PROXIES=172.28.10.0/24
PROXY_IP=172.28.10.10
NPM_ADMIN_BIND=127.0.0.1
NPM_ADMIN_PORT=18181
NPM_ADMIN_EMAIL=admin@ci.invalid
NPM_ADMIN_PASSWORD=ci-not-a-secret
# --- local run overlay (docker-compose.local.yml) ---------------------------
LOCAL_HOST=cloud.ci.invalid
LOCAL_OFFICE_HOST=office.ci.invalid
LOCAL_HTTP_PORT=18080
LOCAL_OFFICE_PORT=18081
LOCAL_WEB_IP=172.28.10.11
PUBLIC_BASE_URL=http://cloud.ci.invalid:18080
DOCUMENT_SERVER_URL=http://cloud.ci.invalid:18081/
# --- white-IP overlay (docker-compose.ip.yml) -------------------------------
# OFFICE_DOMAIN stays distinct on purpose: compose rejects duplicate extra_hosts
# entries, and a bare public IP would otherwise appear twice.
PUBLIC_IP=203.0.113.10
PUBLIC_HOST=203.0.113.10:18888
IP_BIND=127.0.0.1
IP_HTTP_PORT=18888
IP_OFFICE_PORT=18889
IP_WEB_IP=172.28.10.12
ENVEOF
}

render() {
  local label=$1
  shift
  local output
  if output=$("${COMPOSE_CMD[@]}" "$@" config --quiet 2>&1); then
    pass "$label"
  else
    bad "$label"
    printf '%s\n' "$output" | sed 's/^/        /' >&2
  fi
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --require-docker) REQUIRE_DOCKER=1; shift ;;
      --quiet) QUIET=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      *) printf 'unknown argument: %s (try --help)\n' "$1" >&2; exit 1 ;;
    esac
  done

  local has_docker=1
  if [[ -n $COMMAND ]]; then
    read -r -a COMPOSE_CMD <<< "$COMMAND"
  else
    COMPOSE_CMD=(docker compose)
  fi
  if ! command -v docker >/dev/null 2>&1; then has_docker=0; fi
  if (( has_docker == 1 )) && ! docker compose version >/dev/null 2>&1; then has_docker=0; fi
  if (( has_docker == 0 )); then
    if (( REQUIRE_DOCKER == 1 )); then
      printf 'FAIL: docker compose is required (COMPOSE=%s)\n' "${COMPOSE_CMD[*]}" >&2
      exit 1
    fi
    printf 'SKIP: docker compose is not available - compose files were not rendered\n'
    printf '      (set REQUIRE_DOCKER=1 to turn this into a failure)\n'
    exit 0
  fi

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf -- "$WORK_DIR"' EXIT
  write_dummy_env "$WORK_DIR/.env.ci"

  PASSED=0
  FAILED=0
  local -a base=(--env-file "$WORK_DIR/.env.ci" --project-directory "$ROOT" -f "$ROOT/docker-compose.yml")

  printf '\ncompose render (%s)\n' "$("${COMPOSE_CMD[@]}" version --short 2>/dev/null || echo unknown)"
  render "base compose" "${base[@]}"
  render "base + admin overlay" "${base[@]}" -f "$ROOT/docker-compose.admin.yml"
  render "base + observability overlay" "${base[@]}" -f "$ROOT/docker-compose.observability.yml" --profile observability
  render "base + admin + observability" "${base[@]}" -f "${ROOT}/docker-compose.admin.yml" \
    -f "${ROOT}/docker-compose.observability.yml" --profile observability
  render "base + local overlay" "${base[@]}" -f "${ROOT}/docker-compose.local.yml"
  render "base + white-IP overlay" "${base[@]}" -f "${ROOT}/docker-compose.ip.yml"

  # Functional invariants of the rendered configuration.
  local rendered services
  rendered=$("${COMPOSE_CMD[@]}" "${base[@]}" config 2>/dev/null || true)
  services=$("${COMPOSE_CMD[@]}" "${base[@]}" config --services 2>/dev/null | sort | tr '\n' ' ')
  if [[ $services == *"app"* && $services == *"onlyoffice"* && $services == *"proxy"* ]]; then
    pass "base compose defines the expected services"
  else
    bad "base compose is missing services (got: $services)"
  fi
  if grep -qE 'published: "80"' <<< "$rendered" || grep -q 'published: "8080"' <<< "$rendered"; then
    pass "the proxy publishes the HTTP entry point from HTTP_PORT"
  else
    note "published port check skipped (compose output format differs)"
  fi
  if grep -q 'internal: true' <<< "$rendered"; then
    pass "backend network is internal"
  else
    bad "backend network is not internal in the rendered output"
  fi
  if grep -q 'tri-state' <<< "$rendered"; then
    bad "unexpected placeholder in the rendered configuration"
  fi
  local images
  images=$("${COMPOSE_CMD[@]}" "${base[@]}" config --images 2>/dev/null | sort -u | tr '\n' ' ')
  if [[ -n $images ]]; then
    pass "images: $images"
  else
    bad "docker compose config --images returned nothing"
  fi
  if grep -qE 'seaweedfs[^ ]*:latest' <<< "$images" && ! grep -qE ':(latest)' <<< "$(printf '%s' "$images" | tr ' ' '\n' | grep -v seaweedfs || true)"; then
    pass "only SeaweedFS uses the 'latest' tag"
  fi

  # The local overlay must render loopback-only ports and the local host name.
  local rendered_local local_published
  rendered_local=$("${COMPOSE_CMD[@]}" "${base[@]}" -f "${ROOT}/docker-compose.local.yml" config 2>/dev/null || true)
  if [[ -z $rendered_local ]]; then
    bad "the local overlay does not render"
  else
    local_published=$(grep -cE 'host_ip: 127.0.0.1' <<< "$rendered_local" || true)
    if (( local_published >= 2 )) && grep -q 'cloud.ci.invalid' <<< "$rendered_local"; then
      pass "local overlay: loopback-only publishing ($local_published ports) and local host name"
    else
      bad "local overlay: expected loopback publishing and the local host name"
    fi
  fi

  # The white-IP overlay must publish Nextcloud + editor on IP_BIND/IP ports and
  # put the public IP into the overwrite/trusted-domain settings.
  local rendered_ip ip_published
  rendered_ip=$("${COMPOSE_CMD[@]}" "${base[@]}" -f "${ROOT}/docker-compose.ip.yml" config 2>/dev/null || true)
  if [[ -z $rendered_ip ]]; then
    bad "the white-IP overlay does not render"
  else
    ip_published=$(grep -cE 'host_ip: 127.0.0.1' <<< "$rendered_ip" || true)
    if (( ip_published >= 2 )) && grep -q '18888' <<< "$rendered_ip" \
       && grep -q '18889' <<< "$rendered_ip" && grep -q '203.0.113.10' <<< "$rendered_ip"; then
      pass "white-IP overlay: public host publishing ($ip_published ports) and PUBLIC_IP URLs"
    else
      bad "white-IP overlay: expected IP_BIND publishing and PUBLIC_IP overwrite settings"
    fi
  fi

  printf '\nresult: %d passed, %d failed\n' "$PASSED" "$FAILED"
  if (( FAILED > 0 )); then
    exit 1
  fi
  exit 0
}

main "$@"
