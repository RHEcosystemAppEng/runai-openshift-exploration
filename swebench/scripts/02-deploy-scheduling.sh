#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 02-deploy-scheduling.sh — deploy the shared GPU scheduling fabric.
#
# Applies the cluster-scoped scheduling overlay (ResourceFlavor, cohort
# ClusterQueues cq-squad-a/-b/-c, Workload + core PriorityClasses, DRA DeviceClass)
# ONCE, then the per-squad LocalQueue 'default' and the DRA ResourceClaimTemplate
# in each squad namespace.
#
# Vendor is selected by GPU_VENDOR (-> KSERVE_OVERLAY) from config/env.sh.
#
# Usage:
#   bash scripts/02-deploy-scheduling.sh             # cluster objects + all squads
#   bash scripts/02-deploy-scheduling.sh --squad a   # cluster objects + Squad A only
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

log "Applying cluster-scoped scheduling overlay (vendor: ${GPU_VENDOR}) ..."
apply_overlay scheduling
ok "ResourceFlavor ${ACCELERATOR_FLAVOR}, cohort ${COHORT_NAME}, ClusterQueues + priority classes + DRA DeviceClass applied"
echo

for s in $(resolve_squads "$SQUAD_ARG"); do
  ns="$(squad_ns "$s")"
  oc get namespace "$ns" >/dev/null 2>&1 || die "Namespace $ns missing — run 01-create-projects.sh first."
  log "Squad $s -> LocalQueue '${LOCAL_QUEUE}' + ResourceClaimTemplate in ${ns}"
  oc apply -f "$DEPLOY_DIR/squads/${ns}/localqueue.yaml"
  # The per-squad ResourceClaimTemplate hardcodes deviceClassName gpu.nvidia.com,
  # but the amd overlay renames the DeviceClass to gpu.amd.com. Rather than apply
  # the NVIDIA manifest raw on the AMD path, rewrite deviceClassName to the vendor
  # DeviceClass (${DRA_DEVICE_CLASS}) so the claim matches the applied DeviceClass.
  if [[ "${GPU_VENDOR}" == "amd" ]]; then
    sed "s#deviceClassName: gpu.nvidia.com#deviceClassName: ${DRA_DEVICE_CLASS}#" \
      "$DEPLOY_DIR/squads/${ns}/resourceclaimtemplate.yaml" | oc apply -f -
  else
    oc apply -f "$DEPLOY_DIR/squads/${ns}/resourceclaimtemplate.yaml"
  fi
  ok "${ns}: LocalQueue bound to cq-squad-${s}, ResourceClaimTemplate (${DRA_DEVICE_CLASS}) applied"
done

echo
log "Verify quotas:   oc get clusterqueue -o wide"
log "Verify cohort:   oc get clusterqueue -o json | jq -r '.items[] | \"\\(.metadata.name) cohort=\\(.spec.cohort)\"'"
log "Next: bash scripts/03-deploy-serving.sh --squad a"
