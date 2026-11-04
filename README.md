# Trusted Software Supply Chain — Proof of Concept

An end-to-end Proof of Concept demonstrating a Trusted Software Supply Chain (TSSC) based on upstream Red Hat TSSC components. The pipeline automates Quarkus container builds, generates SBOMs, correlates vulnerability telemetry via ACS and Trustify, and enforces Conforma CVE/VEX policy gates before signing and attestation with Sigstore Cosign.

> [!WARNING]
> **PoC Only — Not for Production Use**  
> This repository is designed exclusively for architectural evaluation and technical validation. It is not hardened, optimized, or supported for production deployments.

> [!CAUTION]
> **Illustrative VEX & Synthetic Vulnerability**  
> The codebase intentionally includes `log4j-core 2.14.1` to trigger ACS alerts (`CVE-2021-44228` / `CVE-2021-45046`). The Dockerfile workaround (`JndiLookup.class` removal) and accompanying CSAF VEX (`known_not_affected`) exist solely to demonstrate Conforma gate evaluation. **Do not copy this mitigation pattern to production; always upgrade vulnerable dependencies.**

---

## What this PoC shows

1. **Gate blocks** a build that ships Log4Shell (`log4j-core` 2.14.1): ACS reports CRITICAL CVEs and Trustify has no VEX yet.
2. **SecOps publishes an illustrative CSAF VEX** tied to the Dockerfile mitigation, marking those CVEs `known_not_affected` in Trustify (optional OSV feed).
3. **Rebuild**: ACS still reports the CVEs; Trustify VEX waives them; Conforma passes; waivers sync to ACS as approved FPs; Cosign signs the image.

```
┌──────────┐    ┌──────────┐    ┌───────────────────┐    ┌──────────────────────┐    ┌────────────┐
│  Source  │───▸│  Build   │───▸│ SBOM + GUAC       │───▸│ Collect evidence     │───▸│ Sign       │
│ (GitHub) │    │(Buildah) │    │       + Trustify  │    │ ACS scan + Trustify  │    │ (Cosign)   │
└──────────┘    └──────────┘    └───────────────────┘    │ VEX → evidence.json  │    └────────────┘
                                   │             │       └──────────┬───────────┘
                                   ▼             ▼                  │
                               GUAC          Trustify               ▼
                           (dep graph)    (SBOM + VEX)    ┌──────────────────────┐
                                                          │ Conforma             │
                                                          │ ec validate input    │
                                                          └──────────┬───────────┘
                                                                  ╱           ╲
                                                                FAIL          PASS
                                                                 ↓              ↓
                                                           ❌ HALTED   ACS FP sync → ✅ SIGNED
```

| Upstream | Red Hat product | Role in this PoC |
|---|---|---|
| Tekton Pipelines | OpenShift Pipelines | CI/CD engine |
| Sigstore / Cosign | Trusted Artifact Signer (TAS) | Image signing |
| GUAC | Trusted Profile Analyzer (TPA) | Dependency graph |
| Trustify | Trusted Profile Analyzer (TPA) | SBOM store, advisories, **VEX Single Source of Truth (SSOT)** |
| Conforma (`ec`) | Conforma / Enterprise Contract | **CVE gate policy engine** |
| StackRox / roxctl | Advanced Cluster Security (ACS) | Informational scan + FP UI sync |
| Syft + CycloneDX | — | SBOM generation |

---

## Repository layout

