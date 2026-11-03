#!/usr/bin/env bash
# Monitor the current status of a running SWE-bench benchmark on the OCP cluster.
# Designed to be run from a local machine with oc CLI access.
#
# Usage: ./monitor-benchmark.sh [--watch N]
#
# Options:
#   --watch N    Refresh every N seconds (default: one-shot)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="ccamacho-test-bench"
WATCH_INTERVAL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --watch) WATCH_INTERVAL="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ── OCP login ──────────────────────────────────────────────────────────
ensure_login() {
  if oc whoami >/dev/null 2>&1; then
    return 0
  fi
  TOKEN_FILE="$OCP_DIR/token.md"
  if [[ -f "$TOKEN_FILE" ]]; then
    local TOKEN SERVER
    TOKEN=$(grep 'sha256~' "$TOKEN_FILE" | head -1 | grep -oP 'sha256~[A-Za-z0-9_-]+')
    SERVER=$(grep -- '--server=' "$TOKEN_FILE" | grep -oP 'https://[^ ]+')
    echo "Logging in to OCP..."
    oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1
  else
    echo "ERROR: Not logged in and no token.md found at $TOKEN_FILE" >&2
    exit 1
  fi
}

# ── helper: get coordinator pod name ───────────────────────────────────
get_coordinator_pod() {
  oc get pods -n "$NAMESPACE" -l app=benchmark-runner \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# ── helper: get vllm pod name ─────────────────────────────────────────
get_vllm_pod() {
  oc get pods -n "$NAMESPACE" -l app=vllm-qwen \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

# ── main display ──────────────────────────────────────────────────────
show_status() {
  local NOW
  NOW=$(date '+%Y-%m-%d %H:%M:%S')
  echo "================================================================"
  echo "  SWE-bench Benchmark Monitor  |  $NOW"
  echo "================================================================"
  echo ""

  # ── 1. vLLM pod status ─────────────────────────────────────────────
  echo "-- vLLM Inference --"
  local VLLM_POD VLLM_READY
  VLLM_POD=$(get_vllm_pod)
  if [[ -n "$VLLM_POD" ]]; then
    VLLM_READY=$(oc get pod "$VLLM_POD" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    local VLLM_PHASE
    VLLM_PHASE=$(oc get pod "$VLLM_POD" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$VLLM_READY" == "True" ]]; then
      echo "  Pod:    $VLLM_POD  [READY]  ($VLLM_PHASE)"
    else
      echo "  Pod:    $VLLM_POD  [NOT READY]  ($VLLM_PHASE)"
    fi

    # GPU VRAM via rocm-smi
    local VRAM_INFO
    VRAM_INFO=$(oc exec "$VLLM_POD" -n "$NAMESPACE" -- \
      rocm-smi --showmeminfo vram 2>/dev/null | grep -E 'VRAM Total|VRAM Used' || true)
    if [[ -n "$VRAM_INFO" ]]; then
      echo "  GPU VRAM:"
      echo "$VRAM_INFO" | sed 's/^/    /'
    else
      echo "  GPU VRAM: (could not query rocm-smi)"
    fi
  else
    echo "  Pod:    NOT FOUND"
  fi
  echo ""

  # ── 2. Coordinator pod status ───────────────────────────────────────
  echo "-- Coordinator --"
  local COORD_POD
  COORD_POD=$(get_coordinator_pod)
  if [[ -n "$COORD_POD" ]]; then
    local COORD_READY COORD_PHASE
    COORD_READY=$(oc get pod "$COORD_POD" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
    COORD_PHASE=$(oc get pod "$COORD_POD" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    if [[ "$COORD_READY" == "True" ]]; then
      echo "  Pod:    $COORD_POD  [READY]  ($COORD_PHASE)"
    else
      echo "  Pod:    $COORD_POD  [NOT READY]  ($COORD_PHASE)"
    fi
  else
    echo "  Pod:    NOT FOUND"
  fi
  echo ""

  # ── 3. Running K8s Jobs ─────────────────────────────────────────────
  echo "-- SWE-bench Instance Jobs --"
  local JOBS_OUTPUT
  JOBS_OUTPUT=$(oc get jobs -n "$NAMESPACE" -l app=swebench-instance \
    --no-headers 2>/dev/null || echo "")
  if [[ -n "$JOBS_OUTPUT" ]]; then
    local TOTAL_JOBS ACTIVE_JOBS SUCCEEDED_JOBS FAILED_JOBS
    TOTAL_JOBS=$(echo "$JOBS_OUTPUT" | wc -l)
    ACTIVE_JOBS=$(echo "$JOBS_OUTPUT" | awk '$3 ~ /^[1-9]/' | wc -l)
    SUCCEEDED_JOBS=$(echo "$JOBS_OUTPUT" | awk '$4 ~ /^[1-9]/' | wc -l)
    FAILED_JOBS=$(echo "$JOBS_OUTPUT" | awk '$5 ~ /^[1-9]/' | wc -l)
    echo "  Total: $TOTAL_JOBS  |  Active: $ACTIVE_JOBS  |  Succeeded: $SUCCEEDED_JOBS  |  Failed: $FAILED_JOBS"
    echo ""
    echo "  Active jobs:"
    oc get jobs -n "$NAMESPACE" -l app=swebench-instance \
      --sort-by=.metadata.creationTimestamp 2>/dev/null \
      | head -20 || true
  else
    echo "  No swebench-instance jobs found"
  fi
  echo ""

  # ── 4. Results & eval counts (via coordinator pod) ──────────────────
  echo "-- Results --"
  if [[ -n "$COORD_POD" ]]; then
    # Count results directories per model slug
    local RESULTS_INFO
    RESULTS_INFO=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      for model_dir in /workspace/results/*/; do
        [ -d "$model_dir" ] || continue
        model=$(basename "$model_dir")
        total=$(find "$model_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        with_patch=$(find "$model_dir" -name "ami-*-diff.patch" -not -empty 2>/dev/null | wc -l)
        echo "  $model: $total attempted, $with_patch with patches"
      done
    ' 2>/dev/null || echo "  (could not query coordinator)")
    echo "$RESULTS_INFO"

    # Count eval-results
    local EVAL_INFO
    EVAL_INFO=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      for model_dir in /workspace/eval-results/*/; do
        [ -d "$model_dir" ] || continue
        model=$(basename "$model_dir")
        total=$(find "$model_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        resolved=$(find "$model_dir" -name "report.json" -exec grep -l "\"resolved\": true" {} \; 2>/dev/null | wc -l)
        echo "  $model eval: $resolved / $total resolved"
      done
    ' 2>/dev/null || echo "  (could not query eval-results)")
    if [[ -n "$EVAL_INFO" && "$EVAL_INFO" != *"could not"* ]]; then
      echo "$EVAL_INFO"
    fi
  else
    echo "  (coordinator pod not available)"
  fi
  echo ""

  # ── 5. Resolution rate from eval reports ────────────────────────────
  echo "-- Resolution Rate --"
  if [[ -n "$COORD_POD" ]]; then
    local RESOLUTION_INFO
    RESOLUTION_INFO=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      for model_dir in /workspace/eval-results/*/; do
        [ -d "$model_dir" ] || continue
        model=$(basename "$model_dir")
        total=0
        resolved=0
        for r in "$model_dir"/*/report.json; do
          [ -f "$r" ] || continue
          total=$((total + 1))
          if python3 -c "import json; print(json.load(open(\"$r\")).get(\"resolved\", False))" 2>/dev/null | grep -q "True"; then
            resolved=$((resolved + 1))
          fi
        done
        if [ "$total" -gt 0 ]; then
          pct=$(python3 -c "print(f\"{$resolved/$total*100:.1f}\")" 2>/dev/null || echo "?")
          echo "  $model: $resolved / $total ($pct%)"
        else
          echo "  $model: no evaluations yet"
        fi
      done
    ' 2>/dev/null || echo "  (could not compute resolution rate)")
    echo "$RESOLUTION_INFO"
  else
    echo "  (coordinator pod not available)"
  fi
  echo ""

  # ── 6. Autonomous monitor log (last 15 lines) ──────────────────────
  echo "-- Autonomous Monitor Log (last 15 lines) --"
  if [[ -n "$COORD_POD" ]]; then
    local LOG_FILE
    LOG_FILE=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      ls -t /workspace/logs/run-*.log 2>/dev/null | head -1
    ' 2>/dev/null || echo "")
    if [[ -n "$LOG_FILE" ]]; then
      echo "  Log: $LOG_FILE"
      oc exec "$COORD_POD" -n "$NAMESPACE" -- tail -15 "$LOG_FILE" 2>/dev/null \
        | sed 's/^/  /' || echo "  (could not read log)"
    else
      echo "  No run logs found in /workspace/logs/"
    fi
  else
    echo "  (coordinator pod not available)"
  fi
  echo ""

  # ── 7. Current retry round ─────────────────────────────────────────
  echo "-- Retry Round --"
  if [[ -n "$COORD_POD" ]]; then
    local LOG_COUNT
    LOG_COUNT=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      ls /workspace/logs/run-*.log 2>/dev/null | wc -l
    ' 2>/dev/null || echo "0")
    echo "  Run logs found: $LOG_COUNT (each log file = 1 run/retry round)"
    # Show the latest log file name which usually encodes round info
    local LATEST_LOG
    LATEST_LOG=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      ls -t /workspace/logs/run-*.log 2>/dev/null | head -1 | xargs basename 2>/dev/null
    ' 2>/dev/null || echo "none")
    echo "  Latest: $LATEST_LOG"
  else
    echo "  (coordinator pod not available)"
  fi
  echo ""

  # ── 8. ETA based on average instance duration ──────────────────────
  echo "-- ETA --"
  if [[ -n "$COORD_POD" ]]; then
    local ETA_INFO
    ETA_INFO=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      # Get completed job durations from K8s
      COMPLETED=0
      TOTAL_SECS=0
      while IFS= read -r line; do
        start=$(echo "$line" | cut -d"|" -f1)
        end=$(echo "$line" | cut -d"|" -f2)
        [ -z "$start" ] || [ -z "$end" ] && continue
        start_epoch=$(date -d "$start" +%s 2>/dev/null || echo 0)
        end_epoch=$(date -d "$end" +%s 2>/dev/null || echo 0)
        [ "$start_epoch" -eq 0 ] || [ "$end_epoch" -eq 0 ] && continue
        duration=$((end_epoch - start_epoch))
        [ "$duration" -le 0 ] && continue
        TOTAL_SECS=$((TOTAL_SECS + duration))
        COMPLETED=$((COMPLETED + 1))
      done < <(oc get jobs -n ccamacho-test-bench -l app=swebench-instance \
        -o jsonpath="{range .items[?(@.status.completionTime)]}{.status.startTime}|{.status.completionTime}{\"\n\"}{end}" 2>/dev/null)

      if [ "$COMPLETED" -gt 0 ]; then
        AVG_SECS=$((TOTAL_SECS / COMPLETED))
        AVG_MIN=$((AVG_SECS / 60))

        # Count remaining (active) jobs
        ACTIVE=$(oc get jobs -n ccamacho-test-bench -l app=swebench-instance \
          -o jsonpath="{range .items[?(@.status.active)]}{.metadata.name}{\"\n\"}{end}" 2>/dev/null | grep -c . || echo 0)

        # Count total results vs total dataset
        for model_dir in /workspace/results/*/; do
          [ -d "$model_dir" ] || continue
          DONE=$(find "$model_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
        done
        DONE=${DONE:-0}

        TOTAL_DATASET=0
        for f in /workspace/data/swebench-multilang-*.jsonl; do
          [ -f "$f" ] || continue
          TOTAL_DATASET=$((TOTAL_DATASET + $(wc -l < "$f")))
        done

        REMAINING=$((TOTAL_DATASET - DONE))
        [ "$REMAINING" -lt 0 ] && REMAINING=0

        # Assume current parallelism from active jobs (min 1)
        PARALLELISM=$ACTIVE
        [ "$PARALLELISM" -lt 1 ] && PARALLELISM=1

        ETA_SECS=$(( (REMAINING * AVG_SECS) / PARALLELISM ))
        ETA_HRS=$((ETA_SECS / 3600))
        ETA_MINS=$(( (ETA_SECS % 3600) / 60 ))

        echo "  Completed instances: $COMPLETED"
        echo "  Avg duration: ${AVG_MIN}m per instance"
        echo "  Remaining:    ~$REMAINING instances"
        echo "  Parallelism:  $PARALLELISM active jobs"
        echo "  ETA:          ~${ETA_HRS}h ${ETA_MINS}m"
      else
        echo "  No completed jobs yet -- cannot estimate"
      fi
    ' 2>/dev/null || echo "  (could not compute ETA)")
    echo "$ETA_INFO"
  else
    echo "  (coordinator pod not available)"
  fi

  echo ""
  echo "================================================================"
}

# ── run ───────────────────────────────────────────────────────────────
ensure_login

if [[ -n "$WATCH_INTERVAL" ]]; then
  while true; do
    clear
    show_status
    sleep "$WATCH_INTERVAL"
  done
else
  show_status
fi
