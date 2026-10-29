#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - end-to-end smoke test
#  ---------------------------------------------------------------------------
#  Creates a throw-away user, exercises the paths that actually carry user
#  data, and removes everything again:
#
#    WebDAV PUT / PROPFIND / GET / DELETE   (sync client path)
#    public link share + anonymous download (customer path)
#    file versioning                        (restore path)
#    trashbin delete + cleanup              (recovery path)
#    ONLYOFFICE health + internal reachability
#    audit log growth                       (admin_audit is really logging)
#
#  Exit codes: 0 all checks passed, 1 one or more checks failed,
#              2 setup problem (stack not running / missing tools).
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "smoke-test.sh"

SMOKE_USER=${SMOKE_USER:-cloudsuite-smoke}
SMOKE_PASS=""
BASE_URL=""
INSECURE=0
KEEP=0
VERBOSE=0
PASSED=0
FAILED=0
SKIPPED=0
CURL_OPTS=()
CREATED_USER=0
AUDIT_BEFORE=0
WORK_DIR=""

usage() {
  cat <<'USAGE'
smoke-test.sh - prove that the deployment works end to end

Usage:
  ./scripts/smoke-test.sh [options]

Options:
      --base-url URL   public base URL (default: https://$CLOUD_DOMAIN)
      --user NAME      name of the throw-away test user
                       (default: cloudsuite-smoke)
      --insecure       do not verify the TLS certificate (staging only)
      --keep           keep the test user and files for inspection
  -v, --verbose        print the HTTP details of every request
  -h, --help           show this help and exit

The test user is created with a random password and deleted at the end.
Requires: docker, curl, python3 (all present on a Cloud Suite host).
USAGE
}

smoke_curl() {
  local config
  config=$(mktemp)
  printf 'user = "%s:%s"\n' "$SMOKE_USER" "$SMOKE_PASS" > "$config"
  local rc=0
  curl --config "$config" --silent --show-error --fail "${CURL_OPTS[@]}" "$@" || rc=$?
  rm -f "$config"
  return "$rc"
}

pass_check() {
  PASSED=$(( PASSED + 1 ))
  ok "$1"
}

fail_check() {
  FAILED=$(( FAILED + 1 ))
  error "$1"
}

skip_check() {
  SKIPPED=$(( SKIPPED + 1 ))
  warn "$1"
}

# shellcheck disable=SC2329 # invoked through the register_cleanup trap chain
cleanup() {
  local user=${SMOKE_USER}
  if (( KEEP == 1 )); then
    section "keeping the test user ${user} (--keep)"
    return 0
  fi
  if (( CREATED_USER == 1 )); then
    section "cleanup"
    occ trashbin:cleanup "${user}" >/dev/null 2>&1 || true
    if occ user:delete "${user}" >/dev/null 2>&1; then
      ok "test user ${user} deleted"
    else
      warn "could not delete the test user ${user} - remove it with: occ user:delete ${user}"
    fi
  fi
  if [[ -n $WORK_DIR && -d $WORK_DIR ]]; then
    rm -rf -- "$WORK_DIR"
  fi
}

setup_user() {
  section "prepare the test user"
  if occ user:info "$SMOKE_USER" >/dev/null 2>&1; then
    info "user ${SMOKE_USER} already exists - resetting the password"
    if ! OC_PASS="$SMOKE_PASS" occ user:resetpassword --password-from-env "$SMOKE_USER" >/dev/null 2>&1; then
      die "cannot reset the password of ${SMOKE_USER}"
    fi
  else
    if ! OC_PASS="$SMOKE_PASS" occ user:add --password-from-env --display-name "Cloud Suite smoke test" "$SMOKE_USER" >/dev/null 2>&1; then
      die "cannot create the test user ${SMOKE_USER}"
    fi
    CREATED_USER=1
  fi
  ok "test user ${SMOKE_USER} is ready"
  sleep 2
  local quota
  quota=$(occ user:setting "$SMOKE_USER" files quota 2>/dev/null || true)
  log "test user quota: ${quota:-<default>} (quota failures would surface as 507 on upload)"
}

webdav_url() {
  printf '%s/remote.php/dav/files/%s' "$BASE_URL" "$SMOKE_USER"
}

check_webdav() {
  section "WebDAV (the sync client path)"
  local dir_url file_url remote_dir
  dir_url=$(webdav_url)
  remote_dir="$dir_url/smoke"
  file_url="$remote_dir/hello.txt"

  local mkcol_code
  mkcol_code=$(smoke_curl -X MKCOL "$remote_dir" -o /dev/null -w '%{http_code}' 2>/dev/null || true)
  case $mkcol_code in
    201) pass_check "MKCOL ${remote_dir##*/}/ created" ;;
    405|301|302) pass_check "MKCOL ${remote_dir##*/}/ (already exists)" ;;
    *) fail_check "MKCOL ${remote_dir##*/}/ failed (HTTP ${mkcol_code:-none})" ;;
  esac

  local payload
  payload="cloudsuite-smoke-$(timestamp_compact)"
  if printf '%s' "$payload" | smoke_curl -X PUT --data-binary @- "$file_url" -o /dev/null; then
    pass_check "PUT hello.txt ($(printf '%s' "$payload" | wc -c | tr -d ' ') bytes)"
  else
    fail_check "PUT hello.txt failed"
    return 0
  fi

  local body
  body=$(smoke_curl -X PROPFIND -H 'Depth: 1' "$remote_dir" 2>/dev/null || true)
  if grep -q 'hello.txt' <<< "$body"; then
    pass_check "PROPFIND lists hello.txt"
  else
    fail_check "PROPFIND does not list hello.txt"
  fi

  local downloaded
  downloaded=$(smoke_curl -X GET "$file_url" 2>/dev/null || true)
  if [[ $downloaded == "$payload" ]]; then
    pass_check "GET returns the same bytes"
  else
    fail_check "GET returned different content"
  fi

  local fileid
  fileid=$(grep -o '<oc:fileid>[0-9]*</oc:fileid>' <<< "$body" | head -n 1 | grep -o '[0-9]*' || true)
  if [[ -n $fileid ]]; then
    pass_check "file id resolved: ${fileid}"
  else
    fail_check "could not resolve the file id (versioning check needs it)"
  fi
  printf '%s' "$fileid" > "$WORK_DIR/fileid"
}

