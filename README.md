# Trusted Software Supply Chain —  Proof of Concept

This proof-of-concept demonstrates an end-to-end trusted software supply chain using the upstream projects behind the Red Hat Trusted Software Supply Chain portfolio.

---

## Context

Every container image deployed to production is the output of a multi-step transformation pipeline: source code is compiled, dependencies are resolved, a container is assembled, and the result is pushed to a registry. **If any link in this chain is compromised, the entire deployment is at risk.** High-profile supply-chain attacks —  SolarWinds, Log4Shell, and xz-utils — have demonstrated that writing secure code is not enough: organisations must be able to **cryptographically prove** that every artefact is intact, that its dependency graph has been analysed for known vulnerabilities, and that a human-defined security policy was enforced before the artifact was signed and promoted.

## Architectural Overview
This PoC implements a **Trusted Software Supply Chain** that ties together four upstream projects, each mapping directly to a Red Hat product:

| Upstream | Red Hat Product | Role |
|---|---|---|
| **Tekton Pipelines** | OpenShift Pipelines | Cloud-native CI/CD pipeline engine |
| **Sigstore / Cosign** | Trusted Artifact Signer (TAS) | Cryptographic signing and verification of OCI artefacts |
| **GUAC** | Trusted Profile Analyzer (TPA) | SBOM ingestion, dependency graph analysis, visualisation |
| **StackRox / roxctl** | Advanced Cluster Security (ACS) | Image scanning and build-time policy enforcement |
| **CycloneDX + Syft** | —  | SBOM generation |

The pipeline clones source from **GitHub**, builds a Quarkus application with **Buildah**, pushes to **Quay.io**, generates a CycloneDX SBOM with **Syft**, ingests it into **GUAC**, and runs a **blocking security gate** powered by **StackRox/ACS**: `roxctl image scan` identifies known vulnerabilities, then `roxctl image check` enforces the **build-time policies** defined in ACS Central. If any enforced policy is violated the pipeline **fails and the image is never signed**. Only when all build-time policies pass does Cosign sign the image with a static keypair and push the signature to the registry.

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────────┐    ┌────────────┐
│  Source  │───▸│  Build   │───▸│  SBOM + GUAC │───▸│ Security Gate  │───▸│ Sign + Push│
│ (GitHub) │    │(Buildah) │    │ (Syft/GUAC)  │    │(StackRox/ACS)  │    │ (Cosign)   │
└──────────┘    └──────────┘    └──────────────┘    └───────┬────────┘    └────────────┘
                                                            │
                                                  Build-time policy
                                                    violation?
                                                      ╱         ╲
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
│   │   ├── generate-sbom.yaml            #   Syft SBOM → cosign attest
│   │   ├── security-gate.yaml            #   StackRox scan → GUAC ingest → policy gate
│   │   └── cosign-sign.yaml              #   Cosign sign → verify
│   └── pipelines/
│       ├── trusted-supply-chain.yaml     # Pipeline: GitHub → Buildah → Quay.io → sign
│       └── workspace-template.yaml       # PVC template
├── kind-config.yaml                      # Kind cluster configuration
├── guac/
│   ├── guac-deployment.yaml              # GUAC server (GraphQL + CollectSub)
│   └── guac-visualizer.yaml              # GUAC Visualizer (dependency graph UI)
├── stackrox/
│   └── stackrox-central-values.yaml      # Helm values for StackRox Central on Kind
└── scripts/
    ├── 01-bootstrap-cluster.sh           # Create cluster, install Tekton + GUAC + credentials
    ├── 02-run-pipeline.sh                # Launch pipeline (tkn or kubectl)
    ├── 03-verify.sh                      # Verify image signature post-pipeline
    └── 04-cleanup.sh                     # Tear down cluster and keys
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

A **Quay.io** account with push access to the target namespace (e.g. `mronconi`) is required. StackRox/ACS Central is installed **locally on Kind** by the bootstrap script —  no external ACS instance needed. Create a `.env` file in the project root:

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
- **Installs StackRox Central Services** (ACS) on the cluster via Helm.
- **Generates a StackRox API token** (role: Continuous Integration) automatically.
- Applies all Tekton Tasks and Pipelines.
- Generates a **Cosign static keypair** (no passphrase) under `.keys/`.
- Creates the `cosign-keys`, `quay-registry-secret`, and `stackrox-secret` Kubernetes Secrets.

> **Security note**: `.keys/` is git-ignored. Never commit private keys.

Verify:

```bash
kubectl get pods -n tekton-pipelines          # controller + webhook Running
kubectl get pods -n stackrox                  # central, central-db, scanner-v4-* Running
kubectl get pods -n trusted-supply-chain      # guac-graphql + guac-collectsub + guac-visualizer Running
kubectl get pipelines -n trusted-supply-chain # trusted-supply-chain-quay, test-trust-chain
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

---

## Demo Walkthrough

The demo script (`scripts/demo.sh`) executes the full use case interactively. It pauses between phases so you can narrate each step to the team.

```bash
./scripts/demo.sh
```

> **Prerequisite**: Run `./scripts/01-bootstrap-cluster.sh` first to create the cluster, install all components (Tekton, GUAC, StackRox), and set up credentials.

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

1. **SBOM Generation** —  Syft scans the image from Quay.io and produces a CycloneDX 1.6 SBOM.
2. **GUAC Ingestion** —  The SBOM is ingested into GUAC via `guacone collect files`, populating the dependency graph.
3. **Security Gate** —  StackRox scans the image (`roxctl image scan`) and enforces ACS build-time policies (`roxctl image check`):
   - Build-time policies (e.g. "Fixable CVSS ≥ 7", "Log4Shell: CVE-2021-44228") are evaluated.
   - Policy exceptions are managed centrally in ACS Central —  no local allowlist file required.
   - Log4Shell triggers an enforced policy → **the gate fails**.
4. **Cosign Sign** —  This stage is **never reached** because the gate exited with a non-zero status.

Expected output:

```
║  STACKROX BUILD-TIME POLICY CHECK                       ║
║  Image    : quay.io/mronconi/trusted-supply-chain-app:vulnerable
║  Central  : central.stackrox.svc:443
║  CRITICAL : 4
║  TOTAL    : 476

