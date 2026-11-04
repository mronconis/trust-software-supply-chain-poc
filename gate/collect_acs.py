#!/usr/bin/env python3
"""Normalize ACS / roxctl image-scan JSON into critical CVE inventory."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

CVE_RE = re.compile(r"^CVE-[0-9]{4}-[0-9]+$")


def _is_critical(item: dict[str, Any]) -> bool:
    severity = str(item.get("cveSeverity") or item.get("severity") or "")
    if "CRITICAL" in severity.upper():
        return True
    return item.get("severity") == "CRITICAL_VULNERABILITY_SEVERITY"


def _cve_id(item: dict[str, Any]) -> str | None:
    raw = item.get("cveId") or item.get("cve")
    if not raw:
        info = item.get("cveInfo")
        if isinstance(info, dict):
            raw = info.get("cve")
    if isinstance(raw, str) and CVE_RE.match(raw):
        return raw
    return None


def _root(scan: dict[str, Any]) -> dict[str, Any]:
    if isinstance(scan.get("result"), dict):
        return scan["result"]
    if isinstance(scan.get("scan"), dict):
        return scan["scan"]
    return scan


def extract_critical_cves(scan: dict[str, Any]) -> list[str]:
    root = _root(scan)
    found: set[str] = set()

    for vuln in root.get("vulnerabilities") or []:
        if isinstance(vuln, dict) and _is_critical(vuln):
            cve = _cve_id(vuln)
            if cve:
                found.add(cve)

    for component in root.get("components") or []:
        if not isinstance(component, dict):
            continue
        for vuln in component.get("vulns") or []:
            if isinstance(vuln, dict) and _is_critical(vuln):
                cve = _cve_id(vuln)
                if cve:
                    found.add(cve)

    return sorted(found)


def extract_total_vulnerabilities(scan: dict[str, Any]) -> int:
    root = _root(scan)
    summary = root.get("summary") or {}
    if isinstance(summary, dict):
        for key in ("TOTAL-VULNERABILITIES", "TOTAL_VULNERABILITIES", "total"):
            if key in summary and summary[key] is not None:
                try:
                    return int(summary[key])
                except (TypeError, ValueError):
                    pass

    vulns = root.get("vulnerabilities")
    if isinstance(vulns, list):
        return len(vulns)

    total = 0
    for component in root.get("components") or []:
        if isinstance(component, dict):
            total += len(component.get("vulns") or [])
    return total


def collect_from_scan(scan: dict[str, Any] | None) -> dict[str, Any]:
    if not scan:
        return {
            "source": "acs",
            "critical_cves": [],
            "total_vulnerabilities": 0,
        }
    return {
        "source": "acs",
        "critical_cves": extract_critical_cves(scan),
        "total_vulnerabilities": extract_total_vulnerabilities(scan),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scan-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)

    scan: dict[str, Any] | None = None
    if args.scan_json.is_file():
        scan = json.loads(args.scan_json.read_text(encoding="utf-8"))
    else:
        print(f"warn: scan file missing: {args.scan_json}", file=sys.stderr)

    result = collect_from_scan(scan)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(
        f"ACS scan: critical={len(result['critical_cves'])} "
        f"total={result['total_vulnerabilities']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
