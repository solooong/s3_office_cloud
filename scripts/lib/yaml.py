#!/usr/bin/env python3
"""Cloud Suite - YAML to JSON helper.

Prints a YAML document as JSON on stdout.  Uses PyYAML when it is available
(the preferred, fully featured parser) and otherwise falls back to a small
stdlib-only parser that covers the YAML subset used by config/rbac/*.yaml:
block mappings, block sequences, nested blocks, flow sequences/mappings,
quoted scalars, booleans, numbers, null and literal/folded block scalars.

This keeps scripts/rbac-sync.sh working on a stock Ubuntu/Debian host where
python3-yaml is not installed.

Exit codes: 0 ok, 1 read error, 2 parse error, 3 usage error.
"""

from __future__ import annotations

import json
import re
import sys

__version__ = "1.0.0"

# --------------------------------------------------------------------------- #
# stdlib fallback parser
# --------------------------------------------------------------------------- #
_TRUE = {"true", "True", "TRUE", "yes", "Yes", "YES", "on", "ON"}
_FALSE = {"false", "False", "FALSE", "no", "No", "NO", "off", "OFF"}
_NULL = {"null", "Null", "NULL", "~", ""}
_INT = re.compile(r"^[-+]?[0-9]+$")
_FLOAT = re.compile(r"^[-+]?([0-9]+\.[0-9]*|\.[0-9]+)([eE][-+]?[0-9]+)?$")


class YamlError(ValueError):
    """Raised when the fallback parser cannot understand the document."""


def _strip_comment(text: str) -> str:
    """Remove a trailing comment that is outside quotes."""
    quote = None
    index = 0
    while index < len(text):
        char = text[index]
        if quote:
            if char == quote:
                quote = None
        elif char in ("'", '"'):
            quote = char
        elif char == "#" and (index == 0 or text[index - 1] in " \t"):
            return text[:index].rstrip()
        index += 1
    return text.rstrip()


def _split_flow(body: str, separator: str = ",") -> list[str]:
    """Split a flow collection body on a separator, respecting nesting/quotes."""
    parts, current, depth, quote = [], [], 0, None
    for char in body:
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
        elif char in "[{":
            depth += 1
            current.append(char)
        elif char in "]}":
            depth -= 1
            current.append(char)
        elif char == separator and depth == 0:
            parts.append("".join(current).strip())
            current = []
        else:
            current.append(char)
    tail = "".join(current).strip()
    if tail:
        parts.append(tail)
    return parts


