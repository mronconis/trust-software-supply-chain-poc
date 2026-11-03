#!/usr/bin/env bash
#
# demo.sh — Full Trusted Supply Chain demo workflow (Quay.io + GitHub)
#
# Demonstrates:
#   1. Pipeline FAILS on a CRITICAL CVE (Log4Shell in log4j-core 2.14.1)
#   2. SecOps uploads a Trustify VEX (not_affected) → gate PASSES without upgrading
#   3. Developer applies a real fix (upgrades log4j-core to 2.24.3)
#   4. Pipeline PASSES on fixed code — image is signed on Quay.io
#   5. cosign verify proves only gate-approved images are signed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
APP_DIR="${ROOT_DIR}/quarkus-app"
VEX_FILE="${ROOT_DIR}/trustify/quarkus-log4j-vex.csaf.json"

QUAY_IMAGE="quay.io/mronconi/trusted-quarkus-app"
GIT_URL="https://github.com/mronconis/trust-software-supply-chain-poc.git"
GIT_REVISION="main"
NS="trusted-supply-chain"
TRUSTIFY_URL="${TRUSTIFY_URL:-http://localhost:8084}"
PIPELINE_NAME="${PIPELINE_NAME:-trusted-supply-chain}"

ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi
# Default to local StackRox Central on kind
ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS:-central.stackrox.svc:443}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}$1${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

pause() {
  echo ""
  echo -e "${YELLOW}  ▸ Press ENTER to continue...${NC}"
  read -r
}

start_pipeline() {
  local image_tag="$1"
  tkn pipeline start "${PIPELINE_NAME}" \
    --namespace "${NS}" \
    --param IMAGE="${QUAY_IMAGE}:${image_tag}" \
    --param GIT_URL="${GIT_URL}" \
    --param GIT_REVISION="${GIT_REVISION}" \
    --param APP_CONTEXT="quarkus-app" \
    --param ROX_CENTRAL_ADDRESS="${ROX_CENTRAL_ADDRESS}" \
    --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
    --workspace name=cosign-keys,secret=cosign-keys \
    --workspace name=dockerconfig,secret=quay-registry-secret \
    --workspace name=roxctl-secret,secret=stackrox-secret \
    --use-param-defaults \
    --showlog
}

# ══════════════════════════════════════════════════════════
# PRE-FLIGHT
# ══════════════════════════════════════════════════════════

for cmd in tkn cosign kubectl curl; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "❌ '${cmd}' not found. Please install it first."
    exit 1
  fi
done

if [ ! -f "${VEX_FILE}" ]; then
  echo "❌ VEX file not found: ${VEX_FILE}"
  exit 1
fi

banner "TRUSTED SOFTWARE SUPPLY CHAIN — LIVE DEMO"

echo "  This demo walks through a real supply-chain security workflow"
echo "  using Tekton, StackRox/ACS, Quay.io, Sigstore/Cosign, GUAC, and Trustify."
echo ""
echo "    Phase 1 — Show vulnerable dependency (Log4Shell CVE-2021-44228)"
echo "    Phase 2 — Pipeline detects CVE via StackRox and BLOCKS release"
echo "    Phase 3 — Upload Trustify VEX (not_affected) → gate PASSES"
echo "    Phase 4 — Developer upgrades log4j (true remediation)"
echo "    Phase 5 — Pipeline passes on fixed code, image SIGNED"
echo "    Phase 6 — Verify signatures with cosign"
echo ""
echo "  Registry   : ${QUAY_IMAGE}"
echo "  Source     : ${GIT_URL}"
echo "  Pipeline   : ${PIPELINE_NAME}"
echo "  ACS Central: ${ROX_CENTRAL_ADDRESS}"
echo "  ACS UI     : https://localhost:30443  (admin / stackrox)"
echo "  Trustify   : ${TRUSTIFY_URL}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 1 — Show the VULNERABLE dependency
# ══════════════════════════════════════════════════════════
banner "PHASE 1 — Vulnerable dependency (log4j-core 2.14.1)"

echo -e "  ${RED}pom.xml contains a deliberately vulnerable dependency:${NC}"
echo ""
echo "    <dependency>"
echo "        <groupId>org.apache.logging.log4j</groupId>"
echo "        <artifactId>log4j-core</artifactId>"
echo -e "        <version>${RED}2.14.1${NC}</version>    ← ${RED}CVE-2021-44228 (Log4Shell) CRITICAL${NC}"
echo "    </dependency>"
echo ""

echo -e "  ${YELLOW}Current pom.xml:${NC}"
grep -A2 'log4j-core' "${APP_DIR}/pom.xml" | head -6

# Ensure vulnerable version is committed and pushed
cd "${ROOT_DIR}"
if grep -q '2.14.1' "${APP_DIR}/pom.xml"; then
  echo ""
  echo -e "  ${GREEN}✓${NC} Vulnerable version confirmed in pom.xml"
  if ! git diff --quiet "${APP_DIR}/pom.xml" 2>/dev/null; then
    echo "  Committing vulnerable version to GitHub..."
    git add "${APP_DIR}/pom.xml"
    git commit -m "demo: revert to vulnerable log4j-core 2.14.1" --quiet
    git push origin "${GIT_REVISION}" --quiet 2>/dev/null
    echo -e "  ${GREEN}✓${NC} Pushed to GitHub"
  fi
fi

pause

# ══════════════════════════════════════════════════════════
# PHASE 2 — Run pipeline → EXPECTED FAILURE
# ══════════════════════════════════════════════════════════
banner "PHASE 2 — Running pipeline (expecting FAILURE)"

echo -e "  ${YELLOW}The pipeline will:${NC}"
echo "    1. Clone source from GitHub"
echo "    2. Build container image with Buildah"
echo "    3. Push to Quay.io"
echo "    4. Generate SBOM with Syft → ingest into GUAC + Trustify"
echo "    5. Scan with StackRox (roxctl) → detect Log4Shell"
echo "    6. Consult Trustify VEX — no not_affected statement yet"
echo -e "    7. ACS build-time policy violation → ${RED}BLOCK the release${NC}"
echo ""

start_pipeline "vulnerable" 2>&1 || true

echo ""
echo -e "  ${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${RED}║  Pipeline FAILED — StackRox policy not waived by VEX.     ║${NC}"
echo -e "  ${RED}║  The image was NOT signed. cosign verify would fail.     ║${NC}"
echo -e "  ${RED}╚═══════════════════════════════════════════════════════════╝${NC}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 3 — Upload VEX → EXPECTED SUCCESS (same vulnerable code)
# ══════════════════════════════════════════════════════════
banner "PHASE 3 — Upload Trustify VEX (CVE-2021-44228 not_affected)"

echo "  SecOps documents that Log4Shell is a false positive for this deployment"
echo "  (JNDI lookup disabled / unreachable) via CSAF VEX:"
echo ""
echo "    ${VEX_FILE}"
echo ""
echo "  Uploading advisory to Trustify at ${TRUSTIFY_URL} ..."

HTTP_CODE=$(curl -s -o /tmp/trustify-vex-upload.json -w "%{http_code}" \
  -X POST \
  -H "Content-Type: application/json" \
  --data-binary @"${VEX_FILE}" \
  "${TRUSTIFY_URL}/api/v3/advisory" || echo "000")

if [ "${HTTP_CODE}" = "200" ] || [ "${HTTP_CODE}" = "201" ]; then
  echo -e "  ${GREEN}✓${NC} VEX uploaded (HTTP ${HTTP_CODE})"
  cat /tmp/trustify-vex-upload.json 2>/dev/null || true
  echo ""
else
  echo -e "  ${YELLOW}⚠${NC} Trustify returned HTTP ${HTTP_CODE} (advisory may already exist)"
  cat /tmp/trustify-vex-upload.json 2>/dev/null || true
  echo ""
fi

echo ""
echo -e "  ${GREEN}Re-running the pipeline on the SAME vulnerable code.${NC}"
echo -e "  ${GREEN}StackRox still finds CVE-2021-44228, but Trustify waives it.${NC}"
echo ""

pause

start_pipeline "vex-waived" 2>&1

echo ""
echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║  Pipeline PASSED — VEX not_affected waived the CVE.      ║${NC}"
echo -e "  ${GREEN}║  Image :vex-waived was SIGNED despite vulnerable log4j.  ║${NC}"
echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 4 — Apply the fix, commit, push
# ══════════════════════════════════════════════════════════
banner "PHASE 4 — Applying a real fix (upgrade log4j)"

echo "  VEX waivers manage false positives. For a true remediation,"
echo "  upgrade log4j-core from 2.14.1 → 2.24.3 ..."
echo ""

# Apply the fix
if [[ "$OSTYPE" == darwin* ]]; then
  sed -i '' 's|<version>2.14.1</version>|<version>2.24.3</version>|' "${APP_DIR}/pom.xml"
else
  sed -i 's|<version>2.14.1</version>|<version>2.24.3</version>|' "${APP_DIR}/pom.xml"
fi

echo -e "  ${GREEN}pom.xml updated:${NC}"
grep -A2 'log4j-core' "${APP_DIR}/pom.xml" | head -6
echo ""

echo "  Committing and pushing fix to GitHub..."
cd "${ROOT_DIR}"
git add "${APP_DIR}/pom.xml"
git commit -m "fix: upgrade log4j-core 2.14.1 → 2.24.3 (CVE-2021-44228)" --quiet
git push origin "${GIT_REVISION}" --quiet 2>/dev/null
echo -e "  ${GREEN}✓${NC} Fix pushed to GitHub"

pause

# ══════════════════════════════════════════════════════════
# PHASE 5 — Run pipeline → EXPECTED SUCCESS
# ══════════════════════════════════════════════════════════
banner "PHASE 5 — Running pipeline on fixed code (expecting SUCCESS)"

echo -e "  ${GREEN}Log4Shell is gone from the image. Policies pass without relying on VEX.${NC}"
echo -e "  ${GREEN}The pipeline will PASS and :latest will be SIGNED on Quay.io.${NC}"
echo ""

start_pipeline "latest" 2>&1

echo ""
echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║  Pipeline PASSED — fixed image is SIGNED and TRUSTED.    ║${NC}"
echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 6 — Verify with cosign
# ══════════════════════════════════════════════════════════
banner "PHASE 6 — Signature verification (cosign verify)"

# Authenticate cosign with Quay.io (private registry)
if [ -n "${QUAY_USERNAME:-}" ] && [ -n "${QUAY_PASSWORD:-}" ]; then
  echo "${QUAY_PASSWORD}" | cosign login quay.io -u "${QUAY_USERNAME}" --password-stdin 2>/dev/null
fi

echo "  Verifying the VEX-waived image on Quay.io..."
echo ""
cosign verify \
  --key "${ROOT_DIR}/.keys/cosign.pub" \
  --insecure-ignore-tlog \
  "${QUAY_IMAGE}:vex-waived" 2>&1

echo ""
echo "  ────────────────────────────────────────────────────"
echo ""
echo "  Verifying the SIGNED (fixed) image on Quay.io..."
echo ""
cosign verify \
  --key "${ROOT_DIR}/.keys/cosign.pub" \
  --insecure-ignore-tlog \
  "${QUAY_IMAGE}:latest" 2>&1

echo ""
echo "  ────────────────────────────────────────────────────"
echo ""
echo "  Now verifying the UNSIGNED (pre-VEX vulnerable) image..."
echo ""

cosign verify \
  --key "${ROOT_DIR}/.keys/cosign.pub" \
  --insecure-ignore-tlog \
  "${QUAY_IMAGE}:vulnerable" 2>&1 || true

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    DEMO COMPLETE                         ║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║${NC}  ${RED}✗${NC} Vulnerable (no VEX) → gate FAILED → NOT signed     ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${GREEN}✓${NC} Vulnerable + VEX    → gate PASSED → SIGNED ✓       ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${GREEN}✓${NC} Fixed image         → gate PASSED → SIGNED ✓       ${GREEN}║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║${NC}  StackRox enforces build policies; Trustify VEX         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  waives documented false positives (not_affected).      ${GREEN}║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║${NC}  Registry : quay.io/mronconi/trusted-quarkus-app         ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ACS UI     : https://localhost:30443                    ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  GUAC UI    : http://localhost:3000                      ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  Trustify   : http://localhost:8084                      ${GREEN}║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

# Restore pom.xml to vulnerable state for repeatable demo
if [[ "$OSTYPE" == darwin* ]]; then
  sed -i '' 's|<version>2.24.3</version>|<version>2.14.1</version>|' "${APP_DIR}/pom.xml"
else
  sed -i 's|<version>2.24.3</version>|<version>2.14.1</version>|' "${APP_DIR}/pom.xml"
fi
echo ""
echo -e "  ${YELLOW}pom.xml restored to vulnerable state (2.14.1) for next demo run${NC}"
