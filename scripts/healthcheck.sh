#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - stack health check
#  ---------------------------------------------------------------------------
#  Verifies every service of the compose stack (per CONTRACT.md section 7) plus
#  host thresholds (disk, memory) and reports PASS/WARN/FAIL/SKIP per check.
#
#  Exit code: 0 = healthy (warnings allowed unless --strict), 1 = at least one
#  FAIL.  Use --json for monitoring integration (Zabbix/Prometheus textfile).
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "healthcheck.sh"

TIMEOUT=10
JSON=0
STRICT=0
EXTERNAL=0
VERBOSE=0
ONLY=""

R_IDS=()
R_LABELS=()
R_STATES=()
R_DETAILS=()
R_DURATIONS=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
TOTAL_COUNT=0

EXPECTED_SERVICES=("proxy" "web" "app" "cron" "db" "cache" "s3" "onlyoffice")

usage() {
  cat <<'USAGE'
healthcheck.sh - health of the Cloud Suite stack and host thresholds

Usage:
  ./scripts/healthcheck.sh [options]

Options:
  --timeout SEC   per-check timeout in seconds (default: 10)
  --json          machine readable report on stdout (nothing else on stdout)
  --strict        treat WARN as failure
  --external      additionally probe https://CLOUD_DOMAIN through the public
                  edge (TLS handshake + certificate expiry + Nextcloud status.php)
  --only LIST     comma separated check ids to run (see --list)
  --list          print the check ids and exit
  -v, --verbose   print per-check duration
  -h, --help      show this help and exit

Checks:
  services, proxy_api, proxy_tcp, tls, web, app, cron, db, cache, s3, s3_init,
  onlyoffice, occ, disk, memory, backup_dir  (+ tls_cert, nextcloud_public
  with --external)

Exit code: 0 = no failures, 1 = at least one failure.
USAGE
}

add_result() {
  local id=$1 label=$2 state=$3 detail=$4 duration=${5:-0}
  R_IDS+=("$id")
  R_LABELS+=("$label")
  R_STATES+=("$state")
  R_DETAILS+=("$detail")
  R_DURATIONS+=("$duration")
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  case $state in
    PASS) PASS_COUNT=$(( PASS_COUNT + 1 )) ;;
    WARN) WARN_COUNT=$(( WARN_COUNT + 1 )) ;;
    FAIL) FAIL_COUNT=$(( FAIL_COUNT + 1 )) ;;
    SKIP) SKIP_COUNT=$(( SKIP_COUNT + 1 )) ;;
  esac
  if (( JSON == 0 )); then
    case $state in
      PASS) printf '%sPASS%s  %-14s %s\n' "${C_GREEN}" "${C_RESET}" "$label" "$detail" ;;
      WARN) printf '%sWARN%s  %-14s %s\n' "${C_YELLOW}" "${C_RESET}" "$label" "$detail" ;;
      FAIL) printf '%sFAIL%s  %-14s %s\n' "${C_RED}" "${C_RESET}" "$label" "$detail" ;;
      SKIP) printf '%sSKIP%s  %-14s %s\n' "${C_DIM}" "${C_RESET}" "$label" "$detail" ;;
    esac
    if (( VERBOSE == 1 )); then printf '      %s(%ss)%s\n' "${C_DIM}" "$duration" "${C_RESET}"; fi
  fi
}

should_run() {
  local id=$1
  [[ -z $ONLY ]] && return 0
  local item
  IFS=',' read -r -a items <<< "$ONLY"
  for item in "${items[@]}"; do
    [[ $item == "$id" ]] && return 0
  done
  return 1
}

