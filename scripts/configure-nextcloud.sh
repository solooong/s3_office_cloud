#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - idempotent Nextcloud provisioning (occ)
#  ---------------------------------------------------------------------------
#  Everything below is safe to re-run: occ config:system:set / config:app:set
#  overwrite the same value, app install/enable is guarded, group handling is
#  checked before it changes anything.
#
#  Two classes of settings are handled deliberately differently:
#    * APPLIED  - owned by this script and written through occ:
#                 trusted proxies/domains, mail, memcache/redis, share policy,
#                 password policy, onlyoffice app config, app enablement,
#                 default quota, background jobs mode.
#    * VERIFIED - owned by config/nextcloud/config/zz-10-cloudsuite.config.php
#                 (log targets, audit log, retention, previews, phone region,
#                 maintenance window, skeleton, bruteforce protection).
#                 Writing them with occ as well would create two sources of
#                 truth that silently override each other, so this script only
#                 checks the effective value and fails loudly on drift.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "configure-nextcloud.sh"

APPLIED=0
VERIFIED=0
FAILED=0
SKIPPED=0
DRY_RUN_FLAG=0

ENFORCE_2FA=0
SKIP_APPS=0
SKIP_MAIL=0
SKIP_SHARE=0
SKIP_CACHE=0

APP_REQUIRED=(admin_audit onlyoffice twofactor_totp password_policy)
# federatedfilesharing is a core app: Nextcloud 35 refuses to disable it
# ("federatedfilesharing can't be disabled"), so remote shares are blocked at
# the sharing layer instead - see configure_apps().
APP_DISABLED=(federation)

