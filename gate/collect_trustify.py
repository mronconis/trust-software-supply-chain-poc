#!/usr/bin/env python3
"""Load CSAF VEX known_not_affected CVEs from Trustify."""

from __future__ import annotations

import argparse
import json
import re
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

CVE_RE = re.compile(r"^CVE-[0-9]{4}-[0-9]+$")
QUERY_TERMS = ("csaf_vex", "DEMO-VEX", "VEX")


def _http_get_json(url: str, timeout: float = 15.0) -> Any | None:
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(url, timeout=timeout, context=ctx) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        print(f"warn: GET {url}: {exc}", file=sys.stderr)
        return None


def _reachable(base_url: str) -> bool:
    base = base_url.rstrip("/")
    # Prefer the advisory API (JSON). Root may return non-JSON HTML.
    if _http_get_json(f"{base}/api/v3/advisory?limit=1") is not None:
        return True
    try:
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(f"{base}/", timeout=5, context=ctx):
            return True
    except Exception:
        return False


def _advisory_uuids(base_url: str) -> list[str]:
    base = base_url.rstrip("/")
    seen: set[str] = set()
    ordered: list[str] = []

    urls = [f"{base}/api/v3/advisory?limit=50&q={q}" for q in QUERY_TERMS]
    urls.append(f"{base}/api/v3/advisory?limit=20&sort=ingested%3Adesc")

    for url in urls:
        payload = _http_get_json(url)
        if not isinstance(payload, dict):
            continue
        for item in payload.get("items") or []:
            if not isinstance(item, dict):
                continue
            uuid = item.get("uuid")
            if isinstance(uuid, str) and uuid and uuid not in seen:
                seen.add(uuid)
                ordered.append(uuid)
    return ordered


def _download_advisory(base_url: str, uuid: str) -> dict[str, Any] | None:
    base = base_url.rstrip("/")
    for path in (f"/api/v3/advisory/{uuid}/download", f"/api/v3/advisory/{uuid}"):
        payload = _http_get_json(f"{base}{path}")
        if isinstance(payload, dict) and "document" in payload:
            return payload
    return None


def extract_known_not_affected(csaf: dict[str, Any]) -> tuple[str | None, list[str]]:
    document = csaf.get("document") or {}
    if document.get("category") != "csaf_vex":
        return None, []

    tracking = document.get("tracking") or {}
    advisory_id = tracking.get("id") or document.get("title")

    cves: set[str] = set()
    for vuln in csaf.get("vulnerabilities") or []:
        if not isinstance(vuln, dict):
            continue
        status = vuln.get("product_status") or {}
        not_affected = status.get("known_not_affected") or []
        if not not_affected:
            continue
        cve = vuln.get("cve")
        if isinstance(cve, str) and CVE_RE.match(cve):
            cves.add(cve)
    return (str(advisory_id) if advisory_id else None), sorted(cves)


def collect_from_trustify(base_url: str) -> dict[str, Any]:
    if not _reachable(base_url):
        print("warn: Trustify not reachable — no VEX waivers", file=sys.stderr)
        return {
            "source": "trustify",
            "advisories": [],
            "known_not_affected": [],
        }

    advisories: list[str] = []
    cves: set[str] = set()
    for uuid in _advisory_uuids(base_url):
        csaf = _download_advisory(base_url, uuid)
        if not csaf:
            continue
        advisory_id, waived = extract_known_not_affected(csaf)
        if advisory_id is None:
            continue
        advisories.append(advisory_id)
        cves.update(waived)
        print(f"CSAF VEX: {advisory_id} ({len(waived)} known_not_affected)")

    return {
        "source": "trustify",
        "advisories": sorted(set(advisories)),
        "known_not_affected": sorted(cves),
    }


def collect_from_csaf_files(paths: list[Path]) -> dict[str, Any]:
    """Offline helper for tests: load VEX directly from CSAF files."""
    advisories: list[str] = []
    cves: set[str] = set()
    for path in paths:
        csaf = json.loads(path.read_text(encoding="utf-8"))
        advisory_id, waived = extract_known_not_affected(csaf)
        if advisory_id is None:
            continue
        advisories.append(advisory_id)
        cves.update(waived)
    return {
        "source": "trustify",
        "advisories": sorted(set(advisories)),
        "known_not_affected": sorted(cves),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trustify-url", default="")
    parser.add_argument("--csaf-file", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    if args.csaf_file:
        result = collect_from_csaf_files(args.csaf_file)
    elif args.trustify_url:
        result = collect_from_trustify(args.trustify_url)
    else:
        print("error: provide --trustify-url or --csaf-file", file=sys.stderr)
        return 2

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        f"Trustify VEX: advisories={len(result['advisories'])} "
        f"known_not_affected={len(result['known_not_affected'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
