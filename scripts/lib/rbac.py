#!/usr/bin/env python3
"""Cloud Suite - RBAC policy helper.

Reads config/rbac/roles.yaml, validates the schema and prints the data in the
shapes scripts/rbac-sync.sh needs.  Kept separate from the shell script so the
YAML parsing and the validation rules live in one place and can be unit tested.

Modes:
  --mode tsv     one tab-separated line per role (for the bash loop)
  --mode policy  minified JSON document (stored with occ config:app:set)
  --mode groups  newline separated group ids
  --check        validate only, print a short report

Exit codes: 0 ok, 1 validation error, 2 parse/read error, 3 usage error.
"""

from __future__ import annotations

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
__version__ = "1.0.0"

ALLOWED_TOP = {"version", "defaults", "roles"}
ALLOWED_ROLE = {"name", "display_name", "description", "quota", "delegated_admins", "share"}
ALLOWED_SHARE = {
    "links_allowed",
    "enforce_password",
    "default_expire_days",
    "public_edit_allowed",
    "resharing",
    "remote_shares",
}
ALLOWED_DEFAULTS = {
    "default_quota",
    "enforce_link_password",
    "link_expire_days",
    "allow_public_edit",
    "resharing",
    "remote_shares",
}
GROUP_ID = re.compile(r"^[a-z][a-z0-9_-]{1,63}$")
QUOTA = re.compile(r"^([0-9]+(?:\.[0-9]+)?)\s*([KMGTkmgt]B|B)$")


class RbacError(Exception):
    """Raised for a schema violation."""

    def __init__(self, message: str, warning: bool = False) -> None:
        super().__init__(message)
        self.warning = warning


def load_yaml_module(path: str):
    """Load PyYAML without shadowing scripts/lib/yaml.py (see that file)."""
    import importlib

    saved_path = list(sys.path)
    saved_module = sys.modules.get("yaml")
    try:
        sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != HERE]
        sys.modules.pop("yaml", None)
        return importlib.import_module("yaml")
    except ImportError:
        return None
    finally:
        sys.path[:] = saved_path
        if saved_module is not None:
            sys.modules["yaml"] = saved_module


def parse_document(path: str):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        raise SystemExit("rbac.py: cannot read %s: %s" % (path, exc)) from exc
    pyyaml = load_yaml_module(path)
    if pyyaml is not None:
        try:
            return pyyaml.safe_load(text)
        except Exception as exc:  # noqa: BLE001 - surface the parser message
            raise SystemExit("rbac.py: YAML parse error in %s: %s" % (path, exc)) from exc
    # Fallback: reuse the bundled parser from yaml.py next to this file.
    import importlib.util

    spec = importlib.util.spec_from_file_location("cloudsuite_yaml", os.path.join(HERE, "yaml.py"))
    if spec is None or spec.loader is None:
        raise SystemExit("rbac.py: cannot load scripts/lib/yaml.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        return module.load_document(text)
    except Exception as exc:  # noqa: BLE001
        raise SystemExit("rbac.py: YAML parse error in %s: %s" % (path, exc)) from exc


def as_bool(value, field, problems):
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"true", "yes", "on", "1"}:
            return True
        if lowered in {"false", "no", "off", "0"}:
            return False
    problems.append("%s must be a boolean (got %r)" % (field, value))
    return False


def normalise_quota(value, field, problems):
    """Return the value in the form Nextcloud accepts, or None."""
    if value is None:
        return None
    text = str(value).strip()
    if text.lower() in {"unlimited", "none", "default"}:
        return "none" if text.lower() == "unlimited" else text.lower()
    match = QUOTA.match(text)
    if not match:
        problems.append("%s must be 'unlimited' or a size like 100GB/1.5TB (got %r)" % (field, value))
        return None
    number, unit = match.groups()
    if float(number) <= 0:
        problems.append("%s must be greater than zero (got %r)" % (field, value))
        return None
    return "%s %s" % (number, unit.upper())


