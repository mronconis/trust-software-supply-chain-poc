#!/usr/bin/env bash
#
# 01-bootstrap-cluster.sh
# Creates Kind cluster and installs Tekton Pipelines + GUAC + StackRox
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

TEKTON_VERSION="latest"
KIND_CLUSTER_NAME="tssc"

NAMESPACE="trusted-supply-chain"
GUAC_NS="guac"
STACKROX_NS="stackrox"

ROX_ADMIN_PASSWORD="stackrox"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Software Supply Chain PoC — Bootstrap               ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Pre-flight checks ────────────────────────────────────────────
for cmd in kind kubectl cosign helm; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "❌ '${cmd}' not found. Please install it first."
    if [ "${cmd}" = "helm" ]; then
      echo "   brew install helm"
    fi
    exit 1
  fi
done

# ── Step 1: Create Kind cluster ──────────────────────────────────
echo ""
echo "▸ [1/8] Creating Kind cluster: ${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME}"; then
  echo "  ⚠ Cluster '${KIND_CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/kind-config.yaml"
  echo "  ✅ Kind cluster created"
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"

# ── Step 2: Create namespace ─────────────────────────────────────
echo ""
echo "▸ [2/8] Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Step 3: Install Tekton Pipelines ─────────────────────────────
echo ""
echo "▸ [3/8] Installing Tekton Pipelines (${TEKTON_VERSION})"
kubectl apply --filename "https://storage.googleapis.com/tekton-releases/pipeline/${TEKTON_VERSION}/release.yaml"

echo "  ⏳ Waiting for Tekton Pipelines to be ready..."
kubectl wait --for=condition=Available \
  deployment/tekton-pipelines-controller \
  -n tekton-pipelines \
  --timeout=300s

kubectl wait --for=condition=Available \
  deployment/tekton-pipelines-webhook \
  -n tekton-pipelines \
  --timeout=120s

echo "  ✅ Tekton Pipelines installed and ready"

# ── Step 4: Deploy GUAC ──────────────────────────────────────────
echo ""
echo "▸ [4/8] Deploying GUAC (upstream Trusted Profile Analyzer)"
kubectl create namespace "${GUAC_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n "${GUAC_NS}" -f "${ROOT_DIR}/guac/guac-deployment.yaml"

echo "  ⏳ Waiting for GUAC to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-graphql \
  -n "${GUAC_NS}" \
  --timeout=120s || echo "  ⚠ GUAC may need more time — continuing..."

echo "  ✅ GUAC deployed"

# ── Step 5: Deploy GUAC Visualizer ────────────────────────────────
echo ""
echo "▸ [5/8] Deploying GUAC Visualizer"
kubectl apply -n "${GUAC_NS}" -f "${ROOT_DIR}/guac/guac-visualizer.yaml"

echo "  ⏳ Waiting for GUAC Visualizer to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-visualizer \
  -n "${GUAC_NS}" \
  --timeout=120s || echo "  ⚠ Visualizer may need more time — continuing..."

echo "  ✅ GUAC Visualizer deployed"

# ── Step 6: Install StackRox Central Services (ACS) ──────────────
echo ""
echo "▸ [6/8] Installing StackRox Central Services (ACS)"

helm repo add stackrox \
  https://raw.githubusercontent.com/stackrox/helm-charts/main/opensource/ \
  2>/dev/null || true
helm repo update stackrox 2>/dev/null

if helm status stackrox-central-services -n "${STACKROX_NS}" &>/dev/null; then
  echo "  ⚠ StackRox Central already installed, skipping Helm install."
else
  kubectl create namespace "${STACKROX_NS}" --dry-run=client -o yaml | kubectl apply -f -

  echo "  ⏳ Installing Helm chart (this may take a few minutes)..."
  helm install stackrox-central-services stackrox/stackrox-central-services \
    -n "${STACKROX_NS}" \
    -f "${ROOT_DIR}/stackrox/stackrox-central-values.yaml" \
    --wait --timeout 10m
fi

echo "  ⏳ Waiting for Central deployment to be ready..."
kubectl wait --for=condition=Available \
  deployment/central \
  -n "${STACKROX_NS}" \
  --timeout=300s

echo "  ✅ StackRox Central Services installed"
echo "  ℹ  UI: https://localhost:30443  (admin / ${ROX_ADMIN_PASSWORD})"

# ── Wait for Central API to accept connections ────────────────────
echo ""
echo "  ⏳ Waiting for Central API to be responsive..."
MAX_RETRIES=30
RETRY=0
while [ "${RETRY}" -lt "${MAX_RETRIES}" ]; do
  if curl -sk "https://localhost:30443/v1/metadata" \
       -u "admin:${ROX_ADMIN_PASSWORD}" 2>/dev/null \
     | grep -q '"version"'; then
    break
  fi
  RETRY=$((RETRY + 1))
  printf "    attempt %s/%s\r" "${RETRY}" "${MAX_RETRIES}"
  sleep 10
done
echo ""

