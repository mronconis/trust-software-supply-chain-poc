# Trustify — importers and VEX (PoC)

Helpers for the demo Step 2 in the root [`README.md`](../README.md): load vulnerability intelligence and upload the CSAF VEX that the Tekton **security gate** uses to waive ACS Log4Shell findings.

Trustify UI / API (after bootstrap port-forward): [http://localhost:8084](http://localhost:8084) · OpenAPI at `/openapi/`.

## Role in the security gate

1. Pipeline uploads the image SBOM (`POST /api/v3/sbom`).
2. SecOps creates importers (OSV / optional Red Hat CSAF) and uploads a CSAF VEX with `known_not_affected`.
3. Task `security-gate` loads advisories with `document.category == csaf_vex` and waives matching ACS violations before pass/fail.

Demo VEX: [`quarkus-log4j-vex.csaf.json`](quarkus-log4j-vex.csaf.json)  
→ `CVE-2021-44228` and `CVE-2021-45046` as `known_not_affected` for `pkg:maven/org.apache.logging.log4j/log4j-core@2.14.1`.

The ACS policy *Log4Shell: log4j Remote Code Execution vulnerability* fails on **both** CVEs; the VEX must cover both.

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
        "rhel-9",
        "rhsa-2021"
      ]
    }
  }'
```

## Upload demo CSAF VEX

From the `trustify/` directory (or adjust the path):

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @quarkus-log4j-vex.csaf.json
```

Verify:

```bash
curl -s "http://localhost:8084/api/v3/advisory?q=DEMO-VEX" | jq '.items[].document_id'
# → DEMO-VEX-QUARKUS-004
```

After a successful upload, re-run the pipeline with `./scripts/02-run-pipeline.sh` on the same vulnerable source; the gate should pass and Cosign should sign the image.
