# =============================================================================
#  Cloud Suite - self-hosted file platform (Nextcloud + ONLYOFFICE + SeaweedFS)
#  -----------------------------------------------------------------------------
#  make            show this help (default target)
#  make bootstrap  first run: .env, secrets, directories, validation
#
#  Everything is phony; every target that needs the stack depends on
#  "require-env", which fails with a clear message when .env is missing.
# =============================================================================

.DEFAULT_GOAL := help
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# --- configuration -----------------------------------------------------------
# COMPOSE can be overridden to add an overlay, for example:
#   make up COMPOSE="docker compose -f docker-compose.yml -f docker-compose.admin.yml"
COMPOSE ?= docker compose
COMPOSE_FILES ?= -f docker-compose.yml
ENV_FILE ?= .env
COMPOSE_CMD ?= $(COMPOSE) $(COMPOSE_FILES) --env-file $(ENV_FILE)
SCRIPTS := ./scripts
PYTHON ?= python3
SHELLCHECK ?= shellcheck
ENV_CI ?= .env.ci
# --- local (no-domain) run ---------------------------------------------------
LOCAL_ENV_FILE ?= .env.local
LOCAL_COMPOSE_FILES ?= -f docker-compose.yml -f docker-compose.local.yml
LOCAL_COMPOSE_CMD ?= $(COMPOSE) $(LOCAL_COMPOSE_FILES) --env-file $(LOCAL_ENV_FILE)
# --- white-IP run (no domain, no hosting) ------------------------------------
IP_ENV_FILE ?= .env.ip
IP_COMPOSE_FILES ?= -f docker-compose.yml -f docker-compose.ip.yml
IP_COMPOSE_CMD ?= $(COMPOSE) $(IP_COMPOSE_FILES) --env-file $(IP_ENV_FILE)
ARGS ?=
SERVICE ?=

.PHONY: help default bootstrap up down admin-up admin-down restart ps logs status \
        doctor test test-compose env-ci lint backup restore migrate update \
        configure rbac prune-versions prune-versions-dry-run audit-report smoke \
        healthcheck occ shell-app shell-db require-env clean nuke \
        local-env local-hosts local-up local-down local-ps local-logs local-configure \
        local-check require-local-env \
        ip-env ip-up ip-down ip-ps ip-logs ip-configure ip-check ip-route require-ip-env

# --- meta --------------------------------------------------------------------
help: ## show this help
	@printf '\nCloud Suite - self-hosted file platform\n\n'
	@printf 'Usage: make <target> [ARGS="..."] [SERVICE=<name>]\n\n'
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z0-9_-]+:.*## / {printf "  \033[36m%-24s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@printf '\nExamples:\n'
	@printf '  make bootstrap                 first run (creates .env, secrets, dirs)\n'
	@printf '  make up && make status         start the stack and check it\n'
	@printf '  make admin-up                  start with the admin overlay (NPM GUI, SeaweedFS UI)\n'
	@printf '  make configure rbac            provision Nextcloud + apply RBAC\n'
	@printf '  make backup                    full backup into ./backups\n'
	@printf '  make restore ARGS="--dir backups/LATEST --confirm"\n'
	@printf '  make smoke                     end-to-end proof\n'
	@printf '  make audit-report ARGS="--from 2026-01-01 --action file_download"\n'
	@printf '  make local-env local-hosts     локальный запуск без домена (http://cloud.local)\n'
	@printf '  make ip-env ip-up              запуск на белом IP без домена (http://PUBLIC_IP)\n'
	@printf '  make test lint                 validation gates used by CI\n'
	@printf '  make test-compose              render every compose combination\n\n'

default: help ## alias for help

require-env:
	@test -f $(ENV_FILE) || { printf '\nERROR: %s is missing.\n  Run: make bootstrap  (it creates .env from .env.example)\n\n' "$(ENV_FILE)"; exit 1; }
	@grep -q '^POSTGRES_PASSWORD=.\{1,\}' $(ENV_FILE) || { printf '\nERROR: secrets are empty in %s.\n  Run: ./scripts/generate-secrets.sh\n\n' "$(ENV_FILE)"; exit 1; }

# --- lifecycle ---------------------------------------------------------------
bootstrap: ## first run: .env, secrets, directories, validation (idempotent)
	@$(SCRIPTS)/bootstrap.sh $(ARGS)

