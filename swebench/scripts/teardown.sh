#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# teardown.sh — remove squad workloads (serving + agents), optionally scheduling.
#
# By default removes per-squad serving + agent planes and keeps the model-cache
# and workspace PVCs (so a redeploy does not re-download the 27B model). Flags:
#   --keep-pvc        keep PVCs (DEFAULT)
#   --delete-pvc      also delete model-cache + workspace PVCs
#   --scheduling      also delete the shared cluster-scoped scheduling fabric
#   --namespaces      also delete the squad namespaces (implies everything)
#
# Usage:
#   bash scripts/teardown.sh --squad a
#   bash scripts/teardown.sh --squad all --delete-pvc
#   bash scripts/teardown.sh --squad all --namespaces --scheduling
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="all"; KEEP_PVC=1; DEL_SCHED=0; DEL_NS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad)      SQUAD_ARG="$2"; shift 2 ;;
    --keep-pvc)   KEEP_PVC=1; shift ;;
    --delete-pvc) KEEP_PVC=0; shift ;;
    --scheduling) DEL_SCHED=1; shift ;;
    --namespaces) DEL_NS=1; KEEP_PVC=0; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_server_guard
echo

teardown_one() {
  local s="$1" ns
  ns="$(squad_ns "$s")"
  oc get namespace "$ns" >/dev/null 2>&1 || { warn "${ns}: missing, skipping"; return; }
  log "Squad $s (${ns}): removing workloads"

  if [[ "$DEL_NS" == 1 ]]; then
    oc delete namespace "$ns" --wait=false >/dev/null 2>&1 || true
    ok "${ns}: namespace deletion requested (removes everything inside)"
    return
  fi

  # agents + serving (all three serving modes share object names)
  oc -n "$ns" delete jobs -l app=swebench-instance --ignore-not-found --wait=false >/dev/null 2>&1 || true
  oc -n "$ns" delete deployment benchmark-coordinator --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete rolebinding coordinator-job-manager --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete role job-manager --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete configmap agent-config --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete inferenceservice qwen-inference --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete servingruntime qwen-vllm-runtime --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete hardwareprofile swebench-gpu-profile --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete deployment vllm-qwen --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete service qwen-inference --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete route qwen-inference --ignore-not-found >/dev/null 2>&1 || true
  oc -n "$ns" delete configmap vllm-config --ignore-not-found >/dev/null 2>&1 || true

  if [[ "$KEEP_PVC" == 1 ]]; then
    log "${ns}: keeping PVCs (model cache + workspace preserved)"
  else
    oc -n "$ns" delete pvc vllm-model-cache benchmark-workspace --ignore-not-found >/dev/null 2>&1 || true
    ok "${ns}: PVCs deleted"
  fi
  ok "${ns}: workloads removed"
  echo
}

for s in $(resolve_squads "$SQUAD_ARG"); do teardown_one "$s"; done

if [[ "$DEL_SCHED" == 1 ]]; then
  log "Deleting shared scheduling fabric (ClusterQueues, flavor, priority classes, DeviceClass) ..."
  oc delete -k "$DEPLOY_DIR/overlays/${KSERVE_OVERLAY}/scheduling" --ignore-not-found >/dev/null 2>&1 || true
  ok "scheduling fabric removed"
fi

log "Teardown complete."
