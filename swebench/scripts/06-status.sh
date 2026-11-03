#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 06-status.sh — cross-squad status: serving, agents, benchmark, and Kueue quota.
#
# For each squad prints: vLLM endpoint health, coordinator state, running
# swebench-instance Jobs, and per-instance results. Then prints the cohort-wide
# Kueue view (ClusterQueue usage/borrowing + per-namespace LocalQueue + pending
# Workloads) so you can see admission, quota borrowing, and preemption in action.
#
# Usage:
#   bash scripts/06-status.sh                 # all squads + cohort
#   bash scripts/06-status.sh --squad a
#   bash scripts/06-status.sh --watch 30      # refresh every 30s
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="all"; WATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad) SQUAD_ARG="$2"; shift 2 ;;
    --watch) WATCH="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_login

squad_status() {
  local s="$1" ns split
  ns="$(squad_ns "$s")"; split="$(squad_split "$s")"
  echo "────────────────────────────────────────────────────────────"
  echo "  Squad $s — ${ns}  (SWE-bench ${split})"
  echo "────────────────────────────────────────────────────────────"
  if ! oc get namespace "$ns" >/dev/null 2>&1; then echo "  namespace not created"; echo; return; fi

  # vLLM endpoint
  local host code="n/a"
  host="$(oc -n "$ns" get route qwen-inference -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/v1/models" \
      -H "Authorization: Bearer ${VLLM_API_KEY}" 2>/dev/null || echo 000)"
  fi
  printf '  vLLM     : %s (route HTTP %s)\n' \
    "$(oc -n "$ns" get pods -l app=vllm-qwen -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo none)" "$code"
  printf '  Coord    : %s\n' \
    "$(oc -n "$ns" get pods -l app=benchmark-runner -o jsonpath='{.items[*].status.phase}' 2>/dev/null || echo none)"

  # instance jobs
  local jobs active succ fail
  jobs="$(oc -n "$ns" get jobs -l app=swebench-instance --no-headers 2>/dev/null || true)"
  if [[ -n "$jobs" ]]; then
    active="$(echo "$jobs" | awk '$3 ~ /^[1-9]/' | wc -l)"
    succ="$(echo "$jobs"  | grep -c 'Complete' || true)"
    fail="$(echo "$jobs"  | awk '$0 ~ /[1-9]\/1.*fail/i' | wc -l)"
    printf '  Jobs     : %s total | %s active\n' "$(echo "$jobs" | wc -l)" "$active"
  else
    echo "  Jobs     : none"
  fi

  # results from coordinator
  local coord
  coord="$(oc -n "$ns" get pods -l app=benchmark-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$coord" ]]; then
    oc -n "$ns" exec "$coord" -- bash -c '
      shopt -s nullglob
      for d in /workspace/verified/*/*/; do
        [ -d "$d" ] || continue
        echo "  Verified : $(basename "$(dirname "$d")")/$(basename "$d") -> $(find "$d" -maxdepth 1 -mindepth 1 -type d | wc -l) resolved"
      done
      wp=$(find /workspace/results -name "*-diff.patch" -not -empty 2>/dev/null | wc -l)
      echo "  Patches  : $wp non-empty diffs in /workspace/results"
    ' 2>/dev/null || echo "  Results  : (coordinator unreachable)"
  fi
  echo
}

cohort_status() {
  echo "════════════════════════════════════════════════════════════"
  echo "  Kueue cohort: ${COHORT_NAME}  (shared ${POOL_GPU_TOTAL}-GPU pool)"
  echo "════════════════════════════════════════════════════════════"
  echo "  ClusterQueues (nominal / borrowing / admitted):"
  oc get clusterqueue -l app.kubernetes.io/part-of=swebench-live-vllm \
    -o custom-columns='NAME:.metadata.name,COHORT:.spec.cohort,PENDING:.status.pendingWorkloads,ADMITTED:.status.admittedWorkloads,RESERVING:.status.reservingWorkloads' \
    2>/dev/null || echo "  (Kueue not installed?)"
  echo
  echo "  GPU flavor usage:"
  oc get clusterqueue -l app.kubernetes.io/part-of=swebench-live-vllm -o json 2>/dev/null \
    | jq -r '.items[] | "    \(.metadata.name): " + (
        ([.status.flavorsUsage[]?.resources[]? | select(.name|test("gpu")) | .total] | add // "0" | tostring)
        + " GPU admitted")' 2>/dev/null || true
  echo
  for s in "${SQUADS[@]}"; do
    ns="$(squad_ns "$s")"
    oc get namespace "$ns" >/dev/null 2>&1 || continue
    echo "  LocalQueue + Workloads in ${ns}:"
    oc -n "$ns" get localqueue 2>/dev/null | sed 's/^/    /' || true
    oc -n "$ns" get workloads -o custom-columns='WORKLOAD:.metadata.name,QUEUE:.spec.queueName,ADMITTED:.status.conditions[-1].type' 2>/dev/null \
      | sed 's/^/    /' | head -12 || true
    echo
  done
}

render() {
  echo "SWE-bench Live / vLLM — status @ $(date '+%Y-%m-%d %H:%M:%S')"
  echo
  for s in $(resolve_squads "$SQUAD_ARG"); do squad_status "$s"; done
  cohort_status
}

if [[ -n "$WATCH" ]]; then
  while true; do clear; render; sleep "$WATCH"; done
else
  render
fi
