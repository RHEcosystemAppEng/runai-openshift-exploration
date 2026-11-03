#!/usr/bin/env bash
# Test inference against the self-hosted vLLM endpoint.
#
# Usage: ./test-inference.sh [--prompt "custom prompt"]

set -euo pipefail

NAMESPACE="ccamacho-test-bench"
PROMPT="${1:-Write a Python function that reverses a string.}"

ROUTE_HOST=$(oc get route vllm-qwen -n "$NAMESPACE" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
if [[ -z "$ROUTE_HOST" ]]; then
  echo "ERROR: vLLM route not found" >&2
  exit 1
fi

VLLM_URL="https://${ROUTE_HOST}/v1"
API_KEY="swebench-token"

echo "=== Testing vLLM Inference ==="
echo "  Endpoint: $VLLM_URL"
echo "  Prompt:   $PROMPT"
echo ""

# ── list models ─────────────────────────────────────────────────────
echo "── Available Models ──"
curl -sk "$VLLM_URL/models" -H "Authorization: Bearer $API_KEY" | jq '.data[] | {id, created}' 2>/dev/null
echo ""

# ── chat completion ─────────────────────────────────────────────────
echo "── Chat Completion ──"
START_MS=$(($(date +%s%N) / 1000000))

RESPONSE=$(curl -sk "$VLLM_URL/chat/completions" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "{
    \"model\": \"Qwen/Qwen3.8-27B\",
    \"messages\": [{\"role\": \"user\", \"content\": \"$PROMPT\"}],
    \"max_tokens\": 512,
    \"temperature\": 0.7
  }" 2>/dev/null)

END_MS=$(($(date +%s%N) / 1000000))
ELAPSED_MS=$((END_MS - START_MS))

echo "$RESPONSE" | jq -r '.choices[0].message.content' 2>/dev/null || echo "$RESPONSE"
echo ""

# ── usage stats ─────────────────────────────────────────────────────
echo "── Usage ──"
echo "$RESPONSE" | jq '{
  prompt_tokens: .usage.prompt_tokens,
  completion_tokens: .usage.completion_tokens,
  total_tokens: .usage.total_tokens,
  latency_ms: '$ELAPSED_MS'
}' 2>/dev/null || echo "  Could not parse usage"