usage() {
  cat <<'USAGE'
configure-nextcloud.sh - provision Nextcloud through occ (idempotent)

Usage:
  ./scripts/configure-nextcloud.sh [options]

Options:
      --enforce-2fa   require TOTP for every user (occ twofactorauth:enforce --on)
      --skip-apps     do not install/enable/disable apps
      --skip-mail     do not configure SMTP
      --skip-share    do not configure the share policy
      --skip-cache    do not touch/verify memcache + Redis
  -n, --dry-run       print every occ command, change nothing
  -h, --help          show this help and exit

Environment overrides (local / no-domain run):
  PUBLIC_BASE_URL       full base URL, e.g. http://cloud.local:8080
                        (sets scheme/host/overwrite.cli.url instead of https://CLOUD_DOMAIN)
  DOCUMENT_SERVER_URL   browser URL of ONLYOFFICE Docs, e.g. http://cloud.local:8081/
                        (default: https://OFFICE_DOMAIN/)

Applied through occ:
  trusted_domains trusted_proxies overwriteprotocol/overwritehost/overwrite.cli.url
  background:cron, SMTP, memcache.local=APCu, memcache.distributed/locking=Redis,
  link shares (password + expiry + public upload), resharing and user
  enumeration, password policy (min length 12), files default_quota,
  onlyoffice DocumentServerUrl/InternalUrl/StorageUrl + JWT,
  apps: enable admin_audit/onlyoffice/twofactor_totp/password_policy,
        disable federation and block server2server shares (remote shares off)

Verified (owned by config/nextcloud/config/zz-10-cloudsuite.config.php):
  maintenance_window_start, default_phone_region, skeletondirectory,
  log_type/logfile/log_type_audit/logfile_audit, loglevel,
  versions_retention_obligation, trashbin_retention_obligation,
  enable_previews + preview limits, auth.bruteforce.protection.enabled

Exit codes: 0 success, 1 one or more verifications failed.
USAGE
}

# --- occ wrappers ------------------------------------------------------------
occ_q() { occ "$@" >/dev/null 2>&1; }

occ_set_system() {
  local key=$1
  local value=$2
  local type=${3:-}
  local -a args=(config:system:set "$key" --value="$value")
  if [[ -n $type ]]; then args+=(--type="$type"); fi
  if is_dry_run; then
    printf '%s[dry-run]%s occ %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "${args[@]}")" >&2
  else
    occ "${args[@]}" >/dev/null
  fi
  APPLIED=$(( APPLIED + 1 ))
}

occ_set_app() {
  local app=$1
  local key=$2
  local value=$3
  local -a args=(config:app:set "$app" "$key" --value="$value")
  if is_dry_run; then
    printf '%s[dry-run]%s occ %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "${args[@]}")" >&2
  else
    occ "${args[@]}" >/dev/null
  fi
  APPLIED=$(( APPLIED + 1 ))
}

occ_get_system() {
  occ config:system:get "$1" 2>/dev/null | head -n 1 || true
}

occ_get_app() {
  occ config:app:get "$1" "$2" 2>/dev/null | head -n 1 || true
}

normalise_value() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  value=${value#\"}
  value=${value%\"}
  value=${value#\'}
  value=${value%\'}
  case $value in
    True|TRUE|true|on|ON|1) printf 'true' ;;
    False|FALSE|false|off|OFF|0) printf 'false' ;;
    '') printf '' ;;
    *) printf '%s' "$value" ;;
  esac
}

verify_system() {
  local key=$1
  local expected=$2
  local label=${3:-$1}
  if is_dry_run; then
    log "[dry-run] verify ${label} == '${expected}'"
    return 0
  fi
  local actual
  actual=$(occ_get_system "$key")
  if [[ "$(normalise_value "$actual")" == "$(normalise_value "$expected")" ]]; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "${label} = ${actual:-<empty>}"
  else
    FAILED=$(( FAILED + 1 ))
    error "${label} is '${actual}' but should be '${expected}' (check config/nextcloud/config/zz-10-cloudsuite.config.php)"
  fi
}

occ_set_system_nested() {
  # Nested system key: "redis => ${parent} => ${child}" (e.g. redis host = cache).
  # occ takes both key components positionally, so the flat occ_set_system helper
  # cannot express it (it would treat the child as --type).
  local parent=$1
  local child=$2
  local value=$3
  local type=${4:-}
  local -a args=(config:system:set "$parent" "$child" --value="$value")
  if [[ -n $type ]]; then args+=(--type="$type"); fi
  if is_dry_run; then
    printf '%s[dry-run]%s occ %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "${args[@]}")" >&2
  else
    occ "${args[@]}" >/dev/null
  fi
  APPLIED=$(( APPLIED + 1 ))
}

occ_get_system_nested() {
  occ config:system:get "$1" "$2" 2>/dev/null | head -n 1 || true
}

verify_system_nested() {
  local parent=$1
  local child=$2
  local expected=$3
  local label=${4:-${parent} ${child}}
  if is_dry_run; then
    log "[dry-run] verify ${label} == '$expected'"
    return 0
  fi
  local actual
  actual=$(occ_get_system_nested "$parent" "$child")
  if [[ "$(normalise_value "$actual")" == "$(normalise_value "$expected")" ]]; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "${label} = ${actual:-<empty>}"
  else
    FAILED=$(( FAILED + 1 ))
    error "${label} is '$actual' but should be '$expected'"
  fi
}

verify_redis_host() {
  local expected=${1:-cache}
  local label=${2:-redis host}
  if is_dry_run; then
    log "[dry-run] verify ${label} == '$expected'"
    return 0
  fi
  # Nextcloud stores the host as "tcp://cache"; accept both forms.
  local actual
  actual=$(occ_get_system_nested redis host)
  actual=${actual#tcp://}
  actual=${actual#redis://}
  if [[ "$(normalise_value "$actual")" == "$(normalise_value "$expected")" ]]; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "${label} = ${actual:-<empty>}"
  else
    FAILED=$(( FAILED + 1 ))
    error "${label} is '$actual' but should be '$expected'"
  fi
}

verify_app() {
  local app=$1
  local key=$2
  local expected=$3
  local label=${4:-${app}.${key}}
  if is_dry_run; then
    log "[dry-run] verify ${label} == '${expected}'"
    return 0
  fi
  local actual
  actual=$(occ_get_app "$app" "$key")
  if [[ "$(normalise_value "$actual")" == "$(normalise_value "$expected")" ]]; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "${label} = ${actual:-<empty>}"
  else
    FAILED=$(( FAILED + 1 ))
    error "${label} is '${actual}' but should be '${expected}'"
  fi
}

app_installed() {
  occ app:getpath "$1" >/dev/null 2>&1
}

app_enabled() {
  # Do not pipe into "grep -q": grep exits on the first match, the writer gets
  # SIGPIPE, and with "set -o pipefail" the whole pipeline reports failure even
  # though the app IS enabled (observed as flaky "not enabled" errors).
  local enabled
  enabled=$(occ app:list 2>/dev/null | sed -n '/^Enabled:/,/^Disabled:/p' || true)
  [[ $enabled == *"  - ${1}:"* ]]
}

ensure_app() {
  local app=$1
  if ! app_installed "$app"; then
    if is_dry_run; then
      printf '%s[dry-run]%s occ app:install %s\n' "${C_YELLOW}" "${C_RESET}" "$app" >&2
    else
      info "installing app ${app}"
      if ! occ app:install "$app" >/dev/null 2>&1; then
        error "cannot install app '${app}' - the App Store must be reachable"
        hint "check outbound HTTPS to apps.nextcloud.com (make doctor prints an 'appstore' check)"
        hint "or install the app manually: place it in apps/ and run occ app:enable ${app}"
        FAILED=$(( FAILED + 1 ))
        return 1
      fi
    fi
    APPLIED=$(( APPLIED + 1 ))
  fi
  if ! app_enabled "$app"; then
    if is_dry_run; then
      printf '%s[dry-run]%s occ app:enable %s\n' "${C_YELLOW}" "${C_RESET}" "$app" >&2
    else
      occ app:enable "$app" >/dev/null
    fi
    APPLIED=$(( APPLIED + 1 ))
  fi
  ok "app ${app} is installed and enabled"
}

disable_app() {
  local app=$1
  if app_enabled "$app"; then
    if is_dry_run; then
      printf '%s[dry-run]%s occ app:disable %s\n' "${C_YELLOW}" "${C_RESET}" "$app" >&2
    else
      occ app:disable "$app" >/dev/null
    fi
    APPLIED=$(( APPLIED + 1 ))
    ok "app ${app} disabled"
  else
    ok "app ${app} already disabled"
  fi
}

wait_for_app() {
  if is_dry_run; then
    return 0
  fi
  local deadline=$(( SECONDS + 180 ))
  while (( SECONDS < deadline )); do
    if occ_q status; then return 0; fi
    sleep 3
  done
  die "the app container did not become ready for occ within 180s (check: make logs-app)"
}

# --- provisioning sections ---------------------------------------------------
occ_set_index() {
  local key=$1
  local index=$2
  local value=$3
  if is_dry_run; then
    printf '%s[dry-run]%s occ config:system:set %s %s --value=%s\n' "${C_YELLOW}" "${C_RESET}" "$key" "$index" "$value" >&2
  else
    occ config:system:set "$key" "$index" --value="$value" >/dev/null
  fi
  APPLIED=$(( APPLIED + 1 ))
}

configure_identity() {
  section "domains, proxies, background jobs"
  local index=0 domain
  local domains=()
  for domain in ${NEXTCLOUD_TRUSTED_DOMAINS:-${CLOUD_DOMAIN:-} ${OFFICE_DOMAIN:-} web}; do
    [[ -n $domain ]] && domains+=("$domain")
  done
  for domain in "${domains[@]}"; do
    occ_set_index trusted_domains "$index" "$domain"
    index=$(( index + 1 ))
  done
  # Drop stale indexes left over from an older configuration.
  local stale
  for stale in 5 6 7 8 9; do
    if (( stale >= index )); then
      if ! is_dry_run; then occ config:system:delete trusted_domains "$stale" >/dev/null 2>&1 || true; fi
    fi
  done
  ok "trusted_domains: ${domains[*]}"

  index=0
  local proxies=()
  local proxy
  for proxy in ${TRUSTED_PROXIES:-172.28.10.0/24}; do
    [[ -n $proxy ]] && proxies+=("$proxy")
  done
  for proxy in "${proxies[@]}"; do
    occ_set_index trusted_proxies "$index" "$proxy"
    index=$(( index + 1 ))
  done
  ok "trusted_proxies: ${proxies[*]}"

  # Публичный базовый URL: PUBLIC_BASE_URL (локальный запуск без домена) или
  # https://CLOUD_DOMAIN для продакшна с TLS на NPM.
  local protocol=https overwrite_host base_url
  if [[ -n ${PUBLIC_BASE_URL:-} ]]; then
    base_url=${PUBLIC_BASE_URL%/}
    protocol=${base_url%%://*}
    overwrite_host=${base_url#*://}
  else
    base_url="https://${CLOUD_DOMAIN:-}"
    overwrite_host="${CLOUD_DOMAIN:-}"
  fi
  occ_set_system overwriteprotocol "$protocol"
  occ_set_system overwritehost "$overwrite_host"
  occ_set_system overwrite.cli.url "$base_url"
  occ_set_system default_phone_region "${DEFAULT_PHONE_REGION:-RU}"
  if is_dry_run; then
    printf '%s[dry-run]%s occ background:cron\n' "${C_YELLOW}" "${C_RESET}" >&2
  else
    occ background:cron >/dev/null
  fi
  APPLIED=$(( APPLIED + 1 ))
  ok "background jobs mode: cron"
  verify_system overwriteprotocol "$protocol" "overwrite protocol"
  verify_system overwritehost "$overwrite_host" "overwrite host"
}

configure_mail() {
  if (( SKIP_MAIL == 1 )); then
    warn "mail configuration skipped (--skip-mail)"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  section "mail (SMTP)"
  if [[ -z ${SMTP_HOST:-} ]]; then
    warn "SMTP_HOST is empty - invitations, password resets and share mails will not work"
    hint "set SMTP_HOST/SMTP_PORT/SMTP_USER/SMTP_PASSWORD/SMTP_FROM in ${CLOUDSUITE_ENV_FILE} and re-run"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  local secure=${SMTP_SECURE:-tls}
  case $secure in
    ssl|SSL) secure=ssl ;;
    tls|TLS|starttls) secure=tls ;;
    none|'') secure='' ;;
    *) warn "unknown SMTP_SECURE='${secure}', using tls"; secure=tls ;;
  esac
  occ_set_system mail_smtpmode smtp
  occ_set_system mail_sendmailmode smtp
  occ_set_system mail_smtphost "${SMTP_HOST}"
  occ_set_system mail_smtpport "${SMTP_PORT:-587}" integer
  occ_set_system mail_smtpsecure "$secure"
  occ_set_system mail_smtptimeout 30 integer
  if [[ -n ${SMTP_USER:-} ]]; then
    occ_set_system mail_smtpauth 1 boolean
    occ_set_system mail_smtpname "${SMTP_USER}"
    occ_set_system mail_smtppassword "${SMTP_PASSWORD:-}"
  else
    occ_set_system mail_smtpauth 0 boolean
  fi
  local from=${SMTP_FROM:-}
  if [[ -n $from ]]; then
    occ_set_system mail_from_address "${from%@*}"
    local mail_domain=${MAIL_DOMAIN:-}
    if [[ -z $mail_domain ]]; then mail_domain="${from#*@}"; fi
    occ_set_system mail_domain "$mail_domain"
  fi
  verify_system mail_smtpmode smtp "smtp mode"
  verify_system mail_smtphost "${SMTP_HOST}" "smtp host"
  ok "SMTP configured: ${SMTP_HOST}:${SMTP_PORT:-587} (${secure:-plain}), from ${SMTP_FROM:-<unset>}"
  if [[ -z ${SMTP_PASSWORD:-} ]] && [[ -n ${SMTP_USER:-} ]]; then
    warn "SMTP_USER is set but SMTP_PASSWORD is empty - authenticated relay will fail"
  fi
}

configure_apps() {
  if (( SKIP_APPS == 1 )); then
    warn "app management skipped (--skip-apps)"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  section "apps"
  local app
  for app in "${APP_REQUIRED[@]}"; do
    ensure_app "$app" || true
  done
  for app in "${APP_DISABLED[@]}"; do
    disable_app "$app"
  done
  # Block server-to-server (federated) shares in both directions. The core app
  # cannot be disabled, but these two files_sharing switches stop outgoing and
  # incoming federated shares at the sharing layer.
  occ_set_app files_sharing outgoing_server2server_share_enabled no
  occ_set_app files_sharing incoming_server2server_share_enabled no
  if is_dry_run; then
    return 0
  fi
  for app in "${APP_REQUIRED[@]}"; do
    if app_enabled "$app"; then
      VERIFIED=$(( VERIFIED + 1 ))
    else
      FAILED=$(( FAILED + 1 ))
      error "app ${app} is not enabled"
    fi
  done
  verify_app files_sharing outgoing_server2server_share_enabled no "federated shares (outgoing) blocked"
  verify_app files_sharing incoming_server2server_share_enabled no "federated shares (incoming) blocked"
  for app in "${APP_DISABLED[@]}"; do
    if app_enabled "$app"; then
      FAILED=$(( FAILED + 1 ))
      error "app ${app} is still enabled (remote shares must stay blocked)"
    else
      VERIFIED=$(( VERIFIED + 1 ))
    fi
  done
}

configure_onlyoffice() {
  section "ONLYOFFICE integration"
  if [[ -z ${OFFICE_DOMAIN:-} && -z ${DOCUMENT_SERVER_URL:-} ]]; then
    error "OFFICE_DOMAIN and DOCUMENT_SERVER_URL are empty - cannot configure the ONLYOFFICE app"
    FAILED=$(( FAILED + 1 ))
    return 0
  fi
  if [[ -z ${ONLYOFFICE_JWT_SECRET:-} ]]; then
    error "ONLYOFFICE_JWT_SECRET is empty - generate secrets first (./scripts/generate-secrets.sh)"
    FAILED=$(( FAILED + 1 ))
    return 0
  fi
  if ! app_installed onlyoffice && (( SKIP_APPS == 1 )); then
    warn "onlyoffice app is not installed and --skip-apps was given - skipping its configuration"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  # Браузерный адрес редактора: DOCUMENT_SERVER_URL (локальный запуск) или
  # https://OFFICE_DOMAIN/ (прод с TLS на NPM).
  local ds_url=${DOCUMENT_SERVER_URL:-https://${OFFICE_DOMAIN}/}
  occ_set_app onlyoffice DocumentServerUrl "$ds_url"
  occ_set_app onlyoffice DocumentServerInternalUrl "http://onlyoffice/"
  occ_set_app onlyoffice StorageUrl "http://web:8080/"
  occ_set_app onlyoffice jwt_secret "${ONLYOFFICE_JWT_SECRET}"
  occ_set_app onlyoffice jwt_header "${ONLYOFFICE_JWT_HEADER:-Authorization}"
  occ_set_app onlyoffice jwt_in_body "${ONLYOFFICE_JWT_IN_BODY:-true}"
  occ_set_app onlyoffice verify_peer_off false
  occ_set_app onlyoffice preview true
  verify_app onlyoffice DocumentServerUrl "$ds_url" "onlyoffice DocumentServerUrl"
  if is_dry_run; then
    log "[dry-run] verify onlyoffice jwt_secret is set (value is never printed)"
  else
    if [[ -n $(occ_get_app onlyoffice jwt_secret) ]]; then
      VERIFIED=$(( VERIFIED + 1 ))
      ok "onlyoffice jwt_secret is set (value not printed)"
    else
      FAILED=$(( FAILED + 1 ))
      error "onlyoffice jwt_secret is empty"
    fi
  fi
  ok "ONLYOFFICE: ${ds_url} (internal http://onlyoffice/, storage http://web:8080/)"
}

configure_cache() {
  if (( SKIP_CACHE == 1 )); then
    warn "cache configuration skipped (--skip-cache)"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  section "memcache + redis"
  occ_set_system memcache.local '\OC\Memcache\APCu'
  occ_set_system memcache.distributed '\OC\Memcache\Redis'
  occ_set_system memcache.locking '\OC\Memcache\Redis'
  # redis.* is a nested config array: occ needs "config:system:set redis <key>".
  occ_set_system_nested redis host cache
  occ_set_system_nested redis port 6379 integer
  occ_set_system_nested redis password "${REDIS_PASSWORD:-}"
  occ_set_system_nested redis dbindex 0 integer
  occ_set_system_nested redis timeout 1.5 double
  verify_system memcache.local '\OC\Memcache\APCu' "memcache.local"
  verify_system memcache.distributed '\OC\Memcache\Redis' "memcache.distributed"
  verify_system memcache.locking '\OC\Memcache\Redis' "memcache.locking"
  verify_redis_host cache "redis host"
  verify_system_nested redis port 6379 "redis port"

  if is_dry_run; then
    log "[dry-run] verify APCu and Redis round-trip inside the app container"
    return 0
  fi
  local modules
  modules=$(compose exec -T app php -m 2>/dev/null || true)
  if grep -qix 'apcu' <<< "$modules"; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "PHP extension apcu is loaded"
  else
    FAILED=$(( FAILED + 1 ))
    error "PHP extension apcu is not loaded - memcache.local will fall back to the database"
  fi
  if grep -qix 'redis' <<< "$modules"; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "PHP extension redis is loaded"
  else
    FAILED=$(( FAILED + 1 ))
    error "PHP extension redis is not loaded - file locking will not work"
  fi
  local probe
  # shellcheck disable=SC2016 # PHP code, not shell
  probe=$(compose exec -T app php -r '
require "/var/www/html/lib/base.php";
$factory = \OCP\Server::get(\OCP\ICacheFactory::class);
$cache = $factory->createDistributed("cloudsuite");
$cache->set("probe", "ok", 30);
$ok = ($cache->get("probe") === "ok");
$locker = \OCP\Server::get(\OCP\Lock\ILockingProvider::class);
printf("distributed=%s locking=%s\n", $ok ? "ok" : "fail", get_class($locker));
' 2>&1) || true
  if grep -q 'distributed=ok' <<< "$probe"; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "distributed cache round-trip: ${probe}"
  else
    FAILED=$(( FAILED + 1 ))
    error "distributed cache round-trip failed: ${probe:-no output}"
  fi
  # Nextcloud 33+ locks through MemcacheLockingProvider (backed by
  # memcache.locking=Redis); older releases used RedisLockingProvider directly.
  if grep -q 'locking=' <<< "$probe" && grep -qE 'MemcacheLockingProvider|RedisLockingProvider' <<< "$probe"; then
    VERIFIED=$(( VERIFIED + 1 ))
    ok "locking provider is backed by Redis"
  else
    warn "locking provider does not look like the Redis-backed locker: ${probe:-no output}"
    FAILED=$(( FAILED + 1 ))
  fi
}

configure_sharing() {
  if (( SKIP_SHARE == 1 )); then
    warn "share policy skipped (--skip-share)"
    SKIPPED=$(( SKIPPED + 1 ))
    return 0
  fi
  section "share policy"
  local expire_days=${LINK_EXPIRE_DAYS:-30}
  occ_set_system shareapi_enabled yes
  occ_set_system shareapi_allow_links yes
  occ_set_system shareapi_enforce_links_password yes
  occ_set_system shareapi_default_expire_date yes
  occ_set_system shareapi_expire_after_n_days "$expire_days" integer
  occ_set_system shareapi_enforce_expire_date yes
  occ_set_system shareapi_allow_public_upload yes
  occ_set_system shareapi_allow_resharing yes
  occ_set_system shareapi_allow_share_dialog_user_enumeration yes
  occ_set_system shareapi_restrict_user_enumeration_to_group no
  occ_set_system shareapi_allow_group_sharing yes
  occ_set_system shareapi_allow_mail_sharing no
  occ_set_system shareapi_allow_links_with_password_by_default yes
  verify_system shareapi_enabled yes "sharing enabled"
  verify_system shareapi_allow_links yes "link shares allowed"
  verify_system shareapi_enforce_links_password yes "link passwords enforced"
  verify_system shareapi_expire_after_n_days "$expire_days" "link expiry (days)"
  ok "links: password required, expire after ${expire_days} days, public upload allowed, resharing allowed"
  ok "remote/federated sharing is blocked (federation app disabled, server2server shares off)"
}

configure_quota_and_policy() {
  section "default quota, password policy, 2FA"
  local quota=${DEFAULT_QUOTA:-}
  if [[ -z $quota && -f "${CLOUDSUITE_ROOT}/config/rbac/roles.yaml" ]]; then
    quota=$(python3 "${CLOUDSUITE_LIB_DIR}/rbac.py" --mode policy "${CLOUDSUITE_ROOT}/config/rbac/roles.yaml" 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["defaults"]["default_quota"])' 2>/dev/null || true)
  fi
  [[ -n $quota ]] || quota="10GB"
  occ_set_app files default_quota "$quota"
  verify_app files default_quota "$quota" "files.default_quota"
  ok "default quota for new users: ${quota}"

  occ_set_app password_policy minLength 12
  occ_set_app password_policy enforceNonCommonPassword true
  occ_set_app password_policy enforceUpperLowerCase false
  occ_set_app password_policy enforceNumericCharacters false
  occ_set_app password_policy enforceSpecialCharacters false
  verify_app password_policy minLength 12 "password minLength"
  ok "password policy: minLength 12, common-password check on, character classes off (long passphrases)"

  if (( ENFORCE_2FA == 1 )); then
    if is_dry_run; then
      printf '%s[dry-run]%s occ twofactorauth:enforce --on\n' "${C_YELLOW}" "${C_RESET}" >&2
    else
      occ twofactorauth:enforce --on >/dev/null
    fi
    APPLIED=$(( APPLIED + 1 ))
    ok "two-factor authentication is enforced for every user"
  else
    log "2FA enforcement not requested (use --enforce-2fa); the TOTP app is enabled and ready"
    SKIPPED=$(( SKIPPED + 1 ))
  fi
}

verify_config_owned_by_config_php() {
  section "effective config owned by zz-10-cloudsuite.config.php"
  verify_system maintenance_window_start 1 "maintenance window start"
  verify_system default_phone_region "${DEFAULT_PHONE_REGION:-RU}" "default phone region"
  verify_system log_type file "log_type"
  verify_system logfile /var/log/cloudsuite/nextcloud.log "logfile"
  verify_system log_type_audit file "log_type_audit"
  verify_system logfile_audit /var/log/cloudsuite/audit.log "logfile_audit (audit log)"
  verify_system versions_retention_obligation "auto, ${VERSIONS_RETENTION_DAYS:-30}" "versions retention"
  verify_system trashbin_retention_obligation "auto, ${TRASH_RETENTION_DAYS:-30}" "trashbin retention"
  verify_system enable_previews true "previews enabled"
  verify_system 'auth.bruteforce.protection.enabled' true "bruteforce protection"
  verify_system skeletondirectory "" "skeleton directory (empty = no sample files)"
  # loglevel is documented as 2 (warning) for production; a debug level is only a warning.
  if is_dry_run; then
    log "[dry-run] verify loglevel is not debug"
  else
    local level
    level=$(occ_get_system loglevel)
    case $level in
      0)
        FAILED=$(( FAILED + 1 ))
        error "loglevel=0 (debug) would fill the disk with logs - expected 2"
        ;;
      1|2|3|4)
        VERIFIED=$(( VERIFIED + 1 ))
        ok "loglevel=${level}"
        ;;
      *)
        warn "unexpected loglevel '${level}'"
        ;;
    esac
  fi
}

