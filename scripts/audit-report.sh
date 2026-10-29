#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - audit report from the admin_audit JSON-lines log
#  ---------------------------------------------------------------------------
#  Source resolution order:
#    1. --file PATH
#    2. AUDIT_LOG_FILE environment variable
#    3. ./logs/cloudsuite/audit.log on the host (bind mount of /var/log/cloudsuite)
#    4. docker compose exec -T app cat /var/log/cloudsuite/audit.log
#
#  Requires python3 (stdlib only) for JSON parsing and aggregation.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "audit-report.sh"

AUDIT_FILE=""
FROM_DATE=""
TO_DATE=""
USER_FILTER=""
ACTION_FILTER=""
IP_FILTER=""
LIMIT=0
CSV=0
LIST=0
JSON_OUT=0
QUIET=0

usage() {
  cat <<'USAGE'
audit-report.sh - summarise Nextcloud admin_audit events (JSON lines)

Usage:
  ./scripts/audit-report.sh [options]

Filters:
  --file PATH        audit log to read (see the source resolution order above)
  --from DATE        only events at/after DATE (YYYY-MM-DD or ISO-8601)
  --to DATE          only events at/before DATE (YYYY-MM-DD or ISO-8601)
  --user UID         only events of one user id
  --action NAME      only events with this action (see the derived names below)
  --ip ADDRESS       only events from this remote address
  --limit N          print at most N matching events (0 = all)

Output:
  --csv              print matching events as CSV on stdout (RFC 4180 quoting)
  --list             print the distinct actions/users found in the log
  --json             print the summary as JSON on stdout
  -q, --quiet        no summary on stderr
  -h, --help         show this help and exit

The admin_audit log of Nextcloud 35 has no "action" field: the event type is
only in the human readable "message" (e.g. "File X has been downloaded").
audit-report.sh therefore derives the action from the message when the log
does not carry one.  Derived names:
  file_access, file_download, file_delete, file_create, file_update,
  file_rename, file_restore, file_move, file_share, file_unshare,
  login, console_command, app_enable, app_disable, password_change,
  user_create, user_delete, quota_change, other

Examples:
  ./scripts/audit-report.sh --from 2026-01-01 --action file_download
  ./scripts/audit-report.sh --user alice --csv > alice-audit.csv
  ./scripts/audit-report.sh --list

Exit codes: 0 ok, 1 no audit log found / read error, 2 usage error.
USAGE
}

resolve_source() {
  local candidate
  if [[ -n $AUDIT_FILE ]]; then
    [[ -r $AUDIT_FILE ]] || die "cannot read audit log: ${AUDIT_FILE}"
    printf '%s' "$AUDIT_FILE"
    return 0
  fi
  if [[ -n ${AUDIT_LOG_FILE:-} ]]; then
    [[ -r $AUDIT_LOG_FILE ]] || die "AUDIT_LOG_FILE is set but not readable: ${AUDIT_LOG_FILE}"
    printf '%s' "$AUDIT_LOG_FILE"
    return 0
  fi
  candidate="${CLOUDSUITE_ROOT}/logs/cloudsuite/audit.log"
  if [[ -r $candidate ]]; then
    printf '%s' "$candidate"
    return 0
  fi
  printf 'docker'
}

require_python() {
  require_cmd python3
  python3 -c 'import json, sys' >/dev/null 2>&1 || die "python3 is required (stdlib only)"
}

