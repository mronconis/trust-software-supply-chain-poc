#!/usr/bin/env bash
#
# apply-conforma-gate.sh
# Creates ConfigMaps for gate collectors + Conforma policy and applies Tekton Tasks/Pipeline.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
NAMESPACE="${NAMESPACE:-trusted-supply-chain}"

echo "▸ Namespace: ${NAMESPACE}"
kubectl get namespace "${NAMESPACE}" >/dev/null

echo "▸ ConfigMap gate-scripts"
kubectl -n "${NAMESPACE}" create configmap gate-scripts \
  --from-file="${ROOT_DIR}/gate/collect_acs.py" \
  --from-file="${ROOT_DIR}/gate/collect_trustify.py" \
  --from-file="${ROOT_DIR}/gate/assemble_evidence.py" \
  --from-file="${ROOT_DIR}/gate/sync_acs_fp.py" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▸ ConfigMap conforma-policy"
# Flatten policy files: policy.yaml at root + *.rego under policy/
kubectl -n "${NAMESPACE}" create configmap conforma-policy \
  --from-file=policy.yaml="${ROOT_DIR}/conforma/policy.yaml" \
  --from-file=critical_vex.rego="${ROOT_DIR}/conforma/policy/critical_vex.rego" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "▸ Tekton Tasks + Pipeline"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/tasks/collect-security-evidence.yaml"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/tasks/conforma-cve-gate.yaml"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/tasks/sync-acs-false-positives.yaml"
kubectl apply -n "${NAMESPACE}" -f "${ROOT_DIR}/tekton/pipelines/trusted-supply-chain.yaml"

# Remove obsolete monolithic gate if present
if kubectl -n "${NAMESPACE}" get task security-gate >/dev/null 2>&1; then
  echo "▸ Deleting obsolete Task security-gate"
  kubectl -n "${NAMESPACE}" delete task security-gate --ignore-not-found
fi

echo "✅ Conforma security gate applied"
