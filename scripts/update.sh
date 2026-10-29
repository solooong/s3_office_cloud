#!/usr/bin/env bash
# =============================================================================
#  Cloud Suite - controlled update of the running stack
#  ---------------------------------------------------------------------------
#  Sequence (every step aborts on failure, nothing is skipped silently):
#    1. record the current image digests and Nextcloud version (rollback data)
#    2. create a full backup (skip with --skip-backup at your own risk)
#    3. docker compose pull (new digests for the pinned tags in .env)
#    4. docker compose up -d, wait for healthy containers
#    5. occ upgrade + maintenance:repair + maintenance:mode --off
#    6. healthcheck.sh
#    7. print the rollback commands
#
#  Versions are changed ONLY by editing the *_VERSION variables in .env; this
#  script never rewrites .env, so every change stays reviewable in git history.
# =============================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
cs_set_script_name "update.sh"

SKIP_BACKUP=0
DO_PULL=1
SKIP_HEALTHCHECK=0
STATE_DIR=""
STARTED_AT=$(date +%s)

usage() {
  cat <<'USAGE'
update.sh - update the Cloud Suite stack in a controlled way

Usage:
  ./scripts/update.sh [options]

Options:
      --yes               do not ask for confirmation (for automation)
      --skip-backup       do not create a backup first (not recommended)
      --no-pull           do not pull images (recreate with the current ones)
      --skip-healthcheck  do not run scripts/healthcheck.sh at the end
  -n, --dry-run           print the plan, change nothing
  -h, --help              show this help and exit

Rollback data is written to logs/update-<timestamp>/rollback.env before the
first change.  To roll back: restore that file's digests (commands are printed)
and rerun this script, or restore the backup with scripts/restore.sh.

Exit codes: 0 success, 1 failure before the stack was changed, 2 the stack is
in an unknown state and needs manual attention (rollback commands printed).
USAGE
}

state_dir() {
  printf '%s/logs/update-%s' "${CLOUDSUITE_ROOT}" "$(timestamp_compact)"
}

capture_state() {
  local dir=$1 image digest
  mkdir -p "$dir"
  chmod 750 "$dir" 2>/dev/null || true
  {
    printf 'UPDATE_TIMESTAMP=%s\n' "$(timestamp_iso)"
    printf 'PROJECT=%s\n' "${COMPOSE_PROJECT_NAME:-cloudsuite}"
    printf 'NEXTCLOUD_VERSION=%s\n' "${NEXTCLOUD_VERSION:-}"
    printf 'ONLYOFFICE_VERSION=%s\n' "${ONLYOFFICE_VERSION:-}"
    printf 'POSTGRES_VERSION=%s\n' "${POSTGRES_VERSION:-}"
    printf 'REDIS_VERSION=%s\n' "${REDIS_VERSION:-}"
    printf 'NGINX_VERSION=%s\n' "${NGINX_VERSION:-}"
    printf 'NPM_VERSION=%s\n' "${NPM_VERSION:-}"
    printf 'SEAWEEDFS_VERSION=%s\n' "${SEAWEEDFS_VERSION:-}"
  } > "$dir/rollback.env"
  : > "$dir/images.before.txt"
  while IFS= read -r image; do
    [[ -n $image ]] || continue
    digest=$(docker image inspect -f '{{index .RepoDigests 0}}' "$image" 2>/dev/null || true)
    if [[ -z $digest ]]; then digest="not-present-locally"; fi
    printf '%s %s\n' "$image" "$digest" >> "$dir/images.before.txt"
  done < <(compose config --images 2>/dev/null | sort -u)
  if [[ -s $dir/images.before.txt ]]; then
    ok "rollback data: ${dir}/images.before.txt ($(wc -l < "$dir/images.before.txt" | tr -d ' ') images)"
  else
    warn "could not record the current images (docker compose config --images returned nothing)"
  fi
  printf '%s\n' "$dir"
}

run_backup() {
  if (( SKIP_BACKUP == 1 )); then
    warn "backup skipped (--skip-backup) - updates without a backup are not recoverable"
    return 0
  fi
  section "backup before the update"
  if "${SCRIPT_DIR}/backup.sh" --no-offsite; then
    ok "backup finished (see ${BACKUP_DIR:-./backups}/LATEST)"
  else
    die "backup failed - update aborted before any change"
  fi
}

pull_images() {
  if (( DO_PULL == 0 )); then
    log "image pull skipped (--no-pull)"
    return 0
  fi
  section "pull images"
  if ! compose pull 2>&1 | tail -n 20; then
    die "docker compose pull failed - update aborted before any change"
  fi
  ok "images pulled"
}

