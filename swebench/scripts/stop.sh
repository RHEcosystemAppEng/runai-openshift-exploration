#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# stop.sh — gracefully stop a running benchmark without tearing down infra.
#
# Kills the autonomous monitor inside the coordinator, deletes outstanding
# swebench-instance Jobs/pods, and prints a final results summary. The vLLM
# endpoint, scheduling fabric, and workspace PVC are left intact so you can relaunch.
# Adapted from _legacy/stop-benchmark.sh, generalised to per-squad namespaces.
#
# Usage:
#   bash scripts/stop.sh --squad a
#   bash scripts/stop.sh --squad all
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad) SQUAD_ARG="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_server_guard
echo

stop_one() {
  local s="$1" ns coord
  ns="$(squad_ns "$s")"
  oc get namespace "$ns" >/dev/null 2>&1 || { warn "${ns}: namespace missing, skipping"; return; }
  log "Squad $s (${ns}): stopping benchmark"

  coord="$(oc -n "$ns" get pods -l app=benchmark-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$coord" ]]; then
    oc -n "$ns" exec "$coord" -- bash -c '
      pkill -f "autonomous-k8s-monitor" 2>/dev/null || true
      pkill -f "run-all-k8s"           2>/dev/null || true
      pkill -f "run-instance-k8s"      2>/dev/null || true
      echo "monitor processes signalled"
    ' 2>/dev/null || warn "${ns}: could not signal coordinator"
  fi

  local n
  n="$(oc -n "$ns" get jobs -l app=swebench-instance --no-headers 2>/dev/null | wc -l)"
  if [[ "$n" -gt 0 ]]; then
    oc -n "$ns" delete jobs -l app=swebench-instance --wait=false >/dev/null 2>&1 || true
    oc -n "$ns" delete pods -l app=swebench-instance --wait=false >/dev/null 2>&1 || true
    ok "${ns}: deleted ${n} instance job(s)"
  else
    log "${ns}: no instance jobs running"
  fi
  echo
}

for s in $(resolve_squads "$SQUAD_ARG"); do stop_one "$s"; done
log "Benchmark stopped. Serving + scheduling + workspace remain. Relaunch with 05-launch-benchmark.sh."
