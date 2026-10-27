#!/usr/bin/env bash
#
# 01-bootstrap-cluster.sh
# Cleans up Kind cluster and related resources
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
KEYS_DIR="${ROOT_DIR}/.keys"

KIND_CLUSTER_NAME="tssc"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Cleanup                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Delete Kind cluster ────────────────────────────────────
echo ""
echo "▸ [1/4] Deleting Kind cluster: ${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME}"; then
  kind delete cluster --name="${KIND_CLUSTER_NAME}"
  echo "  ✅ Kind cluster deleted"
else
  echo "  ⚠ Cluster '${KIND_CLUSTER_NAME}' not found, skipping deletion."
fi

# ── Step 2: Delete Cosign keys ──────────────────────────────────────
echo ""
echo "▸ [2/4] Deleting Cosign static keypair"
rm -rf "${KEYS_DIR}"

# ── Step 3: Delete port-forward processes ────────────────────────
echo ""
echo "▸ [4/4] Killing kubectl port-forward processes for GUAC Visualizer and GraphQL"
pkill -f "kubectl port-forward.*svc/guac-visualizer"
pkill -f "kubectl port-forward.*svc/guac-graphql"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Cleanup complete!                                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
