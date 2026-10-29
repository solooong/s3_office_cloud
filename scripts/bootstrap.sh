#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - bootstrap a fresh checkout on the target VM
#  ---------------------------------------------------------------------------
#  Steps (all idempotent, nothing is destructive):
#    1. verify .env against .env.example (all variables present, secrets set)
#    2. validate domains, S3 credentials and paths
#    3. restore the executable bit on scripts and entrypoint hooks
#    4. create the runtime directories with the right owners and modes
#    5. render the compose configuration (docker compose config -q)
#    6. print the exact next steps (NPM routes, configure, first start)
#
#  SeaweedFS S3 identities and the bucket are created by the s3-init compose
#  service from S3_* variables - this script does not write s3.json.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "bootstrap.sh"

DRY_RUN_FLAG=0
SKIP_PREFLIGHT=0
SKIP_COMPOSE=0
WARN_COUNT=0

SECRET_KEYS="POSTGRES_PASSWORD REDIS_PASSWORD S3_ACCESS_KEY S3_SECRET_KEY ONLYOFFICE_JWT_SECRET NEXTCLOUD_ADMIN_PASSWORD NPM_ADMIN_PASSWORD BACKUP_PASSPHRASE"
REQUIRED_CONFIG_FILES="config/nginx/nginx.conf config/nextcloud/php.ini config/nextcloud/config/zz-10-cloudsuite.config.php config/nextcloud/custom/prune-versions.php config/redis/redis.conf config/rbac/roles.yaml docker-compose.yml"
# Only the log directories that are bind-mounted from the host.
# ./logs/nginx (web) is written by nginx (uid 101) and ./logs/cloudsuite
# (app, cron) by www-data (uid 33).  OnlyOffice and NPM write into named
# volumes, so no host directory is needed for them.
LOG_DIRS="logs logs/nginx logs/cloudsuite"
DATA_DIRS="data backups"

