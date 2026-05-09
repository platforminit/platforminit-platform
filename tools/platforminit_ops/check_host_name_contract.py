#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

CANONICAL_DEV_HOST = "platforminit-dev-01"
FORBIDDEN_TOKENS = [
    "platforminit-" + "develop" + "ment-01",
]
SCAN_ROOTS = [
    pathlib.Path(".github"),
    pathlib.Path("platform"),
    pathlib.Path("docs"),
    pathlib.Path("scripts"),
    pathlib.Path("tools"),
]
SKIP_DIRS = {".git", "node_modules", "dist", "artifacts", "__pycache__"}
BINARY_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".zip", ".gz", ".tar", ".db"}


def iter_files() -> list[pathlib.Path]:
    files: list[pathlib.Path] = []
    for root in SCAN_ROOTS:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            if any(part in SKIP_DIRS for part in path.parts):
                continue
            if path.suffix.lower() in BINARY_SUFFIXES:
                continue
            files.append(path)
    return sorted(files)


def main() -> int:
    violations: list[str] = []
    for path in iter_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for token in FORBIDDEN_TOKENS:
            if token in text:
                for lineno, line in enumerate(text.splitlines(), start=1):
                    if token in line:
                        violations.append(f"{path}:{lineno}: forbidden host token {token!r}")

    if violations:
        print("Host naming contract violation detected.", file=sys.stderr)
        print(f"Use canonical development host: {CANONICAL_DEV_HOST}", file=sys.stderr)
        print("", file=sys.stderr)
        for item in violations:
            print(item, file=sys.stderr)
        return 1

    print(f"Host naming contract OK: canonical development host is {CANONICAL_DEV_HOST}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
