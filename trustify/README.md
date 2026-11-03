# Trustify helpers (PoC)

Import OSV / CSAF feeds and upload a custom VEX so the Tekton **security gate**
can waive StackRox violations for CVEs marked `not_affected`.

## Role in the security gate

1. Pipeline uploads the image SBOM to Trustify (`POST /api/v3/sbom`).
2. SecOps (or this README) uploads a CSAF VEX advisory with `known_not_affected`.
3. The `security-gate` task queries Trustify for `not_affected` CVEs and filters
   matching ACS policy violations before deciding pass/fail.

Demo VEX document: [`quarkus-log4j-vex.csaf.json`](quarkus-log4j-vex.csaf.json)
(`CVE-2021-44228` → `known_not_affected` for `log4j-core@2.14.1`).

## GitHub OSV (Open Source Vulnerabilities)

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

## RedHat CSAF (Common Security Advisory Framework)

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

## Custom Quarkus VEX (CSAF 2.0)

Upload the demo VEX that marks Log4Shell as not affected for this application:

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @quarkus-log4j-vex.csaf.json
```

After this upload, a pipeline run on the still-vulnerable `log4j-core:2.14.1`
image should **pass** the security gate because `CVE-2021-44228` is waived via VEX.
