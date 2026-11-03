#!/usr/bin/env bash
# Tear down the vLLM deployment from the OCP cluster.
#
# Usage: ./teardown.sh [--keep-pvc]
#
# Options:
#   --keep-pvc    Keep the model cache PVC (saves re-downloading on next deploy)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="ccamacho-test-bench"

KEEP_PVC=0
[[ "${1:-}" == "--keep-pvc" ]] && KEEP_PVC=1

echo "=== Tearing down vLLM deployment ==="

oc project "$NAMESPACE" 2>/dev/null || true

echo "Deleting deployment..."
oc delete deployment vllm-qwen --ignore-not-found 2>/dev/null || true

echo "Deleting service..."
oc delete service vllm-qwen --ignore-not-found 2>/dev/null || true

echo "Deleting route..."
oc delete route vllm-qwen --ignore-not-found 2>/dev/null || true

echo "Deleting configmap..."
oc delete configmap vllm-config --ignore-not-found 2>/dev/null || true

if [[ "$KEEP_PVC" == "1" ]]; then
  echo "Keeping PVC vllm-model-cache (model cache preserved)"
else
  echo "Deleting PVC (model cache will be lost)..."
  oc delete pvc vllm-model-cache --ignore-not-found 2>/dev/null || true
fi

echo ""
echo "Teardown complete."