# run_check <id> <label> <function>
# The function prints a one line detail and returns 0=PASS 1=WARN 2=FAIL 3=SKIP.
run_check() {
  local id=$1 label=$2 fn=$3 output rc=0 start elapsed
  should_run "$id" || return 0
  start=$SECONDS
  output=$("$fn" 2>&1) || rc=$?
  elapsed=$(( SECONDS - start ))
  case $rc in
    0) add_result "$id" "$label" PASS "$output" "$elapsed" ;;
    1) add_result "$id" "$label" WARN "$output" "$elapsed" ;;
    2) add_result "$id" "$label" FAIL "$output" "$elapsed" ;;
    *) add_result "$id" "$label" SKIP "$output" "$elapsed" ;;
  esac
  return 0
}

with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" "$@"
  else
    "$@"
  fi
}

http_code() {
  local url=$1
  shift
  curl -s -o /dev/null -m "$TIMEOUT" -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

container_http_get() {
  local service=$1 url=$2
  with_timeout compose exec -T "$service" sh -c "curl -fsS -m ${TIMEOUT} '${url}' 2>/dev/null || wget -q -T ${TIMEOUT} -O - '${url}' 2>/dev/null" 2>/dev/null
}

container_http_via_app() {
  local url=$1
  # shellcheck disable=SC2016 # $argv is PHP code, not shell
  with_timeout compose exec -T app php -r 'if (!function_exists("curl_init")) { exit(1); } $h=curl_init($argv[1]); curl_setopt_array($h, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>5, CURLOPT_CONNECTTIMEOUT=>5]); $b=curl_exec($h); $code=(int)curl_getinfo($h, CURLINFO_HTTP_CODE); if ($b === false || $code >= 400) { exit(1); } echo $b;' "$url" 2>/dev/null
}

# --- service checks ---------------------------------------------------------
check_services() {
  local missing=() service ids
  if ! docker compose version >/dev/null 2>&1; then
    printf 'docker compose is not available on this host'
    return 2
  fi
  ids=$(compose ps --format '{{.Service}}' 2>/dev/null || true)
  for service in "${EXPECTED_SERVICES[@]}"; do
    printf '%s\n' "$ids" | grep -qx "$service" || missing+=("$service")
  done
  if (( ${#missing[@]} > 0 )); then
    printf 'not running: %s' "${missing[*]}"
    return 2
  fi
  printf 'all %d long-running services are up' "${#EXPECTED_SERVICES[@]}"
  return 0
}

check_proxy_api() {
  local code
  code=$(http_code "http://127.0.0.1:${NPM_ADMIN_PORT:-8181}/api/")
  case $code in
    200|401) printf 'GET /api/ -> HTTP %s' "$code"; return 0 ;;
    000) printf 'cannot connect to 127.0.0.1:%s' "${NPM_ADMIN_PORT:-8181}"; return 2 ;;
    *) printf 'GET /api/ -> unexpected HTTP %s' "$code"; return 1 ;;
  esac
}

check_proxy_tcp() {
  local code
  code=$(http_code "http://127.0.0.1:${HTTP_PORT:-80}/")
  case $code in
    000) printf 'nothing is listening on port %s' "${HTTP_PORT:-80}"; return 2 ;;
    *) printf 'port %s answers HTTP %s' "${HTTP_PORT:-80}" "$code"; return 0 ;;
  esac
}

check_tls() {
  local rc=0
  curl -sk -o /dev/null -m "$TIMEOUT" "https://127.0.0.1:${HTTPS_PORT:-443}/" >/dev/null 2>&1 || rc=$?
  case $rc in
    0|60) printf 'TLS handshake on port %s ok' "${HTTPS_PORT:-443}"; return 0 ;;
    7) printf 'nothing is listening on port %s' "${HTTPS_PORT:-443}"; return 2 ;;
    *) printf 'TLS handshake failed on port %s (curl exit %s)' "${HTTPS_PORT:-443}" "$rc"; return 2 ;;
  esac
}

check_web() {
  local body
  body=$(container_http_get web "http://127.0.0.1:8080/status")
  if [[ -z $body ]]; then
    printf 'nginx stub_status at web:8080 did not answer'
    return 2
  fi
  if grep -q 'Active connections' <<< "$body"; then
    printf '%s' "$(grep 'Active connections' <<< "$body" | tr -s ' ')"
    return 0
  fi
  printf 'web:8080 answered but the body does not look like stub_status'
  return 1
}