check_link_share() {
  section "public link share (the customer path)"
  local fileid token share_id payload response
  fileid=$(cat "$WORK_DIR/fileid" 2>/dev/null || true)
  [[ -n $fileid ]] || { skip_check "no file id - link share check skipped"; return 0; }

  payload=$(printf 'path=%s&shareType=3&permissions=1' "/smoke/hello.txt")
  response=$(smoke_curl -X POST \
    -H 'OCS-APIRequest: true' \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    --data "$payload" \
    "$BASE_URL/ocs/v2.php/apps/files_sharing/api/v1/shares" 2>/dev/null || true)
  token=$(grep -o '"token":"[^"]*"' <<< "$response" | head -n 1 | cut -d'"' -f4 || true)
  share_id=$(grep -o '"id":"[0-9]*"' <<< "$response" | head -n 1 | cut -d'"' -f4 || true)
  if [[ -z $token ]]; then
    fail_check "could not create a public link share"
    debug "OCS response: ${response:0:400}"
    return 0
  fi
  pass_check "link share created (token ${token})"
  printf '%s\n%s\n' "$token" "$share_id" > "$WORK_DIR/share"

  local content
  content=$(curl --silent --show-error "${CURL_OPTS[@]}" "$BASE_URL/s/${token}/download" 2>/dev/null || true)
  if [[ -n $content ]]; then
    pass_check "anonymous download through /s/${token}/download works"
  else
    fail_check "anonymous download failed (check the edge nginx / NPM configuration)"
  fi

  if [[ -n $share_id ]]; then
    if smoke_curl -X DELETE -H 'OCS-APIRequest: true' -o /dev/null \
        "$BASE_URL/ocs/v2.php/apps/files_sharing/api/v1/shares/${share_id}"; then
      pass_check "link share deleted again"
    else
      warn "could not delete the test share id ${share_id}"
    fi
  fi
}

check_versions() {
  section "file versions (the restore path)"
  local fileid versions_url body count
  fileid=$(cat "$WORK_DIR/fileid" 2>/dev/null || true)
  [[ -n $fileid ]] || { skip_check "no file id - version check skipped"; return 0; }
  local file_url
  file_url="$(webdav_url)/smoke/hello.txt"
  printf 'version-two-%s' "$(timestamp_compact)" | smoke_curl -X PUT --data-binary @- "$file_url" -o /dev/null \
    || { fail_check "second PUT failed"; return 0; }
  sleep 2
  versions_url="$BASE_URL/remote.php/dav/versions/${SMOKE_USER}/versions/${fileid}"
  body=$(smoke_curl -X PROPFIND -H 'Depth: 1' "$versions_url" 2>/dev/null || true)
  count=$(grep -o '<d:response>' <<< "$body" | wc -l | tr -d ' ')
  if (( count > 1 )); then
    pass_check "at least one previous version is stored (${count} DAV entries)"
  else
    fail_check "no previous version found - check files_versions and versions_retention_obligation"
  fi
}