def validate(document, strict: bool):
    problems: list[str] = []
    warnings: list[str] = []

    if not isinstance(document, dict):
        raise RbacError("the document must be a mapping with version/roles")

    unknown = set(document) - ALLOWED_TOP
    for key in sorted(unknown):
        warnings.append("unknown top-level key %r (ignored)" % key)

    version = document.get("version")
    if version != 1:
        problems.append("version must be 1 (got %r)" % (version,))

    defaults_raw = document.get("defaults") or {}
    if not isinstance(defaults_raw, dict):
        raise RbacError("defaults must be a mapping")
    for key in sorted(set(defaults_raw) - ALLOWED_DEFAULTS):
        warnings.append("unknown defaults key %r (ignored)" % key)

    defaults = {
        "default_quota": normalise_quota(defaults_raw.get("default_quota", "10GB"), "defaults.default_quota", problems),
        "enforce_link_password": as_bool(defaults_raw.get("enforce_link_password", True), "defaults.enforce_link_password", problems),
        "link_expire_days": int(defaults_raw.get("link_expire_days", 30) or 30),
        "allow_public_edit": as_bool(defaults_raw.get("allow_public_edit", True), "defaults.allow_public_edit", problems),
        "resharing": as_bool(defaults_raw.get("resharing", True), "defaults.resharing", problems),
        "remote_shares": as_bool(defaults_raw.get("remote_shares", False), "defaults.remote_shares", problems),
    }

    roles_raw = document.get("roles")
    if not isinstance(roles_raw, list) or not roles_raw:
        raise RbacError("roles must be a non-empty list")

    seen = set()
    roles = []
    for index, raw in enumerate(roles_raw):
        where = "roles[%d]" % index
        if not isinstance(raw, dict):
            problems.append("%s must be a mapping" % where)
            continue
        for key in sorted(set(raw) - ALLOWED_ROLE):
            warnings.append("%s: unknown key %r (ignored)" % (where, key))
        name = raw.get("name")
        if not isinstance(name, str) or not GROUP_ID.match(name):
            problems.append("%s.name must match ^[a-z][a-z0-9_-]{1,63}$ (got %r)" % (where, name))
            continue
        if name in seen:
            problems.append("duplicate role name %r" % name)
            continue
        seen.add(name)
        where = "role %r" % name
        display_name = raw.get("display_name")
        if not isinstance(display_name, str) or not display_name.strip():
            problems.append("%s.display_name must be a non-empty string" % where)
            display_name = name
        description = raw.get("description") or ""
        if not isinstance(description, str):
            problems.append("%s.description must be a string" % where)
            description = ""
        quota = normalise_quota(raw.get("quota", defaults["default_quota"]), "%s.quota" % where, problems)
        delegated = raw.get("delegated_admins") or []
        if not isinstance(delegated, list) or any(not isinstance(item, str) for item in delegated):
            problems.append("%s.delegated_admins must be a list of user ids" % where)
            delegated = []
        share_raw = raw.get("share") or {}
        if not isinstance(share_raw, dict):
            problems.append("%s.share must be a mapping" % where)
            share_raw = {}
        for key in sorted(set(share_raw) - ALLOWED_SHARE):
            warnings.append("%s.share: unknown key %r (ignored)" % (where, key))
        expire = share_raw.get("default_expire_days", defaults["link_expire_days"])
        try:
            expire = int(expire)
        except (TypeError, ValueError):
            problems.append("%s.share.default_expire_days must be an integer (got %r)" % (where, expire))
            expire = defaults["link_expire_days"]
        if expire < 0:
            problems.append("%s.share.default_expire_days must be >= 0" % where)
        share = {
            "links_allowed": as_bool(share_raw.get("links_allowed", True), "%s.share.links_allowed" % where, problems),
            "enforce_password": as_bool(share_raw.get("enforce_password", defaults["enforce_link_password"]), "%s.share.enforce_password" % where, problems),
            "default_expire_days": expire,
            "public_edit_allowed": as_bool(share_raw.get("public_edit_allowed", defaults["allow_public_edit"]), "%s.share.public_edit_allowed" % where, problems),
            "resharing": as_bool(share_raw.get("resharing", defaults["resharing"]), "%s.share.resharing" % where, problems),
            "remote_shares": as_bool(share_raw.get("remote_shares", defaults["remote_shares"]), "%s.share.remote_shares" % where, problems),
        }
        roles.append(
            {
                "name": name,
                "display_name": display_name.strip(),
                "description": description.strip(),
                "quota": quota or "none",
                "delegated_admins": delegated,
                "share": share,
            }
        )

    if strict:
        problems.extend(warnings)
        warnings = []
    if problems:
        raise RbacError("\n".join(problems))
    return {"version": 1, "defaults": defaults, "roles": roles}, warnings


