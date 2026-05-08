#!/usr/bin/env python3
"""Resolve PlatformInit logical project config into GitHub Actions env vars."""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

import yaml

VALID_PROJECT = re.compile(r"^[a-z0-9][a-z0-9._-]*$")


def fail(message: str) -> None:
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def emit(key: str, value: str) -> None:
    print(f"{key}={value}")


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: project_resolver.py <project>")

    project = sys.argv[1].strip()
    if not VALID_PROJECT.match(project):
        fail(f"invalid project name: {project}")

    config_path = Path("platform/projects") / f"{project}.yaml"
    if not config_path.exists():
        fail(f"missing project registry file: {config_path}")

    with config_path.open("r", encoding="utf-8") as fh:
        cfg = yaml.safe_load(fh) or {}

    if cfg.get("project_id") != project:
        fail(f"project_id mismatch in {config_path}: expected {project}, got {cfg.get('project_id')}")

    hetzner = cfg.get("hetzner") or {}
    ssh = cfg.get("ssh") or {}
    volumes = cfg.get("volumes") or {}
    dns = cfg.get("dns") or {}

    token_secret = hetzner.get("token_secret")
    if not token_secret:
        fail(f"missing hetzner.token_secret in {config_path}")

    token = os.environ.get(token_secret, "").strip()
    if not token:
        fail(f"missing GitHub secret/env value for {token_secret}")

    emit("PLATFORMINIT_PROJECT", project)
    emit("HCLOUD_TOKEN", token)
    emit("HCLOUD_TOKEN_SECRET_NAME", token_secret)
    emit("REGION", str(hetzner.get("region", "hel1")))
    emit("SERVER_PREFIX", str(hetzner.get("server_prefix", f"platforminit-{project}")))
    emit("SSH_KEY_NAME", str(ssh.get("key_name", f"platforminit-{project}-automation")))
    emit("VOLUME_NAMESPACE", str(volumes.get("namespace", f"platforminit-{project}")))
    emit("DEFAULT_VOLUME_LAYOUT", str(volumes.get("layout", "split")))
    emit("BASE_DOMAIN", str(dns.get("base_domain", "")))


if __name__ == "__main__":
    main()