recreate() {
  section "recreate containers"
  compose up -d 2>&1 | tail -n 30
  local service
  for service in db cache s3 app web onlyoffice proxy; do
    if wait_for_service_healthy "$service" 420; then
      ok "${service} is healthy"
    else
      warn "${service} did not become healthy within 420s"
      return 1
    fi
  done
  return 0
}

upgrade_nextcloud() {
  section "occ upgrade"
  local out
  if ! out=$(compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ upgrade --no-interaction 2>&1); then
    error "occ upgrade failed:"
    printf '%s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$out" | tail -n 15
  ok "occ upgrade completed"
  compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ maintenance:mode --off >/dev/null 2>&1 || true
  if compose exec -T -u "${CLOUDSUITE_OCC_USER}" app php occ maintenance:repair --no-interaction >/dev/null 2>&1; then
    ok "occ maintenance:repair completed"
  else
    warn "occ maintenance:repair reported errors - run it manually"
  fi
  return 0
}

print_rollback() {
  local dir=$1
  section "rollback instructions"
  printf 'previous images: %s/images.before.txt\n' "$dir"
  printf 'backup:          %s/LATEST (restore with ./scripts/restore.sh --confirm)\n' "${BACKUP_DIR:-./backups}"
  cat <<EOF

Roll back the images only (no data change):
  1. re-pin the previous digests, e.g. for every line in ${dir}/images.before.txt:
       docker pull <image>@<digest>
       docker tag  <image>@<digest> <image>
  2. docker compose up -d --force-recreate
  3. ./scripts/healthcheck.sh

Roll back images and data:
  ./scripts/restore.sh --dir ${BACKUP_DIR:-./backups}/LATEST --confirm

Nextcloud app downgrades are NOT supported: if occ upgrade changed the
database schema, restoring the backup is the only supported rollback.
EOF
}

main() {
  while (( $# > 0 )); do
    case $1 in
      --yes) assume_yes; shift ;;
      --skip-backup) SKIP_BACKUP=1; shift ;;
      --no-pull) DO_PULL=0; shift ;;
      --skip-healthcheck) SKIP_HEALTHCHECK=1; shift ;;
      -n|--dry-run) set_dry_run; shift ;;
      -h|--help|help) usage; exit 0 ;;
      -V|--version) print_version; exit 0 ;;
      *) die "unknown argument: $1 (try --help)" 2 ;;
    esac
  done

  ensure_env
  CLOUDSUITE_ENV_KEEP_EXISTING=0
  load_env "${CLOUDSUITE_ENV_FILE}"
  require_cmd docker

  section "Cloud Suite update plan"
  printf 'project        : %s\n' "${COMPOSE_PROJECT_NAME:-cloudsuite}"
  printf 'nextcloud      : %s\n' "${NEXTCLOUD_VERSION:-}"
  printf 'onlyoffice     : %s\n' "${ONLYOFFICE_VERSION:-}"
  printf 'postgres       : %s\n' "${POSTGRES_VERSION:-}"
  printf 'redis          : %s\n' "${REDIS_VERSION:-}"
  printf 'nginx / npm    : %s / %s\n' "${NGINX_VERSION:-}" "${NPM_VERSION:-}"
  printf 'seaweedfs      : %s\n' "${SEAWEEDFS_VERSION:-}"
  printf 'pull images    : %s\n' "$(if (( DO_PULL == 1 )); then echo yes; else echo no; fi)"
  printf 'backup first   : %s\n' "$(if (( SKIP_BACKUP == 1 )); then echo NO; else echo yes; fi)"

  if is_dry_run; then
    warn "dry-run: nothing was changed"
    exit 0
  fi

  confirm "Update the running stack now?" || die "aborted by the operator"
  acquire_lock update

  STATE_DIR=$(state_dir)
  capture_state "$STATE_DIR" >/dev/null

  run_backup
  pull_images

  if ! recreate; then
    error "containers did not become healthy - the stack needs attention"
    print_rollback "$STATE_DIR"
    exit 2
  fi
  if ! upgrade_nextcloud; then
    error "Nextcloud upgrade failed - the stack needs attention"
    print_rollback "$STATE_DIR"
    exit 2
  fi

  if (( SKIP_HEALTHCHECK == 0 )); then
    section "health check"
    if "${SCRIPT_DIR}/healthcheck.sh"; then
      ok "health check passed"
    else
      warn "health check reported failures - review the output above"
    fi
  fi

  section "update report"
  printf 'duration : %s\n' "$(human_seconds $(( $(date +%s) - STARTED_AT )))"
  printf 'state    : %s\n' "$STATE_DIR"
  print_rollback "$STATE_DIR"
  ok "update finished"
}

main "$@"
