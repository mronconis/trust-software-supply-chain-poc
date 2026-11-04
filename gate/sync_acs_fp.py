#!/usr/bin/env python3
"""Mirror Trustify-waived CRITICAL CVEs into ACS as approved false positives."""

from __future__ import annotations

import argparse
import json
import ssl
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

# Script may run from /opt/gate without an installed package.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_evidence import waived_critical  # noqa: E402


def parse_image_scope(image: str) -> tuple[str, str, str]:
    no_digest = image.split("@", 1)[0]
    registry, _, rest = no_digest.partition("/")
    if not rest:
        raise ValueError(f"invalid image ref: {image}")
    if ":" in rest:
        remote, tag = rest.rsplit(":", 1)
    else:
        remote, tag = rest, "latest"
    return registry, remote, tag


def _ssl_ctx() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def _request(
    method: str,
    url: str,
    token: str,
    body: dict[str, Any] | None = None,
) -> tuple[int, Any]:
    data = None
    headers = {"Authorization": f"Bearer {token}"}
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30, context=_ssl_ctx()) as resp:
            raw = resp.read().decode("utf-8")
            payload: Any = json.loads(raw) if raw else {}
            return resp.status, payload
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            payload = json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            payload = {"raw": raw}
        return exc.code, payload
    except Exception as exc:  # noqa: BLE001 — non-blocking side effect
        return 0, {"error": str(exc)}


def already_approved_fps(
    exceptions_payload: dict[str, Any],
    registry: str,
    remote: str,
    tag: str,
) -> set[str]:
    found: set[str] = set()
    for exc in exceptions_payload.get("exceptions") or []:
        if not isinstance(exc, dict):
            continue
        if exc.get("status") != "APPROVED":
            continue
        if exc.get("expired") is True:
            continue
        target = exc.get("targetState") or exc.get("target_state")
        if target != "FALSE_POSITIVE":
            continue
        scope = (exc.get("scope") or {}).get("imageScope") or (exc.get("scope") or {}).get(
            "image_scope"
        ) or {}
        if scope.get("registry") != registry:
            continue
        if scope.get("remote") != remote:
            continue
        if scope.get("tag") != tag:
            continue
        for cve in exc.get("cves") or []:
            if isinstance(cve, str):
                found.add(cve)
    return found


def sync_false_positives(
    *,
    evidence: dict[str, Any],
    central: str,
    token: str,
) -> int:
    waived = waived_critical(evidence)
    if not waived:
        print("Nothing to sync — no VEX-waived CRITICAL CVEs")
        return 0

    image = evidence["image"]
    registry, remote, tag = parse_image_scope(image)
    print(f"Image scope: registry={registry} remote={remote} tag={tag}")

    base = central.rstrip("/")
    if not base.startswith("http"):
        base = f"https://{base}"

    status, listing = _request(
        "GET",
        f"{base}/v2/vulnerability-exceptions?pagination.limit=500",
        token,
    )
    if status != 200 or not isinstance(listing, dict):
        print(f"warn: list exceptions HTTP {status} (non-blocking): {listing}")
        listing = {"exceptions": []}

    already = already_approved_fps(listing, registry, remote, tag)
    marked = 0
    to_mark: list[str] = []
    for cve in waived:
        if cve in already:
            print(f"already FP in ACS: {cve}")
            marked += 1
        else:
            to_mark.append(cve)

    if not to_mark:
        return marked

    print("Creating ACS false-positive exception for:")
    for cve in to_mark:
        print(f"  {cve}")

    payload = {
        "cves": to_mark,
        "comment": (
            "Synced from Trustify CSAF VEX (known_not_affected) by "
            f"Tekton sync-acs-false-positives for {image}"
        ),
        "scope": {
            "imageScope": {
                "registry": registry,
                "remote": remote,
                "tag": tag,
            }
        },
    }
    create_status, create_body = _request(
        "POST",
        f"{base}/v2/vulnerability-exceptions/false-positive",
        token,
        payload,
    )
    if create_status not in (200, 201):
        print(f"warn: create HTTP {create_status} (non-blocking): {create_body}")
        return marked

    exc_id = ""
    if isinstance(create_body, dict):
        exc = create_body.get("exception") or {}
        if isinstance(exc, dict):
            exc_id = str(exc.get("id") or "")
    print(f"Created exception id={exc_id} (HTTP {create_status})")
    if not exc_id:
        return marked

    approve_status, approve_body = _request(
        "POST",
        f"{base}/v2/vulnerability-exceptions/{exc_id}/approve",
        token,
        {"comment": "Auto-approved by Tekton: Trustify VEX is source of truth"},
    )
    if approve_status == 200:
        marked += len(to_mark)
        print(f"Approved exception — {len(to_mark)} CVE(s) marked false positive in ACS")
    else:
        print(f"warn: approve HTTP {approve_status} (non-blocking): {approve_body}")
    return marked


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--rox-central", required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--marked-out", type=Path, default=None)
    args = parser.parse_args(argv)

    evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
    token = args.token_file.read_text(encoding="utf-8").strip()
    marked = sync_false_positives(
        evidence=evidence,
        central=args.rox_central,
        token=token,
    )
    print(f"ACS FP marked/confirmed: {marked}")
    if args.marked_out:
        args.marked_out.parent.mkdir(parents=True, exist_ok=True)
        args.marked_out.write_text(str(marked), encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
