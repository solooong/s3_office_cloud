#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - host preflight / doctor
#  ---------------------------------------------------------------------------
#  Read-only verification of everything the single-VM deployment depends on:
#  operating system, docker engine + compose plugin, CPU/RAM/disk/inodes,
#  free ports 80/443, DNS A records for CLOUD_DOMAIN/OFFICE_DOMAIN,
#  OnlyOffice kernel tuning (vm.max_map_count), inotify limits, clock sync,
#  SELinux, required host tools and the .env file itself.
#
#  Exit code: 0 when nothing FAILed, 1 when at least one check FAILed.
#  --strict turns WARN into failure (use it in acceptance tests).
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "preflight.sh"

MIN_CPU=4
MIN_RAM_MB=8192
MIN_DISK_GB=50
MIN_INODES_FREE_PCT=10
PUBLIC_IP=""
SKIP_DNS=0
SKIP_PORTS=0
STRICT=0
JSON=0
FIX_SYSCTL=0

CHECK_IDS=()
CHECK_LABELS=()
CHECK_STATES=()
CHECK_DETAILS=()
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

usage() {
  cat <<'USAGE'
preflight.sh - verify that this VM can run the Cloud Suite stack

Usage:
  ./scripts/preflight.sh [options]

Options:
  --min-cpu N          minimum CPU cores (default: 4)
  --min-ram-mb N       minimum RAM in MiB (default: 8192)
  --min-disk-gb N      minimum free disk on / and BACKUP_DIR (default: 50)
  --public-ip IP       expected public IPv4 for the DNS A-record check
  --skip-dns           skip the DNS checks
  --skip-ports         skip the port checks
  --fix-sysctl         apply the required sysctl values (needs root)
  --strict             treat warnings as failures
  --json               machine readable report on stdout
  -h, --help           show this help and exit

Checks:
  os, kernel, docker engine, compose plugin, cpu, ram, disk, inodes,
  ports HTTP_PORT/HTTPS_PORT/NPM_ADMIN_PORT, DNS for both domains,
  vm.max_map_count (OnlyOffice), inotify watches/instances, NTP sync,
  SELinux/AppArmor, required host tools, logrotate, swap, .env permissions,
  reachability of apps.nextcloud.com (the ONLYOFFICE connector is installed
  from the App Store on first run)

Exit code: 0 = no failures, 1 = at least one failure.
USAGE
}

record() {
  local id=$1 label=$2 state=$3 detail=$4
  CHECK_IDS+=("$id")
  CHECK_LABELS+=("$label")
  CHECK_STATES+=("$state")
  CHECK_DETAILS+=("$detail")
  case $state in
    PASS) PASS_COUNT=$(( PASS_COUNT + 1 )) ;;
    WARN) WARN_COUNT=$(( WARN_COUNT + 1 )) ;;
    FAIL) FAIL_COUNT=$(( FAIL_COUNT + 1 )) ;;
  esac
  if (( JSON == 0 )); then
    case $state in
      PASS) printf '%sPASS%s  %-22s %s\n' "${C_GREEN}" "${C_RESET}" "$label" "$detail" ;;
      WARN) printf '%sWARN%s  %-22s %s\n' "${C_YELLOW}" "${C_RESET}" "$label" "$detail" ;;
      FAIL) printf '%sFAIL%s  %-22s %s\n' "${C_RED}" "${C_RESET}" "$label" "$detail" ;;
    esac
  fi
}

check_cmd() { command -v "$1" >/dev/null 2>&1; }

