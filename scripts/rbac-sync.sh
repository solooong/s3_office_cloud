#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - apply config/rbac/roles.yaml to Nextcloud
#  ---------------------------------------------------------------------------
#  For every role the script:
#    * creates the group (display name is set at creation; a later change is
#      reported as drift because Nextcloud's occ cannot rename it)
#    * adds the delegated admins with "occ group:add-subadmin"
#    * with --apply-quotas, sets "files quota" for members that still use the
#      default quota and never overwrites an explicit per-user override
#    * stores the resolved policy as JSON in the cloudsuite app config so that
#      the share rules travel with the deployment
#    * verifies the global share policy against the most restrictive role and
#      reports every deviation (core Nextcloud has no per-group share rules)
#
#  The YAML parsing and validation live in scripts/lib/rbac.py.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "rbac-sync.sh"

ROLES_FILE=""
APPLY_QUOTAS=0
PRUNE=0
STRICT=0
TAB=$'\t'
TMP_DIR=""
GROUPS_JSON=""
APPLIED=0
VERIFIED=0
FAILED=0
SKIPPED=0
CREATED_GROUPS=()
MANAGED_GROUPS=()

usage() {
  cat <<'USAGE'
rbac-sync.sh - synchronise config/rbac/roles.yaml with Nextcloud groups

Usage:
  ./scripts/rbac-sync.sh [options]

Options:
  --file PATH       policy file (default: config/rbac/roles.yaml)
  --apply-quotas    set "files quota" for group members still on the default
                    quota; explicit per-user overrides are never overwritten
  --prune           delete groups that this script created earlier and that are
                    no longer present in the policy (only empty groups)
  --strict          treat unknown YAML keys as errors
  -n, --dry-run     print every occ command, change nothing
  -h, --help        show this help and exit

Applies: groups + display names, delegated admins (subadmins), optional quotas,
         the resolved policy JSON (app config cloudsuite/rbac_roles).
Checks:  global share policy, group existence, subadmin membership.

Exit codes: 0 success, 1 one or more groups could not be applied/verified.
USAGE
}

# --- small JSON helpers ------------------------------------------------------
json_groups_have() {
  python3 - "$1" "$2" <<'PY'
import json
import sys

path, group = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
if isinstance(data, dict):
    ids = set(data)
elif isinstance(data, list):
    ids = {item.get("id") for item in data if isinstance(item, dict)}
else:
    ids = set()
sys.exit(0 if group in ids else 1)
PY
}

group_field() {
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, group, field = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
info = None
if isinstance(data, dict) and group == "":
    info = data
elif isinstance(data, dict):
    info = data.get(group)
elif isinstance(data, list):
    for item in data:
        if isinstance(item, dict) and item.get("id") == group:
            info = item
            break
if isinstance(info, dict):
    value = info.get(field)
elif field == "users" and isinstance(info, list):
    value = info
else:
    value = None
if value is None:
    value = []
if isinstance(value, str):
    print(value)
elif isinstance(value, list):
    print("\n".join(str(item) for item in value))
else:
    print("")
PY
}

# --- occ wrappers ------------------------------------------------------------
occ_apply() {
  local description=$1
  shift
  if is_dry_run; then
    printf '%s[dry-run]%s occ %s\n' "${C_YELLOW}" "${C_RESET}" "$(quote_cmd "$@")" >&2
    return 0
  fi
  if ! occ "$@" >/dev/null 2>&1; then
    error "occ $* failed (${description})"
    return 1
  fi
  return 0
}

group_info_json() {
  local gid=$1 out
  out=$(occ group:info "$gid" --output=json 2>/dev/null || true)
  if [[ -z $out ]]; then
    printf '{}'
  else
    printf '%s' "$out"
  fi
}

ensure_group() {
  local gid=$1 display=$2
  if json_groups_have "$TMP_DIR/groups.json" "$gid"; then
    local current
    current=$(group_field "$TMP_DIR/groups.json" "$gid" "displayName")
    if [[ -n $current && $current != "$display" ]]; then
      warn "group ${gid}: display name is '${current}' but the policy says '${display}' (occ cannot rename groups - fix it in the admin UI)"
      SKIPPED=$(( SKIPPED + 1 ))
    else
      ok "group ${gid} exists"
      VERIFIED=$(( VERIFIED + 1 ))
    fi
    return 0
  fi
  if is_dry_run; then
    printf '%s[dry-run]%s occ group:add %s --display-name %s\n' "${C_YELLOW}" "${C_RESET}" "$gid" "$display" >&2
  else
    if ! occ group:add "$gid" --display-name "$display" >/dev/null 2>&1; then
      error "cannot create group ${gid}"
      FAILED=$(( FAILED + 1 ))
      return 1
    fi
    GROUPS_JSON=$(occ group:list --output=json 2>/dev/null || true)
    if [[ -n $GROUPS_JSON ]]; then
      printf '%s' "$GROUPS_JSON" > "$TMP_DIR/groups.json"
    fi
  fi
  CREATED_GROUPS+=("$gid")
  APPLIED=$(( APPLIED + 1 ))
  ok "group ${gid} created (${display})"
}