up: require-env ## start (or create) the whole stack
	@$(COMPOSE_CMD) up -d --remove-orphans
	@printf '\nStack is starting. Next steps:\n  make status    container and service health\n  make logs      follow the logs\n'

down: require-env ## stop and remove containers and networks (VOLUMES ARE KEPT)
	@$(COMPOSE_CMD) down --remove-orphans
	@printf '\nContainers removed, data volumes kept. Start again with: make up\n'

admin-up: require-env ## start with the admin overlay (NPM GUI, SeaweedFS filer, S3 master)
	@$(COMPOSE) -f docker-compose.yml -f docker-compose.admin.yml --env-file $(ENV_FILE) up -d --remove-orphans
	@printf '\nAdmin overlay started. Endpoints (knobs live in docker-compose.admin.yml):\n'
	@printf '  NPM admin GUI    http://127.0.0.1:8181   (NPM_ADMIN_BIND / NPM_ADMIN_PORT)\n'
	@printf '  SeaweedFS filer  http://127.0.0.1:8888   (SEAWEEDFS_ADMIN_BIND_LAN / SEAWEEDFS_FILER_PORT)\n'
	@printf '  SeaweedFS master http://127.0.0.1:9333\n'
	@printf '  Prefer a tunnel: ssh -L 8181:127.0.0.1:8181 <host>\n'

admin-down: require-env ## stop the stack started with the admin overlay
	@$(COMPOSE) -f docker-compose.yml -f docker-compose.admin.yml --env-file $(ENV_FILE) down --remove-orphans

restart: require-env ## restart all containers
	@$(COMPOSE_CMD) restart

ps: require-env ## docker compose ps
	@$(COMPOSE_CMD) ps

logs: require-env ## follow logs (SERVICE=app for one service)
	@$(COMPOSE_CMD) logs -f --tail=200 $(SERVICE)

status: require-env ## container health, occ status, disk and memory
	@$(SCRIPTS)/healthcheck.sh --only services,occ,disk,memory

doctor: ## host preflight (CPU/RAM/disk/ports/DNS/sysctl/.env)
	@$(SCRIPTS)/preflight.sh $(ARGS)

# --- local run (no domain, no TLS) -------------------------------------------
require-local-env:
	@test -f $(LOCAL_ENV_FILE) || { printf '\nERROR: %s is missing.\n  Run: make local-env\n\n' "$(LOCAL_ENV_FILE)"; exit 1; }
	@grep -q '^POSTGRES_PASSWORD=.\{1,\}' $(LOCAL_ENV_FILE) || { printf '\nERROR: secrets are empty in %s.\n  Run: ./scripts/generate-secrets.sh --file %s\n\n' "$(LOCAL_ENV_FILE)" "$(LOCAL_ENV_FILE)"; exit 1; }

local-env: ## локальный запуск: создать .env.local из шаблона и заполнить секреты
	@test -f $(LOCAL_ENV_FILE) || cp .env.local.example $(LOCAL_ENV_FILE)
	@$(SCRIPTS)/generate-secrets.sh --file $(LOCAL_ENV_FILE)
	@printf '\n.env.local готов. Дальше: make local-up && make local-configure\n'
	@grep -E '^(NEXTCLOUD_ADMIN_USER|NEXTCLOUD_ADMIN_PASSWORD)=' $(LOCAL_ENV_FILE) | sed 's/^/  /' || true

local-hosts: require-local-env ## показать/добавить cloud.local и office.local в /etc/hosts
	@CLOUDSUITE_ENV_FILE=$(LOCAL_ENV_FILE) $(SCRIPTS)/local-hosts.sh $(ARGS)

local-up: require-local-env ## поднять локальный стек без домена (http://cloud.local:8080)
	@$(LOCAL_COMPOSE_CMD) up -d --remove-orphans
	@bash -c 'set -eu; eval "$$(grep -E "^(LOCAL_HOST|LOCAL_HTTP_PORT|LOCAL_OFFICE_PORT)=" "$(LOCAL_ENV_FILE)")"; \
	  printf "\nЛокальный стек запускается (профиль без домена и TLS):\n"; \
	  printf "  Nextcloud        http://%s:%s\n" "$$LOCAL_HOST" "$$LOCAL_HTTP_PORT"; \
	  printf "  ONLYOFFICE Docs  http://%s:%s\n" "$$LOCAL_HOST" "$$LOCAL_OFFICE_PORT"; \
	  printf "  NPM не запускается (профиль edge в docker-compose.local.yml)\n\n"; \
	  printf "  Дальше: make local-configure  (occ-настройки под локальные URL)\n"; \
	  printf "          make local-check      (проверка GUI по HTTP)\n"; \
	  printf "          make local-hosts      (если браузер не открывает %s)\n\n" "$LOCAL_HOST"'

