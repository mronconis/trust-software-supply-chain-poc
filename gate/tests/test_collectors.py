from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parent
sys.path.insert(0, str(ROOT))

from assemble_evidence import assemble, blocking_critical, waived_critical  # noqa: E402
from collect_acs import collect_from_scan, extract_critical_cves  # noqa: E402
from collect_trustify import collect_from_csaf_files, extract_known_not_affected  # noqa: E402
from sync_acs_fp import already_approved_fps, parse_image_scope  # noqa: E402

FIXTURES = Path(__file__).parent / "fixtures"


def test_extract_critical_from_result_vulnerabilities():
    scan = json.loads((FIXTURES / "acs-scan-critical.json").read_text(encoding="utf-8"))
    assert extract_critical_cves(scan) == ["CVE-2021-44228", "CVE-2021-45046"]
    result = collect_from_scan(scan)
    assert result["total_vulnerabilities"] == 255
    assert result["source"] == "acs"


def test_extract_critical_legacy_components():
    scan = {
        "scan": {
            "components": [
                {
                    "vulns": [
                        {
                            "cve": "CVE-2021-44228",
                            "severity": "CRITICAL_VULNERABILITY_SEVERITY",
                        },
                        {"cve": "CVE-2019-1", "severity": "LOW_VULNERABILITY_SEVERITY"},
                    ]
                }
            ]
        }
    }
    assert extract_critical_cves(scan) == ["CVE-2021-44228"]


def test_trustify_csaf_known_not_affected():
    vex_path = REPO / "trustify" / "quarkus-log4j-vex.csaf.json"
    csaf = json.loads(vex_path.read_text(encoding="utf-8"))
    advisory_id, cves = extract_known_not_affected(csaf)
    assert advisory_id == "DEMO-VEX-QUARKUS-004"
    assert cves == ["CVE-2021-44228", "CVE-2021-45046"]

    collected = collect_from_csaf_files([vex_path])
    assert "DEMO-VEX-QUARKUS-004" in collected["advisories"]
    assert collected["known_not_affected"] == ["CVE-2021-44228", "CVE-2021-45046"]


def test_assemble_pass_and_fail():
    scan = collect_from_scan(
        json.loads((FIXTURES / "acs-scan-critical.json").read_text(encoding="utf-8"))
    )
    empty_vex = {"source": "trustify", "advisories": [], "known_not_affected": []}
    fail_ev = assemble("quay.io/mronconi/trusted-quarkus-app:insecure", scan, empty_vex)
    assert blocking_critical(fail_ev) == ["CVE-2021-44228", "CVE-2021-45046"]
    assert waived_critical(fail_ev) == []

    full_vex = collect_from_csaf_files([REPO / "trustify" / "quarkus-log4j-vex.csaf.json"])
    pass_ev = assemble("quay.io/mronconi/trusted-quarkus-app:vex-waived", scan, full_vex)
    assert blocking_critical(pass_ev) == []
    assert waived_critical(pass_ev) == ["CVE-2021-44228", "CVE-2021-45046"]
    assert pass_ev["apiVersion"] == "trust-supply-chain.poc/v1"
    assert pass_ev["kind"] == "SecurityEvidence"


def test_parse_image_scope_and_fp_idempotency():
    assert parse_image_scope("quay.io/mronconi/app:tag") == (
        "quay.io",
        "mronconi/app",
        "tag",
    )
    assert parse_image_scope("quay.io/mronconi/app@sha256:abc") == (
        "quay.io",
        "mronconi/app",
        "latest",
    )

    listing = {
        "exceptions": [
            {
                "status": "APPROVED",
                "expired": True,
                "targetState": "FALSE_POSITIVE",
                "cves": ["CVE-2021-44228"],
                "scope": {
                    "imageScope": {
                        "registry": "quay.io",
                        "remote": "mronconi/app",
                        "tag": ".*",
                    }
                },
            },
            {
                "status": "APPROVED",
                "expired": False,
                "targetState": "FALSE_POSITIVE",
                "cves": ["CVE-2021-45046"],
                "scope": {
                    "imageScope": {
                        "registry": "quay.io",
                        "remote": "mronconi/app",
                        "tag": "vex-waived",
                    }
                },
            },
        ]
    }
    already = already_approved_fps(listing, "quay.io", "mronconi/app", "vex-waived")
    assert already == {"CVE-2021-45046"}


def test_evidence_schema_shape():
    jsonschema = pytest.importorskip("jsonschema")
    schema = json.loads((ROOT / "schema" / "evidence.schema.json").read_text(encoding="utf-8"))
    scan = collect_from_scan(
        json.loads((FIXTURES / "acs-scan-critical.json").read_text(encoding="utf-8"))
    )
    vex = collect_from_csaf_files([REPO / "trustify" / "quarkus-log4j-vex.csaf.json"])
    evidence = assemble("quay.io/mronconi/trusted-quarkus-app:t", scan, vex)
    jsonschema.validate(evidence, schema)