print_summary() {
  section "summary"
  printf 'applied        : %d\n' "$APPLIED"
  printf 'verified       : %d\n' "$VERIFIED"
  printf 'skipped        : %d\n' "$SKIPPED"
  printf 'failed         : %d\n' "$FAILED"
  if (( FAILED > 0 )); then
    error "configuration finished with ${FAILED} failed check(s) - review the output above"
    return 1
  fi
  ok "Nextcloud is configured"
  hint "next: make rbac   (groups, quotas, delegated admins)"
  hint "next: make smoke  (end-to-end proof: WebDAV, links, versions)"
  return 0
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --enforce-2fa) ENFORCE_2FA=1; shift ;;
      --skip-apps) SKIP_APPS=1; shift ;;
      --skip-mail) SKIP_MAIL=1; shift ;;
      --skip-share) SKIP_SHARE=1; shift ;;
      --skip-cache) SKIP_CACHE=1; shift ;;
      -n|--dry-run) set_dry_run; DRY_RUN_FLAG=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker
  if [[ -z ${CLOUD_DOMAIN:-} ]]; then
    die "CLOUD_DOMAIN is empty in ${CLOUDSUITE_ENV_FILE}"
  fi
  if ! service_running app; then
    die "the app container is not running - start the stack first (make up)"
  fi
  wait_for_app

  section "configure Nextcloud (${CLOUD_DOMAIN})"
  configure_identity
  configure_mail
  configure_apps
  configure_onlyoffice
  configure_cache
  configure_sharing
  configure_quota_and_policy
  verify_config_owned_by_config_php

  if ! is_dry_run; then
    occ status >/dev/null 2>&1 || warn "occ status failed after configuration"
    occ maintenance:mode --off >/dev/null 2>&1 || true
  fi

  if ! print_summary; then
    exit 1
  fi
  if (( DRY_RUN_FLAG == 1 )); then
    warn "dry-run: nothing was changed"
  fi
  exit 0
}

main "$@"