# --- individual checks -------------------------------------------------------
# The ONLYOFFICE connector is not bundled with the Nextcloud release tarball:
# configure-nextcloud.sh installs it from the App Store, so the host needs
# outbound HTTPS to apps.nextcloud.com before the first run.
check_appstore() {
  if (( SKIP_DNS == 1 )); then
    record appstore "Nextcloud App Store" WARN "skipped (--skip-dns)"
    return 0
  fi
  if ! check_cmd curl; then
    record appstore "Nextcloud App Store" WARN "curl is not installed - cannot verify access to apps.nextcloud.com"
    return 0
  fi
  local url=https://apps.nextcloud.com/ code
  # The command sits in an "if" on purpose: a failing curl must not trigger
  # the ERR trap, it is an expected outcome that we report as FAIL.
  if code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null) && [[ $code == 200 ]]; then
    record appstore "Nextcloud App Store" PASS "apps.nextcloud.com reachable (HTTP ${code})"
  else
    record appstore "Nextcloud App Store" FAIL "cannot reach ${url} (HTTP ${code:-none}) - the onlyoffice app cannot be installed; allow outbound HTTPS to apps.nextcloud.com or install the app manually"
  fi
}
check_os() {
  local id=/etc/os-release distro="" version="" kernel
  kernel=$(uname -r 2>/dev/null || echo unknown)
  if [[ ! -f $id ]]; then
    record os "operating system" WARN "no /etc/os-release (kernel ${kernel}); supported: Ubuntu 24.04 LTS / Debian 12"
    return 0
  fi
  # shellcheck disable=SC1090,SC1091 # /etc/os-release is provided by the host
  . "$id"
  distro=${ID:-unknown}
  version=${VERSION_ID:-unknown}
  case "$distro" in
    ubuntu)
      if [[ ${version%%.*} -ge 24 ]]; then
        record os "operating system" PASS "Ubuntu ${version} (kernel ${kernel})"
      else
        record os "operating system" WARN "Ubuntu ${version} is older than the supported 24.04 LTS"
      fi
      ;;
    debian)
      if [[ ${version%%.*} -ge 12 ]]; then
        record os "operating system" PASS "Debian ${version} (kernel ${kernel})"
      else
        record os "operating system" WARN "Debian ${version} is older than the supported 12 (bookworm)"
      fi
      ;;
    *)
      record os "operating system" WARN "${distro} ${version} - supported: Ubuntu 24.04 LTS / Debian 12 (kernel ${kernel})"
      ;;
  esac
}

check_docker() {
  local server_version client_version
  if ! check_cmd docker; then
    record docker "docker engine" FAIL "docker CLI not found - install Docker Engine 27+ (see docs/02-deployment.md)"
    return 0
  fi
  client_version=$(docker version --format '{{.Client.Version}}' 2>/dev/null || echo unknown)
  if ! server_version=$(docker version --format '{{.Server.Version}}' 2>/dev/null); then
    record docker "docker engine" FAIL "cannot talk to the docker daemon (is it running? are you in the docker group?)"
    return 0
  fi
  if [[ $server_version =~ ^([0-9]+)\. ]]; then
    if (( BASH_REMATCH[1] >= 27 )); then
      record docker "docker engine" PASS "server ${server_version}, client ${client_version}"
    else
      record docker "docker engine" WARN "server ${server_version} is older than the tested 27+ (client ${client_version})"
    fi
  else
    record docker "docker engine" WARN "unrecognised docker server version '${server_version}'"
  fi
  local driver
  driver=$(docker info --format '{{.Driver}}' 2>/dev/null || echo unknown)
  if [[ $driver == overlay2 || $driver == unknown ]]; then
    record storage_driver "docker storage driver" PASS "${driver}"
  else
    record storage_driver "docker storage driver" WARN "${driver} (overlay2 recommended)"
  fi
}

check_compose() {
  if ! check_cmd docker; then
    record compose "compose plugin" FAIL "docker CLI missing, cannot check the compose plugin"
    return 0
  fi
  if ! docker compose version >/dev/null 2>&1; then
    record compose "compose plugin" FAIL "docker compose plugin is not installed (apt install docker-compose-plugin)"
    return 0
  fi
  local version
  version=$(docker compose version --short 2>/dev/null || echo unknown)
  if [[ $version =~ ^([0-9]+)\. ]]; then
    if (( BASH_REMATCH[1] >= 2 )); then
      record compose "compose plugin" PASS "docker compose ${version}"
    else
      record compose "compose plugin" FAIL "docker compose ${version} is too old (need v2.24+ for --env-file/--images)"
    fi
  else
    record compose "compose plugin" WARN "could not parse compose version '${version}'"
  fi
}