check_app() {
  local out
  # shellcheck disable=SC2016 # $errno/$errstr are PHP code, not shell
  out=$(with_timeout compose exec -T app php -r '$s=@fsockopen("127.0.0.1", 9000, $errno, $errstr, 3); if ($s === false) { echo "fpm-down: $errstr"; exit(2); } fclose($s); echo "fpm-up";' 2>&1) || true
  if [[ $out == fpm-up ]]; then
    printf 'php-fpm accepts connections on app:9000'
    return 0
  fi
  printf 'php-fpm is not accepting connections on app:9000 (%s)' "${out:-no output}"
  return 2
}

check_cron() {
  local status
  status=$(docker inspect -f '{{.State.Status}}' "$(service_container_id cron)" 2>/dev/null || echo missing)
  if [[ $status == running ]]; then
    printf 'cron container is running'
    return 0
  fi
  printf 'cron container state: %s' "$status"
  return 2
}

check_db() {
  local out
  out=$(with_timeout compose exec -T db pg_isready -U "${POSTGRES_USER:-nextcloud}" -d "${POSTGRES_DB:-nextcloud}" 2>&1) || true
  if grep -q 'accepting connections' <<< "$out"; then
    printf 'postgres accepts connections (%s)' "$(tr -d '\n' <<< "$out")"
    return 0
  fi
  printf 'postgres is not ready: %s' "${out:-no output}"
  return 2
}

check_cache() {
  local out
  out=$(with_timeout compose exec -T cache redis-cli -a "${REDIS_PASSWORD:-}" --no-auth-warning ping 2>&1) || true
  if grep -qx 'PONG' <<< "$out"; then
    printf 'redis replies PONG'
    return 0
  fi
  printf 'redis did not reply PONG: %s' "${out:-no output}"
  return 2
}

check_s3() {
  local body
  body=$(container_http_get s3 "http://127.0.0.1:9333/cluster/status")
  if [[ -z $body ]]; then
    body=$(container_http_via_app "http://s3:9333/cluster/status")
  fi
  if [[ -z $body ]]; then
    printf 'SeaweedFS master did not answer on s3:9333/cluster/status'
    return 2
  fi
  if grep -qE '"(IsLeader|Peers|Topology)"' <<< "$body"; then
    printf 'SeaweedFS master answers /cluster/status'
    return 0
  fi
  printf 'SeaweedFS answered with an unexpected payload'
  return 1
}

check_s3_init() {
  local out
  out=$(compose ps -a --format '{{.Service}} {{.State}} {{.ExitCode}}' 2>/dev/null | awk '$1 == "s3-init" {print $2 " " $3}' | head -n 1)
  if [[ -z $out ]]; then
    printf 's3-init container has not run yet (make up creates the bucket)'
    return 3
  fi
  case $out in
    "exited 0") printf 'bucket bootstrap (s3-init) completed with exit code 0'; return 0 ;;
    "running "*) printf 's3-init is still running'; return 1 ;;
    *) printf 's3-init state: %s' "$out"; return 2 ;;
  esac
}