if [ "${RETRY}" -eq "${MAX_RETRIES}" ]; then
  echo "  ⚠ Central API not responsive after ${MAX_RETRIES} attempts."
  echo "    Generate an API token manually from the ACS Central UI."
  ROX_API_TOKEN=""
else
  echo "  ✅ Central API is ready"

  # ── Generate API token for the pipeline ─────────────────────────
  echo ""
  echo "  ▸ Generating StackRox API token (role: Continuous Integration)..."
  TOKEN_JSON=$(curl -sk "https://localhost:30443/v1/apitokens/generate" \
    -u "admin:${ROX_ADMIN_PASSWORD}" \
    -H "Content-Type: application/json" \
    -d '{"name":"tekton-pipeline","role":"Admin"}')

  ROX_API_TOKEN=$(echo "${TOKEN_JSON}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin).get('token',''))" 2>/dev/null \
    || echo "")

  if [ -z "${ROX_API_TOKEN}" ]; then
    echo "  ⚠ Could not parse API token. Generate it manually from the UI."
  else
    echo "  ✅ API token generated"
  fi

  # ── Configure Quay.io credentials in Central ─────────────────────
  # The built-in "Public Quay.io" integration (type: quay) uses the
  # Quay-specific API and does NOT support username/password auth.
  # We create a separate Docker Registry v2 integration with credentials
  # so StackRox can pull manifests from private Quay.io repos.
  echo ""
  echo "  ▸ Configuring Quay.io registry credentials in StackRox Central..."

  QUAY_USER_FOR_ROX="${QUAY_USERNAME:-}"
  QUAY_PASS_FOR_ROX="${QUAY_PASSWORD:-}"

  if [ -n "${QUAY_USER_FOR_ROX}" ] && [ -n "${QUAY_PASS_FOR_ROX}" ]; then
    # Check if a private integration already exists
    EXISTING_PRIVATE=$(curl -sk "https://localhost:30443/v1/imageintegrations" \
      -u "admin:${ROX_ADMIN_PASSWORD}" 2>/dev/null \
      | python3 -c "
import sys, json
for i in json.load(sys.stdin).get('integrations', []):
    if i.get('type') == 'docker' and 'quay.io' in i.get('docker',{}).get('endpoint',''):
        print(i['id']); break
" 2>/dev/null || echo "")

    if [ -n "${EXISTING_PRIVATE}" ]; then
      echo "  ⚠ Quay.io (private) integration already exists (${EXISTING_PRIVATE}), skipping."
    else
      REG_RESULT=$(curl -sk "https://localhost:30443/v1/imageintegrations" \
        -u "admin:${ROX_ADMIN_PASSWORD}" \
        -H "Content-Type: application/json" \
        -d "{
          \"name\": \"Quay.io (private)\",
          \"type\": \"docker\",
          \"categories\": [\"REGISTRY\"],
          \"docker\": {
            \"endpoint\": \"quay.io\",
            \"username\": \"${QUAY_USER_FOR_ROX}\",
            \"password\": \"${QUAY_PASS_FOR_ROX}\",
            \"insecure\": false
          },
          \"skipTestIntegration\": true,
          \"autogenerated\": false
        }" 2>/dev/null)
      if echo "${REG_RESULT}" | grep -q '"id"'; then
        echo "  ✅ Quay.io (private) Docker Registry integration created"
      else
        echo "  ⚠ Could not create Quay.io integration. Add it manually from the ACS UI."
        echo "     Error: ${REG_RESULT}"
      fi
    fi
  else
    echo "  ⚠ Quay credentials not available — add the registry integration manually in ACS Central."
    echo "     Set QUAY_USERNAME and QUAY_PASSWORD in .env, then re-run this script."
  fi

  # ── Configure build-time policy enforcement ──────────────────────
  echo ""
  echo "  ▸ Configuring ACS build-time policy enforcement..."

  configure_policy_enforcement() {
    local POLICY_NAME="$1"
    local ACTIONS="$2"
    local POLICY_ID
    POLICY_ID=$(curl -sk "https://localhost:30443/v1/policies" \
      -u "admin:${ROX_ADMIN_PASSWORD}" 2>/dev/null \
      | python3 -c "
import sys, json
for p in json.load(sys.stdin).get('policies', []):
    if p['name'] == '${POLICY_NAME}':
        print(p['id']); break
" 2>/dev/null)

    if [ -z "${POLICY_ID}" ]; then
      echo "    ⚠ Policy '${POLICY_NAME}' not found"
      return 1
    fi

    local FULL_POLICY
    FULL_POLICY=$(curl -sk "https://localhost:30443/v1/policies/${POLICY_ID}" \
      -u "admin:${ROX_ADMIN_PASSWORD}" 2>/dev/null)

    local UPDATED
    UPDATED=$(echo "${FULL_POLICY}" | python3 -c "
import sys, json
p = json.load(sys.stdin)
p['enforcementActions'] = ${ACTIONS}
json.dump(p, sys.stdout)
" 2>/dev/null)

    curl -sk -X PUT "https://localhost:30443/v1/policies/${POLICY_ID}" \
      -u "admin:${ROX_ADMIN_PASSWORD}" \
      -H "Content-Type: application/json" \
      -d "${UPDATED}" >/dev/null 2>&1

    echo "    ✅ ${POLICY_NAME} → enforcement=${ACTIONS}"
  }

  configure_policy_enforcement "Log4Shell: log4j Remote Code Execution vulnerability" '["FAIL_BUILD_ENFORCEMENT"]'
  configure_policy_enforcement "Latest tag" '["FAIL_BUILD_ENFORCEMENT"]'
  configure_policy_enforcement "Fixable Severity at least Important" '[]'
fi

# ── Step 7: Install Tekton Tasks and Pipeline ─────────────────────
echo ""
echo "▸ [7/8] Installing Tekton Tasks and Pipeline"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/tasks/"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/pipelines/trusted-supply-chain.yaml"

# ── Step 8: Setup Credentials ─────────────────────────────────────
echo ""
echo "▸ [8/8] Setting up credentials"

# ── Load credentials from .env ───────────────────────────────────
ENV_FILE="${ROOT_DIR}/.env"
KEYS_DIR="${ROOT_DIR}/.keys"

if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  echo "  ℹ  Loaded credentials from ${ENV_FILE}"
fi

echo ""
echo "  ▸ [a] Generating Cosign static keypair"
mkdir -p "${KEYS_DIR}"

if [ -f "${KEYS_DIR}/cosign.key" ]; then
  echo "  ⚠ Keypair already exists in ${KEYS_DIR}, skipping."
else
  COSIGN_PASSWORD="" cosign generate-key-pair \
    --output-key-prefix "${KEYS_DIR}/cosign"
  echo "  ✅ Keypair generated:"
  echo "     Private key: ${KEYS_DIR}/cosign.key"
  echo "     Public key : ${KEYS_DIR}/cosign.pub"
fi

# ── Create Cosign keys secret ────────────────────────────
echo ""
echo "  ▸ [b] Creating Kubernetes secret: cosign-keys"
kubectl create secret generic cosign-keys \
  --namespace "${NAMESPACE}" \
  --from-file=cosign.key="${KEYS_DIR}/cosign.key" \
  --from-file=cosign.pub="${KEYS_DIR}/cosign.pub" \
  --from-literal=password="" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Secret 'cosign-keys' created"

# ── Create Quay.io registry secret ───────────────────────
echo ""
echo "  ▸ [c] Creating Kubernetes secret: quay-registry-secret"
echo ""

if [ -z "${QUAY_USERNAME:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
  echo "  ℹ  Set QUAY_USERNAME and QUAY_PASSWORD in .env (project root)"
  echo "     or enter them interactively below."
  echo ""
  if [ -z "${QUAY_USERNAME:-}" ]; then
    read -rp "  Quay.io username: " QUAY_USERNAME
  fi
  if [ -z "${QUAY_PASSWORD:-}" ]; then
    read -rsp "  Quay.io password/token: " QUAY_PASSWORD
    echo ""
  fi
fi

kubectl create secret docker-registry quay-registry-secret \
  --namespace "${NAMESPACE}" \
  --docker-server=quay.io \
  --docker-username="${QUAY_USERNAME}" \
  --docker-password="${QUAY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✅ Secret 'quay-registry-secret' created"

# ── Create StackRox API token secret ─────────────────────
echo ""
echo "  ▸ [d] Creating Kubernetes secret: stackrox-secret"

if [ -n "${ROX_API_TOKEN:-}" ]; then
  kubectl create secret generic stackrox-secret \
    --namespace "${NAMESPACE}" \
    --from-literal=rox-api-token="${ROX_API_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "  ✅ Secret 'stackrox-secret' created"
else
  echo "  ⚠ No API token available. Generate one manually:"
  echo "     1. Open https://localhost:30443 → Platform Configuration → Integrations → API Token"
  echo "     2. Create a token with role 'Continuous Integration'"
  echo "     3. Run:"
  echo "        kubectl create secret generic stackrox-secret -n ${NAMESPACE} \\"
  echo "          --from-literal=rox-api-token=<YOUR_TOKEN> \\"
  echo "          --dry-run=client -o yaml | kubectl apply -f -"
fi

# ── Step 9: Port Forward GUAC Visualizer ───────────────────────────
echo ""
echo "▸ [9/8] Port forwarding GUAC Visualizer"
kubectl port-forward -n "${GUAC_NS}" svc/guac-visualizer 3000:3000 &
kubectl port-forward -n "${GUAC_NS}" svc/guac-graphql 8085:8080 &
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Bootstrap complete!                                      ║"
echo "║                                                              ║"
echo "║  StackRox Central UI : https://localhost:30443               ║"
echo "║                        (admin / stackrox)                    ║"
echo "║  GUAC Visualizer     : http://localhost:3000                 ║"
echo "║                                                              ║"
echo "║  Next: run ./scripts/02-run-pipeline.sh                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
