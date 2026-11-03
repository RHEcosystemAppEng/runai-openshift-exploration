#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 12-runai-status.sh — Phase 2: Run:AI project / queue / allocation status
#
# The Run:AI counterpart of the RHOAI baseline's 06-status.sh. It prints the same
# shape of information (per-squad GPU allocation, workloads, scheduler) using the
# Run:AI control plane, so the two stacks can be compared apples-to-apples. Uses
# the `runai` CLI when present, otherwise falls back to `oc get` on the installed
# Run:AI CRDs.
#
# Usage:
#   bash scripts/runai/12-runai-status.sh [--squad a|b|c] [--watch SECONDS]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/scripts/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/common.sh"
else
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/env.sh"
fi

declare -F die >/dev/null 2>&1 || die() { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
declare -F require_server >/dev/null 2>&1 || require_server() {
  command -v oc >/dev/null 2>&1 || die "'oc' not found in PATH"
  local current expected="${CLUSTER_SERVER%/}"
  current="$(oc whoami --show-server 2>/dev/null || true)"
  [[ -n "$current" ]] || die "Not logged in to OpenShift. Run 'oc login' first."
  [[ "${current%/}" == "$expected" ]] || die "Refusing to run: current server '${current}' != expected '${expected}' (config/env.sh CLUSTER_SERVER)."
}

ONLY_SQUAD=""
WATCH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad) ONLY_SQUAD="${2:?}"; shift 2 ;;
    --watch) WATCH="${2:?}"; shift 2 ;;
    -h|--help) grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_server

squads=("${SQUADS[@]}")
[[ -n "$ONLY_SQUAD" ]] && squads=("$ONLY_SQUAD")

runai_kinds() { oc api-resources --no-headers 2>/dev/null | awk '$0 ~ /run\.ai/ {print $1}' | sort -u; }

gpu_requested_in_ns() {
  local ns="$1"
  if command -v python3 >/dev/null 2>&1; then
    oc get pods -n "$ns" -o json 2>/dev/null | GPU_RES="$GPU_RESOURCE" python3 -I -c '
import json, os, sys
res = os.environ["GPU_RES"]
try: d = json.load(sys.stdin)
except Exception: print("0"); sys.exit(0)
tot = 0
for p in d.get("items", []):
    if p.get("status", {}).get("phase") not in ("Running", "Pending"): continue
    for c in p.get("spec", {}).get("containers", []):
        v = c.get("resources", {}).get("requests", {}).get(res)
        if v:
            try: tot += int(v)
            except ValueError: pass
print(tot)
'
  else
    echo "?"
  fi
}

show_status() {
  local now; now="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "================================================================"
  echo "  Run:AI Status  |  $now"
  echo "  cluster:   $CLUSTER_SERVER"
  echo "  cohort:    $COHORT_NAME  (${POOL_GPU_TOTAL} x ${GPU_RESOURCE}, flavor ${ACCELERATOR_FLAVOR})"
  echo "  scheduler: $RUNAI_SCHEDULER   department: $RUNAI_DEPARTMENT"
  echo "================================================================"
  echo

  # ── Run:AI projects / queues ────────────────────────────────────────────
  echo "-- Run:AI projects / queues --"
  if command -v runai >/dev/null 2>&1; then
    runai list projects 2>/dev/null || echo "  (runai CLI present but 'runai list projects' failed — check login)"
  else
    local kinds; kinds="$(runai_kinds || true)"
    if [[ -z "$kinds" ]]; then
      echo "  No 'runai' CLI and no run.ai CRDs found — is the Run:AI operator installed?"
    else
      local k
      for k in $kinds; do
        echo "  [$k]"
        oc get "$k" -A 2>/dev/null | sed 's/^/    /' || true
      done
    fi
  fi
  echo

  # ── Per-squad view ───────────────────────────────────────────────────────
  for s in "${squads[@]}"; do
    local ns="${SQUAD_NS[$s]}"
    echo "-- Squad $s → project $ns (split ${SQUAD_SPLIT[$s]}, priority ${SQUAD_PRIORITY[$s]}) --"
    if ! oc get ns "$ns" >/dev/null 2>&1; then
      echo "  namespace not found"; echo; continue
    fi
    local qlabel; qlabel="$(oc get ns "$ns" -o jsonpath='{.metadata.labels.runai/queue}' 2>/dev/null || true)"
    echo "  runai/queue label: ${qlabel:-<unset — not enabled for Run:AI>}"
    echo "  GPUs requested (Running+Pending): $(gpu_requested_in_ns "$ns")"

    echo "  Deployments (scheduler / ready):"
    oc get deploy -n "$ns" -l app.kubernetes.io/part-of=swebench-live-vllm \
      -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas,SCHED:.spec.template.spec.schedulerName \
      --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (none)"

    echo "  Pods:"
    oc get pods -n "$ns" -l app.kubernetes.io/part-of=swebench-live-vllm \
      -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,SCHED:.spec.schedulerName \
      --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (none)"

    echo "  Agent jobs (app=swebench-instance):"
    oc get jobs -n "$ns" -l app=swebench-instance --no-headers 2>/dev/null | sed 's/^/    /' || echo "    (none)"
    echo
  done

  # ── Scheduling / preemption events ────────────────────────────────────────
  echo "-- Recent Warning events (scheduling / preemption / quota) --"
  oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null \
    | grep -Ei 'preempt|evict|reclaim|quota|unschedulable|insufficient' | tail -20 \
    || echo "  (none)"
  echo "================================================================"
}

if [[ -n "$WATCH" ]]; then
  while true; do clear; show_status; sleep "$WATCH"; done
else
  show_status
fi
