#!/usr/bin/env bash
# Check the status of the vLLM deployment on the OCP cluster.
#
# Usage: ./check-status.sh

set -euo pipefail

NAMESPACE="ccamacho-test-bench"

echo "=== vLLM Deployment Status ==="
echo ""

# ── login check ─────────────────────────────────────────────────────
if ! oc whoami >/dev/null 2>&1; then
  echo "ERROR: Not logged in. Run: oc login ..." >&2
  exit 1
fi
echo "Logged in as: $(oc whoami)"
echo ""

# ── pods ────────────────────────────────────────────────────────────
echo "── Pods ──"
oc get pods -n "$NAMESPACE" -l app=vllm-qwen -o wide 2>/dev/null || echo "  No pods found"
echo ""

# ── deployment ──────────────────────────────────────────────────────
echo "── Deployment ──"
oc get deployment vllm-qwen -n "$NAMESPACE" -o wide 2>/dev/null || echo "  Not deployed"
echo ""

# ── PVC ─────────────────────────────────────────────────────────────
echo "── Storage (PVC) ──"
oc get pvc vllm-model-cache -n "$NAMESPACE" 2>/dev/null || echo "  No PVC"
echo ""

# ── route ───────────────────────────────────────────────────────────
echo "── Route ──"
ROUTE_HOST=$(oc get route vllm-qwen -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -n "$ROUTE_HOST" ]]; then
  echo "  URL: https://${ROUTE_HOST}/v1"

  HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://${ROUTE_HOST}/v1/models" \
    -H "Authorization: Bearer swebench-token" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" == "200" ]]; then
    echo "  Health: HEALTHY (HTTP 200)"
    MODELS=$(curl -sk "https://${ROUTE_HOST}/v1/models" \
      -H "Authorization: Bearer swebench-token" 2>/dev/null \
      | jq -r '.data[].id' 2>/dev/null || echo "unknown")
    echo "  Serving: $MODELS"
  else
    echo "  Health: UNHEALTHY (HTTP $HTTP_CODE)"
  fi
else
  echo "  No route found"
fi
echo ""

# ── GPU in pod ──────────────────────────────────────────────────────
POD=$(oc get pods -n "$NAMESPACE" -l app=vllm-qwen -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [[ -n "$POD" ]]; then
  echo "── GPU (via rocm-smi in pod) ──"
  oc exec "$POD" -n "$NAMESPACE" -- rocm-smi --showproductname 2>/dev/null | grep -E 'Card Series|Card Model' || echo "  Could not query GPU"
  echo ""
  echo "── VRAM Usage ──"
  oc exec "$POD" -n "$NAMESPACE" -- rocm-smi --showmeminfo vram 2>/dev/null | grep -E 'VRAM' || echo "  Could not query VRAM"
fi

echo ""
echo "── Recent Events ──"
oc get events -n "$NAMESPACE" --sort-by=.lastTimestamp --field-selector involvedObject.name=vllm-qwen 2>/dev/null | tail -10 || echo "  No events"