✗ Policy "Fixable CVSS >= 7" —  Violated (log4j-core:2.14.1)

❌ SECURITY GATE FAILED —  ACS build-time policy violation(s) detected
```

### Phase 3 —  Apply the fix

The developer upgrades `log4j-core` from `2.14.1` to `2.24.3`, commits, and pushes to GitHub:

```bash
sed -i 's/2.14.1/2.24.3/' quarkus-app/pom.xml
git add quarkus-app/pom.xml
git commit -m "fix: upgrade log4j-core 2.14.1 → 2.24.3 (CVE-2021-44228)"
git push origin main
```

### Phase 4 —  Pipeline run → SUCCESS

With Log4Shell eliminated:
- All ACS build-time policies are satisfied.
- The security gate **passes** (`roxctl image check` exits with code 0).
- Cosign **signs** the image, attaches the SBOM attestation, and **verifies** the signature.

```
✅ SECURITY GATE PASSED —  all ACS build-time policies satisfied

╔═══════════════════════════════════════════════════════════╗
║  COSIGN SIGN                                             ║
║  Image : quay.io/mronconi/trusted-supply-chain-app:latest@sha256:...
╚═══════════════════════════════════════════════════════════╝
✅ Image signed successfully
✅ Signature verified —  the chain of trust is intact
```

### Phase 5 —  Verify with cosign

```bash
# Signed image —  verification PASSES
cosign verify \
  --key .keys/cosign.pub \
  --insecure-ignore-tlog \
  quay.io/mronconi/trusted-supply-chain-app:latest

# Unsigned image —  verification FAILS
cosign verify \
  --key .keys/cosign.pub \
  --insecure-ignore-tlog \
  quay.io/mronconi/trusted-supply-chain-app:vulnerable
# → Error: no matching signatures
```

**Key takeaway**: The signed image is the only one that can pass a policy-based admission controller. The vulnerable image was never signed and cannot be deployed.

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

---

## Security Gate Design

The gate uses **StackRox/ACS build-time policies** enforced via `roxctl` in three steps:

1. **Image Scan** —  `roxctl image scan` analyses the container image and produces a vulnerability report (both table and JSON output). The report is displayed in the pipeline logs and saved for result parsing.
2. **GUAC Ingest** —  The CycloneDX SBOM is ingested into GUAC for dependency graph analysis and visualisation.
3. **Policy Check** —  `roxctl image check` evaluates the image against the **build-time policies** defined in ACS Central. If any enforced policy is violated, the command exits with a non-zero status and Tekton halts the pipeline. The signing stage is never executed.

In this PoC, StackRox Central runs **locally on Kind** (namespace `stackrox`). The Tekton security-gate task connects to it at `central.stackrox.svc:443`. The pipeline's `ROX_CENTRAL_ADDRESS` parameter defaults to this in-cluster address; override it to point at an external ACS instance if needed.

Policy exceptions (e.g. accepted base-image CVEs, time-bound waivers) are managed centrally in ACS Central (https://localhost:30443) rather than in a local allowlist file —  this gives the security team a single pane of glass across all pipelines and clusters.

## Product Mapping

| PoC component | Production equivalent (Red Hat) |
|---|---|
| Kind cluster | OpenShift (ROSA, ARO, self-managed) |
| Tekton Pipelines | **Red Hat OpenShift Pipelines** |
| Cosign with static keys | **Trusted Artifact Signer (TAS)** —  keyless signing via Sigstore Fulcio + Rekor |
| GUAC (in-memory) | **Trusted Profile Analyzer (TPA)** —  persistent storage, UI, policy engine |
| GUAC Visualizer | TPA integrated dashboard |
| StackRox on Kind (Helm) | **Red Hat Advanced Cluster Security (ACS)** —  managed operator on OpenShift |
| Quay.io SaaS | **Red Hat Quay** (on-premise or cloud) |
| CycloneDX SBOM (manual) | Integrated SBOM generation in Trusted Application Pipeline |

In production, the static keypair used here would be replaced by **keyless signing** (OIDC-backed identity via Fulcio), with every signature recorded in an immutable **transparency log** (Rekor). The CVE allowlist would be managed through a formal exception process with time-bound approvals.

---

## Cleanup

```bash
./scripts/cleanup.sh
```

Deletes the Kind cluster and removes the `.keys/` directory.

---

## References

- [Sigstore](https://www.sigstore.dev/) —  Software signing for everyone
- [GUAC](https://guac.sh/) —  Graph for Understanding Artifact Composition
- [Tekton](https://tekton.dev/) —  Cloud-native CI/CD
- [CycloneDX](https://cyclonedx.org/) —  SBOM standard
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
