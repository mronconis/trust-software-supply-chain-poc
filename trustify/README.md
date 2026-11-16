# Trustify — importers and VEX (PoC)

Helpers for demo Step 2 in the root [`README.md`](../README.md): load vulnerability intelligence and upload the CSAF VEX. Trustify is the **Single Source of Truth (SSOT)** for VEX / exploitability used by the Conforma CVE gate.

Trustify UI / API: [http://localhost:8084](http://localhost:8084) · OpenAPI at `/openapi/`.

## Role in the security gate

1. Pipeline uploads the image SBOM (`POST /api/v3/sbom`).
2. Task `collect-security-evidence` runs an informational ACS scan and loads Trustify CSAF VEX into `evidence.json`.
3. SecOps uploads a CSAF VEX (`known_not_affected`) — and optionally OSV/CSAF importers.
4. Task `conforma-cve-gate` runs `ec validate input` and **blocks only CRITICAL CVEs that are not waived**.
5. Task `sync-acs-false-positives` mirrors waived CRITICAL CVEs into ACS as **approved false-positive exceptions** (exact image registry/remote/tag — not `.*`).

Demo VEX: [`quarkus-log4j-vex.csaf.json`](quarkus-log4j-vex.csaf.json)  
→ `CVE-2021-44228` and `CVE-2021-45046` as `known_not_affected` for `pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1`.

Both CRITICAL CVEs from the ACS scan must be waived or Conforma fails. Trustify remains the VEX **SSOT**; ACS Exception Management is updated to match that VEX (one-way sync).

## GitHub OSV importer

```bash
curl -X POST "http://localhost:8084/api/v3/importer/osv-github-2021" \
  -H "Content-Type: application/json" \
  -d '{
    "osv": {
      "description": "GitHub Advisory Database (2021 only)",
      "source": "https://github.com/github/advisory-database",
      "path": "advisories/github-reviewed/2021",
      "period": "1d",
      "disabled": false
    }
  }'
```

## Red Hat CSAF importer (optional)

```bash
curl -X POST "http://localhost:8084/api/v3/importer/redhat-csaf-quarkus" \
  -H "Content-Type: application/json" \
  -d '{
    "csaf": {
      "description": "Red Hat Quarkus & UBI CSAF Feed",
      "source": "https://redhat.com/.well-known/csaf/provider-metadata.json",
      "v3Signatures": true,
      "disabled": false,
      "period": "1d",
      "onlyPatterns": [
        "quarkus",
        "rhel-9"
      ]
    }
  }'
```

## Upload demo CSAF VEX

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @quarkus-log4j-vex.csaf.json
```

```bash
curl -s "http://localhost:8084/api/v3/advisory?q=DEMO-VEX" | jq '.items[].document_id'
# → DEMO-VEX-QUARKUS-004
```

Then re-run `./scripts/02-run-pipeline.sh` on the same vulnerable source; Conforma should pass and Cosign should sign the image.