def _unquote(text: str) -> str:
    if len(text) >= 2 and text[0] == text[-1] == "'":
        return text[1:-1].replace("''", "'")
    if len(text) >= 2 and text[0] == text[-1] == '"':
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            return text[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    return text


def parse_scalar(text: str):
    text = text.strip()
    if text in _NULL:
        return None
    if text in _TRUE:
        return True
    if text in _FALSE:
        return False
    if text.startswith('"') and text.endswith('"') and len(text) > 1:
        return _unquote(text)
    if text.startswith("'") and text.endswith("'") and len(text) > 1:
        return _unquote(text)
    if text.startswith("[") and text.endswith("]"):
        body = text[1:-1].strip()
        if not body:
            return []
        return [parse_scalar(item) for item in _split_flow(body)]
    if text.startswith("{") and text.endswith("}"):
        body = text[1:-1].strip()
        result: dict = {}
        if not body:
            return result
        for item in _split_flow(body):
            if ":" not in item:
                raise YamlError("flow mapping entry without ':': %r" % item)
            key, _, value = item.partition(":")
            result[_unquote(key.strip())] = parse_scalar(value)
        return result
    if _INT.match(text):
        return int(text)
    if _FLOAT.match(text):
        return float(text)
    return text


def _split_key(text: str) -> tuple[str, str]:
    """Split 'key: value' at the first top-level colon."""
    quote = None
    depth = 0
    for index, char in enumerate(text):
        if quote:
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
        elif char in "[{":
            depth += 1
        elif char in "]}":
            depth -= 1
        elif char == ":" and depth == 0:
            return text[:index], text[index + 1 :]
    raise YamlError("expected 'key: value', got %r" % text)


class _FallbackParser:
    def __init__(self, document: str) -> None:
        self.raw_lines = document.splitlines()
        self.lines: list[tuple[int, str, int]] = []  # indent, text, raw line no
        for number, line in enumerate(self.raw_lines, 1):
            if "\t" in line[: len(line) - len(line.lstrip())]:
                raise YamlError("tabs are not allowed for indentation (line %d)" % number)
            stripped = _strip_comment(line)
            if not stripped.strip():
                continue
            if stripped.strip() in ("---", "..."):
                continue
            indent = len(stripped) - len(stripped.lstrip(" "))
            self.lines.append((indent, stripped.strip(), number))
        self.index = 0

    # -- helpers -----------------------------------------------------------
    def _peek(self):
        if self.index < len(self.lines):
            return self.lines[self.index]
        return None

    def _block_scalar(self, indicator: str, parent_indent: int) -> str:
        collected: list[str] = []
        while self.index < len(self.lines) and self.lines[self.index][0] > parent_indent:
            collected.append(self.lines[self.index][1])
            self.index += 1
        if indicator.startswith(">"):
            return " ".join(collected).strip() + "\n"
        return "\n".join(collected) + ("\n" if collected else "")

    def _value_after_colon(self, rest: str, indent: int):
        rest = rest.strip()
        if rest in ("|", "|-", "|+", ">", ">-", ">+"):
            return self._block_scalar(rest, indent)
        if rest:
            return parse_scalar(rest)
        nxt = self._peek()
        if nxt is None or nxt[0] <= indent:
            return None
        return self._parse_block(nxt[0])

    def _parse_block(self, indent: int):
        nxt = self._peek()
        if nxt is None:
            return None
        if nxt[1].startswith("- "):
            return self._parse_sequence(indent)
        if nxt[1] == "-":
            return self._parse_sequence(indent)
        return self._parse_mapping(indent)

    def _parse_mapping(self, indent: int) -> dict:
        result: dict = {}
        while True:
            nxt = self._peek()
            if nxt is None or nxt[0] < indent:
                break
            line_indent, text, number = nxt
            if line_indent > indent:
                raise YamlError("unexpected indentation at line %d" % number)
            if text.startswith("- "):
                break
            key, rest = _split_key(text)
            self.index += 1
            key = _unquote(key.strip())
            result[key] = self._value_after_colon(rest, indent)
        return result

    def _parse_sequence(self, indent: int) -> list:
        result: list = []
        while True:
            nxt = self._peek()
            if nxt is None or nxt[0] < indent:
                break
            line_indent, text, number = nxt
            if line_indent > indent:
                raise YamlError("unexpected indentation at line %d" % number)
            if not (text.startswith("- ") or text == "-"):
                break
            item_text = text[1:].lstrip()
            item_indent = indent + (len(text) - len(item_text))
            self.index += 1
            if not item_text:
                nxt2 = self._peek()
                if nxt2 is not None and nxt2[0] > indent:
                    result.append(self._parse_block(nxt2[0]))
                else:
                    result.append(None)
                continue
            if item_text.startswith("- "):
                raise YamlError("nested inline sequences are not supported (line %d)" % number)
            if ":" in item_text and not item_text.startswith(("'", '"', "[", "{")):
                # mapping inside a sequence item: "- key: value" + siblings
                mapping: dict = {}
                key, rest = _split_key(item_text)
                mapping[_unquote(key.strip())] = self._value_after_colon(rest, item_indent)
                nxt2 = self._peek()
                if nxt2 is not None and nxt2[0] == item_indent and not nxt2[1].startswith("- "):
                    mapping.update(self._parse_mapping(item_indent))
                result.append(mapping)
            else:
                result.append(parse_scalar(item_text))
        return result

    def parse(self):
        if not self.lines:
            return None
        value = self._parse_block(self.lines[0][0])
        if self.index != len(self.lines):
            raise YamlError("trailing content at line %d" % self.lines[self.index][2])
        return value


def _import_pyyaml():
    """Import PyYAML without shadowing this very file.

    When the script runs as 'python3 scripts/lib/yaml.py' the first entry of
    sys.path is scripts/lib, so a plain 'import yaml' would import THIS file
    instead of the real PyYAML package.  Drop our own directory from the search
    path for the duration of the import and refuse a module that is ourselves.
    """
    import importlib
    import os

    here = os.path.dirname(os.path.abspath(__file__))
    saved_path = list(sys.path)
    try:
        sys.path[:] = [p for p in sys.path if os.path.abspath(p or os.getcwd()) != here]
        sys.modules.pop("yaml", None)
        module = importlib.import_module("yaml")
    except ImportError:
        return None
    finally:
        sys.path[:] = saved_path
    if getattr(module, "__file__", "") == os.path.abspath(__file__):
        sys.modules.pop("yaml", None)
        return None
    if not hasattr(module, "safe_load"):
        sys.modules.pop("yaml", None)
        return None
    return module


def load_document(document: str):
    """Parse YAML text, preferring PyYAML, falling back to the bundled parser."""
    pyyaml = _import_pyyaml()
    if pyyaml is None:
        return _FallbackParser(document).parse()
    return pyyaml.safe_load(document)


def parser_name() -> str:
    return "fallback" if _import_pyyaml() is None else "pyyaml"


def main(argv: list[str]) -> int:
    args = [arg for arg in argv[1:] if arg not in ("-q", "--quiet")]
    if any(arg in ("-h", "--help") for arg in args):
        print("usage: yaml.py FILE")
        print("Convert a YAML document to JSON on stdout (PyYAML or stdlib fallback).")
        print("options: --parser  print which parser would be used and exit")
        return 0
    if "--parser" in args:
        print(parser_name())
        return 0
    args = [arg for arg in args if not arg.startswith("-")]
    if len(args) != 1:
        print("usage: yaml.py FILE", file=sys.stderr)
        return 3
    path = args[0]
    try:
        with open(path, "r", encoding="utf-8") as handle:
            document = handle.read()
    except OSError as exc:
        print("yaml.py: cannot read %s: %s" % (path, exc), file=sys.stderr)
        return 1
    try:
        data = load_document(document)
    except YamlError as exc:
        print("yaml.py: YAML parse error in %s: %s" % (path, exc), file=sys.stderr)
        return 2
    except Exception as exc:  # PyYAML raises its own exception hierarchy
        print("yaml.py: YAML parse error in %s: %s" % (path, exc), file=sys.stderr)
        return 2
    json.dump(data, sys.stdout, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