local-down: require-local-env ## остановить локальный стек (VOLUMES=1 — удалить данные)
	@$(LOCAL_COMPOSE_CMD) down --remove-orphans $(if $(filter 1 yes true,$(VOLUMES)),--volumes)
	@printf '\nЛокальный стек остановлен. Данные сохранены в томах проекта (VOLUMES=1 удаляет их).\n'

local-ps: require-local-env ## docker compose ps локального стека
	@$(LOCAL_COMPOSE_CMD) ps

local-logs: require-local-env ## логи локального стека (SERVICE=app для одного сервиса)
	@$(LOCAL_COMPOSE_CMD) logs -f --tail=200 $(SERVICE)

local-configure: require-local-env ## применить occ-настройки к локальному стеку (без TLS)
	@CLOUDSUITE_ENV_FILE=$(LOCAL_ENV_FILE) \
	  CLOUDSUITE_COMPOSE_FILES="docker-compose.yml docker-compose.local.yml" \
	  $(SCRIPTS)/configure-nextcloud.sh $(ARGS)

local-check: require-local-env ## проверить локальный GUI: status.php, /login, ONLYOFFICE /healthcheck
	@bash -c 'set -eu; eval "$$(grep -E "^(LOCAL_HOST|LOCAL_HTTP_PORT|LOCAL_OFFICE_PORT)=" "$(LOCAL_ENV_FILE)")"; \
	  host_header="$$LOCAL_HOST"; base="http://127.0.0.1:$$LOCAL_HTTP_PORT"; \
	  code=$$(curl -sS -o /dev/null -w "%{http_code}" -H "Host: $$host_header" "$$base/status.php"); \
	  [ "$$code" = 200 ] || { printf "FAIL status.php: HTTP %s\n" "$$code"; exit 1; }; \
	  curl -fsS -H "Host: $$host_header" "$$base/status.php" | grep -q "\"installed\":true" \
	    || { printf "FAIL: Nextcloud is not installed yet (make local-up still booting?)\n"; exit 1; }; \
	  login=$$(curl -sS -o /dev/null -w "%{http_code}" -H "Host: $$host_header" "$$base/login"); \
	  case "$$login" in 200|302|303) : ;; *) printf "FAIL /login: HTTP %s\n" "$$login"; exit 1 ;; esac; \
	  office=$$(curl -sS -o /dev/null -w "%{http_code}" "http://127.0.0.1:$$LOCAL_OFFICE_PORT/healthcheck"); \
	  [ "$$office" = 200 ] || { printf "FAIL ONLYOFFICE /healthcheck: HTTP %s\n" "$$office"; exit 1; }; \
	  printf "OK  Nextcloud  http://%s:%s  (status.php 200, /login %s)\n" "$$LOCAL_HOST" "$$LOCAL_HTTP_PORT" "$$login"; \
	  printf "OK  ONLYOFFICE http://%s:%s  (/healthcheck 200)\n" "$$LOCAL_HOST" "$$LOCAL_OFFICE_PORT"'

# --- white-IP run (no domain, no hosting, plain HTTP) ----------------------
require-ip-env:
	@test -f $(IP_ENV_FILE) || { printf '\nERROR: %s is missing.\n  Run: make ip-env   (creates it from .env.ip.example)\n\n' "$(IP_ENV_FILE)"; exit 1; }
	@grep -q '^POSTGRES_PASSWORD=.\{1,\}' $(IP_ENV_FILE) || { printf '\nERROR: secrets are empty in %s.\n  Run: ./scripts/generate-secrets.sh --file %s\n\n' "$(IP_ENV_FILE)" "$(IP_ENV_FILE)"; exit 1; }
	@awk -F= '/^PUBLIC_IP=/{print $$2; exit}' $(IP_ENV_FILE) | tr -d '\r' | { read -r pub; \
	  case "$$pub" in ""|0.*|10.*|127.*|169.254.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) \
	    printf '\nERROR: PUBLIC_IP=%s is not a public (white) IPv4 address.\n  Set the globally routable IPv4 of the server in %s.\n  Loopback/private ranges break ONLYOFFICE callbacks (the browser must reach it).\n\n' "$$pub" "$(IP_ENV_FILE)"; exit 1;; \
	  esac; }