check_onlyoffice() {
  local body
  body=$(with_timeout compose exec -T onlyoffice curl -sf -m "$TIMEOUT" http://127.0.0.1/healthcheck 2>/dev/null) || true
  if [[ $body == true ]]; then
    printf 'ONLYOFFICE /healthcheck -> true'
    return 0
  fi
  if [[ -z $body ]]; then
    printf 'ONLYOFFICE /healthcheck did not answer'
    return 2
  fi
  printf 'ONLYOFFICE /healthcheck -> %s' "$body"
  return 2
}

check_occ() {
  local out installed maintenance
  out=$(with_timeout compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ status --output=json 2>/dev/null) || true
  if [[ -z $out ]]; then
    printf 'occ status failed (app container not ready?)'
    return 2
  fi
  installed=$(grep -o '"installed":[a-z]*' <<< "$out" | head -n 1 | cut -d: -f2)
  maintenance=$(grep -o '"maintenance":[a-z]*' <<< "$out" | head -n 1 | cut -d: -f2)
  if [[ $installed != true ]]; then
    printf 'Nextcloud reports installed=%s' "${installed:-unknown}"
    return 2
  fi
  if [[ $maintenance == true ]]; then
    printf 'Nextcloud is in maintenance mode (upgrade running?)'
    return 1
  fi
  printf 'Nextcloud is installed and out of maintenance mode'
  return 0
}

check_disk() {
  local used_pct free_gb
  used_pct=$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')
  free_gb=$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if (( used_pct >= 90 )); then
    printf 'root filesystem %s%% used (%s GiB free)' "$used_pct" "$free_gb"
    return 2
  fi
  if (( used_pct >= 85 )); then
    printf 'root filesystem %s%% used (%s GiB free)' "$used_pct" "$free_gb"
    return 1
  fi
  printf 'root filesystem %s%% used (%s GiB free)' "$used_pct" "$free_gb"
  return 0
}

check_memory() {
  local total avail pct
  read -r total avail < <(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {printf "%d %d", t, a}' /proc/meminfo)
  pct=$(( avail * 100 / total ))
  if (( pct < 5 )); then
    printf 'only %s%% of RAM available' "$pct"
    return 2
  fi
  if (( pct < 10 )); then
    printf '%s%% of RAM available' "$pct"
    return 1
  fi
  printf '%s%% of RAM available' "$pct"
  return 0
}

check_backup_dir() {
  local dir=${BACKUP_DIR:-./backups}
  [[ $dir == /* ]] || dir="${CLOUDSUITE_ROOT}/${dir#./}"
  if [[ ! -d $dir ]]; then
    printf 'backup directory %s does not exist yet (make bootstrap)' "$dir"
    return 1
  fi
  local free_gb
  free_gb=$(df -Pk "$dir" | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if (( free_gb < 10 )); then
    printf '%s has %s GiB free for backups' "$dir" "$free_gb"
    return 2
  fi
  printf '%s has %s GiB free' "$dir" "$free_gb"
  return 0
}

check_tls_cert() {
  local domain=${CLOUD_DOMAIN:-} end_date
  if [[ -z $domain ]]; then
    printf 'CLOUD_DOMAIN is not set'
    return 2
  fi
  end_date=$(openssl s_client -connect "${domain}:${HTTPS_PORT:-443}" -servername "$domain" </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2 || true)
  if [[ -z $end_date ]]; then
    printf 'cannot read a certificate from %s:%s' "$domain" "${HTTPS_PORT:-443}"
    return 2
  fi
  local end_epoch now_epoch days
  end_epoch=$(date -d "$end_date" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  if (( end_epoch == 0 )); then
    printf 'certificate for %s ends %s' "$domain" "$end_date"
    return 1
  fi
  days=$(( (end_epoch - now_epoch) / 86400 ))
  if (( days < 0 )); then
    printf 'certificate for %s expired %s' "$domain" "$end_date"
    return 2
  fi
  if (( days < 14 )); then
    printf 'certificate for %s expires in %s days (%s)' "$domain" "$days" "$end_date"
    return 1
  fi
  printf 'certificate for %s is valid for %s more days' "$domain" "$days"
  return 0
}

check_nextcloud_public() {
  local domain=${CLOUD_DOMAIN:-} code body
  if [[ -z $domain ]]; then
    printf 'CLOUD_DOMAIN is not set'
    return 2
  fi
  code=$(http_code "https://${domain}/status.php")
  if [[ $code == 200 ]]; then
    printf 'https://%s/status.php -> HTTP 200' "$domain"
    return 0
  fi
  printf 'https://%s/status.php -> HTTP %s' "$domain" "$code"
  return 2
}

print_list() {
  printf 'services\nproxy_api\nproxy_tcp\ntls\nweb\napp\ncron\ndb\ncache\ns3\ns3_init\nonlyoffice\nocc\ndisk\nmemory\nbackup_dir\ntls_cert\nnextcloud_public\n'
}

print_json() {
  local index first=1 status=ok
  if (( FAIL_COUNT > 0 )); then status=failed; elif (( WARN_COUNT > 0 )); then status=degraded; fi
  printf '{\n'
  printf '  "status": "%s",\n' "$status"
  printf '  "generated_at": "%s",\n' "$(timestamp_iso)"
  printf '  "host": "%s",\n' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
  printf '  "summary": {"pass": %d, "warn": %d, "fail": %d, "skip": %d, "total": %d},\n' \
    "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$TOTAL_COUNT"
  printf '  "checks": [\n'
  for (( index=0; index<${#R_IDS[@]}; index++ )); do
    if (( first == 1 )); then first=0; else printf ',\n'; fi
    printf '    {"id": "%s", "label": "%s", "status": "%s", "detail": "%s", "duration_s": %s}' \
      "$(json_escape "${R_IDS[index]}")" \
      "$(json_escape "${R_LABELS[index]}")" \
      "$(json_escape "${R_STATES[index]}")" \
      "$(json_escape "${R_DETAILS[index]}")" \
      "${R_DURATIONS[index]:-0}"
  done
  printf '\n  ]\n}\n'
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --timeout) TIMEOUT=${2:?--timeout needs a value}; shift 2 ;;
      --json) JSON=1; shift ;;
      --strict) STRICT=1; shift ;;
      --external) EXTERNAL=1; shift ;;
      --only) ONLY=${2:?--only needs a value}; shift 2 ;;
      --list) print_list; exit 0 ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  require_cmd curl
  if ! command -v docker >/dev/null 2>&1; then
    die "docker is not available on this host"
  fi
  local env_file=${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env}
  if [[ -f $env_file ]]; then
    CLOUDSUITE_ENV_KEEP_EXISTING=0
    load_env "$env_file"
  fi

  if (( JSON == 0 )); then
    section "Cloud Suite health check on $(hostname 2>/dev/null || echo host)"
  fi

  run_check services       "services"       check_services
  run_check proxy_api      "proxy:api"      check_proxy_api
  run_check proxy_tcp      "proxy:http"     check_proxy_tcp
  run_check tls            "proxy:tls"      check_tls
  run_check web            "web"            check_web
  run_check app            "app"            check_app
  run_check cron           "cron"           check_cron
  run_check db             "db"             check_db
  run_check cache          "cache"          check_cache
  run_check s3             "s3"             check_s3
  run_check s3_init        "s3:bucket"      check_s3_init
  run_check onlyoffice     "onlyoffice"     check_onlyoffice
  run_check occ            "nextcloud"      check_occ
  run_check disk           "disk"           check_disk
  run_check memory         "memory"         check_memory
  run_check backup_dir     "backup:dir"     check_backup_dir
  if (( EXTERNAL == 1 )); then
    run_check tls_cert         "tls:cert"    check_tls_cert
    run_check nextcloud_public "nextcloud:edge" check_nextcloud_public
  fi

  if (( JSON == 1 )); then
    print_json
  else
    section "summary"
    printf 'PASS %d   WARN %d   FAIL %d   SKIP %d   (total %d)\n' \
      "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT" "$SKIP_COUNT" "$TOTAL_COUNT"
    if (( FAIL_COUNT > 0 )); then
      error "health check failed"
    elif (( WARN_COUNT > 0 )); then
      warn "stack is up but degraded"
    else
      ok "stack is healthy"
    fi
  fi

  if (( FAIL_COUNT > 0 )); then return 1; fi
  if (( STRICT == 1 && WARN_COUNT > 0 )); then return 1; fi
  return 0
}

main "$@"
