#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import json
import os
import sys
import urllib.error
import urllib.request


def write_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if not output_path:
        print(f"{name}={value}")
        return
    with open(output_path, "a", encoding="utf-8") as fh:
        fh.write(f"{name}={value}\n")


def normalized_server_id(raw: str) -> str:
    return raw.strip().lstrip("#")


def resolve_with_api(token: str, server_id: str) -> str:
    req = urllib.request.Request(
        f"https://api.hetzner.cloud/v1/servers/{server_id}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            payload = json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        sys.stderr.write(body + "\n")
        raise SystemExit(1) from exc
    ip = (((payload.get("server") or {}).get("public_net") or {}).get("ipv4") or {}).get("ip")
    if not ip:
        sys.stderr.write(json.dumps(payload, indent=2) + "\n")
        raise SystemExit("Missing IPv4 in Hetzner API response")
    return ip


def main() -> int:
    token = os.environ.get("INFRA_API_TOKEN", "")
    default_server_id = os.environ.get("INFRA_SERVER_ID", "")
    override_server_id = os.environ.get("SERVER_ID_OVERRIDE", "")
    host_ipv4_override = os.environ.get("HOST_IPV4_OVERRIDE", "")

    server_id = normalized_server_id(override_server_id or default_server_id)
    if not server_id:
        raise SystemExit("Missing server id")

    if host_ipv4_override:
        try:
            ipaddress.IPv4Address(host_ipv4_override)
        except ipaddress.AddressValueError as exc:
            raise SystemExit(f"Invalid host_ipv4_override: {host_ipv4_override}") from exc
        sys.stderr.write(f"Using explicit host IPv4 override for break-glass/debug: {host_ipv4_override}\n")
        write_output("server_id", server_id)
        write_output("public_ip", host_ipv4_override)
        return 0

    if not token:
        raise SystemExit("Missing INFRA_API_TOKEN")

    public_ip = resolve_with_api(token=token, server_id=server_id)
    write_output("server_id", server_id)
    write_output("public_ip", public_ip)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