ip-env: ## запуск на белом IP: создать .env.ip из шаблона и заполнить секреты
	@test -f $(IP_ENV_FILE) || cp .env.ip.example $(IP_ENV_FILE)
	@$(SCRIPTS)/generate-secrets.sh --file $(IP_ENV_FILE)
	@printf '\n.env.ip готов. Проверьте PUBLIC_IP (и порты), затем: make ip-up && make ip-configure && make ip-check\n'
	@grep -E '^(PUBLIC_IP|IP_BIND|IP_HTTP_PORT|IP_OFFICE_PORT|NEXTCLOUD_ADMIN_USER|NEXTCLOUD_ADMIN_PASSWORD)=' $(IP_ENV_FILE) | sed 's/^/  /' || true

ip-up: require-ip-env ## поднять стек на белом IP (http://PUBLIC_IP/)
	@$(IP_COMPOSE_CMD) up -d --remove-orphans
	@printf '\nСтек на белом IP запускается (без домена и TLS): Nextcloud http://PUBLIC_IP/ , ONLYOFFICE http://PUBLIC_IP:8081/\n'
	@printf 'NPM не запускается (профиль edge в docker-compose.ip.yml).\n'
	@printf 'Дальше: make ip-configure (occ + маршрут callback-ов), затем make ip-check\n\n'

ip-down: require-ip-env ## остановить стек (VOLUMES=1 — удалить данные)
	@$(IP_COMPOSE_CMD) down --remove-orphans $(if $(filter 1 yes true,$(VOLUMES)),--volumes)
	@printf '\nСтек остановлен. Данные сохранены в томах проекта (VOLUMES=1 удаляет их).\n'

ip-ps: require-ip-env ## docker compose ps для стека на белом IP
	@$(IP_COMPOSE_CMD) ps

ip-logs: require-ip-env ## логи стека на белом IP (SERVICE=app для одного сервиса)
	@$(IP_COMPOSE_CMD) logs -f --tail=200 $(SERVICE)

ip-configure: require-ip-env ## occ-настройки + маршрут callback-ов для белого IP
	@CLOUDSUITE_ENV_FILE=$(IP_ENV_FILE) \
	  CLOUDSUITE_COMPOSE_FILES="docker-compose.yml docker-compose.ip.yml" \
	  $(SCRIPTS)/configure-nextcloud.sh $(ARGS)
	@CLOUDSUITE_ENV_FILE=$(IP_ENV_FILE) $(SCRIPTS)/ip-callback-route.sh

ip-route: require-ip-env ## (пере)создать маршрут callback-ов ONLYOFFICE -> web
	@CLOUDSUITE_ENV_FILE=$(IP_ENV_FILE) $(SCRIPTS)/ip-callback-route.sh $(ARGS)

ip-check: require-ip-env ## проверить GUI, редактор и callback на белом IP
	@CLOUDSUITE_ENV_FILE=$(IP_ENV_FILE) $(SCRIPTS)/ip-check.sh

# --- provisioning ------------------------------------------------------------
configure: require-env ## provision Nextcloud with occ (idempotent)
	@$(SCRIPTS)/configure-nextcloud.sh $(ARGS)

rbac: require-env ## apply config/rbac/roles.yaml (groups, admins, policy JSON)
	@$(SCRIPTS)/rbac-sync.sh $(ARGS)

prune-versions: require-env ## enforce VERSIONS_MAX versions per file
	@$(SCRIPTS)/prune-versions.sh $(ARGS)

prune-versions-dry-run: require-env ## show what prune-versions would delete
	@$(SCRIPTS)/prune-versions.sh --dry-run $(ARGS)

audit-report: require-env ## summarise the admin_audit log
	@$(SCRIPTS)/audit-report.sh $(ARGS)

# --- operations --------------------------------------------------------------
backup: require-env ## full backup (db + volumes + encrypted config)
	@$(SCRIPTS)/backup.sh $(ARGS)

restore: require-env ## restore a backup (needs ARGS="--dir ... --confirm")
	@$(SCRIPTS)/restore.sh $(ARGS)