def emit_tsv(document, roles):
    for role in roles:
        share = role["share"]
        delegated = ",".join(role["delegated_admins"])
        display = role["display_name"].replace("\t", " ").replace("\n", " ")
        print(
            "\t".join(
                [
                    role["name"],
                    display,
                    role["quota"],
                    delegated,
                    "1" if share["links_allowed"] else "0",
                    "1" if share["enforce_password"] else "0",
                    str(share["default_expire_days"]),
                    "1" if share["public_edit_allowed"] else "0",
                    "1" if share["resharing"] else "0",
                    "1" if share["remote_shares"] else "0",
                ]
            )
        )


def main(argv):
    args = [arg for arg in argv[1:]]
    mode = "check"
    strict = False
    path = None
    index = 0
    while index < len(args):
        arg = args[index]
        if arg in {"-h", "--help"}:
            print(__doc__.strip())
            return 0
        if arg in {"-V", "--version"}:
            print("rbac.py %s" % __version__)
            return 0
        if arg == "--strict":
            strict = True
            index += 1
            continue
        if arg == "--mode":
            if index + 1 >= len(args):
                print("rbac.py: --mode needs a value", file=sys.stderr)
                return 3
            mode = args[index + 1]
            index += 2
            continue
        if arg.startswith("--mode="):
            mode = arg.split("=", 1)[1]
            index += 1
            continue
        if arg.startswith("-"):
            print("rbac.py: unknown option %r" % arg, file=sys.stderr)
            return 3
        path = arg
        index += 1

    if mode not in {"tsv", "policy", "groups", "check"}:
        print("rbac.py: unknown mode %r" % mode, file=sys.stderr)
        return 3
    if not path:
        print("usage: rbac.py [--mode tsv|policy|groups|check] [--strict] FILE", file=sys.stderr)
        return 3

    document = parse_document(path)
    try:
        clean, warnings = validate(document, strict)
    except RbacError as exc:
        print("rbac.py: invalid RBAC policy:", file=sys.stderr)
        for line in str(exc).splitlines():
            print("  - %s" % line, file=sys.stderr)
        return 1

    for warning in warnings:
        print("rbac.py: warning: %s" % warning, file=sys.stderr)

    if mode == "tsv":
        emit_tsv(clean, clean["roles"])
    elif mode == "policy":
        print(json.dumps(clean, ensure_ascii=False, separators=(",", ":")))
    elif mode == "groups":
        for role in clean["roles"]:
            print(role["name"])
    else:
        print("rbac policy OK: %d role(s), default quota %s" % (len(clean["roles"]), clean["defaults"]["default_quota"]))
        for role in clean["roles"]:
            print(
                "  %-12s quota=%-10s links=%-3s pwd=%-5s expire=%-3sd edit=%-5s reshare=%-5s remote=%s"
                % (
                    role["name"],
                    role["quota"],
                    "yes" if role["share"]["links_allowed"] else "no",
                    "yes" if role["share"]["enforce_password"] else "no",
                    role["share"]["default_expire_days"],
                    "yes" if role["share"]["public_edit_allowed"] else "no",
                    "yes" if role["share"]["resharing"] else "no",
                    "yes" if role["share"]["remote_shares"] else "no",
                )
            )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
