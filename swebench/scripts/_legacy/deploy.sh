#!/usr/bin/env bash
# Deploy vLLM serving Qwen3-27B on the OCP cluster with MI300X GPU.
#
# Usage: ./deploy.sh [--hf-token TOKEN]
#
# Prerequisites:
#   - oc CLI installed and logged in
#   - Access to ccamacho-test-bench namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DEPLOY_DIR="$OCP_DIR/deploy"
NAMESPACE="ccamacho-test-bench"

HF_TOKEN=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --hf-token) HF_TOKEN="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

echo "=== Deploying vLLM (Qwen3-27B) to OCP ==="
echo "  Namespace: $NAMESPACE"
echo "  GPU:       AMD Instinct MI300X"
echo ""

# ── login check ─────────────────────────────────────────────────────
if ! oc whoami >/dev/null 2>&1; then
  TOKEN_FILE="$OCP_DIR/token.md"
  if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(grep 'sha256~' "$TOKEN_FILE" | head -1 | grep -oP 'sha256~[A-Za-z0-9_-]+')
    SERVER=$(grep -- '--server=' "$TOKEN_FILE" | grep -oP 'https://[^ ]+')
    echo "Logging in..."
    oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true
  else
    echo "ERROR: Not logged in and no token.md found" >&2
    exit 1
  fi
fi

oc project "$NAMESPACE" 2>/dev/null || {
  echo "ERROR: Cannot switch to namespace $NAMESPACE" >&2
  exit 1
}

# ── set HF token if provided ────────────────────────────────────────
if [[ -n "$HF_TOKEN" ]]; then
  echo "Setting HuggingFace token..."
  oc create secret generic hf-token \
    --from-literal=token="$HF_TOKEN" \
    --dry-run=client -o yaml | oc apply -f -
fi

# ── deploy ──────────────────────────────────────────────────────────
echo "Applying manifests..."
oc apply -k "$DEPLOY_DIR"

echo ""
echo "Waiting for PVC to bind..."
oc wait --for=jsonpath='{.status.phase}'=Bound pvc/vllm-model-cache --timeout=120s 2>/dev/null || {
  echo "WARNING: PVC not yet bound (may bind on first pod schedule with WaitForFirstConsumer)"
}

echo ""
echo "Waiting for deployment rollout..."
echo "(This may take 15-30 minutes on first run while the model downloads)"
echo "Monitor progress: oc logs -f deployment/vllm-qwen"
echo ""

oc rollout status deployment/vllm-qwen --timeout=3600s || {
  echo ""
  echo "WARNING: Deployment not ready within timeout."
  echo "Check logs: oc logs deployment/vllm-qwen"
  echo "Check events: oc get events --sort-by=.lastTimestamp | tail -20"
  exit 1
}

# ── verify ──────────────────────────────────────────────────────────
echo ""
echo "=== Deployment Ready ==="

ROUTE_HOST=$(oc get route vllm-qwen -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$ROUTE_HOST" ]]; then
  echo "  Internal: http://vllm-qwen.${NAMESPACE}.svc.cluster.local:8000/v1"
  echo "  External: https://${ROUTE_HOST}/v1"
  echo "  API Key:  swebench-token"
  echo ""
  echo "Test with:"
  echo "  curl -sk https://${ROUTE_HOST}/v1/models -H 'Authorization: Bearer swebench-token'"
else
  echo "  Internal: http://vllm-qwen.${NAMESPACE}.svc.cluster.local:8000/v1"
  echo "  WARNING: No external route found"
fi
