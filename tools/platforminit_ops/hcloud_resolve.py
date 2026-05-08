#!/usr/bin/env python3
from __future__ import annotations

import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
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


def hcloud_get(token: str, path: str) -> dict:
    req = urllib.request.Request(
        f"https://api.hetzner.cloud/v1/{path.lstrip('/')}",
        headers={"Authorization": f"Bearer {token}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.load(resp)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        sys.stderr.write(body + "\n")
        raise SystemExit(1) from exc


def server_fields(payload: dict) -> tuple[str, str, dict]:
    server = payload.get("server") or {}
    server_id = str(server.get("id") or "")
    ip = (((server.get("public_net") or {}).get("ipv4") or {}).get("ip") or "")
    labels = server.get("labels") or {}
    if not server_id or not ip:
        sys.stderr.write(json.dumps(payload, indent=2) + "\n")
        raise SystemExit("Missing server id or IPv4 in Hetzner API response")
    return server_id, ip, labels


def resolve_by_id(token: str, server_id: str) -> tuple[str, str, dict]:
    return server_fields(hcloud_get(token, f"servers/{server_id}"))


def resolve_by_labels(token: str, project: str, host_name: str) -> tuple[str, str, dict]:
    selector = f"platforminit.project={project},platforminit.host={host_name}"
    query = urllib.parse.urlencode({"label_selector": selector})
    payload = hcloud_get(token, f"servers?{query}")
    servers = payload.get("servers") or []
    if len(servers) != 1:
        names = ", ".join(str(s.get("name")) for s in servers) or "none"
        raise SystemExit(
            f"Expected exactly one Hetzner server for labels {selector!r}, found {len(servers)}: {names}"
        )
    return server_fields({"server": servers[0]})


def resolve_by_role(token: str, project: str, role: str) -> tuple[str, str, dict]:
    selector = f"platforminit.project={project},platforminit.role={role}"
    query = urllib.parse.urlencode({"label_selector": selector})
    payload = hcloud_get(token, f"servers?{query}")
    servers = payload.get("servers") or []
    if len(servers) != 1:
        names = ", ".join(str(s.get("name")) for s in servers) or "none"
        raise SystemExit(
            f"Expected exactly one Hetzner server for labels {selector!r}, found {len(servers)}: {names}"
        )
    return server_fields({"server": servers[0]})


def main() -> int:
    token = os.environ.get("HCLOUD_TOKEN", "") or os.environ.get("INFRA_API_TOKEN", "")
    default_server_id = os.environ.get("INFRA_SERVER_ID", "")
    override_server_id = os.environ.get("SERVER_ID_OVERRIDE", "")
    host_ipv4_override = os.environ.get("HOST_IPV4_OVERRIDE", "")
    project = os.environ.get("PLATFORMINIT_PROJECT", "").strip()
    host_name = os.environ.get("PLATFORMINIT_HOST_NAME", "").strip()
    role = os.environ.get("PLATFORMINIT_ROLE", "").strip()

    if not token:
        raise SystemExit("Missing HCLOUD_TOKEN / infra_api_token")

    explicit_server_id = normalized_server_id(override_server_id)
    fallback_server_id = normalized_server_id(default_server_id)

    if explicit_server_id:
        server_id, public_ip, labels = resolve_by_id(token, explicit_server_id)
        resolution_mode = "server_id_override"
    elif project and host_name:
        server_id, public_ip, labels = resolve_by_labels(token, project, host_name)
        resolution_mode = "label_discovery_host"
    elif project and role:
        server_id, public_ip, labels = resolve_by_role(token, project, role)
        resolution_mode = "label_discovery_role"
    elif fallback_server_id:
        server_id, public_ip, labels = resolve_by_id(token, fallback_server_id)
        resolution_mode = "legacy_infra_server_id"
    else:
        raise SystemExit("Missing server selector: use server_id_override, or project + host_name, or project + role, or INFRA_SERVER_ID fallback")

    if host_ipv4_override:
        try:
            ipaddress.IPv4Address(host_ipv4_override)
        except ipaddress.AddressValueError as exc:
            raise SystemExit(f"Invalid host_ipv4_override: {host_ipv4_override}") from exc
        sys.stderr.write(f"Using explicit host IPv4 override for break-glass/debug: {host_ipv4_override}\n")
        public_ip = host_ipv4_override

    write_output("server_id", server_id)
    write_output("public_ip", public_ip)
    write_output("resolution_mode", resolution_mode)
    write_output("project", labels.get("platforminit.project", project))
    write_output("host_name", labels.get("platforminit.host", host_name))
    write_output("volume_layout", labels.get("platforminit.volume_layout", "single"))
    write_output("role", labels.get("platforminit.role", role or "primary"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
