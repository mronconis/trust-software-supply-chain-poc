# Trusted Software Supply Chain —  Proof of Concept

This proof-of-concept demonstrates an end-to-end trusted software supply chain using the upstream projects behind the Red Hat Trusted Software Supply Chain portfolio.

---

## Context

Every container image deployed to production is the output of a multi-step transformation pipeline: source code is compiled, dependencies are resolved, a container is assembled, and the result is pushed to a registry. **If any link in this chain is compromised, the entire deployment is at risk.** High-profile supply-chain attacks —  SolarWinds, Log4Shell, and xz-utils — have demonstrated that writing secure code is not enough: organisations must be able to **cryptographically prove** that every artefact is intact, that its dependency graph has been analysed for known vulnerabilities, and that a human-defined security policy was enforced before the artifact was signed and promoted.

## Architectural Overview
This PoC implements a **Trusted Software Supply Chain** that ties together five upstream projects, each mapping directly to a Red Hat product:

| Upstream | Red Hat Product | Role |
|---|---|---|
| **Tekton Pipelines** | OpenShift Pipelines | Cloud-native CI/CD pipeline engine |
| **Sigstore / Cosign** | Trusted Artifact Signer (TAS) | Cryptographic signing and verification of OCI artefacts |
| **GUAC** | Trusted Profile Analyzer (TPA) | SBOM ingestion, dependency graph analysis, visualisation |
| **Trustify** | Trusted Profile Analyzer (TPA) | SBOM storage, vulnerability management, compliance dashboard |
| **StackRox / roxctl** | Advanced Cluster Security (ACS) | Image scanning and build-time policy enforcement |
| **CycloneDX + Syft** | —  | SBOM generation |

The pipeline clones source from **GitHub**, builds a Quarkus application with **Buildah**, pushes to **Quay.io**, generates a CycloneDX SBOM with **Syft**, ingests it into both **GUAC** (dependency graph) and **Trustify** (vulnerability management), and runs a **blocking security gate**: StackRox/`roxctl` scans the image and evaluates ACS build-time policies, then the gate consults **Trustify VEX** statements. CVEs marked `not_affected` in Trustify are waived and do not fail the pipeline. Only remaining (non-waived) enforced violations block signing. When the gate passes, Cosign signs the image with a static keypair and pushes the signature to the registry.

```
┌──────────┐    ┌──────────┐    ┌───────────────────┐    ┌─────────────────────┐    ┌────────────┐
│  Source  │───▸│  Build   │───▸│ SBOM + GUAC       │───▸│ Security Gate       │───▸│ Sign + Push│
│ (GitHub) │    │(Buildah) │    │       + Trustify  │    │ StackRox + VEX      │    │ (Cosign)   │
└──────────┘    └──────────┘    └───────────────────┘    └──────────┬──────────┘    └────────────┘
                                   │             │                   │
                                   ▼             ▼            ACS violation
                               GUAC          Trustify         after VEX filter?
                           (dep graph)   (SBOM + VEX)           ╱         ╲
                                                              YES          NO
                                                               ↓            ↓
                                                         ❌ PIPELINE    ✅ IMAGE
                                                            HALTED       SIGNED
```

---

## Repository Layout

