#!/usr/bin/env python3
"""Cloud Suite - static repository validation.

Runs the checks that must pass before the stack is deployed.  Dependency-free
apart from PyYAML (apt: python3-yaml), so it works on a stock Ubuntu 24.04 /
Debian 12 host and in CI.

Usage:
  python3 tests/validate.py [--verbose] [--no-bash]

Exit codes: 0 all checks passed, 1 at least one check failed.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - environment problem, not a code path
    print("validate.py: PyYAML is required: apt install python3-yaml", file=sys.stderr)
    raise SystemExit(2)

ROOT = Path(__file__).resolve().parent.parent


def _exec_bit_checkable() -> bool:
    """False on a Windows checkout or on a Windows-mounted WSL path.

    NTFS/DrvFs does not store POSIX permission bits, so a correct 0755
    script still reports mode 0777 and a broken one looks the same.  The
    git index keeps the real mode (100755) for Linux and CI checkouts, so
    the exec bit is enforced there instead of in the working copy.
    """
    if os.name == "nt" or sys.platform.startswith("win"):
        return False
    try:
        mounts = Path("/proc/mounts").read_text(encoding="utf-8", errors="replace")
    except OSError:
        return True
    root_text = str(ROOT)
    best_mount = ""
    best_fs = ""
    for line in mounts.splitlines():
        parts = line.split()
        if len(parts) < 3:
            continue
        mount_point, fs_type = parts[1], parts[2]
        if root_text == mount_point or root_text.startswith(mount_point.rstrip("/") + "/"):
            if len(mount_point) >= len(best_mount):
                best_mount, best_fs = mount_point, fs_type
    foreign = {"drvfs", "9p", "cifs", "v9fs", "fuse.v9fs", "fuse.9p", "smbfs"}
    return best_fs not in foreign


EXEC_BIT_CHECKABLE = _exec_bit_checkable()

ERRORS: list[str] = []
WARNINGS: list[str] = []
CHECKS = 0
VERBOSE = False

# --- contract data -----------------------------------------------------------
CONTRACT_ENV = """
COMPOSE_PROJECT_NAME TZ
CLOUD_DOMAIN OFFICE_DOMAIN ACME_EMAIL HTTP_PORT HTTPS_PORT
NPM_ADMIN_BIND NPM_ADMIN_PORT NPM_ADMIN_EMAIL NPM_ADMIN_PASSWORD
NEXTCLOUD_ADMIN_USER NEXTCLOUD_ADMIN_PASSWORD NEXTCLOUD_VERSION
PHP_MEMORY_LIMIT PHP_UPLOAD_LIMIT NEXTCLOUD_TRUSTED_DOMAINS
POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_VERSION
REDIS_PASSWORD REDIS_VERSION
S3_BUCKET S3_REGION S3_ACCESS_KEY S3_SECRET_KEY S3_USE_PATH_STYLE
SEAWEEDFS_VERSION SEAWEEDFS_VOLUME_SIZE_MB SEAWEEDFS_FILER_PORT SEAWEEDFS_S3_PORT
NPM_VERSION MAIL_DOMAIN
ONLYOFFICE_JWT_SECRET ONLYOFFICE_JWT_HEADER ONLYOFFICE_JWT_IN_BODY ONLYOFFICE_VERSION
VERSIONS_MAX VERSIONS_RETENTION_DAYS TRASH_RETENTION_DAYS
BACKUP_RETENTION_DAYS BACKUP_DIR BACKUP_PASSPHRASE
SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER SMTP_PASSWORD SMTP_FROM
NGINX_VERSION CRON_INTERVAL_SECONDS LOG_LEVEL TRUSTED_PROXIES PROXY_IP
""".split()

EMPTY_SECRETS = [
    "NPM_ADMIN_PASSWORD",
    "NEXTCLOUD_ADMIN_PASSWORD",
    "POSTGRES_PASSWORD",
    "REDIS_PASSWORD",
    "S3_ACCESS_KEY",
    "S3_SECRET_KEY",
    "ONLYOFFICE_JWT_SECRET",
    "BACKUP_PASSPHRASE",
]

REQUIRED_SERVICES = ["proxy", "web", "app", "cron", "db", "cache", "s3", "s3-init", "onlyoffice"]
REQUIRED_VOLUMES = [
    "nextcloud_html",
    "nextcloud_data",
    "db_data",
    "redis_data",
    "s3_data",
    "onlyoffice_data",
    "onlyoffice_lib",
    "onlyoffice_logs",
    "proxy_data",
    "proxy_letsencrypt",
]
EXPECTED_IMAGES = {
    "proxy": ("jc21/nginx-proxy-manager", "NPM_VERSION"),
    "web": ("nginx", "NGINX_VERSION"),
    "app": ("nextcloud", "NEXTCLOUD_VERSION"),
    "cron": ("nextcloud", "NEXTCLOUD_VERSION"),
    "db": ("postgres", "POSTGRES_VERSION"),
    "cache": ("redis", "REDIS_VERSION"),
    "s3": ("chrislusf/seaweedfs", "SEAWEEDFS_VERSION"),
    "onlyoffice": ("onlyoffice/documentserver", "ONLYOFFICE_VERSION"),
}

SCRIPTS = [
    "bootstrap.sh",
    "generate-secrets.sh",
    "preflight.sh",
    "backup.sh",
    "restore.sh",
    "healthcheck.sh",
    "smoke-test.sh",
    "configure-nextcloud.sh",
    "rbac-sync.sh",
    "prune-versions.sh",
    "migrate-yandex-disk.sh",
    "update.sh",
    "audit-report.sh",
    "occ.sh",
    "local-hosts.sh",
    "ip-check.sh",
    "ip-callback-route.sh",
]

MAKE_TARGETS = [
    "help",
    "default",
    "bootstrap",
    "up",
    "down",
    "restart",
    "ps",
    "logs",
    "status",
    "doctor",
    "test",
    "lint",
    "backup",
    "restore",
    "migrate",
    "update",
    "occ",
    "shell-app",
    "admin-up",
    "admin-down",
    "configure",
    "rbac",
    "prune-versions",
    "audit-report",
    "smoke",
    "test-compose",
    "env-ci",
    "clean",
]

PLACEHOLDER = re.compile(r"\b(TODO|FIXME|XXX|CHANGEME|PLACEHOLDER|TBD)\b")
IPV4 = re.compile(r"^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}"
                  r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$")
PRIVATE_IP = re.compile(r"^(?:10\.|127\.|169\.254\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|0\.)")


# --- reporting ---------------------------------------------------------------
def ok(message: str) -> None:
    global CHECKS
    CHECKS += 1
    if VERBOSE:
        print("  ok    %s" % message)


def fail(message: str) -> None:
    global CHECKS
    CHECKS += 1
    ERRORS.append(message)
    print("  FAIL  %s" % message)


def warn(message: str) -> None:
    global CHECKS
    CHECKS += 1
    WARNINGS.append(message)
    print("  WARN  %s" % message)


def check(condition: bool, message: str) -> bool:
    if condition:
        ok(message)
    else:
        fail(message)
    return bool(condition)


def section(title: str) -> None:
    print("\n== %s" % title)


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        fail("cannot read %s: %s" % (path.relative_to(ROOT), exc))
        return ""


def rel(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


# --- checks: files -----------------------------------------------------------
def check_files() -> None:
    section("required files")
    required = [
        "docker-compose.yml",
        "docker-compose.admin.yml",
        "docker-compose.observability.yml",
        "docker-compose.local.yml",
        "docker-compose.ip.yml",
        ".env.example",
        ".env.ip.example",
        ".env.local.example",
        "LICENSES.md",
        ".gitignore",
        "Makefile",
        "CONTRACT.md",
        "config/nginx/nginx.conf",
        "config/nextcloud/php.ini",
        "config/nextcloud/config/zz-10-cloudsuite.config.php",
        "config/nextcloud/custom/prune-versions.php",
        "config/redis/redis.conf",
        "config/rbac/roles.yaml",
        "config/logrotate/cloudsuite",
        "tests/validate.py",
        "tests/compose_render.sh",
        "tests/generate-ci-env.sh",
        "config/nextcloud/hooks/before-starting/10-extra-config.sh",
        "config/nextcloud/hooks/before-starting/20-permissions.sh",
        "config/nextcloud/hooks/before-starting/30-enable-audit.sh",
        "scripts/lib/common.sh",
        ".github/workflows/ci.yml",
    ]
    required += ["scripts/%s" % name for name in SCRIPTS]
    for item in required:
        path = ROOT / item
        if path.is_file():
            ok("%s exists" % item)
        else:
            fail("%s is missing" % item)
    if (ROOT / "scripts" / "lib" / "prune-versions.php").exists():
        fail("scripts/lib/prune-versions.php must not exist - "
             "config/nextcloud/custom/prune-versions.php is the only copy")
    else:
        ok("the version pruner exists in exactly one place")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for line in read(path).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        values[key.strip()] = value.strip().strip('"').strip("'")
    return values


def check_env_example() -> None:
    section(".env.example")
    path = ROOT / ".env.example"
    env = parse_env(path)
    if not env:
        fail(".env.example has no KEY=VALUE entries")
        return
    missing = [name for name in CONTRACT_ENV if name not in env]
    if missing:
        fail(".env.example is missing contract variables: %s" % ", ".join(missing))
    else:
        ok("all %d contract variables are present" % len(CONTRACT_ENV))

    non_empty_secrets = [name for name in EMPTY_SECRETS if env.get(name, "")]
    if non_empty_secrets:
        fail("secrets must be empty in .env.example: %s" % ", ".join(non_empty_secrets))
    else:
        ok("the %d secret variables are empty" % len(EMPTY_SECRETS))

    check(env.get("TRUSTED_PROXIES") == "172.28.10.0/24", "TRUSTED_PROXIES is 172.28.10.0/24")
    check(env.get("PROXY_IP") == "172.28.10.10", "PROXY_IP is 172.28.10.10")
    domains = env.get("NEXTCLOUD_TRUSTED_DOMAINS", "").split()
    cloud = env.get("CLOUD_DOMAIN", "")
    office = env.get("OFFICE_DOMAIN", "")
    if cloud in domains and office in domains and "web" in domains:
        ok("NEXTCLOUD_TRUSTED_DOMAINS lists both domains and web")
    else:
        fail("NEXTCLOUD_TRUSTED_DOMAINS must list %r, %r and 'web' (got %r)"
             % (cloud, office, " ".join(domains)))
    for name in ("BACKUP_DIR", "BACKUP_RETENTION_DAYS", "VERSIONS_MAX", "TRASH_RETENTION_DAYS"):
        check(bool(env.get(name)), "%s has a default value" % name)
    check(env.get("COMPOSE_PROJECT_NAME") == "cloudsuite", "COMPOSE_PROJECT_NAME is cloudsuite")
    for name in [key for key in env if key.endswith("_VERSION")]:
        value = env[name]
        if value == "latest" and name != "SEAWEEDFS_VERSION":
            fail("%s must be pinned (got 'latest')" % name)
        else:
            ok("%s=%s" % (name, value))


# --- checks: compose ---------------------------------------------------------
COMPOSE_VAR = re.compile(r"(?<!\$)\$\{([A-Za-z0-9_]+)([^}]*)\}")


def load_yaml(path: Path):
    try:
        return yaml.safe_load(read(path))
    except yaml.YAMLError as exc:
        fail("%s is not valid YAML: %s" % (rel(path), str(exc).splitlines()[0]))
        return None


def check_compose() -> None:
    section("docker-compose.yml")
    path = ROOT / "docker-compose.yml"
    text = read(path)
    data = load_yaml(path)
    if not isinstance(data, dict):
        return

    check("${COMPOSE_PROJECT_NAME" in str(data.get("name", "")),
          "project name comes from COMPOSE_PROJECT_NAME")

    services = data.get("services") or {}
    missing = [name for name in REQUIRED_SERVICES if name not in services]
    if missing:
        fail("missing services: %s" % ", ".join(missing))
    else:
        ok("all %d services are defined" % len(REQUIRED_SERVICES))
    unexpected = [name for name in services if name not in REQUIRED_SERVICES]
    if unexpected:
        warn("additional services in the base compose file: %s" % ", ".join(unexpected))

    for service, (image_prefix, version_var) in EXPECTED_IMAGES.items():
        block = services.get(service) or {}
        image = str(block.get("image", ""))
        if not image:
            fail("service %s has no image" % service)
            continue
        if not image.startswith(image_prefix):
            fail("service %s uses %s, expected %s" % (service, image, image_prefix))
        elif version_var in image:
            ok("%s: %s" % (service, image))
        elif image_prefix == "chrislusf/seaweedfs":
            warn("%s: %s (SeaweedFS only publishes 'latest')" % (service, image))
        else:
            fail("service %s image is not pinned through %s: %s" % (service, version_var, image))

    volumes = data.get("volumes") or {}
    missing_volumes = [name for name in REQUIRED_VOLUMES if name not in volumes]
    if missing_volumes:
        fail("missing named volumes: %s" % ", ".join(missing_volumes))
    else:
        ok("all %d named volumes are declared" % len(REQUIRED_VOLUMES))

    networks = data.get("networks") or {}
    check("edge" in networks and "backend" in networks, "edge and backend networks exist")
    backend = networks.get("backend") or {}
    check(backend.get("internal") is True, "backend network is internal")

    for service, block in services.items():
        if not isinstance(block, dict):
            continue
        security = block.get("security_opt") or []
        if "no-new-privileges:true" in [str(item) for item in security]:
            ok("%s: no-new-privileges" % service)
        elif service == "s3-init":
            ok("s3-init: one-shot job, no hardening needed")
        else:
            fail("%s: security_opt no-new-privileges is missing" % service)
        restart = block.get("restart")
        if service == "s3-init":
            if restart != "no":
                fail('s3-init must use restart: "no"')
        elif restart != "unless-stopped":
            fail("%s: restart should be unless-stopped (got %r)" % (service, restart))
        logging = block.get("logging") or {}
        if (logging.get("options") or {}).get("max-size"):
            ok("%s: log rotation configured" % service)
        elif service == "s3-init":
            ok("s3-init: one-shot job, log rotation is optional")
        else:
            fail("%s: logging.options.max-size is missing (log files would grow forever)" % service)
        if service in {"app", "cron", "db", "cache", "web", "proxy", "onlyoffice"}:
            if not (block.get("healthcheck") or {}).get("test"):
                fail("%s: healthcheck.test is missing" % service)

    # Published ports: only the proxy and the loopback-only s3 administration UI.
    allowed_ports = {"proxy", "s3"}
    for service, block in services.items():
        if not isinstance(block, dict) or "ports" not in block:
            continue
        if service not in allowed_ports:
            fail("%s must not publish ports (use the proxy)" % service)
            continue
        for mapping in block.get("ports") or []:
            text_mapping = str(mapping)
            entries = text_mapping.split(":") if isinstance(mapping, str) else []
            host_ip = entries[0] if len(entries) >= 3 else ""
            if service == "s3" and host_ip not in {"127.0.0.1", "localhost"}:
                fail("s3 administration ports must bind to 127.0.0.1 (got %s)" % text_mapping)
            elif service == "proxy" and len(entries) >= 3:
                if "${NPM_ADMIN_BIND" in text_mapping:
                    ok("proxy admin port is loopback by default: %s" % text_mapping)
                elif "${HTTP_PORT" in text_mapping or "${HTTPS_PORT" in text_mapping:
                    ok("proxy publishes the public entry point: %s" % text_mapping)

    # Environment variable references vs .env.example.
    env = parse_env(ROOT / ".env.example")
    required_refs = set()
    optional_refs = set()
    for match in COMPOSE_VAR.finditer(text):
        name, modifier = match.group(1), match.group(2)
        if modifier.startswith(":") or modifier.startswith("?"):
            if modifier.startswith(":?") or modifier.startswith("?"):
                required_refs.add(name)
            else:
                optional_refs.add(name)
        else:
            required_refs.add(name)
    missing_required = sorted(required_refs - set(env))
    if missing_required:
        fail("compose requires variables missing from .env.example: %s" % ", ".join(missing_required))
    else:
        ok("all %d required compose variables are documented" % len(required_refs))
    missing_optional = sorted(optional_refs - set(env))
    if missing_optional:
        warn("compose variables with defaults are not in .env.example: %s" % ", ".join(missing_optional))

    # Object storage must be configured for both app and cron.
    for service in ("app", "cron"):
        block = services.get(service) or {}
        env_block = block.get("environment") or {}
        keys = env_block if isinstance(env_block, dict) else {}
        if any(key.startswith("OBJECTSTORE_S3_") and "KEY" in key for key in keys):
            ok("%s: S3 object storage is configured" % service)
        else:
            fail("%s: OBJECTSTORE_S3_KEY is missing (files would land on local disk)" % service)
        if "extra_hosts" not in block:
            warn("%s: extra_hosts is missing (callback hairpin)" % service)

    # The nextcloud image reads OBJECTSTORE_S3_SSL; OBJECTSTORE_S3_USE_SSL is
    # silently ignored and S3 stays on HTTPS, which broke the live stand.
    code_text = "\n".join(line.split("#", 1)[0] for line in text.splitlines())
    check("OBJECTSTORE_S3_SSL" in code_text, "OBJECTSTORE_S3_SSL is set (the variable the image reads)")
    check("OBJECTSTORE_S3_USE_SSL" not in code_text,
          "OBJECTSTORE_S3_USE_SSL is not used (the image ignores it)")
    onlyoffice_env = (services.get("onlyoffice") or {}).get("environment") or {}
    if isinstance(onlyoffice_env, dict) and str(onlyoffice_env.get("ALLOW_PRIVATE_IP_ADDRESS", "")).lower() == "true":
        ok("onlyoffice: ALLOW_PRIVATE_IP_ADDRESS=true (documents are fetched over the edge network)")
    else:
        fail("onlyoffice: ALLOW_PRIVATE_IP_ADDRESS must be \"true\" (extra_hosts resolves CLOUD_DOMAIN to 172.28.10.10)")
    for service in ("app", "cron"):
        volumes = (services.get(service) or {}).get("volumes") or []
        mounts = [str(item) for item in volumes if isinstance(item, (str, int))]
        if any("./config/nextcloud:/opt/cloudsuite:ro" in item for item in mounts):
            ok("%s: ./config/nextcloud is mounted at /opt/cloudsuite:ro" % service)
        else:
            fail("%s: ./config/nextcloud:/opt/cloudsuite:ro is missing" % service)
    if "./config/nextcloud/config:" in text or "./config/nextcloud/config/" in text:
        fail("config/ must not be bind-mounted into /var/www/html/config "
             "(Docker creates the directory as root before the image starts)")
    else:
        ok("the Nextcloud config directory is injected by the entrypoint hook, not bind-mounted")


def check_admin_overlay() -> None:
    section("docker-compose.admin.yml")
    path = ROOT / "docker-compose.admin.yml"
    text = read(path)
    data = load_yaml(path)
    if not isinstance(data, dict):
        return
    services = data.get("services") or {}
    check(set(services) == {"proxy", "s3"}, "the admin overlay only extends proxy and s3")
    check("NPM_ADMIN_PORT" in text, "the overlay exposes the NPM admin port")
    check("SEAWEEDFS_FILER_PORT" in text, "the overlay exposes the SeaweedFS filer UI")


def check_observability_overlay() -> None:
    section("docker-compose.observability.yml")
    path = ROOT / "docker-compose.observability.yml"
    data = load_yaml(path)
    if not isinstance(data, dict):
        return
    services = data.get("services") or {}
    for name in ("loki", "promtail"):
        block = services.get(name) or {}
        if not block:
            fail("observability overlay has no %s service" % name)
            continue
        if "observability" in (block.get("profiles") or []):
            ok("%s is behind the observability profile" % name)
        else:
            fail("%s must be behind the 'observability' profile" % name)
    base = load_yaml(ROOT / "docker-compose.yml") or {}
    base_services = base.get("services") or {}
    leaked = [name for name in services if name in base_services]
    if leaked:
        fail("default compose file also defines: %s" % ", ".join(leaked))
    else:
        ok("the overlay does not affect the default stack")
    check("configs" in data, "the overlay is self-contained (inline configs)")


# --- checks: local (no-domain) run ------------------------------------------
LOCAL_SERVICES = {"proxy", "web", "app", "cron", "onlyoffice"}


def check_local_overlay() -> None:
    section("docker-compose.local.yml (local run, no domain, no TLS)")
    path = ROOT / "docker-compose.local.yml"
    data = load_yaml(path)
    text = read(path)
    if not isinstance(data, dict):
        return
    services = data.get("services") or {}
    check(set(services) == LOCAL_SERVICES,
          "the local overlay only touches: %s" % ", ".join(sorted(LOCAL_SERVICES)))

    proxy = services.get("proxy") or {}
    check("edge" in (proxy.get("profiles") or []),
          "NPM is behind the 'edge' profile, so it does not start locally")

    web = services.get("web") or {}
    ports = [str(item) for item in (web.get("ports") or [])]
    check(any(item.startswith("127.0.0.1:") and item.endswith(":8080") for item in ports),
          "web publishes Nextcloud on loopback only (LOCAL_HTTP_PORT)")
    check("LOCAL_HTTP_PORT" in text, "the local HTTP port is configurable")

    web_env = web.get("environment") or {}
    check("LOCAL_HOST" in str(web_env.get("CLOUD_DOMAIN", "")),
          "web serves the local host name instead of the public domain")
    check("ipv4_address" in str(web.get("networks") or {}),
          "web gets a static address so ONLYOFFICE callbacks resolve inside docker")

    for service in ("app", "cron"):
        env = (services.get(service) or {}).get("environment") or {}
        check(env.get("OVERWRITEPROTOCOL") == "http",
              "%s: overwriteprotocol is http (no TLS locally)" % service)
        check("LOCAL_HOST" in str(env.get("OVERWRITEHOST", "")),
              "%s: overwritehost is the local name:port" % service)
        check("localhost" in str(env.get("NEXTCLOUD_TRUSTED_DOMAINS", "")),
              "%s: localhost is a trusted domain" % service)

    office = services.get("onlyoffice") or {}
    office_ports = [str(item) for item in (office.get("ports") or [])]
    check(any(item.startswith("127.0.0.1:") and item.endswith(":80") for item in office_ports),
          "ONLYOFFICE publishes the editor on loopback only (LOCAL_OFFICE_PORT)")

    local_env = parse_env(ROOT / ".env.local.example")
    check(local_env.get("COMPOSE_PROJECT_NAME") == "cloudsuite-local",
          "the local stack is a separate compose project (own volumes)")
    check(local_env.get("LOCAL_HOST") == "cloud.local",
          "the default local host name is cloud.local (not *.localhost: "
          "curl and glibc/musl force that zone to loopback, ignoring /etc/hosts)")
    check(local_env.get("PUBLIC_BASE_URL", "").startswith("http://"),
          ".env.local.example defines a plain-HTTP PUBLIC_BASE_URL")
    check(local_env.get("DOCUMENT_SERVER_URL", "").startswith("http://"),
          ".env.local.example defines a plain-HTTP DOCUMENT_SERVER_URL")
    check(local_env.get("LOCAL_WEB_IP") == "172.28.10.11",
          "LOCAL_WEB_IP pins web to a static edge address")
    check(local_env.get("PROXY_IP") == local_env.get("LOCAL_WEB_IP"),
          "PROXY_IP equals LOCAL_WEB_IP so ONLYOFFICE callbacks resolve to web")

    configure = read(ROOT / "scripts" / "configure-nextcloud.sh")
    check("PUBLIC_BASE_URL" in configure, "configure-nextcloud.sh honours PUBLIC_BASE_URL")
    check("DOCUMENT_SERVER_URL" in configure, "configure-nextcloud.sh honours DOCUMENT_SERVER_URL")

    makefile = read(ROOT / "Makefile")
    for target in ("local-env", "local-hosts", "local-up", "local-down", "local-configure",
                   "local-check"):
        check("%s:" % target in makefile, "make %s is available" % target)
    hosts_script = ROOT / "scripts" / "local-hosts.sh"
    check(hosts_script.is_file(), "scripts/local-hosts.sh exists (one-time hosts entry)")
    if hosts_script.is_file():
        hosts_text = read(hosts_script)
        check(".localhost" in hosts_text,
              "local-hosts.sh refuses names in the *.localhost zone")

    doc = ROOT / "docs" / "13-local-run.md"
    if doc.is_file() and doc.stat().st_size > 500:
        ok("docs/13-local-run.md documents the local run")
    else:
        fail("docs/13-local-run.md is missing or too short")


def check_ip_overlay() -> None:
    section("docker-compose.ip.yml (white IP, no domain, no hosting)")
    path = ROOT / "docker-compose.ip.yml"
    data = load_yaml(path)
    if not data:
        return
    services = data.get("services") or {}
    check("edge" in str((services.get("proxy") or {}).get("profiles")),
          "proxy (NPM) is disabled in the white-IP overlay")
    web = services.get("web") or {}
    web_env = web.get("environment") or {}
    check("PUBLIC_IP" in str(web_env.get("CLOUD_DOMAIN", "")),
          "web serves the public IP as its server name")
    web_ports = [str(item) for item in (web.get("ports") or [])]
    check(any("IP_BIND" in item and "IP_HTTP_PORT" in item for item in web_ports),
          "web publishes IP_BIND:IP_HTTP_PORT (default 0.0.0.0:80)")
    edge = ((web.get("networks") or {}).get("edge") or {})
    check("IP_WEB_IP" in str(edge.get("ipv4_address", "")),
          "web is pinned to IP_WEB_IP for the callback route")
    for service in ("app", "cron"):
        env = ((services.get(service) or {}).get("environment") or {})
        check(env.get("OVERWRITEPROTOCOL") == "http",
              "%s: overwriteprotocol is http (no TLS on a bare IP)" % service)
        check("PUBLIC_HOST" in str(env.get("OVERWRITEHOST", "")),
              "%s: overwritehost comes from PUBLIC_HOST (host[:port])" % service)
        check("PUBLIC_IP" in str(env.get("NEXTCLOUD_TRUSTED_DOMAINS", "")),
              "%s: the public IP is a trusted domain" % service)
    office_ports = [str(item) for item in ((services.get("onlyoffice") or {}).get("ports") or [])]
    check(any("IP_OFFICE_PORT" in item for item in office_ports),
          "ONLYOFFICE publishes the editor on IP_BIND:IP_OFFICE_PORT")

    ip_env = parse_env(ROOT / ".env.ip.example")
    check(ip_env.get("COMPOSE_PROJECT_NAME") == "cloudsuite-ip",
          "the white-IP stack is a separate compose project (own volumes)")
    public_ip = ip_env.get("PUBLIC_IP", "")
    check(bool(IPV4.match(public_ip)), "PUBLIC_IP is an IPv4 address")
    check(bool(public_ip) and not PRIVATE_IP.match(public_ip),
          "PUBLIC_IP is globally routable (private/loopback would break callbacks)")
    check(ip_env.get("CLOUD_DOMAIN") == public_ip,
          "CLOUD_DOMAIN is the public IP (no domain in this mode)")
    check(ip_env.get("OFFICE_DOMAIN", "") not in ("", public_ip),
          "OFFICE_DOMAIN is a distinct service alias (compose rejects duplicate extra_hosts)")
    check(ip_env.get("PUBLIC_HOST", "").startswith(public_ip),
          "PUBLIC_HOST starts with PUBLIC_IP (host[:port])")
    check(ip_env.get("PUBLIC_BASE_URL", "").startswith("http://"),
          ".env.ip.example defines a plain-HTTP PUBLIC_BASE_URL")
    check(ip_env.get("DOCUMENT_SERVER_URL", "").startswith("http://"),
          ".env.ip.example defines a plain-HTTP DOCUMENT_SERVER_URL")
    check(ip_env.get("IP_WEB_IP") == "172.28.10.12",
          "IP_WEB_IP pins web to a static edge address")
    check(ip_env.get("PROXY_IP") == ip_env.get("IP_WEB_IP"),
          "PROXY_IP equals IP_WEB_IP")
    prod_env = parse_env(ROOT / ".env.example")
    local_env = parse_env(ROOT / ".env.local.example")
    addresses = {prod_env.get("PROXY_IP"), local_env.get("LOCAL_WEB_IP"), ip_env.get("IP_WEB_IP")}
    check(len(addresses) == 3,
          "each run mode has its own static web address (prod / local / ip)")
    check(ip_env.get("NEXTCLOUD_TRUSTED_DOMAINS", "").startswith(public_ip),
          "the public IP is in NEXTCLOUD_TRUSTED_DOMAINS")

    makefile = read(ROOT / "Makefile")
    for target in ("ip-env", "ip-up", "ip-down", "ip-configure", "ip-check", "ip-route"):
        check("%s:" % target in makefile, "make %s is available" % target)
    route_script = ROOT / "scripts" / "ip-callback-route.sh"
    check(route_script.is_file(), "scripts/ip-callback-route.sh exists")
    check((ROOT / "scripts" / "ip-check.sh").is_file(), "scripts/ip-check.sh exists")
    if route_script.is_file():
        route_text = read(route_script)
        check("NET_ADMIN" in route_text and "DNAT" in route_text,
              "ip-callback-route.sh adds an in-namespace DNAT rule (NET_ADMIN)")
        check("IP_WEB_IP" in route_text, "ip-callback-route.sh routes to IP_WEB_IP")
    check("alpine" in read(ROOT / "LICENSES.md").lower(),
          "LICENSES.md documents the alpine helper image used by the IP route")
    doc = ROOT / "docs" / "14-ip-run.md"
    if doc.is_file() and doc.stat().st_size > 500:
        ok("docs/14-ip-run.md documents the white-IP run")
    else:
        fail("docs/14-ip-run.md is missing or too short")


# --- checks: licenses --------------------------------------------------------
# Every image used by any compose file must be OSI-approved, free of charge and
# free of licence keys.  LICENSES.md is the human-readable copy of this table.
IMAGE_LICENSES = {
    "nextcloud": "AGPL-3.0",
    "postgres": "PostgreSQL License",
    "redis": "AGPL-3.0",
    "chrislusf/seaweedfs": "Apache-2.0",
    "nginx": "BSD-2-Clause",
    "jc21/nginx-proxy-manager": "MIT",
    "onlyoffice/documentserver": "AGPL-3.0",
    "grafana/loki": "AGPL-3.0",
    "grafana/promtail": "AGPL-3.0",
    # documented alternatives (allowed if someone switches, see LICENSES.md)
    "valkey/valkey": "BSD-3-Clause",
    "collabora/code": "MPL-2.0",
}
PAID_IMAGE = re.compile(r"(?i)(^|[-/:])(ee|enterprise|plus|trial)([-/:.]|$)")
LICENSE_KEY = re.compile(r"(?i)(license[_-]?key|licence[_-]?key|activation[_-]?key)")


def check_licenses() -> None:
    section("licenses (all images open source, no licence keys)")
    doc_path = ROOT / "LICENSES.md"
    if not doc_path.is_file():
        fail("LICENSES.md is missing - the licence inventory must be in the repo")
        return
    doc = read(doc_path)
    compose_files = [
        "docker-compose.yml",
        "docker-compose.admin.yml",
        "docker-compose.observability.yml",
        "docker-compose.local.yml",
        "docker-compose.ip.yml",
    ]
    used: dict[str, set[str]] = {}
    compose_text = ""
    for name in compose_files:
        path = ROOT / name
        if not path.is_file():
            fail("%s is missing" % name)
            continue
        compose_text += read(path)
        data = load_yaml(path)
        if not isinstance(data, dict):
            continue
        for service, block in (data.get("services") or {}).items():
            image = str((block or {}).get("image") or "")
            if not image:
                continue
            if PAID_IMAGE.search(image):
                fail("%s/%s: %s looks like a paid/enterprise edition" % (name, service, image))
                continue
            # Compose may interpolate the tag: "redis:${REDIS_VERSION:-8.4.7-alpine}".
            clean = re.sub(r"\$\{[^}]*\}", "", image)
            repo = clean.rsplit(":", 1)[0] if ":" in clean.rsplit("/", 1)[-1] else clean
            if repo not in IMAGE_LICENSES:
                fail("%s/%s: image %r has no licence entry (add it to LICENSES.md "
                     "and IMAGE_LICENSES in tests/validate.py)" % (name, service, image))
                continue
            used.setdefault(repo, set()).add(image)

    if not used:
        fail("no images found in the compose files")
        return
    missing_doc = sorted(repo for repo in used if repo not in doc)
    if missing_doc:
        fail("LICENSES.md does not document: %s" % ", ".join(missing_doc))
    else:
        ok("LICENSES.md documents all %d image repositories in use" % len(used))
    for spdx in sorted({IMAGE_LICENSES[repo] for repo in used}):
        check(spdx in doc, "LICENSES.md mentions the %s licence" % spdx)
    if LICENSE_KEY.search(compose_text):
        fail("a compose file references a licence/activation key - the stack must need none")
    else:
        ok("no compose file asks for a licence or activation key")


# --- checks: RBAC policy -----------------------------------------------------
QUOTA = re.compile(r"^(unlimited|none|default|([0-9]+(\.[0-9]+)?)\s*([KMGTkmgt]B|B))$")
GROUP_ID = re.compile(r"^[a-z][a-z0-9_-]{1,63}$")


def check_roles() -> None:
    section("config/rbac/roles.yaml")
    path = ROOT / "config/rbac/roles.yaml"
    data = load_yaml(path)
    if not data:
        return
    check(data.get("version") == 1, "schema version is 1")
    defaults = data.get("defaults") or {}
    check(bool(defaults), "defaults block exists")
    check(bool(defaults.get("default_quota")), "defaults.default_quota is set")
    if defaults.get("default_quota"):
        check(bool(QUOTA.match(str(defaults["default_quota"]))),
              "defaults.default_quota is a valid quota")
    for key in ("enforce_link_password", "allow_public_edit", "resharing", "remote_shares"):
        check(isinstance(defaults.get(key), bool), "defaults.%s is a boolean" % key)
    check(defaults.get("remote_shares") is False, "remote (federated) shares are disabled by default")
    check(isinstance(defaults.get("link_expire_days"), int), "defaults.link_expire_days is an integer")

    roles = data.get("roles")
    if not isinstance(roles, list) or not roles:
        fail("roles must be a non-empty list")
        return
    ok("%d roles are defined" % len(roles))
    names = set()
    for index, role in enumerate(roles):
        if not isinstance(role, dict):
            fail("roles[%d] is not a mapping" % index)
            continue
        name = str(role.get("name", ""))
        if not GROUP_ID.match(name):
            fail("roles[%d].name %r is not a valid group id" % (index, name))
            continue
        if name in names:
            fail("duplicate role name %r" % name)
        names.add(name)
        ok("role %s" % name)
        if not str(role.get("display_name", "")).strip():
            fail("role %s has no display_name" % name)
        quota = str(role.get("quota", ""))
        if not QUOTA.match(quota):
            fail("role %s has an invalid quota %r" % (name, quota))
        delegated = role.get("delegated_admins")
        if not isinstance(delegated, list):
            fail("role %s: delegated_admins must be a list" % name)
        share = role.get("share") or {}
        if not isinstance(share, dict):
            fail("role %s: share must be a mapping" % name)
            continue
        for key in ("links_allowed", "enforce_password", "public_edit_allowed", "resharing", "remote_shares"):
            if not isinstance(share.get(key), bool):
                fail("role %s: share.%s must be a boolean" % (name, key))
        if not isinstance(share.get("default_expire_days"), int):
            fail("role %s: share.default_expire_days must be an integer" % name)
        if share.get("remote_shares") is True:
            fail("role %s allows remote shares, but the platform blocks federation" % name)


# --- checks: scripts ---------------------------------------------------------
def check_scripts(no_bash: bool) -> None:
    section("scripts")
    shell_files = sorted((ROOT / "scripts").glob("*.sh"))
    lib_files = sorted((ROOT / "scripts" / "lib").glob("*.sh"))
    all_shell = shell_files + lib_files
    if len(shell_files) < len(SCRIPTS):
        fail("expected %d scripts, found %d" % (len(SCRIPTS), len(shell_files)))

    for path in all_shell:
        name = rel(path)
        text = read(path)
        if not text.startswith("#!/usr/bin/env bash"):
            fail("%s: shebang must be #!/usr/bin/env bash" % name)
        if "set -Eeuo pipefail" not in text:
            fail("%s: set -Eeuo pipefail is missing" % name)
        if path.parent == ROOT / "scripts" and "lib/common.sh" not in text:
            fail("%s: does not source lib/common.sh" % name)
        found = PLACEHOLDER.search(text)
        if found:
            fail("%s: contains a placeholder marker (%s)" % (name, found.group(0)))
        if not no_bash:
            result = subprocess.run(["bash", "-n", str(path)], capture_output=True, text=True, check=False)
            if result.returncode != 0:
                tail = result.stderr.strip().splitlines()[-1] if result.stderr else ""
                fail("%s: bash -n failed: %s" % (name, tail))
        if path.parent == ROOT / "scripts" and not (path.stat().st_mode & 0o111):
            if EXEC_BIT_CHECKABLE:
                fail("%s: not executable (chmod +x)" % name)
            else:
                warn("%s: exec bit cannot be stored on this filesystem - "
                     "ensure mode 100755 in the git index (git update-index --chmod=+x)" % name)
    ok("%d shell scripts checked for shebang, strict mode, common.sh and placeholders" % len(all_shell))

    for helper in sorted((ROOT / "scripts" / "lib").glob("*.py")):
        result = subprocess.run(
            [sys.executable, "-m", "py_compile", str(helper)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            tail = result.stderr.strip().splitlines()[-1] if result.stderr else ""
            fail("%s: py_compile failed: %s" % (rel(helper), tail))
        else:
            ok("%s compiles" % rel(helper))
        shutil.rmtree(helper.parent / "__pycache__", ignore_errors=True)

    bootstrap = read(ROOT / "scripts" / "bootstrap.sh")
    for expected_dir in ("logs/nginx", "logs/cloudsuite"):
        if expected_dir in bootstrap:
            ok("bootstrap creates %s" % expected_dir)
        else:
            fail("bootstrap does not create %s" % expected_dir)
    for unwanted in ("logs/npm", "logs/onlyoffice"):
        if unwanted in bootstrap:
            fail("bootstrap must not create %s (not bind-mounted, the container "
                 "writes into a named volume)" % unwanted)
        else:
            ok("bootstrap does not create %s" % unwanted)
    for needle, label in (("ensure_exec_bits", "bootstrap restores the exec bits"),
                          ("script exec bits ensured", "bootstrap reports the exec-bit result")):
        check(needle in bootstrap, label)
    if "chmod +x" in bootstrap:
        ok("bootstrap self-heals a copy without POSIX modes (Windows checkout)")
    else:
        fail("bootstrap does not restore exec bits - a Windows copy of the tree cannot run ./scripts/*.sh")

    specs = ("logs/nginx 101 101", "logs/cloudsuite 33 33")
    missing_specs = [spec for spec in specs if spec not in bootstrap]
    if missing_specs:
        fail("bootstrap must chown logs/nginx to 101:101 and logs/cloudsuite to 33:33 "
             "(missing: %s)" % ", ".join(missing_specs))
    else:
        ok("bootstrap fixes log ownership: 101:101 for nginx, 33:33 for www-data")

    common = read(ROOT / "scripts" / "lib" / "common.sh")
    for function in ("load_env", "compose", "occ", "die", "require_cmd", "acquire_lock", "human_bytes"):
        if function + "()" in common:
            ok("common.sh defines %s()" % function)
        else:
            fail("common.sh does not define %s()" % function)


# --- checks: Makefile --------------------------------------------------------
def check_makefile() -> None:
    section("Makefile")
    text = read(ROOT / "Makefile")
    if not text:
        return
    check(".DEFAULT_GOAL := help" in text, ".DEFAULT_GOAL is help")
    for target in MAKE_TARGETS:
        if re.search(r"^%s:" % re.escape(target), text, re.MULTILINE):
            ok("target %s" % target)
        else:
            fail("Makefile has no target %r" % target)
    phony_block = re.search(r"^\.PHONY:(.*?)(?=\n\S)", text, re.MULTILINE | re.DOTALL)
    phony = phony_block.group(1) if phony_block else ""
    missing_phony = [target for target in MAKE_TARGETS if target not in phony]
    if missing_phony:
        fail(".PHONY is missing: %s" % ", ".join(missing_phony))
    else:
        ok("all essential targets are phony")
    check("require-env" in text, "the .env guard target exists")
    check("COMPOSE_CMD" in text, "COMPOSE_CMD can be overridden")
    check("$(COMPOSE_FILES)" in text, "COMPOSE_FILES supports -f overrides")
    if "tests/validate.py" in text:
        ok("make test runs tests/validate.py")
    else:
        fail("make test does not run tests/validate.py")
    check("tests/compose_render.sh" in text, "the Makefile renders every compose combination")
    check("tests/generate-ci-env.sh" in text, "the Makefile generates .env.ci for the render")
    check("$(ENV_CI)" in text and "config -q" in text,
          "make test runs docker compose config -q with .env.ci")
    check("docker-compose.admin.yml" in text, "the Makefile knows the admin overlay")
    if "shellcheck" in text:
        ok("make lint uses shellcheck")
    else:
        fail("make lint does not use shellcheck")


# --- checks: nextcloud / nginx configuration ---------------------------------
def check_nginx() -> None:
    section("nginx configuration")
    conf_text = read(ROOT / "config/nginx/conf.d/10-nextcloud.conf")
    if not conf_text:
        fail("config/nginx/conf.d/10-nextcloud.conf is missing")
    else:
        check("app:9000" in conf_text, "the Nextcloud upstream is app:9000")
        check("/var/www/html" in conf_text, "the document root is /var/www/html")
        check("fastcgi_pass" in conf_text, "fastcgi_pass is configured")
    main_conf = read(ROOT / "config/nginx/nginx.conf")
    check("worker_processes" in main_conf, "nginx.conf sets worker_processes")
    check("include /etc/nginx/conf.d/*.conf" in main_conf or "include conf.d" in main_conf,
          "nginx.conf includes conf.d")
    image_provided = {"mime.types", "fastcgi_params", "fastcgi.conf", "uwsgi_params", "scgi_params"}
    for snippet in sorted((ROOT / "config/nginx").rglob("*.conf")):
        body = "\n".join(line.split("#", 1)[0] for line in read(snippet).splitlines())
        for include in re.findall(r"include\s+([^;]+);", body):
            include = include.strip().strip('"').strip("'")
            if "*" in include:
                continue
            name = include.rsplit("/", 1)[-1]
            if name in image_provided or include.startswith("conf.d/"):
                continue
            if include.startswith("/etc/nginx/"):
                include = include[len("/etc/nginx/"):]
            target = (ROOT / "config/nginx" / include).resolve()
            if not target.is_file():
                fail("%s includes a missing file: %s" % (rel(snippet), include))
    ok("nginx includes resolve inside config/nginx")
    placeholder = re.compile(r"\$[{]?[A-Za-z_][A-Za-z0-9_]*[}]?")
    for template in sorted((ROOT / "config/nginx").rglob("*.template")):
        text = read(template)
        if placeholder.search(text):
            ok("%s uses envsubst placeholders" % rel(template))
        else:
            fail("%s has no envsubst placeholder - NPM cannot substitute anything" % rel(template))


def check_nextcloud_config() -> None:
    section("Nextcloud configuration")
    zz = read(ROOT / "config/nextcloud/config/zz-10-cloudsuite.config.php")
    if not zz:
        return
    for key in (
        "logfile",
        "logfile_audit",
        "log_type_audit",
        "versions_retention_obligation",
        "trashbin_retention_obligation",
        "maintenance_window_start",
        "default_phone_region",
        "skeletondirectory",
    ):
        if key in zz:
            ok("zz-10 config sets %s" % key)
        else:
            fail("zz-10 config does not set %s" % key)
    check("/var/log/cloudsuite" in zz and "/audit.log" in zz,
          "the audit log lives under /var/log/cloudsuite")
    pruner = read(ROOT / "config/nextcloud/custom/prune-versions.php")
    if not pruner:
        return
    check("--dry-run" in pruner, "prune-versions.php supports --dry-run")
    check("--max" in pruner, "prune-versions.php supports --max")
    check("<?php" in pruner, "prune-versions.php is a PHP file")


def check_hooks() -> None:
    section("Nextcloud entrypoint hooks")
    hooks_dir = ROOT / "config" / "nextcloud" / "hooks" / "before-starting"
    expected = {
        "10-extra-config.sh": "config",
        "20-permissions.sh": "www-data",
        "30-enable-audit.sh": "admin_audit",
    }
    for name, needle in expected.items():
        hook = hooks_dir / name
        if not hook.is_file():
            fail("hook %s is missing" % name)
            continue
        body = read(hook)
        if not body.startswith("#!"):
            fail("hook %s has no shebang" % name)
        if not (hook.stat().st_mode & 0o111):
            if EXEC_BIT_CHECKABLE:
                fail("hook %s is not executable (the entrypoint runs it directly)" % name)
            else:
                warn("hook %s: exec bit cannot be stored on this filesystem - "
                     "ensure mode 100755 in the git index" % name)
        if "set -" not in body:
            warn("hook %s does not enable strict mode" % name)
        if needle in body:
            ok("hook %s mentions %s" % (name, needle))
        else:
            warn("hook %s does not mention %s - is it still doing its job?" % (name, needle))


def check_gitignore() -> None:
    section(".gitignore")
    text = read(ROOT / ".gitignore")
    for pattern in (".env", "*.pem", "backups/", "data/", "logs/"):
        if pattern in text:
            ok("%s is ignored" % pattern)
        else:
            fail("%s is not ignored - secrets or data could be committed" % pattern)
    if ".env.example" in text and "!.env.example" not in text:
        fail(".env.example would be ignored (add !.env.example)")
    else:
        ok(".env.example stays tracked")


def check_logrotate() -> None:
    section("config/logrotate/cloudsuite")
    text = read(ROOT / "config/logrotate/cloudsuite")
    if not text:
        return
    for pattern in ("logs/nginx", "logs/cloudsuite"):
        if pattern in text:
            ok("rotates %s" % pattern)
        else:
            fail("no logrotate stanza for %s" % pattern)
    stanzas = re.findall(r"^/\S+\s*\{", text, re.MULTILINE)
    check(len(stanzas) == 2, "exactly %d logrotate stanzas (both host bind mounts)" % len(stanzas))
    if "logs/onlyoffice" in text:
        fail("logs/onlyoffice is not bind-mounted (named volume onlyoffice_logs) - "
             "there is nothing to rotate on the host")
    else:
        ok("no logrotate stanza for a directory that is not bind-mounted")
    for keyword in ("weekly", "rotate 12", "compress", "copytruncate"):
        if keyword in text:
            ok("logrotate uses %s" % keyword)
        else:
            fail("logrotate does not use %s" % keyword)


def check_ci() -> None:
    section(".github/workflows/ci.yml")
    path = ROOT / ".github/workflows/ci.yml"
    data = load_yaml(path)
    if not isinstance(data, dict):
        return
    jobs = data.get("jobs") or {}
    check(bool(jobs), "the workflow defines at least one job")
    text = read(path)
    for token in ("tests/validate.py", "shellcheck", "compose_render.sh"):
        if token in text:
            ok("CI runs %s" % token)
        else:
            fail("CI does not run %s" % token)
    for token in ("make lint", "make test"):
        if token in text:
            ok("CI runs %s" % token)
        else:
            fail("CI does not run %s" % token)
    if "chmod +x scripts/*.sh" in text:
        ok("CI restores the exec bits after checkout (Windows-authored commits)")
    else:
        fail("CI does not chmod +x the scripts after checkout - a commit made on Windows would break the compose job")
    if "pull_request" in text or "push" in text:
        ok("CI is triggered on push/pull_request")
    else:
        fail("CI has no push/pull_request trigger")


def check_docs() -> None:
    section("documentation")
    expected = [
        "docs/01-architecture.md",
        "docs/03-security-hardening.md",
        "docs/04-rbac-and-sharing.md",
        "docs/06-versioning-and-retention.md",
        "docs/08-migration-from-yandex-disk.md",
        "docs/10-user-guide.md",
        "docs/11-troubleshooting.md",
        "docs/12-acceptance-checklist.md",
        "docs/README.md",
        "README.md",
    ]
    for item in expected:
        path = ROOT / item
        if path.is_file() and path.stat().st_size > 200:
            ok("%s" % item)
        else:
            warn("%s is missing or empty (owned by docs)" % item)


# --- main --------------------------------------------------------------------
def main() -> int:
    global VERBOSE
    parser = argparse.ArgumentParser(description="Validate the Cloud Suite repository")
    parser.add_argument("--verbose", "-v", action="store_true", help="print every passing check")
    parser.add_argument("--no-bash", action="store_true", help="skip bash -n (bash not installed)")
    args = parser.parse_args()
    VERBOSE = args.verbose
    if shutil.which("bash") is None:
        args.no_bash = True

    print("Cloud Suite repository validation")
    print("root: %s" % ROOT)
    check_files()
    check_env_example()
    check_compose()
    check_admin_overlay()
    check_observability_overlay()
    check_local_overlay()
    check_ip_overlay()
    check_licenses()
    check_roles()
    check_scripts(args.no_bash)
    check_makefile()
    check_nginx()
    check_nextcloud_config()
    check_hooks()
    check_gitignore()
    check_logrotate()
    check_ci()
    check_docs()
    shutil.rmtree(ROOT / "tests" / "__pycache__", ignore_errors=True)
    shutil.rmtree(ROOT / "scripts" / "lib" / "__pycache__", ignore_errors=True)

    print("\n== summary")
    print("checks run : %d" % CHECKS)
    print("failures   : %d" % len(ERRORS))
    print("warnings   : %d" % len(WARNINGS))
    if ERRORS:
        print("\nFAILED checks:")
        for message in ERRORS:
            print("  - %s" % message)
        return 1
    if WARNINGS:
        print("\nwarnings:")
        for message in WARNINGS:
            print("  - %s" % message)
    print("\nRESULT: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
