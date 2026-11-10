#!/usr/bin/env python3
"""Validate an App Intents metadata package (Metadata.appintents).

This is the check v2.4-v2.6 were missing: it inspects the file iOS
actually reads to discover App Shortcuts (extract.actionsdata), not a
proxy like the binary's symbols. A package that exists but names no
intent fails, so a build that would ship an invisible shortcut fails
here instead of on the user's phone.

Usage: check_appintents_metadata.py <Metadata.appintents dir>
Exit 0 when the package contains CleanCacheIntent (discoverable,
background) and the CleanerShortcuts auto-shortcuts with both phrases;
exit 1 with a diagnosis otherwise. The checks are schema-tolerant on
purpose: the processor's JSON nests the flags/title at various depths
across Xcode versions, so each check searches below the object that
names the intent instead of assuming a fixed path.
"""

import json
import sys
from pathlib import Path

INTENT = "CleanCacheIntent"
PROVIDER = "CleanerShortcuts"
TITLE = "清理全部缓存"
PHRASES = ("清理全部缓存", "清理缓存")


def walk(node):
    """Yield every node below node, inclusive."""
    yield node
    if isinstance(node, dict):
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for item in node:
            yield from walk(item)


def find_key_values(node, key):
    """All values stored under key anywhere below node."""
    for sub in walk(node):
        if isinstance(sub, dict) and key in sub:
            yield sub[key]


def subtree_text(node):
    """Every string in the subtree, joined — for tolerant text checks."""
    parts = []
    for sub in walk(node):
        if isinstance(sub, dict):
            parts.extend(str(key) for key in sub)
            parts.extend(str(v) for v in sub.values() if isinstance(v, str))
        elif isinstance(sub, str):
            parts.append(sub)
    return "\n".join(parts)


def main(argv):
    package = Path(argv[1]) if len(argv) > 1 else None
    if package is None or not package.is_dir():
        print(f"app intents metadata: {package} is not a directory", file=sys.stderr)
        return 1
    actions_path = package / "extract.actionsdata"
    version_path = package / "version.json"
    if not actions_path.is_file():
        print(f"app intents metadata: missing {actions_path}", file=sys.stderr)
        return 1
    if not version_path.is_file():
        print(f"app intents metadata: missing {version_path}", file=sys.stderr)
        return 1
    try:
        data = json.loads(actions_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"app intents metadata: {actions_path} is not valid JSON: {exc}", file=sys.stderr)
        return 1
    try:
        json.loads(version_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"app intents metadata: {version_path} is not valid JSON: {exc}", file=sys.stderr)
        return 1

    errors = []
    # The CleanCacheIntent action: find the object that names it (as an
    # identifier/name/type value, or as a dict key), then check its own
    # subtree for the flags and the title.
    intent_nodes = []
    for node in walk(data):
        if not isinstance(node, dict):
            continue
        if INTENT in (str(node.get("identifier", "")), str(node.get("name", "")),
                      str(node.get("type", ""))) or INTENT in node:
            intent_nodes.append(node)
    if not intent_nodes:
        errors.append(f"no {INTENT} action in extract.actionsdata")
    else:
        intent = intent_nodes[0]
        discoverable = list(find_key_values(intent, "isDiscoverable"))
        if True not in discoverable:
            errors.append(f"{INTENT}: isDiscoverable is not true (found {discoverable!r})")
        open_app = list(find_key_values(intent, "openAppWhenRun"))
        if False not in open_app:
            errors.append(f"{INTENT}: openAppWhenRun is not false (found {open_app!r})")
        if TITLE not in subtree_text(intent):
            errors.append(f"{INTENT}: title {TITLE!r} not found")

    # The CleanerShortcuts auto-shortcuts: any section whose key names
    # shortcuts, whose subtree names the provider and carries both
    # phrases. The phrases may carry the literal app name or the
    # \(.applicationName) placeholder — both contain the two substrings
    # below, so the check accepts either form.
    shortcut_sections = []
    for node in walk(data):
        if isinstance(node, dict):
            for key, value in node.items():
                if "shortcut" in str(key).lower():
                    shortcut_sections.append(value)
    shortcut_ok = False
    for section in shortcut_sections:
        text = subtree_text(section)
        if PROVIDER in text and all(phrase in text for phrase in PHRASES):
            shortcut_ok = True
            break
    if not shortcut_ok:
        errors.append(
            f"no autoShortcuts section naming {PROVIDER} with both phrases "
            f"({PHRASES[0]!r} / {PHRASES[1]!r})"
        )

    if errors:
        for error in errors:
            print(f"app intents metadata: {error}", file=sys.stderr)
        top = list(data) if isinstance(data, dict) else type(data).__name__
        print(f"app intents metadata: top-level keys: {top}", file=sys.stderr)
        print(f"app intents metadata: {actions_path.read_text(encoding='utf-8')[:2000]}",
              file=sys.stderr)
        return 1
    print(f"app intents metadata OK: {INTENT} (discoverable, background) + "
          f"{PROVIDER} ({len(PHRASES)} phrases)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
