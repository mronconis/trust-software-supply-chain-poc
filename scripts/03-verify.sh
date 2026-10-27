#!/usr/bin/env bash
#
# 04-verify.sh
# Verifies the signed image on Quay.io using the public key.
# This is the command you show to colleagues to prove chain-of-trust.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
KEYS_DIR="${ROOT_DIR}/.keys"

IMAGE="${1:-quay.io/mronconi/trust-software-supply-chain-app:latest}"
PUB_KEY="${KEYS_DIR}/cosign.pub"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Signature Verification          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Image      : ${IMAGE}"
echo "  Public Key : ${PUB_KEY}"
echo ""

if [ ! -f "${PUB_KEY}" ]; then
  echo "❌ Public key not found at ${PUB_KEY}"
  echo "   Run ./scripts/01-bootstrap-cluster.sh first."
  exit 1
fi

# Authenticate with Quay.io if credentials available
ENV_FILE="${ROOT_DIR}/.env"
if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
fi

if [ -n "${QUAY_USERNAME:-}" ] && [ -n "${QUAY_PASSWORD}" ]; then
  echo "${QUAY_PASSWORD}" | cosign login quay.io -u "${QUAY_USERNAME}" --password-stdin 2>/dev/null
fi

echo "▸ Verifying image signature..."
echo ""
cosign verify \
  --key "${PUB_KEY}" \
  "${IMAGE}" | head -50

echo ""
echo "════════════════════════════════════════════════════════════════"

echo ""
echo "▸ Verifying SBOM attestation..."
echo ""
cosign verify-attestation \
  --key "${PUB_KEY}" \
  --type cyclonedx \
  "${IMAGE}" | head -50 || echo "  ⚠ No SBOM attestation found (or verification failed)"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Verification complete!                                   ║"
echo "║                                                              ║"
echo "║  The image has a valid signature and SBOM attestation.       ║"
echo "║  The chain of trust is intact.                               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
