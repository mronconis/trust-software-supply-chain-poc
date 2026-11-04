#!/usr/bin/env python3
"""Assemble SecurityEvidence JSON for Conforma `ec validate input`."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


API_VERSION = "trust-supply-chain.poc/v1"
KIND = "SecurityEvidence"


def assemble(
    image: str,
    scan: dict[str, Any],
    vex: dict[str, Any],
) -> dict[str, Any]:
    return {
        "apiVersion": API_VERSION,
        "kind": KIND,
        "image": image,
        "scan": {
            "source": scan.get("source", "acs"),
            "critical_cves": sorted(set(scan.get("critical_cves") or [])),
            "total_vulnerabilities": int(scan.get("total_vulnerabilities") or 0),
        },
        "vex": {
            "source": vex.get("source", "trustify"),
            "advisories": sorted(set(vex.get("advisories") or [])),
            "known_not_affected": sorted(set(vex.get("known_not_affected") or [])),
        },
    }


def waived_critical(evidence: dict[str, Any]) -> list[str]:
    critical = set(evidence["scan"]["critical_cves"])
    waived = set(evidence["vex"]["known_not_affected"])
    return sorted(critical & waived)


def blocking_critical(evidence: dict[str, Any]) -> list[str]:
    critical = set(evidence["scan"]["critical_cves"])
    waived = set(evidence["vex"]["known_not_affected"])
    return sorted(critical - waived)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", required=True)
    parser.add_argument("--scan-json", type=Path, required=True)
    parser.add_argument("--vex-json", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--counts-dir", type=Path, default=None)
    args = parser.parse_args(argv)

    scan = json.loads(args.scan_json.read_text(encoding="utf-8"))
    vex = json.loads(args.vex_json.read_text(encoding="utf-8"))
    evidence = assemble(args.image, scan, vex)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")

    critical = evidence["scan"]["critical_cves"]
    waived = waived_critical(evidence)
    blocking = blocking_critical(evidence)

    print(f"Evidence written: {args.output}")
    print(f"  CRITICAL : {len(critical)}")
    print(f"  VEX waive: {len(waived)}")
    print(f"  Blocking : {len(blocking)}")
    for cve in blocking:
        print(f"  ● block   {cve}")
    for cve in waived:
        print(f"  ○ waived  {cve}")

    if args.counts_dir:
        args.counts_dir.mkdir(parents=True, exist_ok=True)
        (args.counts_dir / "CRITICAL_COUNT").write_text(str(len(critical)), encoding="utf-8")
        (args.counts_dir / "TOTAL_VULN_COUNT").write_text(
            str(evidence["scan"]["total_vulnerabilities"]), encoding="utf-8"
        )
        (args.counts_dir / "VEX_WAIVED_COUNT").write_text(str(len(waived)), encoding="utf-8")
        (args.counts_dir / "BLOCKING_COUNT").write_text(str(len(blocking)), encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
