#!/usr/bin/env bash
# Run SWE-bench instances as K8s Jobs with configurable parallelism.
# Designed to run FROM the coordinator pod on the cluster.
#
# Usage: ./run-all-k8s.sh <language> [options]
#
# Options:
#   --parallel N       Max concurrent jobs (default: 3)
#   --limit N          Max instances to run
#   --skip-existing    Skip already-attempted instances
#
# Example:
#   ./run-all-k8s.sh go --parallel 5 --skip-existing
#   ./run-all-k8s.sh java --limit 10

set -euo pipefail

LANGUAGE="${1:?Usage: $0 <language> [--parallel N] [--limit N] [--skip-existing]}"
shift

WORKSPACE="${WORKSPACE:-/workspace}"
NAMESPACE="${NAMESPACE:-ccamacho-test-bench}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARALLEL=3
LIMIT=""
SKIP_EXISTING=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --parallel)      PARALLEL="$2"; shift 2 ;;
    --limit)         LIMIT="$2"; shift 2 ;;
    --skip-existing) SKIP_EXISTING=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

JSONL_FILE="$WORKSPACE/data/swebench-multilang-${LANGUAGE}.jsonl"
MODEL="${AI_MODEL:-Qwen/Qwen3-32B}"
MODEL_SLUG="$(echo "$MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')"

if [[ ! -f "$JSONL_FILE" ]]; then
  echo "ERROR: Dataset not found at $JSONL_FILE" >&2
  exit 1
fi

# ── check vLLM is healthy ──────────────────────────────────────────
VLLM_URL="${AI_BASE_URL:-http://qwen-inference.ccamacho-test-bench.svc.cluster.local:8000/v1}"
echo "Checking vLLM at $VLLM_URL ..."
HTTP_CODE=$(curl -sk -o /dev/null -w '%{http_code}' "$VLLM_URL/models" \
  -H "Authorization: Bearer ${AI_API_KEY:-swebench-token}" 2>/dev/null || echo "000")
if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR: vLLM not healthy (HTTP $HTTP_CODE). Wait for model to load." >&2
  exit 1
fi
echo "vLLM healthy"

# ── collect instances ──────────────────────────────────────────────
mapfile -t INSTANCE_IDS < <(jq -r '.instance_id' "$JSONL_FILE")
TOTAL=${#INSTANCE_IDS[@]}

if [[ -n "$LIMIT" ]]; then
  INSTANCE_IDS=("${INSTANCE_IDS[@]:0:$LIMIT}")
fi
RUN_COUNT=${#INSTANCE_IDS[@]}

echo ""
echo "=== SWE-bench $LANGUAGE Benchmark (K8s Jobs) ==="
echo "  Model:    $MODEL"
echo "  Dataset:  $TOTAL instances"
echo "  Running:  $RUN_COUNT instances"
echo "  Parallel: $PARALLEL"
echo ""

RESULTS_LOG="$WORKSPACE/logs/run-${LANGUAGE}-$(date +%Y%m%d_%H%M%S).log"
RUNNING=0
COMPLETED=0
STARTED=0

for INSTANCE_ID in "${INSTANCE_IDS[@]}"; do
  [[ -z "$INSTANCE_ID" ]] && continue

  # Skip check
  if [[ "$SKIP_EXISTING" == "1" ]]; then
    RESULT_DIR="$WORKSPACE/results/$MODEL_SLUG/$INSTANCE_ID"
    if [[ -f "$RESULT_DIR/ami-${MODEL_SLUG}-diff.patch" || -f "$RESULT_DIR/ami-${MODEL_SLUG}.json" ]]; then
      echo "SKIP $INSTANCE_ID (existing)" | tee -a "$RESULTS_LOG"
      continue
    fi
  fi

  STARTED=$((STARTED + 1))
  echo "[$STARTED/$RUN_COUNT] Starting $INSTANCE_ID ..."

  (
    export SKIP_EXISTING="$SKIP_EXISTING"
    "$SCRIPT_DIR/run-instance-k8s.sh" "$LANGUAGE" "$INSTANCE_ID" >> "$RESULTS_LOG" 2>&1
    RESULT_DIR="$WORKSPACE/results/$MODEL_SLUG/$INSTANCE_ID"
    PATCH="$RESULT_DIR/ami-${MODEL_SLUG}-diff.patch"
    if [[ -f "$PATCH" && -s "$PATCH" ]]; then
      echo "PASS $INSTANCE_ID" >> "$RESULTS_LOG"
    else
      echo "FAIL $INSTANCE_ID" >> "$RESULTS_LOG"
    fi
  ) &

  RUNNING=$((RUNNING + 1))
  if (( RUNNING >= PARALLEL )); then
    wait -n 2>/dev/null || true
    RUNNING=$((RUNNING - 1))
    COMPLETED=$((COMPLETED + 1))
  fi
done

wait || true

# ── summary ─────────────────────────────────────────────────────────
echo ""
echo "========================================"
WITH_PATCH=$(find "$WORKSPACE/results/$MODEL_SLUG" -name "ami-${MODEL_SLUG}-diff.patch" -not -empty 2>/dev/null | wc -l)
ATTEMPTED=$(find "$WORKSPACE/results/$MODEL_SLUG" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
echo "Results: $WITH_PATCH / $ATTEMPTED with patches"
echo "Log: $RESULTS_LOG"
echo ""

# Clean up completed jobs
echo "Cleaning up completed jobs..."
oc delete jobs -l app=swebench-instance -n "$NAMESPACE" --field-selector=status.successful=1 2>/dev/null || true

echo "========================================"