```
├── quarkus-app/                     # Sample Quarkus app (deliberately vulnerable log4j)
├── gate/                            # Evidence collectors + ACS FP sync (Python, tested)
│   ├── collect_acs.py
│   ├── collect_trustify.py
│   ├── assemble_evidence.py
│   ├── sync_acs_fp.py
│   ├── schema/evidence.schema.json
│   └── tests/
├── conforma/                        # Conforma policy (Rego) + offline fixtures
│   ├── policy.yaml
│   ├── policy/critical_vex.rego
│   └── testdata/
├── tekton/
│   ├── tasks/
│   │   ├── build-and-push.yaml
│   │   ├── generate-sbom.yaml
│   │   ├── collect-security-evidence.yaml
│   │   ├── conforma-cve-gate.yaml
│   │   ├── sync-acs-false-positives.yaml
│   │   └── sign-and-attest.yaml
│   └── pipelines/trusted-supply-chain.yaml
├── trustify/
│   ├── quarkus-log4j-vex.csaf.json  # Demo CSAF VEX (Log4Shell not_affected)
│   └── README.md
├── guac/  stackrox/  kind-config.yaml
└── scripts/
    ├── 01-bootstrap-cluster.sh      # Cluster + Tasks/Pipeline + gate ConfigMaps
    ├── 02-run-pipeline.sh
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

Quay.io credentials with push access. Create `.env` in the repo root (git-ignored):

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

Creates Kind cluster `tssc`, installs Tekton, GUAC, Trustify, and StackRox/ACS, applies Tasks/Pipeline and the Conforma gate ConfigMaps (`gate-scripts`, `conforma-policy`), generates Cosign keys under `.keys/`, creates secrets, and starts port-forwards.

After editing `gate/*.py` or `conforma/policy*`, re-run bootstrap step 8 (or the full `./scripts/01-bootstrap-cluster.sh`) so those ConfigMaps are refreshed.

| Service | URL | Notes |
|---|---|---|
| ACS Central | https://localhost:30443 | `admin` / `stackrox` (accept self-signed cert) |
| Trustify | http://localhost:8084 | Auth disabled in this PoC |
| GUAC Visualizer | http://localhost:3000 | After SBOM ingest |
| GUAC GraphQL | http://localhost:8085/query | |

---

## Offline policy checks (no cluster)

```bash
# Collector unit tests
python3 -m venv .venv && . .venv/bin/activate
pip install -r gate/requirements-dev.txt
pytest gate/tests -q

# Rego unit tests
docker run --rm -v "$PWD/conforma/policy:/policy:ro" openpolicyagent/opa:latest test /policy -v

# Conforma against fixtures
docker run --rm -v "$PWD/conforma:/conforma:ro" -w /conforma \
  quay.io/conforma/cli:latest \
  validate input testdata/evidence-pass.json --policy policy.yaml --info

docker run --rm -v "$PWD/conforma:/conforma:ro" -w /conforma \
  quay.io/conforma/cli:latest \
  validate input testdata/evidence-fail.json --policy policy.yaml --info
# → exit 1, policy.unwaived_critical for both Log4Shell CVEs
```

---

## Demo walkthrough

Use `./scripts/02-run-pipeline.sh` for each run. The sample app pins a vulnerable dependency:

```xml
<!-- quarkus-app/pom.xml -->
<dependency>
    <groupId>org.apache.logging.log4j</groupId>
    <artifactId>log4j-core</artifactId>
    <version>2.14.1</version>   <!-- Log4Shell — CVE-2021-44228 / CVE-2021-45046 -->
</dependency>
```

[`quarkus-app/Dockerfile`](quarkus-app/Dockerfile) keeps that JAR for scanner visibility, then strips `JndiLookup` and sets `log4j2.formatMsgNoLookups=true`. The demo VEX asserts that mitigation — **illustratively only**; it is not a Maven upgrade.

At demo start, Trustify has **no** OSV feed and **no** VEX — only SBOMs uploaded by the pipeline itself.

### Step 1 — Insecure build (gate blocks)

```bash
./scripts/02-run-pipeline.sh \
  --image quay.io/mronconi/trusted-quarkus-app:insecure \
  --revision main
```

What happens:

1. Clone → Buildah → push to Quay.io  
2. Syft SBOM → GUAC + Trustify  
3. **collect-security-evidence**: ACS scan (info) + Trustify VEX → `evidence.json`  
4. **conforma-cve-gate**: `ec validate input` — no VEX → **FAIL**  
5. Cosign is skipped; `:insecure` is **not** signed  

Expected gate snippet:

```
║  STACKROX VULNERABILITY SCAN (informational)             ║
… CVE-2021-44228 … CRITICAL …
… CVE-2021-45046 … CRITICAL …

║  CONFORMA CVE GATE (ec validate input)                   ║
✕ [Violation] policy.unwaived_critical
  Reason: CRITICAL CVE CVE-2021-44228 has no Trustify VEX …

❌ CONFORMA GATE FAILED — unwaived CRITICAL CVE(s)
```

### Step 2 — Import OSV and illustrative VEX into Trustify

Load OSV context and the SecOps CSAF VEX that records the Dockerfile Log4Shell mitigation as `known_not_affected` (demo only). Helpers: [`trustify/README.md`](trustify/README.md).

**GitHub OSV importer** (2021 advisories — includes Log4Shell):

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

**Illustrative CSAF VEX** — `known_not_affected` for CVE-2021-44228 / CVE-2021-45046 on `log4j-core@2.14.1`, justified by the Dockerfile mitigation (not a dependency bump):

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @trustify/quarkus-log4j-vex.csaf.json
```

Document: [`trustify/quarkus-log4j-vex.csaf.json`](trustify/quarkus-log4j-vex.csaf.json) (`DEMO-VEX-QUARKUS-004`).

### Step 3 — Rebuild (illustrative VEX → gate passes)

```bash
./scripts/02-run-pipeline.sh \
  --image quay.io/mronconi/trusted-quarkus-app:vex-waived \
  --revision main
```

- ACS **still** reports Log4Shell in the scan step  
- Collectors build `evidence.json` with both CVEs under `vex.known_not_affected`  
- Conforma **passes**  
- `sync-acs-false-positives` creates/approves an image-tag-scoped ACS FP  
- Cosign signs `:vex-waived`  

```
║  CONFORMA CVE GATE (ec validate input)                   ║
✅ CONFORMA GATE PASSED

║  ACS FALSE-POSITIVE SYNC (from Trustify VEX)             ║
Approved exception — 2 CVE(s) marked false positive in ACS
```

In ACS Central → **Vulnerability Management → Exception Management** you should see the approved exception for `quay.io/mronconi/trusted-quarkus-app:vex-waived` (exact tag — not `.*`).

```bash
TOKEN=$(kubectl get secret stackrox-secret -n trusted-supply-chain \
  -o jsonpath='{.data.rox-api-token}' | base64 -d)
curl -sk "https://localhost:30443/v2/vulnerability-exceptions?pagination.limit=50" \
  -H "Authorization: Bearer ${TOKEN}" \
  | jq -r '.exceptions[]?
      | select(.status=="APPROVED")
      | select(.scope.imageScope.tag=="vex-waived")
      | [.id, (.cves|join(",")), .scope.imageScope.tag] | @tsv'
```

Verify:

```bash
./scripts/03-verify.sh quay.io/mronconi/trusted-quarkus-app:vex-waived

cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:vex-waived

cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:insecure
# → Error: no matching signatures
```

**Takeaway:** ACS = visibility + FP UI sync. Trustify = **Single Source of Truth (SSOT)** for VEX / exploitability (here: Dockerfile mitigation, demo only). Conforma = blocking policy engine. Production fix = upgrade Log4j, not waive via container hacks.

---

## Security gate design

| Step | Tool | Blocking? |
|---|---|---|
| Collect ACS | `roxctl image scan` + `gate/collect_acs.py` | No — inventory only |
| Collect VEX | Trustify API + `gate/collect_trustify.py` | No — waiver inventory |
| Assemble | `gate/assemble_evidence.py` → `evidence.json` | No |
| Decide | Conforma `ec validate input` + Rego `policy.unwaived_critical` | **Yes** |
| ACS sync | `gate/sync_acs_fp.py` | No — exact image tag, idempotent |

**Authority model:** Trustify is the **Single Source of Truth (SSOT)** for VEX waivers. Conforma evaluates `CRITICAL ∖ known_not_affected` from that SSOT. ACS receives a one-way FP sync for UI consistency. An FP created only in ACS does **not** make the Tekton gate pass.

Defaults:

| Component | Address |
|---|---|
| ACS Central (scan + FP sync) | `central.stackrox.svc:443` (`ROX_CENTRAL_ADDRESS`) |
| Trustify (VEX) | `http://trustify-server.trustify.svc:8080` (`TRUSTIFY_URL`) |

ACS build-time `image check` is **not** used for pass/fail.

---

## Product mapping

| PoC component | Production equivalent |
|---|---|
| Kind | OpenShift (ROSA / ARO / self-managed) |
| Tekton | OpenShift Pipelines |
| Cosign static keys | Trusted Artifact Signer (keyless + Rekor) |
| GUAC + Trustify | Trusted Profile Analyzer |
| Conforma | Conforma / Enterprise Contract |
| StackRox on Kind | ACS (visibility / runtime) |
| Quay.io | Red Hat Quay |

---

## Cleanup

```bash
./scripts/04-cleanup.sh
```

---

## References

- [Conforma](https://conforma.dev/) · [`ec validate input`](https://conforma.dev/docs/cli/ec_validate_input.html)
- [Sigstore](https://www.sigstore.dev/)
- [GUAC](https://guac.sh/)
- [Trustify](https://github.com/trustification/trustify) · [docs](https://docs.trustification.dev/)
- [Tekton](https://tekton.dev/)
- [CycloneDX](https://cyclonedx.org/)
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