```
trust-software-supply-chain-poc/
├── quarkus-app/                          # Target Java/Quarkus application
│   ├── pom.xml                           #   Maven configuration (includes CycloneDX plugin)
│   ├── Dockerfile                        #   Multi-stage build on UBI9
│   └── src/                              # Source code of the application
├── tekton/
│   ├── tasks/                            # Reusable Tekton Task definitions
│   │   ├── build-and-push.yaml           #   Git clone → Buildah build → registry push
│   │   ├── generate-sbom.yaml            #   Syft SBOM → GUAC ingest → Trustify ingest
│   │   ├── security-gate.yaml            #   StackRox scan → VEX-aware policy gate
│   │   └── sign-and-attest.yaml          #   Cosign attest SBOM → sign → verify
│   └── pipelines/
│       ├── trusted-supply-chain.yaml     # Pipeline: GitHub → Buildah → Quay.io → sign
│       └── workspace-template.yaml       # PVC template
├── kind-config.yaml                      # Kind cluster configuration
├── guac/
│   ├── guac-deployment.yaml              # GUAC server (GraphQL + CollectSub)
│   └── guac-visualizer.yaml              # GUAC Visualizer (dependency graph UI)
├── trustify/
│   ├── trustify-deployment.yaml          # Trustify server + PostgreSQL (SBOM storage & vuln mgmt)
│   ├── quarkus-log4j-vex.csaf.json       # Demo CSAF VEX (CVE-2021-44228 not_affected)
│   └── README.md                         # Importers + VEX upload helpers
├── stackrox/
│   └── stackrox-central-values.yaml      # Helm values for StackRox Central on Kind
└── scripts/
    ├── 01-bootstrap-cluster.sh           # Create cluster, install Tekton + GUAC + Trustify + ACS + creds
    ├── 02-run-pipeline.sh                # Launch pipeline (tkn or kubectl)
    ├── 03-verify.sh                      # Verify image signature post-pipeline
    ├── 04-cleanup.sh                     # Tear down cluster and keys
    └── demo.sh                           # Interactive demo walkthrough
```

---

## Prerequisites

| Tool | Min. version | Install (macOS) |
|---|---|---|
| `docker` / `podman` | 24+ | `brew install --cask docker` |
| `kind` | 0.23+ | `brew install kind` |
| `kubectl` | 1.28+ | `brew install kubectl` |
| `helm` | 3.14+ | `brew install helm` |
| `cosign` | 2.2+ | `brew install cosign` |
| `tkn` | 0.37+ | `brew install tektoncd-cli` |

A **Quay.io** account with push access to the target namespace (e.g. `mronconi`) is required. StackRox/ACS Central and Trustify are installed **locally on Kind** by the bootstrap script —  no external instances needed. Create a `.env` file in the project root:

```bash
QUAY_USERNAME=<your-username>
QUAY_PASSWORD=<your-token-or-password>
```

> **Security note**: `.env` is git-ignored. Never commit credentials.

---

## Quick Start

### 1. Bootstrap the cluster

```bash
git clone https://github.com/mronconis/trust-software-supply-chain-poc.git
cd trust-software-supply-chain-poc

./scripts/01-bootstrap-cluster.sh
```

This script:
- Creates a two-node Kind cluster (`tssc`).
- Installs Tekton Pipelines (images served from `ghcr.io/tektoncd`).
- Deploys GUAC with an in-memory `keyvalue` backend.
- Deploys the GUAC Visualizer (dependency graph UI).
- **Deploys Trustify** (upstream Trusted Profile Analyzer) with PostgreSQL and filesystem storage.
- **Installs StackRox Central Services** (ACS) on the cluster via Helm.
- **Generates a StackRox API token** (role: Continuous Integration) automatically.
- Applies all Tekton Tasks and Pipelines.
- Generates a **Cosign static keypair** (no passphrase) under `.keys/`.
- Creates the `cosign-keys`, `quay-registry-secret`, and `stackrox-secret` Kubernetes Secrets.
- Sets up port-forwards for GUAC Visualizer and Trustify UI.

> **Security note**: `.keys/` is git-ignored. Never commit private keys.

Verify:

```bash
kubectl get pods -n tekton-pipelines          # controller + webhook Running
kubectl get pods -n stackrox                  # central, central-db, scanner-v4-* Running
kubectl get pods -n guac                      # guac-graphql + guac-collectsub + guac-visualizer Running
kubectl get pods -n trustify                  # trustify-db + trustify-server Running
kubectl get pipelines -n trusted-supply-chain # trusted-supply-chain
```

### 2. Access the StackRox Central UI (ACS)

StackRox Central is exposed via NodePort on port **30443**. No port-forward is needed:

```
https://localhost:30443
```

| Field | Value |
|---|---|
| Username | `admin` |
| Password | `stackrox` |