run_report() {
  local source=$1
  local mode=summary
  if (( CSV == 1 )); then mode=csv; fi
  if (( LIST == 1 )); then mode=list; fi
  if (( JSON_OUT == 1 )); then mode=json; fi
  local input
  if [[ $source == docker ]]; then
    if ! service_running app; then
      die "no host audit log at ${CLOUDSUITE_ROOT}/logs/cloudsuite/audit.log and the app container is not running"
    fi
    input=$(mktemp)
    register_cleanup rm -f -- "$input"
    if ! compose exec -T app cat /var/log/cloudsuite/audit.log > "$input" 2>/dev/null; then
      die "cannot read /var/log/cloudsuite/audit.log from the app container (has admin_audit logged anything yet?)"
    fi
  else
    input=$source
  fi

  AUDIT_INPUT=$input \
  AUDIT_MODE=$mode \
  AUDIT_FROM=$FROM_DATE \
  AUDIT_TO=$TO_DATE \
  AUDIT_USER=$USER_FILTER \
  AUDIT_ACTION=$ACTION_FILTER \
  AUDIT_IP=$IP_FILTER \
  AUDIT_LIMIT=$LIMIT \
  AUDIT_QUIET=$QUIET \
  python3 - <<'PY'
import csv
import json
import os
import sys
from collections import Counter
from datetime import datetime, timezone

path = os.environ["AUDIT_INPUT"]
mode = os.environ["AUDIT_MODE"]
limit = int(os.environ["AUDIT_LIMIT"] or 0)
quiet = os.environ["AUDIT_QUIET"] == "1"


def parse_bound(value, end_of_day):
    if not value:
        return None
    text = value.strip()
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S", "%Y-%m-%d"):
        try:
            parsed = datetime.strptime(text, fmt)
        except ValueError:
            continue
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        if fmt == "%Y-%m-%d" and end_of_day:
            parsed = parsed.replace(hour=23, minute=59, second=59)
        return parsed
    raise SystemExit("audit-report: cannot parse date %r (use YYYY-MM-DD or ISO-8601)" % value)


# Nextcloud 35 writes only a human readable message; the event type is
# derived from it.  Order matters: the first phrase that matches wins, so
# the more specific verbs come first ("shared file ... accessed" is an
# access, not a share).
ACTION_ALIASES = {
    "file_access": ("has been accessed", "accessed"),
    "file_download": ("downloaded", "download"),
    "file_delete": ("deleted", "delete"),
    "file_create": ("created", "create"),
    "file_update": ("updated", "update", "modified"),
    "file_rename": ("renamed", "rename"),
    "file_restore": ("restored", "restore"),
    "file_move": ("moved", "move"),
    "file_share": ("shared", "share"),
    "file_unshare": ("unshared", "unshare"),
    "login": ("logged in", "login", "logged out"),
    "console_command": ("console command", "occ "),
    "app_enable": ("app enabled", "enabled app", "enabled for all users"),
    "app_disable": ("app disabled", "disabled app", "disabled for all users"),
    "password_change": ("password changed", "changed password", "new password"),
    "user_create": ("user created", "created user"),
    "user_delete": ("user deleted", "deleted user"),
    "quota_change": ("quota",),
}


def derive_action(record):
    """Return the event action: the log field when present, else the message."""
    explicit = str(record.get("action", "") or "").strip()
    if explicit:
        return explicit
    message = str(record.get("message", "") or "").strip().lower()
    if not message:
        return ""
    for name, phrases in ACTION_ALIASES.items():
        for phrase in phrases:
            if phrase in message:
                return name
    return "other"


def canonical_action(wanted):
    """Map an alias such as "downloaded" to its canonical name."""
    if wanted in ACTION_ALIASES:
        return wanted
    for name, phrases in ACTION_ALIASES.items():
        if wanted in phrases:
            return name
    return None


def action_matches(record, wanted):
    if not wanted:
        return True
    wanted = wanted.strip().lower()
    derived = derive_action(record).lower()
    canonical = canonical_action(wanted)
    if canonical:
        # An exact canonical match only: "file_share" must not also match
        # the "shared file ... has been accessed" message.
        return derived == canonical
    if derived not in ("", "other"):
        return False
    message = str(record.get("message", "") or "").lower()
    return wanted.replace("_", " ") in message or wanted in message


date_from = parse_bound(os.environ.get("AUDIT_FROM", ""), False)
date_to = parse_bound(os.environ.get("AUDIT_TO", ""), True)
user_filter = os.environ.get("AUDIT_USER", "").strip()
action_filter = os.environ.get("AUDIT_ACTION", "").strip()
ip_filter = os.environ.get("AUDIT_IP", "").strip()

events = []
bad_lines = 0
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except ValueError:
            bad_lines += 1
            continue
        if not isinstance(record, dict):
            bad_lines += 1
            continue
        events.append(record)

matched = []
for record in events:
    event_user = str(record.get("user", "") or "")
    event_ip = str(record.get("remoteAddr", "") or record.get("ip", "") or "")
    if user_filter and event_user != user_filter:
        continue
    if not action_matches(record, action_filter):
        continue
    if ip_filter and event_ip != ip_filter:
        continue
    if date_from or date_to:
        stamp = record.get("time") or record.get("timestamp") or record.get("@timestamp")
        if not stamp:
            continue
        try:
            when = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        except ValueError:
            continue
        if when.tzinfo is None:
            when = when.replace(tzinfo=timezone.utc)
        if date_from and when < date_from:
            continue
        if date_to and when > date_to:
            continue
    matched.append(record)

if limit > 0:
    matched = matched[:limit]

CSV_FIELDS = ["time", "user", "action", "remoteAddr", "method", "url", "message", "app", "reqId"]

if mode == "csv":
    writer = csv.DictWriter(sys.stdout, fieldnames=CSV_FIELDS, extrasaction="ignore", quoting=csv.QUOTE_MINIMAL)
    writer.writeheader()
    for record in matched:
        row = {field: record.get(field, "") for field in CSV_FIELDS}
        row["action"] = derive_action(record)
        if not row["remoteAddr"]:
            row["remoteAddr"] = record.get("ip", "")
        writer.writerow({key: ("" if value is None else str(value)) for key, value in row.items()})
elif mode == "list":
    actions = Counter(derive_action(r) or "(none)" for r in matched)
    users = Counter(str(r.get("user", "") or "(anonymous)") for r in matched)
    print("actions:")
    for name, count in actions.most_common():
        print("  %-28s %d" % (name, count))
    print("users:")
    for name, count in users.most_common():
        print("  %-28s %d" % (name, count))
elif mode == "json":
    summary = {
        "total_events": len(events),
        "matched": len(matched),
        "unparsable_lines": bad_lines,
        "by_action": dict(Counter(derive_action(r) or "(none)" for r in matched)),
        "by_user": dict(Counter(str(r.get("user", "") or "(anonymous)") for r in matched)),
        "by_day": dict(sorted(Counter(str(r.get("time", ""))[:10] for r in matched).items())),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
else:
    by_action = Counter(derive_action(r) or "(none)" for r in matched)
    by_user = Counter(str(r.get("user", "") or "(anonymous)") for r in matched)
    by_day = Counter(str(r.get("time", ""))[:10] for r in matched)
    print("audit log     : %s" % path)
    print("events total  : %d" % len(events))
    print("unparsable    : %d" % bad_lines)
    print("matched       : %d" % len(matched))
    if matched:
        print("\ntop actions:")
        for name, count in by_action.most_common(10):
            print("  %-28s %d" % (name, count))
        print("\ntop users:")
        for name, count in by_user.most_common(10):
            print("  %-28s %d" % (name, count))
        print("\nby day:")
        for day, count in sorted(by_day.items()):
            print("  %-28s %d" % (day or "(no timestamp)", count))

if not quiet and mode != "summary":
    print("audit-report: %d event(s) matched of %d read from %s" % (len(matched), len(events), path), file=sys.stderr)
if matched and mode == "summary" and len(matched) == 0:
    print("audit-report: no events matched the filters", file=sys.stderr)
PY
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --file) AUDIT_FILE=${2:?--file needs a path}; shift 2 ;;
      --from) FROM_DATE=${2:?--from needs a date}; shift 2 ;;
      --to) TO_DATE=${2:?--to needs a date}; shift 2 ;;
      --user) USER_FILTER=${2:?--user needs a uid}; shift 2 ;;
      --action) ACTION_FILTER=${2:?--action needs a name}; shift 2 ;;
      --ip) IP_FILTER=${2:?--ip needs an address}; shift 2 ;;
      --limit) LIMIT=${2:?--limit needs a number}; shift 2 ;;
      --csv) CSV=1; shift ;;
      --list) LIST=1; shift ;;
      --json) JSON_OUT=1; shift ;;
      -q|--quiet) QUIET=1; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done
  [[ $LIMIT =~ ^[0-9]+$ ]] || die "--limit expects a number" 2
  require_python
  local source
  source=$(resolve_source)
  run_report "$source"
}

main "$@"