migrate: require-env ## migrate Yandex.Disk via rclone (ARGS="--source yandex:disk --user alice")
	@$(SCRIPTS)/migrate-yandex-disk.sh $(ARGS)

update: require-env ## controlled update (backup, pull, up, occ upgrade)
	@$(SCRIPTS)/update.sh $(ARGS)

smoke: require-env ## end-to-end smoke test (WebDAV, links, versions, trash)
	@$(SCRIPTS)/smoke-test.sh $(ARGS)

healthcheck: require-env ## full health check
	@$(SCRIPTS)/healthcheck.sh $(ARGS)

occ: require-env ## run an occ command (ARGS="user:list")
	@$(SCRIPTS)/occ.sh $(ARGS)

shell-app: require-env ## shell inside the app container
	@$(COMPOSE_CMD) exec app bash

shell-db: require-env ## psql inside the database container
	@$(COMPOSE_CMD) exec db psql -U "$${POSTGRES_USER:-nextcloud}" -d "$${POSTGRES_DB:-nextcloud}"

# --- validation --------------------------------------------------------------
# The gates never touch .env or the running stack: a throw-away .env.ci is
# generated from .env.example (non-empty secrets) for the compose render.
test: ## static gates: bash -n, python validation, compose render with .env.ci
	@printf '\n== bash -n ==\n'
	@for f in $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh tests/*.sh; do bash -n "$$f" || exit 1; done
	@printf 'bash -n: %s shell scripts OK\n' "$$(ls $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh tests/*.sh | wc -l | tr -d ' ')"
	@printf '\n== tests/validate.py ==\n'
	@$(PYTHON) tests/validate.py
	@printf '\n== docker compose render (.env.ci) ==\n'
	@tests/generate-ci-env.sh
	@if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then \
	  $(COMPOSE) --env-file $(ENV_CI) -f docker-compose.yml config -q \
	    && printf 'compose config: base OK\n'; \
	  $(COMPOSE) --env-file $(ENV_CI) -f docker-compose.yml -f docker-compose.admin.yml config -q \
	    && printf 'compose config: base + admin OK\n'; \
	else \
	  printf 'SKIP: docker compose is not available - compose files were not rendered\n'; \
	fi

test-compose: ## render every compose combination (base, admin, observability)
	@tests/compose_render.sh

env-ci: ## regenerate the throw-away .env.ci used by make test and CI
	@tests/generate-ci-env.sh

lint: ## shellcheck every script (fails if shellcheck is missing)
	@command -v $(SHELLCHECK) >/dev/null || { printf 'ERROR: shellcheck is not installed.\n  Debian/Ubuntu: apt install shellcheck\n  or: make lint SHELLCHECK=/path/to/shellcheck\n'; exit 1; }
	@$(SHELLCHECK) -x -P SCRIPTDIR -s bash $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh tests/*.sh
	@$(PYTHON) -m py_compile $(SCRIPTS)/lib/*.py tests/validate.py
	@rm -rf $(SCRIPTS)/lib/__pycache__ tests/__pycache__
	@printf 'lint OK: %s shell scripts, %s python files\n' "$$(ls $(SCRIPTS)/*.sh $(SCRIPTS)/lib/*.sh tests/*.sh | wc -l | tr -d ' ')" "$$(ls $(SCRIPTS)/lib/*.py tests/validate.py | wc -l | tr -d ' ')"

# --- housekeeping ------------------------------------------------------------
clean: ## stop the stack, remove containers/networks and temp files (VOLUMES ARE KEPT)
	@$(COMPOSE_CMD) down --remove-orphans || true
	@rm -rf .tmp* tmp/ .cache/
	@find . -type d -name __pycache__ -prune -exec rm -rf {} + 2>/dev/null || true
	@find . -type f -name '*.pyc' -delete 2>/dev/null || true
	@printf 'clean: containers and networks removed, temp files deleted, volumes kept.\n'
	@printf '       Use "make nuke FORCE=yes" to also delete the data volumes.\n'

nuke: ## DESTRUCTIVE: remove containers AND volumes (requires FORCE=yes)
	@if [ "$${FORCE:-}" != "yes" ]; then printf 'refusing: this deletes all volumes (files, database, sessions).\n  Re-run: make nuke FORCE=yes\n'; exit 1; fi
	@$(COMPOSE_CMD) down --remove-orphans --volumes
	@printf 'nuke: containers and volumes removed. Host directories ./data ./backups kept.\n'