> Accept the self-signed certificate warning in your browser.

#### Explore Build-Time Policies

1. Navigate to **Platform Configuration → Policy Management**.
2. Filter by **Lifecycle Stage → Build** to see only build-time policies evaluated by `roxctl image check`.
3. Notable policies used by the security gate:
   - **Log4Shell: CVE-2021-44228** —  **enforced** by the bootstrap script; blocks images with Log4Shell.
   - **Fixable Severity at least Important** —  inform-only (not enforced); reports fixable high/critical CVEs.
   - **Fixable CVSS ≥ 7** —  inform-only; reports vulnerabilities above CVSS 7.
4. Click on any policy to see its criteria, enforcement actions, and exclusions.
5. Toggle **Enforce on Build** to make a policy blocking (the pipeline's `roxctl image check` will exit non-zero).

#### Manage Policy Exceptions

Central is the single pane of glass for policy management. To create a time-bound exception:

1. Open the policy → **Edit**.
2. Under **Policy Scope → Excluded Deployments**, add the affected scope.
3. Or navigate to **Vulnerability Management → Image CVEs** and defer/mark a CVE as a false positive.

### 3. Access the GUAC Visualizer

Open [http://localhost:3000](http://localhost:3000) to explore the dependency graph after an SBOM has been ingested.

The GUAC GraphQL playground is available at [http://localhost:8085/query](http://localhost:8085/query).

### 4. Access the Trustify UI

Open [http://localhost:8084](http://localhost:8084) to explore the Trustify dashboard.

Trustify provides:
- **SBOM management** —  browse all ingested SBOMs, view package details and dependency trees.
- **Vulnerability tracking** —  correlate SBOMs with known CVEs and advisories.
- **VEX / false-positive management** —  ingest CSAF VEX documents (e.g. `known_not_affected`) that the security gate consults before failing a build.
- **Search** —  search by package name, pURL, or CVE identifier across all ingested data.

> **Note**: Trustify runs with authentication disabled in this PoC. In production, configure Keycloak OIDC via the Trustify Helm chart.

---

## Demo Walkthrough

The demo script (`scripts/demo.sh`) executes the full use case interactively. It pauses between phases so you can narrate each step to the team.

```bash
./scripts/demo.sh
```

> **Prerequisite**: Run `./scripts/01-bootstrap-cluster.sh` first to create the cluster, install all components (Tekton, GUAC, Trustify, StackRox), and set up credentials.

### Phase 1 —  Show the vulnerable dependency

The `pom.xml` ships with a deliberately pinned vulnerable dependency:

```xml
<dependency>
    <groupId>org.apache.logging.log4j</groupId>
    <artifactId>log4j-core</artifactId>
    <version>2.14.1</version>   <!-- CVE-2021-44228 —  Log4Shell, CVSS 10.0 -->
</dependency>
```

### Phase 2 —  Pipeline run → FAILURE

The pipeline clones source from GitHub, builds the container image, pushes to Quay.io, then:

1. **SBOM Generation** —  Syft scans the image from Quay.io and produces a CycloneDX 1.4 SBOM.
2. **GUAC Ingestion** —  The SBOM is ingested into GUAC via `guacone collect files`, populating the dependency graph.
3. **Trustify Ingestion** —  The same SBOM is uploaded to Trustify via its REST API (`POST /api/v3/sbom`), enabling vulnerability correlation and compliance tracking.
4. **Security Gate** —  StackRox scans the image (`roxctl image scan`) and evaluates ACS build-time policies (`roxctl image check`):
   - Enforced policies (e.g. "Log4Shell: CVE-2021-44228") fire.
   - Trustify has **no** VEX `not_affected` statement yet → **the gate fails**.
5. **Cosign Sign** —  This stage is **never reached** because the gate exited with a non-zero status.

Expected output:

```
║  STACKROX BUILD-TIME POLICY CHECK                       ║
║  Image    : quay.io/mronconi/trusted-quarkus-app:vulnerable
║  Central  : central.stackrox.svc:443
║  Trustify : http://trustify-server.trustify.svc:8080

║  VEX-AWARE GATE DECISION                                 ║
  Remaining failing policies: 1

❌ SECURITY GATE FAILED — remaining ACS build-time policy violation(s)
```

### Phase 3 —  Upload VEX → pipeline PASS (false-positive waiver)

SecOps publishes a CSAF VEX stating CVE-2021-44228 is `known_not_affected` for this deployment (see [`trustify/quarkus-log4j-vex.csaf.json`](trustify/quarkus-log4j-vex.csaf.json)):

```bash
curl -X POST "http://localhost:8084/api/v3/advisory" \
  -H "Content-Type: application/json" \
  --data-binary @trustify/quarkus-log4j-vex.csaf.json
```

Re-running the pipeline on the **same vulnerable code**:
- StackRox still reports Log4Shell.
- The gate waives violations that cite CVE-2021-44228 because Trustify marks it `not_affected`.
- The gate **passes** and Cosign **signs** the image (e.g. `:vex-waived`).

```
║  TRUSTIFY VEX — not_affected CVE LOOKUP                  ║
  ✓ Trustify not_affected CVEs (1):
      CVE-2021-44228

✅ SECURITY GATE PASSED — ACS violations fully waived by Trustify VEX (not_affected)
```

### Phase 4 —  Apply a real fix (optional remediation path)

The developer upgrades `log4j-core` from `2.14.1` to `2.24.3`, commits, and pushes to GitHub:

```bash
sed -i 's/2.14.1/2.24.3/' quarkus-app/pom.xml
git add quarkus-app/pom.xml
git commit -m "fix: upgrade log4j-core 2.14.1 → 2.24.3 (CVE-2021-44228)"
git push origin main
```

### Phase 5 —  Pipeline run on fixed code → SUCCESS

With Log4Shell eliminated from the image:
- ACS build-time policies are satisfied without needing a VEX waiver.
- Cosign **signs** `:latest`, attaches the SBOM attestation, and **verifies** the signature.

```
✅ SECURITY GATE PASSED — all ACS build-time policies satisfied
```

### Phase 6 —  Verify with cosign

```bash
# VEX-waived / fixed images —  verification PASSES
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:vex-waived
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:latest

# First vulnerable run (pre-VEX) —  verification FAILS
cosign verify --key .keys/cosign.pub --insecure-ignore-tlog \
  quay.io/mronconi/trusted-quarkus-app:vulnerable
# → Error: no matching signatures
```

**Key takeaway**: Unsigned images never leave the pipeline. False positives are managed as VEX in Trustify; real remediations remove the CVE. Only gate-approved images are signed and deployable.

---

## GUAC Dependency Graph

After the pipeline ingests an SBOM, the GUAC Visualizer at [http://localhost:3000](http://localhost:3000) renders the full dependency graph of the container image. You can explore:

- **Package nodes** —  every Maven artifact and RPM package in the image.
- **Dependency edges** —  how components relate to each other.
- **SBOM metadata** —  which document declared each component.

The GUAC GraphQL endpoint also supports programmatic queries:

```bash
curl http://localhost:8085/query \
  -H "Content-Type: application/json" \
  -d '{"query":"{ packages(pkgSpec: {}) { type namespaces { namespace names { name versions { version } } } } }"}'
```

## Trustify (Trusted Profile Analyzer)

After the pipeline ingests an SBOM, the Trustify UI at [http://localhost:8084](http://localhost:8084) provides:

- **SBOM Dashboard** —  browse all ingested SBOMs with metadata, creation dates, and package counts.
- **Package Explorer** —  search by package name or pURL to find which SBOMs contain a specific component.
- **Vulnerability Correlation** —  view known CVEs affecting packages in your SBOMs (when advisory data is loaded).
- **REST API** —  programmatic access to all data at [http://localhost:8084/openapi/](http://localhost:8084/openapi/).

### Uploading additional SBOMs manually

```bash
# Upload a single SBOM
curl -X POST \
  --data-binary @/path/to/sbom.json \
  -H "Content-Type: application/json" \
  http://localhost:8084/api/v3/sbom

# Upload a dataset (zip archive of SBOMs + advisories)
curl -X POST \
  --data-binary @dataset.zip \
  -H "Content-Type: application/zip" \
  http://localhost:8084/api/v3/dataset
```

> In production, Trustify is deployed with **Keycloak OIDC** authentication, **S3-compatible** object storage, and the full **Trustify Helm chart** ([trustify-helm-charts](https://github.com/trustification/trustify-helm-charts)). The PoC runs with auth disabled and local filesystem storage for simplicity.

---

## Security Gate Design

The gate is **hybrid**: StackRox/ACS remains the scanner and policy engine; Trustify supplies VEX-based exceptions.

1. **Image Scan** —  `roxctl image scan` analyses the container image and produces a vulnerability report (table + JSON).
2. **Policy Check** —  `roxctl image check` evaluates ACS **build-time** policies and emits JSON (`violatedPolicies`).
3. **Trustify VEX lookup** —  the task queries Trustify for CVEs with status `not_affected` (analyze SBOM PURLs with `include_resolved=true`, plus advisory/CSAF VEX fallback).
4. **VEX-aware decision** —  violation messages that cite a waived CVE are dropped. The gate **fails** only if at least one `failingCheck` policy still has non-waived violations; otherwise it **passes** and signing proceeds.

In this PoC, StackRox Central runs **locally on Kind** (`central.stackrox.svc:443`) and Trustify at `http://trustify-server.trustify.svc:8080` (override via `TRUSTIFY_URL`).

- **ACS Central** remains the pane of glass for build-time policy definitions and enforcement toggles.
- **Trustify** is the pane of glass for product-level false positives via CSAF VEX (`known_not_affected`).

## Product Mapping

| PoC component | Production equivalent (Red Hat) |
|---|---|
| Kind cluster | OpenShift (ROSA, ARO, self-managed) |
| Tekton Pipelines | **Red Hat OpenShift Pipelines** |
| Cosign with static keys | **Trusted Artifact Signer (TAS)** —  keyless signing via Sigstore Fulcio + Rekor |
| GUAC (in-memory) | **Trusted Profile Analyzer (TPA)** —  persistent storage, UI, policy engine |
| Trustify (auth disabled, filesystem) | **Trusted Profile Analyzer (TPA)** —  Keycloak OIDC, S3 storage, Helm deployment |
| GUAC Visualizer | TPA integrated dashboard |
| StackRox on Kind (Helm) | **Red Hat Advanced Cluster Security (ACS)** —  managed operator on OpenShift |
| Quay.io SaaS | **Red Hat Quay** (on-premise or cloud) |
| CycloneDX SBOM (manual) | Integrated SBOM generation in Trusted Application Pipeline |

In production, the static keypair used here would be replaced by **keyless signing** (OIDC-backed identity via Fulcio), with every signature recorded in an immutable **transparency log** (Rekor). False-positive / not-affected decisions would be managed as signed VEX/CSAF advisories in Trustify (TPA) with a formal exception process and time-bound approvals. Trustify would be deployed with the full Helm chart, Keycloak for OIDC authentication, and S3-compatible storage for durability.

---

## Cleanup

```bash
./scripts/04-cleanup.sh
```

Deletes the Kind cluster, removes the `.keys/` directory, and kills all port-forward processes.

---

## References

- [Sigstore](https://www.sigstore.dev/) —  Software signing for everyone
- [GUAC](https://guac.sh/) —  Graph for Understanding Artifact Composition
- [Trustify](https://github.com/trustification/trustify) —  Trust management for software supply chains
- [Trustify Documentation](https://docs.trustification.dev/) —  Administration and deployment guides
- [Tekton](https://tekton.dev/) —  Cloud-native CI/CD
- [CycloneDX](https://cyclonedx.org/) —  SBOM standard
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
