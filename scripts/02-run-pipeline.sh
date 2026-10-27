#!/usr/bin/env bash
#
# 02-run-pipeline.sh
# Launches the Trusted Supply Chain pipeline and follows the logs.
#
set -euo pipefail

# Function to print usage
print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --image IMAGE              Container image name (default: quay.io/mronconi/trusted-quarkus-app:latest)"
  echo "  --git-url URL              Git repository URL (default: https://github.com/mronconis/trust-software-supply-chain-poc.git)"
  echo "  --revision REVISION        Git revision (default: main)"
  echo "  --context CONTEXT          Application context path (default: quarkus-app)"
  echo "  --rox-central ADDRESS      StackRox Central endpoint (default: local StackRox on kind)"
  echo "  -h, --help                 Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --revision \"feature/new-feature\""
  echo "  $0 --image \"custom/image:tag\" --revision \"main\" --rox-central \"central.stackrox.svc:443\""
  echo "  $0 --help"
}

# Initialize default values
IMAGE="quay.io/mronconi/trusted-quarkus-app:latest"
GIT_URL="https://github.com/mronconis/trust-software-supply-chain-poc.git"
GIT_REVISION="main"
APP_CONTEXT="quarkus-app"
ROX_CENTRAL=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    --revision)
      GIT_REVISION="$2"
      shift 2
      ;;
    --context)
      APP_CONTEXT="$2"
      shift 2
      ;;
    --rox-central)
      ROX_CENTRAL="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NAMESPACE="trusted-supply-chain"

# ── Load .env for ROX_CENTRAL_ADDRESS ────────────────────────────
ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  source "${ENV_FILE}"
fi

# Default to local StackRox Central on kind
if [ -z "${ROX_CENTRAL}" ]; then
  ROX_CENTRAL="central.stackrox.svc:443"
  echo "  ℹ  ROX_CENTRAL_ADDRESS not set — using local StackRox: ${ROX_CENTRAL}"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Software Supply Chain PoC — Pipeline Execution      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Image          : ${IMAGE}"
echo "  Git URL        : ${GIT_URL}"
echo "  Git Revision   : ${GIT_REVISION}"
echo "  App Context    : ${APP_CONTEXT}"
echo "  ACS Central    : ${ROX_CENTRAL}"
echo ""

echo "▸ Starting pipeline with tkn CLI..."
echo ""

tkn pipeline start trusted-supply-chain \
  --namespace "${NAMESPACE}" \
  --param IMAGE="${IMAGE}" \
  --param GIT_URL="${GIT_URL}" \
  --param GIT_REVISION="${GIT_REVISION}" \
  --param APP_CONTEXT="${APP_CONTEXT}" \
  --param ROX_CENTRAL_ADDRESS="${ROX_CENTRAL}" \
  --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
  --workspace name=cosign-keys,secret=cosign-keys \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=roxctl-secret,secret=stackrox-secret \
  --use-param-defaults \
  --showlog

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Pipeline started! Watch the logs above.                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
