# Trusted Software Supply Chain — Proof of Concept

End-to-end demo of a trusted software supply chain using the upstream projects behind the Red Hat Trusted Software Supply Chain portfolio. The pipeline builds a Quarkus image, generates an SBOM, evaluates ACS build-time policies, and signs the artefact with Cosign — only if a VEX-aware security gate allows it.

---

## What this PoC shows

1. **ACS blocks** a build that ships Log4Shell (`log4j-core` 2.14.1) when Trustify has no VEX exception.
2. **SecOps imports** vulnerability intelligence (OSV) and a CSAF VEX that marks the finding as `known_not_affected`.
3. **The same insecure code passes** the gate: StackRox still reports the CVE; Trustify VEX waives it as a documented false positive; Cosign signs the image.

```
┌──────────┐    ┌──────────┐    ┌───────────────────┐    ┌─────────────────────┐    ┌────────────┐
│  Source  │───▸│  Build   │───▸│ SBOM + GUAC       │───▸│ Security Gate       │───▸│ Sign       │
│ (GitHub) │    │(Buildah) │    │       + Trustify  │    │ StackRox + VEX      │    │ (Cosign)   │
└──────────┘    └──────────┘    └───────────────────┘    └──────────┬──────────┘    └────────────┘
                                   │             │                   │
                                   ▼             ▼            Remaining ACS
                               GUAC          Trustify         violation after
                           (dep graph)    (SBOM + VEX)         VEX filter?
                                                              ╱         ╲
                                                            YES          NO
                                                             ↓            ↓
                                                       ❌ HALTED    ✅ SIGNED
```

| Upstream | Red Hat product | Role in this PoC |
|---|---|---|
| Tekton Pipelines | OpenShift Pipelines | CI/CD engine |
| Sigstore / Cosign | Trusted Artifact Signer (TAS) | Image signing |
| GUAC | Trusted Profile Analyzer (TPA) | Dependency graph |
| Trustify | Trusted Profile Analyzer (TPA) | SBOM store, advisories, VEX |
| StackRox / roxctl | Advanced Cluster Security (ACS) | Image scan + build policies |
| Syft + CycloneDX | — | SBOM generation |

---

## Repository layout

```
├── quarkus-app/                     # Sample Quarkus app (deliberately vulnerable log4j)
├── tekton/
│   ├── tasks/
│   │   ├── build-and-push.yaml
│   │   ├── generate-sbom.yaml       # Syft → GUAC + Trustify ingest
│   │   ├── security-gate.yaml       # StackRox check + Trustify VEX filter
│   │   └── sign-and-attest.yaml
│   └── pipelines/trusted-supply-chain.yaml
├── trustify/
│   ├── trustify-deployment.yaml
│   ├── quarkus-log4j-vex.csaf.json  # Demo CSAF VEX (Log4Shell not_affected)
│   └── README.md                    # Importer / VEX curl helpers
├── guac/  stackrox/  kind-config.yaml
└── scripts/
    ├── 01-bootstrap-cluster.sh
    ├── 02-run-pipeline.sh           # Primary entrypoint for demo runs
    ├── 03-verify.sh
    └── 04-cleanup.sh
```

---

## Prerequisites

| Tool | Min. version | Install (macOS) |
|---|---|---|
| Docker / Podman | 24+ | `brew install --cask docker` |
| kind | 0.23+ | `brew install kind` |
| kubectl | 1.28+ | `brew install kubectl` |
| helm | 3.14+ | `brew install helm` |
| cosign | 2.2+ | `brew install cosign` |
| tkn | 0.37+ | `brew install tektoncd-cli` |

Quay.io credentials with push access to the target namespace. Create `.env` in the repo root (git-ignored):

```bash
QUAY_USERNAME=<your-username>
QUAY_PASSWORD=<your-token-or-password>
```

---

## Bootstrap

```bash
git clone https://github.com/mronconis/trust-software-supply-chain-poc.git
cd trust-software-supply-chain-poc
./scripts/01-bootstrap-cluster.sh
```

The script creates a Kind cluster (`tssc`), installs Tekton, GUAC, Trustify, and StackRox/ACS, applies Tekton Tasks/Pipeline, generates a Cosign keypair under `.keys/`, creates registry and ACS secrets, and starts port-forwards for GUAC and Trustify.

```bash
kubectl get pods -n tekton-pipelines
kubectl get pods -n stackrox                  # central, scanner-v4-*
kubectl get pods -n guac
kubectl get pods -n trustify                  # trustify-db + trustify-server
kubectl get pipelines -n trusted-supply-chain
```

| Service | URL | Notes |
|---|---|---|
| ACS Central | https://localhost:30443 | `admin` / `stackrox` (accept self-signed cert) |
| Trustify | http://localhost:8084 | Auth disabled in this PoC |
| GUAC Visualizer | http://localhost:3000 | After SBOM ingest |
| GUAC GraphQL | http://localhost:8085/query | |

Bootstrap enables **Enforce on Build** for the ACS policy *Log4Shell: log4j Remote Code Execution vulnerability* (covers `CVE-2021-44228` and `CVE-2021-45046`). Other severity policies remain inform-only.

---

## Demo walkthrough

Use `./scripts/02-run-pipeline.sh` for each pipeline run. The application under test pins a vulnerable dependency on purpose:

```xml
<!-- quarkus-app/pom.xml -->
<dependency>
    <groupId>org.apache.logging.log4j</groupId>
    <artifactId>log4j-core</artifactId>
    <version>2.14.1</version>   <!-- Log4Shell — CVE-2021-44228 / CVE-2021-45046 -->
</dependency>
```