apply_delegated_admins() {
  local gid=$1 delegated=$2 uid
  [[ -n $delegated ]] || { ok "group ${gid}: no delegated admins declared"; return 0; }
  local info current
  info=$(group_info_json "$gid")
  printf '%s' "$info" > "$TMP_DIR/info-${gid}.json"
  current=$(group_field "$TMP_DIR/info-${gid}.json" "" "subadmins" 2>/dev/null || true)
  local -a members=()
  while IFS= read -r uid; do
    [[ -n $uid ]] && members+=("$uid")
  done <<< "$current"
  IFS=',' read -r -a wanted <<< "$delegated"
  local member found
  for uid in "${wanted[@]}"; do
    [[ -n $uid ]] || continue
    found=0
    for member in "${members[@]:-}"; do
      [[ $member == "$uid" ]] && found=1
    done
    if (( found == 1 )); then
      ok "group ${gid}: ${uid} is already a delegated admin"
      VERIFIED=$(( VERIFIED + 1 ))
      continue
    fi
    if ! is_dry_run && ! occ user:info "$uid" >/dev/null 2>&1; then
      warn "group ${gid}: user '${uid}' does not exist yet - create it and re-run make rbac"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    if occ_apply "add-subadmin ${uid} -> ${gid}" group:add-subadmin "$gid" "$uid"; then
      APPLIED=$(( APPLIED + 1 ))
      ok "group ${gid}: ${uid} added as delegated admin"
    else
      FAILED=$(( FAILED + 1 ))
    fi
  done
}

