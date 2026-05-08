#!/usr/bin/env python3
import os
import sys
from pathlib import Path

import yaml


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: project_resolver.py <project>", file=sys.stderr)
        return 2

    project = sys.argv[1]
    project_file = Path("platform/projects") / f"{project}.yaml"
    if not project_file.is_file():
        print(f"Missing project config: {project_file}", file=sys.stderr)
        return 1

    cfg = yaml.safe_load(project_file.read_text())
    token_env = cfg["hetzner"]["token_secret"]
    token = os.getenv(token_env)
    if not token:
        print(f"Missing token: {token_env}", file=sys.stderr)
        return 1

    values = {
        "HCLOUD_TOKEN": token,
        "REGION": cfg["hetzner"]["region"],
        "SERVER_PREFIX": cfg["hetzner"]["server_prefix"],
        "SSH_KEY_NAME": cfg["ssh"]["key_name"],
        "VOLUME_NAMESPACE": cfg["volumes"]["namespace"],
        "PROJECT_VOLUME_LAYOUT": cfg["volumes"].get("layout", "split"),
    }
    for key, value in values.items():
        print(f"{key}={value}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