check_resources() {
  local cpus ram_mb disk_gb inodes_pct swap_mb
  cpus=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
  if (( cpus >= MIN_CPU )); then
    record cpu "cpu cores" PASS "${cpus} (minimum ${MIN_CPU})"
  else
    record cpu "cpu cores" FAIL "${cpus} < ${MIN_CPU} required by the contract"
  fi

  ram_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  if (( ram_mb >= MIN_RAM_MB )); then
    record ram "ram" PASS "${ram_mb} MiB (minimum ${MIN_RAM_MB} MiB)"
  else
    record ram "ram" FAIL "${ram_mb} MiB < ${MIN_RAM_MB} MiB - OnlyOffice plus Nextcloud need headroom"
  fi

  disk_gb=$(df -Pk / | awk 'NR==2 {printf "%d", $4/1024/1024}')
  if (( disk_gb >= MIN_DISK_GB )); then
    record disk "free disk (/)" PASS "${disk_gb} GiB (minimum ${MIN_DISK_GB} GiB)"
  else
    record disk "free disk (/)" FAIL "${disk_gb} GiB < ${MIN_DISK_GB} GiB"
  fi

  inodes_pct=$(df -Pi / | awk 'NR==2 {gsub("%","",$5); print $5}')
  if (( 100 - inodes_pct >= MIN_INODES_FREE_PCT )); then
    record inodes "inodes (/)" PASS "${inodes_pct}% used"
  else
    record inodes "inodes (/)" FAIL "${inodes_pct}% used - too few inodes left (Nextcloud creates many small files)"
  fi

  swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
  if (( swap_mb > 0 )); then
    record swap "swap" PASS "${swap_mb} MiB"
  elif (( ram_mb < 16384 )); then
    record swap "swap" WARN "no swap on a ${ram_mb} MiB host - add a 4 GiB swapfile for update windows"
  else
    record swap "swap" PASS "no swap (${ram_mb} MiB RAM is enough)"
  fi
}

port_listening() {
  local port=$1
  if check_cmd ss; then
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
  elif check_cmd netstat; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}$"
  else
    return 1
  fi
}

check_ports() {
  if (( SKIP_PORTS == 1 )); then
    record ports "ports" WARN "skipped (--skip-ports)"
    return 0
  fi
  local spec port label owner
  for spec in "${HTTP_PORT:-80}:http" "${HTTPS_PORT:-443}:https" "${NPM_ADMIN_PORT:-8181}:npm-admin"; do
    port=${spec%%:*}
    label=${spec##*:}
    if ! port_listening "$port"; then
      record "port_${port}" "port ${port} (${label})" PASS "free"
      continue
    fi
    owner=$(docker ps --filter "publish=${port}" --format '{{.Label "com.docker.compose.project"}}' 2>/dev/null | head -n 1 || true)
    if [[ -n $owner && $owner == "${COMPOSE_PROJECT_NAME:-cloudsuite}" ]]; then
      record "port_${port}" "port ${port} (${label})" PASS "in use by this stack (expected while running)"
    else
      record "port_${port}" "port ${port} (${label})" FAIL "already in use by another process${owner:+ (project: ${owner})} - stop it or change the port in .env"
    fi
  done
}

resolve_ipv4() {
  local name=$1
  if check_cmd getent; then
    getent ahostsv4 "$name" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if check_cmd dig; then
    dig +short A "$name" 2>/dev/null | grep -E '^[0-9.]+$' | sort -u
    return 0
  fi
  if check_cmd host; then
    host -t A "$name" 2>/dev/null | awk '/has address/ {print $NF}' | sort -u
    return 0
  fi
  return 1
}

check_dns() {
  if (( SKIP_DNS == 1 )); then
    record dns "dns records" WARN "skipped (--skip-dns)"
    return 0
  fi
  local domain ips count
  for domain in "${CLOUD_DOMAIN:-}" "${OFFICE_DOMAIN:-}"; do
    if [[ -z $domain ]]; then
      record dns "dns records" FAIL "CLOUD_DOMAIN/OFFICE_DOMAIN are not set - run scripts/bootstrap.sh first"
      return 0
    fi
    if ! ips=$(resolve_ipv4 "$domain"); then
      record "dns_${domain}" "dns ${domain}" FAIL "no resolver available (install dnsutils or bind-utils)"
      continue
    fi
    count=$(printf '%s\n' "$ips" | grep -c . || true)
    if (( count == 0 )); then
      record "dns_${domain}" "dns ${domain}" FAIL "no A record - create it in your DNS zone before the first start"
      continue
    fi
    if [[ -n $PUBLIC_IP ]]; then
      if printf '%s\n' "$ips" | grep -qx "$PUBLIC_IP"; then
        record "dns_${domain}" "dns ${domain}" PASS "A -> ${PUBLIC_IP}"
      else
        record "dns_${domain}" "dns ${domain}" FAIL "A records (${ips}) do not include the expected public IP ${PUBLIC_IP}"
      fi
      continue
    fi
    if printf '%s\n' "$ips" | grep -qE '^(10\.|127\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)'; then
      record "dns_${domain}" "dns ${domain}" WARN "resolves to private address(es) ${ips} - fine for a lab, not for public TLS issuance"
    else
      record "dns_${domain}" "dns ${domain}" PASS "A -> ${ips}"
    fi
  done
}

check_kernel_tuning() {
  local current required=262144 watches instances
  if ! check_cmd sysctl; then
    record max_map_count "vm.max_map_count" WARN "sysctl not available - set vm.max_map_count=${required} manually"
    return 0
  fi
  current=$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)
  if (( current >= required )); then
    record max_map_count "vm.max_map_count" PASS "${current} (>= ${required})"
  else
    record max_map_count "vm.max_map_count" FAIL "${current} < ${required} required by ONLYOFFICE Docs - run: sudo ./scripts/preflight.sh --fix-sysctl"
  fi

  watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
  if (( watches >= 65536 )); then
    record inotify_watches "inotify watches" PASS "${watches}"
  else
    record inotify_watches "inotify watches" FAIL "${watches} < 65536 - Nextcloud/docker will run out of watches"
  fi
  instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
  if (( instances >= 128 )); then
    record inotify_instances "inotify instances" PASS "${instances}"
  else
    record inotify_instances "inotify instances" FAIL "${instances} < 128 - raise fs.inotify.max_user_instances"
  fi
}