apply_quotas() {
  local gid=$1 quota=$2 uid current
  local info
  info=$(group_info_json "$gid")
  printf '%s' "$info" > "$TMP_DIR/info-${gid}.json"
  local -a users=()
  while IFS= read -r uid; do
    [[ -n $uid ]] && users+=("$uid")
  done <<< "$(group_field "$TMP_DIR/info-${gid}.json" "" "users")"
  if (( ${#users[@]} == 0 )); then
    log "group ${gid}: no members, quota ${quota} will apply when users are added"
    return 0
  fi
  for uid in "${users[@]}"; do
    if is_dry_run; then
      printf '%s[dry-run]%s occ user:setting %s files quota %s (if it is still on the default)\n' "${C_YELLOW}" "${C_RESET}" "$uid" "$quota" >&2
      continue
    fi
    current=$(occ user:setting "$uid" files quota 2>/dev/null | head -n 1 || true)
    if [[ -z $current || $current == "default" ]]; then
      if occ_apply "quota ${quota} -> ${uid}" user:setting "$uid" files quota "$quota"; then
        APPLIED=$(( APPLIED + 1 ))
        ok "${uid}: quota set to ${quota}"
      else
        FAILED=$(( FAILED + 1 ))
      fi
    elif [[ $current == "$quota" ]]; then
      ok "${uid}: quota already ${quota}"
      VERIFIED=$(( VERIFIED + 1 ))
    else
      warn "${uid}: explicit quota '${current}' kept (policy wants '${quota}')"
      SKIPPED=$(( SKIPPED + 1 ))
    fi
  done
}

check_share_policy() {
  local gid=$1 links=$2 pwd=$3 expire=$4 edit=$5 reshare=$6 remote=$7
  local global_links global_pwd global_expire global_upload global_reshare federated_enabled=0
  global_links=$(occ_get shareapi_allow_links)
  global_pwd=$(occ_get shareapi_enforce_links_password)
  global_expire=$(occ_get shareapi_expire_after_n_days)
  global_upload=$(occ_get shareapi_allow_public_upload)
  global_reshare=$(occ_get shareapi_allow_resharing)
  if app_enabled federation || app_enabled federatedfilesharing; then federated_enabled=1; fi

  local drift=0
  if [[ $links == 0 && $global_links == yes ]]; then
    warn "role ${gid} forbids link shares but the global policy allows them (core Nextcloud has no per-group link toggle)"
    drift=1
  fi
  if [[ $pwd == 1 && $global_pwd != yes ]]; then
    error "role ${gid} requires link passwords but the global policy does not enforce them - run make configure"
    drift=1
  fi
  if [[ $expire != 0 ]]; then
    # Core Nextcloud has a single global link-expiry value, so a per-role value
    # is a documented limitation, not a bug: report it with the way to enforce
    # it for everybody (LINK_EXPIRE_DAYS + make configure) instead of leaving a
    # bare "drift" warning.
    if [[ -z $global_expire ]]; then
      warn "role ${gid}: wants ${expire}-day links but shareapi_expire_after_n_days is not set - run make configure (LINK_EXPIRE_DAYS)"
      drift=1
    elif [[ $global_expire != "$expire" ]]; then
      warn "role ${gid}: wants ${expire}-day links, the global policy enforces ${global_expire} days - core Nextcloud applies ONE global expiry to all roles, so ${expire} days cannot be enforced per role (to honour it for everybody set LINK_EXPIRE_DAYS=${expire} and run make configure)"
      drift=1
    fi
  fi
  if [[ $edit == 0 && $global_upload == yes ]]; then
    log "role ${gid}: public edit disabled per policy; uploads are still allowed globally"
  fi
  if [[ $reshare == 0 && $global_reshare == yes ]]; then
    warn "role ${gid} forbids resharing but the global policy allows it"
    drift=1
  fi
  if [[ $remote == 0 && $federated_enabled == 1 ]]; then
    error "role ${gid} forbids remote shares but the federation app is enabled - run make configure"
    drift=1
  fi
  if (( drift == 0 )); then
    ok "role ${gid}: share policy is compatible with the global policy"
    VERIFIED=$(( VERIFIED + 1 ))
  else
    SKIPPED=$(( SKIPPED + 1 ))
  fi
}

# occ config:system:get with a safe fallback
occ_get() {
  local value
  value=$(occ config:system:get "$1" 2>/dev/null | head -n 1 || true)
  printf '%s' "$value"
}

app_enabled() {
  # Avoid pipefail+SIGPIPE false negatives: grep -q closes the pipe early, the
  # upstream sed gets SIGPIPE and the pipeline reports failure.
  local enabled
  enabled=$(occ app:list 2>/dev/null | sed -n '/^Enabled:/,/^Disabled:/p' || true)
  [[ $enabled == *"  - ${1}:"* ]]
}

store_policy() {
  local policy_json=$1 groups_csv=$2
  section "store the resolved policy in the cloudsuite app config"
  if is_dry_run; then
    printf '%s[dry-run]%s occ config:app:set cloudsuite rbac_roles --value=<%s bytes>\n' "${C_YELLOW}" "${C_RESET}" "${#policy_json}" >&2
    return 0
  fi
  if ! occ config:app:set cloudsuite rbac_roles --value="$policy_json" >/dev/null 2>&1; then
    error "cannot store cloudsuite/rbac_roles"
    FAILED=$(( FAILED + 1 ))
    return 1
  fi
  occ config:app:set cloudsuite rbac_version --value="1" >/dev/null 2>&1 || true
  occ config:app:set cloudsuite rbac_synced_at --value="$(timestamp_iso)" >/dev/null 2>&1 || true
  occ config:app:set cloudsuite rbac_managed_groups --value="$groups_csv" >/dev/null 2>&1 || true
  APPLIED=$(( APPLIED + 1 ))
  local stored
  stored=$(occ config:app:get cloudsuite rbac_roles 2>/dev/null || true)
  if [[ $stored == "$policy_json" ]]; then
    ok "policy stored (rbac_roles, ${#stored} bytes)"
    VERIFIED=$(( VERIFIED + 1 ))
  else
    error "stored policy does not match the source file"
    FAILED=$(( FAILED + 1 ))
  fi
  return 0
}

prune_groups() {
  local current_csv=$1 previous old gid members
  previous=$(occ config:app:get cloudsuite rbac_managed_groups 2>/dev/null || true)
  [[ -n $previous ]] || { log "no previously managed groups recorded - nothing to prune"; return 0; }
  section "prune groups removed from the policy"
  IFS=',' read -r -a old <<< "$previous"
  IFS=',' read -r -a current <<< "$current_csv"
  local stale is_current
  for gid in "${old[@]:-}"; do
    [[ -n $gid ]] || continue
    is_current=0
    for stale in "${current[@]:-}"; do
      [[ $stale == "$gid" ]] && is_current=1
    done
    (( is_current == 1 )) && continue
    if is_dry_run; then
      printf '%s[dry-run]%s occ group:delete %s (only if empty)\n' "${C_YELLOW}" "${C_RESET}" "$gid" >&2
      continue
    fi
    if ! json_groups_have "$TMP_DIR/groups.json" "$gid"; then
      log "group ${gid} is already gone"
      continue
    fi
    members=$(group_field "$TMP_DIR/groups.json" "$gid" "users" | tr -d '[:space:]')
    if [[ -n $members ]]; then
      warn "group ${gid} is no longer in the policy but still has members - move them first, then re-run with --prune"
      SKIPPED=$(( SKIPPED + 1 ))
      continue
    fi
    if occ group:delete "$gid" >/dev/null 2>&1; then
      APPLIED=$(( APPLIED + 1 ))
      ok "group ${gid} deleted (was managed, empty, removed from the policy)"
    else
      FAILED=$(( FAILED + 1 ))
      error "cannot delete group ${gid}"
    fi
  done
}

print_summary() {
  section "summary"
  printf 'roles          : %d\n' "${#MANAGED_GROUPS[@]}"
  printf 'applied        : %d\n' "$APPLIED"
  printf 'verified       : %d\n' "$VERIFIED"
  printf 'skipped        : %d\n' "$SKIPPED"
  printf 'failed         : %d\n' "$FAILED"
  if (( FAILED > 0 )); then
    error "RBAC synchronisation finished with ${FAILED} failure(s)"
    return 1
  fi
  ok "RBAC is synchronised"
  hint "assign users: occ group:add-member <group> <user>  (or the admin UI)"
  hint "policy details: docs/04-rbac-and-sharing.md"
  return 0
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --file) ROLES_FILE=${2:?--file needs a path}; shift 2 ;;
      --apply-quotas) APPLY_QUOTAS=1; shift ;;
      --prune) PRUNE=1; shift ;;
      --strict) STRICT=1; shift ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker python3
  [[ -n $ROLES_FILE ]] || ROLES_FILE="${CLOUDSUITE_ROOT}/config/rbac/roles.yaml"
  [[ -f $ROLES_FILE ]] || die "RBAC policy not found: ${ROLES_FILE}"

  TMP_DIR=$(mktemp -d)
  register_cleanup rm -rf -- "$TMP_DIR"

  section "validate ${ROLES_FILE}"
  local -a check_args=(--mode check)
  (( STRICT == 1 )) && check_args+=(--strict)
  if ! python3 "${CLOUDSUITE_LIB_DIR}/rbac.py" "${check_args[@]}" "$ROLES_FILE"; then
    die "the RBAC policy is invalid - fix it before syncing" 1
  fi

  python3 "${CLOUDSUITE_LIB_DIR}/rbac.py" --mode tsv "$ROLES_FILE" > "$TMP_DIR/roles.tsv"
  python3 "${CLOUDSUITE_LIB_DIR}/rbac.py" --mode policy "$ROLES_FILE" > "$TMP_DIR/policy.json"
  python3 "${CLOUDSUITE_LIB_DIR}/rbac.py" --mode groups "$ROLES_FILE" > "$TMP_DIR/groups.txt"

  if ! service_running app; then
    die "the app container is not running - start the stack first (make up)"
  fi
  if ! is_dry_run && ! wait_for_occ 180; then
    die "occ is not answering inside the app container (check: make logs-app)"
  fi

  section "current groups"
  if is_dry_run; then
    printf '{}' > "$TMP_DIR/groups.json"
    log "[dry-run] occ group:list --output=json"
  else
    GROUPS_JSON=$(occ group:list --output=json 2>/dev/null || true)
    if [[ -z $GROUPS_JSON ]]; then
      die "cannot list Nextcloud groups (occ group:list --output=json failed)"
    fi
    printf '%s' "$GROUPS_JSON" > "$TMP_DIR/groups.json"
    ok "loaded ${#GROUPS_JSON} bytes of group data"
  fi

  section "apply roles"
  local gid display quota delegated links pwd expire edit reshare remote
  while IFS="$TAB" read -r gid display quota delegated links pwd expire edit reshare remote; do
    [[ -n $gid ]] || continue
    MANAGED_GROUPS+=("$gid")
    log "role ${gid}: quota=${quota} links=${links} password=${pwd} expire=${expire}d edit=${edit} reshare=${reshare} remote=${remote}"
    ensure_group "$gid" "$display" || continue
    apply_delegated_admins "$gid" "$delegated"
    if (( APPLY_QUOTAS == 1 )); then
      apply_quotas "$gid" "$quota"
    fi
    check_share_policy "$gid" "$links" "$pwd" "$expire" "$edit" "$reshare" "$remote"
  done < "$TMP_DIR/roles.tsv"

  local groups_csv
  groups_csv=$(paste -sd, "$TMP_DIR/groups.txt")
  if (( PRUNE == 1 )); then
    prune_groups "$groups_csv"
  fi
  store_policy "$(cat "$TMP_DIR/policy.json")" "$groups_csv"

  if ! print_summary; then
    exit 1
  fi
  if is_dry_run; then
    warn "dry-run: nothing was changed"
  fi
  exit 0
}

main "$@"
