#!/usr/bin/env bash
# Gracefully stop a running SWE-bench benchmark on the OCP cluster.
#
# Usage: ./stop-benchmark.sh [--full]
#
# Options:
#   --full    Also tear down the vLLM inference deployment

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="ccamacho-test-bench"
FULL_TEARDOWN=0

[[ "${1:-}" == "--full" ]] && FULL_TEARDOWN=1

# ── OCP login ──────────────────────────────────────────────────────────
if ! oc whoami >/dev/null 2>&1; then
  TOKEN_FILE="$OCP_DIR/token.md"
  if [[ -f "$TOKEN_FILE" ]]; then
    TOKEN=$(grep 'sha256~' "$TOKEN_FILE" | head -1 | grep -oP 'sha256~[A-Za-z0-9_-]+')
    SERVER=$(grep -- '--server=' "$TOKEN_FILE" | grep -oP 'https://[^ ]+')
    echo "Logging in to OCP..."
    oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1
  else
    echo "ERROR: Not logged in and no token.md found at $TOKEN_FILE" >&2
    exit 1
  fi
fi

echo "=== Stopping SWE-bench Benchmark ==="
echo ""

# ── 1. Kill autonomous monitor in coordinator pod ─────────────────────
COORD_POD=$(oc get pods -n "$NAMESPACE" -l app=benchmark-runner \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -n "$COORD_POD" ]]; then
  echo "Killing autonomous monitor processes in coordinator..."
  oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
    # Kill run-all-k8s.sh and run-instance-k8s.sh processes
    pkill -f "run-all-k8s" 2>/dev/null || true
    pkill -f "run-instance-k8s" 2>/dev/null || true
    pkill -f "run-all-parallel" 2>/dev/null || true
    echo "Monitor processes killed"
  ' 2>/dev/null || echo "  (no coordinator pod or no processes to kill)"
else
  echo "  Coordinator pod not found -- skipping process kill"
fi
echo ""

# ── 2. Delete all running swebench-instance Jobs ──────────────────────
echo "Deleting swebench-instance jobs..."
JOB_COUNT=$(oc get jobs -n "$NAMESPACE" -l app=swebench-instance --no-headers 2>/dev/null | wc -l)
if [[ "$JOB_COUNT" -gt 0 ]]; then
  oc delete jobs -n "$NAMESPACE" -l app=swebench-instance --wait=false 2>/dev/null || true
  echo "  Deleted $JOB_COUNT job(s)"
  # Also clean up any orphaned pods from those jobs
  oc delete pods -n "$NAMESPACE" -l app=swebench-instance --wait=false 2>/dev/null || true
else
  echo "  No swebench-instance jobs found"
fi
echo ""

# ── 3. Final results summary ─────────────────────────────────────────
echo "-- Final Results Summary --"
if [[ -n "$COORD_POD" ]]; then
  oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
    for model_dir in /workspace/results/*/; do
      [ -d "$model_dir" ] || continue
      model=$(basename "$model_dir")
      total=$(find "$model_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
      with_patch=$(find "$model_dir" -name "ami-*-diff.patch" -not -empty 2>/dev/null | wc -l)
      echo "  $model: $total attempted, $with_patch with patches"
    done
    for model_dir in /workspace/eval-results/*/; do
      [ -d "$model_dir" ] || continue
      model=$(basename "$model_dir")
      total=0; resolved=0
      for r in "$model_dir"/*/report.json; do
        [ -f "$r" ] || continue
        total=$((total + 1))
        if python3 -c "import json; print(json.load(open(\"$r\")).get(\"resolved\", False))" 2>/dev/null | grep -q "True"; then
          resolved=$((resolved + 1))
        fi
      done
      [ "$total" -gt 0 ] && pct=$(python3 -c "print(f\"{$resolved/$total*100:.1f}\")" 2>/dev/null || echo "?")
      [ "$total" -gt 0 ] && echo "  $model eval: $resolved / $total resolved ($pct%)"
    done
  ' 2>/dev/null || echo "  (could not retrieve results)"
else
  echo "  (coordinator pod not available)"
fi
echo ""

# ── 4. Optionally tear down vLLM ──────────────────────────────────────
if [[ "$FULL_TEARDOWN" == "1" ]]; then
  echo "-- Full teardown: removing vLLM deployment --"
  "$SCRIPT_DIR/teardown.sh" --keep-pvc
  echo ""
fi

echo "=== Benchmark stopped ==="