usage() {
  cat <<'USAGE'
bootstrap.sh - prepare this host and .env for the first start

Usage:
  ./scripts/bootstrap.sh [options]

Options:
  -n, --dry-run        show every planned action, change nothing
      --skip-preflight do not run scripts/preflight.sh at the end
      --skip-compose   skip the docker compose config validation
  -h, --help           show this help and exit

What it does:
  * checks that .env has every variable from .env.example and no unknown ones
  * checks that the secrets are non-empty (run generate-secrets.sh first)
  * checks domains and S3 credentials/format
  * restores the executable bit on scripts/*.sh, scripts/lib/*.sh,
    tests/*.sh and the Nextcloud entrypoint hooks
    (a Windows/unzip checkout loses it)
  * creates data/, logs/nginx, logs/cloudsuite, backups/
    (data/ and backups/ 0700; logs/nginx 0750 owned by nginx:101,
     logs/cloudsuite 0750 owned by www-data:33)
  * runs "docker compose config -q" to prove the compose files render

Safe to re-run at any time. Does not start containers and sends no e-mail.
USAGE
}

bump_warn() { WARN_COUNT=$(( WARN_COUNT + 1 )); }

# Keys assigned in an env file, sorted and unique.
env_keys() {
  sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p' "$1" | sort -u
}

check_env_contract() {
  local example=${CLOUDSUITE_ROOT}/.env.example
  local env_file=${CLOUDSUITE_ENV_FILE}
  if [[ ! -f $example ]]; then
    warn "no .env.example in ${CLOUDSUITE_ROOT} - cannot verify the variable contract"
    bump_warn
    return 0
  fi
  local missing extra
  missing=$(comm -23 <(env_keys "$example") <(env_keys "$env_file") || true)
  extra=$(comm -13 <(env_keys "$example") <(env_keys "$env_file") || true)
  if [[ -n $missing ]]; then
    error "${env_file} is missing variables that .env.example defines:"
    printf '%s\n' "$missing" | sed 's/^/        - /' >&2
    hint "merge them from .env.example (keep your existing values), then re-run"
    exit 1
  fi
  local key_count
  key_count=$(env_keys "$example" | wc -l | tr -d ' ')
  ok "${env_file} defines every variable of .env.example (${key_count} keys)"
  if [[ -n $extra ]]; then
    warn "${env_file} has extra variables that are not in .env.example (ignored by compose):"
    printf '%s\n' "$extra" | sed 's/^/        - /' >&2
    bump_warn
  fi
}

check_secrets() {
  local key empty=() count=0
  for key in $SECRET_KEYS; do
    count=$(( count + 1 ))
    if [[ ${!key:-} == "" ]]; then empty+=("$key"); fi
  done
  if (( ${#empty[@]} > 0 )); then
    warn "empty secrets: ${empty[*]}"
    hint "run: ./scripts/generate-secrets.sh"
    bump_warn
  else
    ok "all ${count} secrets are set"
  fi
}

check_domains() {
  local domain pattern='^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'
  for domain in ${CLOUD_DOMAIN:-} ${OFFICE_DOMAIN:-}; do
    if [[ -z $domain ]]; then
      die "CLOUD_DOMAIN and OFFICE_DOMAIN must be set in ${CLOUDSUITE_ENV_FILE}"
    fi
    if [[ ! $domain =~ $pattern ]]; then
      die "'${domain}' is not a valid lower-case FQDN"
    fi
  done
  if [[ $CLOUD_DOMAIN == "$OFFICE_DOMAIN" ]]; then
    die "CLOUD_DOMAIN and OFFICE_DOMAIN must differ (Nextcloud and ONLYOFFICE need separate hostnames)"
  fi
  ok "domains: ${CLOUD_DOMAIN} (Nextcloud), ${OFFICE_DOMAIN} (ONLYOFFICE)"
  local warning_domain="example.com"
  if [[ $CLOUD_DOMAIN == *"$warning_domain" || $OFFICE_DOMAIN == *"$warning_domain" ]]; then
    warn "domains still use the documentation suffix 'example.com' - replace them with real DNS names before the first start"
    bump_warn
  fi
  if [[ ${ACME_EMAIL:-} == "" ]]; then
    warn "ACME_EMAIL is empty - Let's Encrypt issuance in NPM needs a real address"
    bump_warn
  fi
}

check_s3_credentials() {
  env_require S3_BUCKET S3_ACCESS_KEY S3_SECRET_KEY
  local weak=0
  if (( ${#S3_ACCESS_KEY} < 16 )); then
    warn "S3_ACCESS_KEY is shorter than 16 characters - regenerate it (./scripts/generate-secrets.sh --force)"
    weak=1
  fi
  if (( ${#S3_SECRET_KEY} < 32 )); then
    warn "S3_SECRET_KEY is shorter than 32 characters - regenerate it (./scripts/generate-secrets.sh --force)"
    weak=1
  fi
  if [[ $S3_ACCESS_KEY =~ [[:space:]/] ]]; then
    die "S3_ACCESS_KEY must not contain spaces or slashes (it is passed to the s3-init service)"
  fi
  if [[ $S3_SECRET_KEY =~ [[:space:]] ]]; then
    die "S3_SECRET_KEY must not contain whitespace (it is passed to the s3-init service)"
  fi
  case $S3_ACCESS_KEY in
    minioadmin|admin|test|accesskey) warn "S3_ACCESS_KEY is a well-known default value"; weak=1 ;;
  esac
  if [[ $S3_BUCKET =~ [[:space:]/] ]]; then
    die "S3_BUCKET must be a DNS compatible bucket name without spaces or slashes"
  fi
  if (( weak == 0 )); then
    ok "S3 identity ${S3_ACCESS_KEY} (bucket: ${S3_BUCKET}, path-style: ${S3_USE_PATH_STYLE:-true})"
  fi
}

check_config_files() {
  local file missing=()
  for file in $REQUIRED_CONFIG_FILES; do
    [[ -f "${CLOUDSUITE_ROOT}/${file}" ]] || missing+=("$file")
  done
  if (( ${#missing[@]} > 0 )); then
    error "required repository files are missing:"
    printf '%s\n' "${missing[@]}" | sed 's/^/        - /' >&2
    exit 1
  fi
  ok "repository layout is complete (compose files + config/ present)"
}

ensure_permissions() {
  local env_file=${CLOUDSUITE_ENV_FILE} perm
  perm=$(stat -c '%a' "$env_file" 2>/dev/null || echo unknown)
  if [[ $perm != 600 ]]; then
    if is_dry_run; then
      log "[dry-run] chmod 600 ${env_file}"
    else
      chmod 600 "$env_file"
      warn "${env_file} had mode ${perm} - changed to 600 (it contains secrets)"
      bump_warn
    fi
  fi
}

resolve_backup_dir() {
  local dir=${BACKUP_DIR:-./backups}
  if [[ $dir == /* ]]; then printf '%s' "$dir"; else printf '%s/%s' "${CLOUDSUITE_ROOT}" "${dir#./}"; fi
}

normalise_line_endings() {
  local env_file=${CLOUDSUITE_ENV_FILE}
  if grep -q $'\r' "$env_file" 2>/dev/null; then
    if is_dry_run; then
      log "[dry-run] would convert CRLF line endings in ${env_file}"
      return 0
    fi
    warn "${env_file} contains CRLF line endings - converting to LF (values would otherwise keep a trailing carriage return)"
    local tmp
    tmp=$(mktemp)
    tr -d '\r' < "$env_file" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$env_file"
    bump_warn
  fi
}

# A checkout made on Windows, or an archive unpacked there, does not keep
# POSIX permission bits: every script ends up 0644 and "./scripts/*.sh" or
# "make test" fails with "Permission denied" once the directory is copied to
# the server without git.  Restore the bits idempotently; on Linux this is a
# no-op (the git index stores 100755 and a Linux checkout already has it).
ensure_exec_bits() {
  local target rel fixed=0 checked=0
  local -a candidates=()
  shopt -s nullglob
  candidates=(
    "${CLOUDSUITE_ROOT}"/scripts/*.sh
    "${CLOUDSUITE_ROOT}"/scripts/lib/*.sh
    "${CLOUDSUITE_ROOT}"/tests/*.sh
    "${CLOUDSUITE_ROOT}"/config/nextcloud/hooks/before-starting/*.sh
  )
  shopt -u nullglob
  for target in "${candidates[@]}"; do
    [[ -f $target ]] || continue
    checked=$(( checked + 1 ))
    rel=${target#"${CLOUDSUITE_ROOT}"/}
    if [[ -x $target ]]; then
      debug "already executable: ${rel}"
      continue
    fi
    if is_dry_run; then
      log "[dry-run] chmod +x ${rel}"
      fixed=$(( fixed + 1 ))
      continue
    fi
    if ! chmod +x "$target" 2>/dev/null; then
      warn "cannot set the exec bit on ${rel} - this filesystem does not store POSIX modes; copy the tree with git (mode 100755) or run 'bash ${rel}'"
      bump_warn
      continue
    fi
    debug "chmod +x ${rel}"
    fixed=$(( fixed + 1 ))
  done
  if (( fixed > 0 )); then
    if is_dry_run; then
      log "script exec bits ensured (${fixed} of ${checked} file(s) would be fixed)"
    else
      ok "script exec bits ensured (${fixed} of ${checked} file(s) fixed)"
    fi
  else
    ok "script exec bits ensured (all ${checked} file(s) are executable)"
  fi
}

create_directories() {
  local dir abs backup_dir
  backup_dir=$(resolve_backup_dir)
  for dir in $LOG_DIRS; do
    abs="${CLOUDSUITE_ROOT}/${dir}"
    if [[ -d $abs ]]; then
      debug "exists: ${dir}"
    elif is_dry_run; then
      log "[dry-run] mkdir -p ${dir}"
    else
      mkdir -p "$abs"
      log "created ${dir}"
    fi
  done
  for dir in $DATA_DIRS; do
    abs="${CLOUDSUITE_ROOT}/${dir}"
    if [[ -d $abs ]]; then
      debug "exists: ${dir}"
    elif is_dry_run; then
      log "[dry-run] mkdir -p -m 700 ${dir}"
    else
      mkdir -p "$abs"
      chmod 700 "$abs"
      log "created ${dir} (mode 700)"
    fi
  done
  if [[ ! -d $backup_dir ]]; then
    if is_dry_run; then
      log "[dry-run] mkdir -p -m 700 ${backup_dir}"
    else
      mkdir -p "$backup_dir"
      chmod 700 "$backup_dir"
      log "created ${backup_dir} (mode 700)"
    fi
  fi

  # Bind-mounted log directories must be writable by the container user:
  #   logs/nginx      -> nginx runs as uid/gid 101
  #   logs/cloudsuite -> www-data (33) writes nextcloud.log and audit.log
  local spec dir uid gid abs owner
  for spec in "logs/nginx 101 101 nginx" "logs/cloudsuite 33 33 www-data"; do
    read -r dir uid gid <<< "${spec%% *} ${spec#* }"
    abs="${CLOUDSUITE_ROOT}/${dir}"
    if is_dry_run; then
      log "[dry-run] chown -R ${uid}:${gid} ${dir} && chmod 750 ${dir}"
      continue
    fi
    if is_root; then
      chown -R "${uid}:${gid}" "$abs" 2>/dev/null || warn "chown ${uid}:${gid} ${dir} failed"
      chmod 750 "$abs" 2>/dev/null || warn "chmod 750 ${dir} failed"
      ok "${dir} is owned by ${uid}:${gid} (${spec##* }), mode 750"
    else
      owner=$(stat -c '%u:%g' "$abs" 2>/dev/null || echo unknown)
      chmod 750 "$abs" 2>/dev/null || warn "cannot chmod ${abs} (not root)"
      if [[ $owner == "${uid}:${gid}" ]]; then
        ok "${dir} owned by ${uid}:${gid} (${spec##* }), mode 750"
      else
        warn "${dir} is owned by ${owner}, needs ${uid}:${gid} - run: sudo chown -R ${uid}:${gid} ${abs}"
        bump_warn
      fi
    fi
  done
}

validate_compose() {
  if (( SKIP_COMPOSE == 1 )); then
    warn "compose validation skipped (--skip-compose)"
    bump_warn
    return 0
  fi
  require_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    die "the docker compose plugin is not available (apt install docker-compose-plugin)"
  fi
  local base_files="docker-compose.yml" file
  if compose config -q; then
    ok "docker compose config renders: ${base_files}"
  else
    die "docker compose config failed - fix the compose files or ${CLOUDSUITE_ENV_FILE} first"
  fi
  for file in docker-compose.admin.yml docker-compose.observability.yml; do
    if [[ ! -f "${CLOUDSUITE_ROOT}/${file}" ]]; then
      warn "optional overlay not found: ${file}"
      bump_warn
      continue
    fi
    if CLOUDSUITE_COMPOSE_FILES="${base_files} ${file}" compose config -q; then
      ok "overlay renders: ${file}"
    else
      die "docker compose config failed for ${base_files} + ${file}"
    fi
  done
  if ! docker info >/dev/null 2>&1; then
    warn "the docker daemon is not reachable from this shell - start it before 'make up'"
    bump_warn
  fi
}

run_preflight() {
  if (( SKIP_PREFLIGHT == 1 )); then
    warn "preflight skipped (--skip-preflight)"
    return 0
  fi
  if [[ ! -x "${SCRIPT_DIR}/preflight.sh" ]]; then
    warn "scripts/preflight.sh is not executable - skipping"
    bump_warn
    return 0
  fi
  section "preflight"
  if "${SCRIPT_DIR}/preflight.sh" --skip-dns; then
    ok "preflight passed"
  else
    warn "preflight reported failures - review the output above before 'make up'"
    bump_warn
  fi
}

next_steps() {
  section "next steps"
  cat <<EOF
1. install the logrotate policy (once, as root):
     sudo sed 's#/opt/cloudsuite#'"${CLOUDSUITE_ROOT}"'#' config/logrotate/cloudsuite \\
       | sudo tee /etc/logrotate.d/cloudsuite >/dev/null
     sudo logrotate -d /etc/logrotate.d/cloudsuite

2. start the stack (first start initialises Nextcloud + ONLYOFFICE):
     make up
     make status

3. configure the proxy routes in the NPM GUI (127.0.0.1:8181, see docs/02-deployment.md):
     ${CLOUD_DOMAIN}    ->  http://web:8080        (websocket, 10G body, SSL+HSTS)
     ${OFFICE_DOMAIN}   ->  http://onlyoffice:80   (websocket, 3600s timeouts, SSL+HSTS)

4. provision Nextcloud (idempotent, safe to re-run):
     make configure
     make rbac

5. schedule operations on the host (see docs/07-backup-restore-dr.md):
     backup     nightly:  make backup (uses flock, keeps ${BACKUP_RETENTION_DAYS:-30} days)
     versions   hourly :  make prune-versions
     audit      daily  :  make audit-report

6. verify end to end:
     make healthcheck
     make smoke
EOF
}

main() {
  while (( $# > 0 )); do
    case $1 in
      -n|--dry-run) set_dry_run; DRY_RUN_FLAG=1; shift ;;
      --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
      --skip-compose) SKIP_COMPOSE=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  if (( DRY_RUN_FLAG == 1 )); then
    section "bootstrap (dry-run) in ${CLOUDSUITE_ROOT}"
  else
    section "bootstrap in ${CLOUDSUITE_ROOT}"
  fi

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  ok "environment loaded from ${CLOUDSUITE_ENV_FILE}"

  normalise_line_endings
  ensure_exec_bits
  ensure_permissions
  check_env_contract
  check_secrets
  check_domains
  check_s3_credentials
  check_config_files
  create_directories
  validate_compose
  run_preflight

  section "summary"
  if (( WARN_COUNT > 0 )); then
    warn "${WARN_COUNT} warning(s) - review them before 'make up'"
  else
    ok "bootstrap completed without warnings"
  fi
  if is_dry_run; then
    warn "dry-run: no change was applied"
  fi
  next_steps
}

main "$@"