check_trashbin() {
  section "trashbin (the recovery path)"
  local file_url body
  file_url="$(webdav_url)/smoke/hello.txt"
  if ! smoke_curl -X DELETE "$file_url" -o /dev/null; then
    fail_check "DELETE of the test file failed"
    return 0
  fi
  pass_check "file moved to the trashbin"
  body=$(smoke_curl -X PROPFIND -H 'Depth: 1' "$BASE_URL/remote.php/dav/trashbin/${SMOKE_USER}/trash" 2>/dev/null || true)
  if grep -q 'hello.txt' <<< "$body"; then
    pass_check "trashbin lists the deleted file"
  else
    fail_check "trashbin does not list the deleted file"
  fi
  occ trashbin:cleanup "$SMOKE_USER" >/dev/null 2>&1 || true
}

check_onlyoffice() {
  section "ONLYOFFICE Document Server"
  local health
  health=$(curl --silent --show-error "${CURL_OPTS[@]}" "https://${OFFICE_DOMAIN:-}/healthcheck" 2>/dev/null || true)
  if [[ $health == true || $health == TRUE ]]; then
    pass_check "https://${OFFICE_DOMAIN:-}/healthcheck returns true"
  else
    fail_check "ONLYOFFICE healthcheck did not return true (got '${health:0:40}')"
  fi
  if compose exec -T onlyoffice curl --silent --fail --max-time 10 http://web:8080/status.php >/dev/null 2>&1; then
    pass_check "ONLYOFFICE can reach the Nextcloud backend (http://web:8080/status.php)"
  else
    fail_check "ONLYOFFICE cannot reach http://web:8080/status.php"
  fi
  local ds_url
  ds_url=$(occ config:app:get onlyoffice DocumentServerUrl 2>/dev/null || true)
  if [[ -n $ds_url ]]; then
    pass_check "onlyoffice app points at ${ds_url}"
  else
    fail_check "onlyoffice DocumentServerUrl is empty - run make configure"
  fi
}

check_audit_log() {
  section "audit log"
  local log_file=${CLOUDSUITE_ROOT}/logs/cloudsuite/audit.log after
  if [[ ! -f $log_file ]]; then
    skip_check "audit log not found at ${log_file} (no audited action so far?)"
    return 0
  fi
  after=$(wc -l < "$log_file" | tr -d ' ')
  if (( after > AUDIT_BEFORE )); then
    pass_check "audit log grew from ${AUDIT_BEFORE} to ${after} lines"
  else
    fail_check "audit log did not grow (${after} lines) - admin_audit may be disabled"
  fi
  if tail -n 20 "$log_file" | grep -q '"action"'; then
    pass_check "audit entries are JSON with an action field"
  else
    warn "audit entries do not look like JSON lines"
  fi
}

print_summary() {
  section "smoke test summary"
  printf 'passed  : %d\n' "$PASSED"
  printf 'failed  : %d\n' "$FAILED"
  printf 'skipped : %d\n' "$SKIPPED"
  if (( FAILED > 0 )); then
    error "smoke test FAILED"
    return 1
  fi
  ok "smoke test PASSED"
  return 0
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --base-url) BASE_URL=${2:?--base-url needs a URL}; shift 2 ;;
      --user) SMOKE_USER=${2:?--user needs a name}; shift 2 ;;
      --insecure) INSECURE=1; shift ;;
      --keep) KEEP=1; shift ;;
      -v|--verbose) VERBOSE=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker curl python3
  if [[ -z $BASE_URL ]]; then
    [[ -n ${CLOUD_DOMAIN:-} ]] || die "CLOUD_DOMAIN is empty - pass --base-url"
    BASE_URL="https://${CLOUD_DOMAIN}"
  fi
  BASE_URL=${BASE_URL%/}
  CURL_OPTS=(--max-time 30)
  if (( INSECURE == 1 )); then CURL_OPTS+=(--insecure); fi
  if (( VERBOSE == 1 )); then CURL_OPTS+=(--verbose); fi

  if ! service_running app; then
    die "the app container is not running (make up)"
  fi
  if ! wait_for_occ 120; then
    die "occ is not answering (make logs-app)"
  fi

  WORK_DIR=$(mktemp -d)
  register_cleanup cleanup
  SMOKE_PASS=$(openssl rand -hex 16)
  AUDIT_BEFORE=0
  if [[ -f ${CLOUDSUITE_ROOT}/logs/cloudsuite/audit.log ]]; then
    AUDIT_BEFORE=$(wc -l < "${CLOUDSUITE_ROOT}/logs/cloudsuite/audit.log" | tr -d ' ')
  fi

  section "Cloud Suite smoke test (${BASE_URL})"
  setup_user
  check_webdav
  check_link_share
  check_versions
  check_trashbin
  check_onlyoffice
  check_audit_log

  if ! print_summary; then
    exit 1
  fi
  exit 0
}

main "$@"