check_time_sync() {
  local synced="" ntp=""
  if check_cmd timedatectl; then
    synced=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    ntp=$(timedatectl show -p NTP --value 2>/dev/null || true)
  fi
  if [[ $synced == yes ]]; then
    record clock "clock sync" PASS "systemd-timesyncd reports NTPSynchronized=yes (NTP=${ntp:-unknown})"
    return 0
  fi
  if check_cmd chronyc && chronyc tracking >/dev/null 2>&1; then
    record clock "clock sync" PASS "chrony is tracking a source"
    return 0
  fi
  if [[ -z $synced ]]; then
    record clock "clock sync" WARN "cannot determine the NTP state (no timedatectl/chronyc) - audit timestamps and TLS depend on it"
  else
    record clock "clock sync" WARN "clock is not NTP synchronised (NTPSynchronized=${synced}) - run: timedatectl set-ntp true"
  fi
}

check_security_modules() {
  if check_cmd getenforce; then
    local mode
    mode=$(getenforce 2>/dev/null || echo unknown)
    case $mode in
      Enforcing)
        record selinux "selinux" WARN "Enforcing - the stack uses plain bind mounts; add :z labels or a permissive policy for ./config, ./logs, ./data"
        ;;
      *) record selinux "selinux" PASS "${mode}" ;;
    esac
  else
    record selinux "selinux" PASS "not installed (AppArmor is the default on Ubuntu)"
  fi
  if [[ -f /sys/module/apparmor/parameters/enabled ]]; then
    record apparmor "apparmor" PASS "kernel support enabled"
  else
    record apparmor "apparmor" WARN "apparmor kernel support not detected"
  fi
}