At the start of the demo, Trustify has **no** OSV feed and **no** VEX advisory — only what the pipeline itself uploads (SBOMs).

### Step 1 — Insecure build (ACS blocks)

```bash
./scripts/02-run-pipeline.sh \
  --image quay.io/mronconi/trusted-quarkus-app:insecure \
  --revision main
```

Pipeline stages:

1. Clone → Buildah build → push to Quay.io  
2. Syft CycloneDX SBOM → ingest into GUAC and Trustify  
3. Security gate: `roxctl image scan` + `roxctl image check`  
4. Trustify has no CSAF VEX → Log4Shell violations are **not** waived → **gate fails**  
5. Cosign is never reached; `:insecure` is **not** signed  

Expected gate snippet:

```
║  STACKROX BUILD-TIME POLICY CHECK                       ║
║  Image    : quay.io/mronconi/trusted-quarkus-app:insecure
…
║  VEX-AWARE GATE DECISION                                 ║
  ACS image check exit code : 1
  VEX waived CVEs           : 0
  Remaining failing policies: 1

❌ SECURITY GATE FAILED — remaining ACS build-time policy violation(s):
  • Log4Shell: log4j Remote Code Execution vulnerability …
``` 

### Step 2 — Import OSV and VEX into Trustify

Trustify must learn about the vulnerability context (OSV) and the SecOps exception (CSAF VEX). Run these against the Trustify API (port-forward on `localhost:8084`). Full helper notes live in [`trustify/README.md`](trustify/README.md).

**GitHub OSV importer** (2021 advisories — includes Log4Shell GHSA):

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

**Optional — Red Hat CSAF importer** (Quarkus / RHEL-oriented feed):

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

**Custom CSAF VEX** — marks Log4Shell as `known_not_affected` for this app’s `log4j-core@2.14.1` (both CVEs ACS enforces):

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @trustify/quarkus-log4j-vex.csaf.json
```

Document: [`trustify/quarkus-log4j-vex.csaf.json`](trustify/quarkus-log4j-vex.csaf.json) (`DEMO-VEX-QUARKUS-004`).

> The ACS Log4Shell policy fails on **CVE-2021-44228** and **CVE-2021-45046**. The VEX must waive both, or the gate still fails.

Confirm in Trustify UI (Advisories) or:

```bash
curl -s "http://localhost:8084/api/v3/advisory?q=DEMO-VEX" | jq '.items[].document_id'
# → DEMO-VEX-QUARKUS-004
```

### Step 3 — Rebuild (VEX waives false positive → gate passes)

Same source, new tag:

```bash
./scripts/02-run-pipeline.sh \
  --image quay.io/mronconi/trusted-quarkus-app:vex-waived \
  --revision main
```

Behaviour:

- StackRox **still** reports Log4Shell on `log4j` 2.14.1  
- Security gate loads CSAF VEX from Trustify (`csaf_vex`)  
- Violations citing the waived CVEs are dropped  
- Gate **passes** → Cosign signs `:vex-waived`  

Expected gate snippet:

```
║  TRUSTIFY VEX — not_affected CVE LOOKUP                  ║
  ✓ CSAF VEX: DEMO-VEX-QUARKUS-004
  ✓ Trustify not_affected CVEs (2):
      CVE-2021-44228
      CVE-2021-45046

║  VEX-AWARE GATE DECISION                                 ║
  ACS image check exit code : 1
  VEX waived CVEs           : 2
  Remaining failing policies: 0

✅ SECURITY GATE PASSED — ACS violations fully waived by Trustify VEX (not_affected)
```

Verify signatures:

```bash
# Signed after VEX waiver
./scripts/03-verify.sh quay.io/mronconi/trusted-quarkus-app:vex-waived
# or:
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:vex-waived

# First insecure run was never signed
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:insecure
# → Error: no matching signatures
```

**Takeaway:** ACS remains the policy authority for detection and enforcement. Trustify holds SecOps VEX statements. The Tekton gate joins them so documented false positives do not block signing, while unsigned images never leave the pipeline.

---

## Security gate design

Hybrid model:

1. **`roxctl image scan`** — vulnerability report (table + JSON).  
2. **`roxctl image check`** — ACS build-time policies → JSON (`violatedPolicies`, `failingCheck`).  
3. **Trustify VEX lookup** — load CSAF documents with `document.category == csaf_vex` and collect CVEs under `product_status.known_not_affected`.  
4. **Decision** — drop ACS violation lines that cite a waived CVE (also matches CVE IDs in the policy name/description when messages omit them). Fail only if a `failingCheck` policy still has non-waived violations.

Endpoints (defaults):

| Component | Address |
|---|---|
| ACS Central (in-cluster) | `central.stackrox.svc:443` (`ROX_CENTRAL_ADDRESS`) |
| Trustify (in-cluster) | `http://trustify-server.trustify.svc:8080` (`TRUSTIFY_URL`) |

---

## Cleanup

```bash
./scripts/04-cleanup.sh
```

Deletes the Kind cluster, `.keys/`, and local port-forwards.

---

## References

- [Sigstore](https://www.sigstore.dev/)
- [GUAC](https://guac.sh/)
- [Trustify](https://github.com/trustification/trustify) · [docs](https://docs.trustification.dev/)
- [Tekton](https://tekton.dev/)
- [CycloneDX](https://cyclonedx.org/)
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