check_tools() {
  local missing=() tool
  for tool in openssl curl tar; do
    check_cmd "$tool" || missing+=("$tool")
  done
  if (( ${#missing[@]} == 0 )); then
    record tools "host tools" PASS "openssl curl tar"
  else
    record tools "host tools" FAIL "missing: ${missing[*]} (apt install ${missing[*]})"
  fi
  if check_cmd rclone; then
    record rclone "rclone (migration/offsite)" PASS "$(rclone version 2>/dev/null | head -n 1)"
  else
    record rclone "rclone (migration/offsite)" WARN "not installed - needed by migrate-yandex-disk.sh and BACKUP_OFFSITE_REMOTE"
  fi
  if check_cmd logrotate; then
    record logrotate "logrotate" PASS "$(logrotate --version 2>&1 | head -n 1)"
  else
    record logrotate "logrotate" WARN "not installed - config/logrotate/cloudsuite will not be applied"
  fi
}

check_env_file() {
  local env_file=${CLOUDSUITE_ENV_FILE:-${CLOUDSUITE_ROOT}/.env}
  if [[ ! -f $env_file ]]; then
    record env_file "environment file" FAIL "${env_file} missing - cp .env.example .env && ./scripts/generate-secrets.sh"
    return 0
  fi
  local perm
  perm=$(stat -c '%a' "$env_file" 2>/dev/null || echo unknown)
  if [[ $perm == 600 ]]; then
    record env_file "environment file" PASS "${env_file} mode 600"
  else
    record env_file "environment file" FAIL "${env_file} mode ${perm} - must be 600: chmod 600 ${env_file}"
  fi
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "$env_file"
  local key
  local missing=()
  local required_keys="POSTGRES_PASSWORD REDIS_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY ONLYOFFICE_JWT_SECRET NEXTCLOUD_ADMIN_PASSWORD NPM_ADMIN_PASSWORD BACKUP_PASSPHRASE CLOUD_DOMAIN OFFICE_DOMAIN ACME_EMAIL"
  for key in $required_keys; do
    if [[ ${!key:-} == "" ]]; then missing+=("$key"); fi
  done
  if (( ${#missing[@]} == 0 )); then
    record env_secrets "env secrets" PASS "all required secrets and domains are set"
  else
    record env_secrets "env secrets" FAIL "empty values: ${missing[*]} - run ./scripts/generate-secrets.sh and edit the domains"
  fi
}

apply_sysctl_fixes() {
  require_root
  local conf=/etc/sysctl.d/99-cloudsuite.conf
  info "writing ${conf}"
  {
    printf '# Cloud Suite - kernel tuning required by ONLYOFFICE Docs and Nextcloud\n'
    printf 'vm.max_map_count = 262144\n'
    printf 'fs.inotify.max_user_watches = 524288\n'
    printf 'fs.inotify.max_user_instances = 1024\n'
  } > "$conf"
  sysctl --system >/dev/null
  ok "sysctl values applied and persisted in ${conf}"
}

print_json() {
  local index first=1
  printf '{\n'
  printf '  "generated_at": "%s",\n' "$(timestamp_iso)"
  printf '  "host": "%s",\n' "$(json_escape "$(hostname 2>/dev/null || echo unknown)")"
  printf '  "summary": {"pass": %d, "warn": %d, "fail": %d},\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
  printf '  "checks": [\n'
  for (( index=0; index<${#CHECK_IDS[@]}; index++ )); do
    if (( first == 1 )); then first=0; else printf ',\n'; fi
    printf '    {"id": "%s", "label": "%s", "status": "%s", "detail": "%s"}' \
      "$(json_escape "${CHECK_IDS[index]}")" \
      "$(json_escape "${CHECK_LABELS[index]}")" \
      "$(json_escape "${CHECK_STATES[index]}")" \
      "$(json_escape "${CHECK_DETAILS[index]}")"
  done
  printf '\n  ]\n}\n'
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --min-cpu) MIN_CPU=${2:?--min-cpu needs a value}; shift 2 ;;
      --min-ram-mb) MIN_RAM_MB=${2:?--min-ram-mb needs a value}; shift 2 ;;
      --min-disk-gb) MIN_DISK_GB=${2:?--min-disk-gb needs a value}; shift 2 ;;
      --public-ip) PUBLIC_IP=${2:?--public-ip needs a value}; shift 2 ;;
      --skip-dns) SKIP_DNS=1; shift ;;
      --skip-ports) SKIP_PORTS=1; shift ;;
      --fix-sysctl) FIX_SYSCTL=1; shift ;;
      --strict) STRICT=1; shift ;;
      --json) JSON=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  if (( JSON == 0 )); then
    section "Cloud Suite preflight on $(hostname 2>/dev/null || echo host)"
  fi

  if [[ $(host_os) != linux ]]; then
    if (( JSON == 0 )); then
      warn "this host is not Linux ($(host_os)) - only limited checks are meaningful here"
    fi
    check_env_file
  else
    check_os
    check_docker
    check_compose
    check_resources
    check_ports
    check_dns
    check_appstore
    check_kernel_tuning
    check_time_sync
    check_security_modules
    check_tools
    check_env_file
  fi

  if (( FIX_SYSCTL == 1 )); then
    apply_sysctl_fixes
  fi

  if (( JSON == 1 )); then
    print_json
  else
    section "summary"
    printf 'PASS %d   WARN %d   FAIL %d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    if (( FAIL_COUNT > 0 )); then
      error "preflight failed - fix the items above before 'make up'"
    elif (( WARN_COUNT > 0 && STRICT == 1 )); then
      error "strict mode: warnings are treated as failures"
    else
      ok "host is ready for the Cloud Suite stack"
    fi
  fi

  # Exit (not return) so the ERR trap does not report this expected failure.
  if (( FAIL_COUNT > 0 )); then exit 1; fi
  if (( STRICT == 1 && WARN_COUNT > 0 )); then exit 1; fi
  return 0
}

main "$@"
