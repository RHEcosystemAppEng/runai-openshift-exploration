#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 00-preflight.sh — verify the cluster has everything the baseline needs.
#
# Checks oc login + server, then probes for the operators/CRDs this project uses:
# RHOAI (DataScienceCluster), Kueue, DRA, KServe/ServingRuntime, RHOAI
# HardwareProfile, the NVIDIA/AMD GPU operator + NFD, and (optionally) Run:AI.
# Prints a readiness table and exits non-zero if a REQUIRED capability is missing.
#
# Usage:
#   bash scripts/00-preflight.sh
#   GPU_VENDOR=amd bash scripts/00-preflight.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_server_guard
echo

ROWS=()
add_row() { ROWS+=("$1|$2|$3"); }   # name | status | detail

# check_crd <display> <crd> <required|optional>
check_crd() {
  local name="$1" crd="$2" req="$3"
  if oc get crd "$crd" >/dev/null 2>&1; then
    add_row "$name" "PRESENT" "$crd"
  else
    add_row "$name" "$([[ "$req" == required ]] && echo MISSING || echo "absent")" "$crd"
  fi
}

log "Probing cluster capabilities ..."

check_crd "RHOAI DataScienceCluster" "datascienceclusters.datasciencecluster.opendatahub.io" required
check_crd "Kueue"                     "clusterqueues.kueue.x-k8s.io"                            required
check_crd "Kueue WorkloadPriority"    "workloadpriorityclasses.kueue.x-k8s.io"                  required
check_crd "DRA DeviceClass"           "deviceclasses.resource.k8s.io"                           required
check_crd "KServe ServingRuntime"     "servingruntimes.serving.kserve.io"                       required
check_crd "KServe InferenceService"   "inferenceservices.serving.kserve.io"                     required
check_crd "RHOAI HardwareProfile"     "hardwareprofiles.infrastructure.opendatahub.io"          required
check_crd "NVIDIA GPU operator"       "clusterpolicies.nvidia.com"                              optional
check_crd "AMD GPU operator"          "deviceconfigs.amd.com"                                   optional
check_crd "Node Feature Discovery"    "nodefeaturediscoveries.nfd.openshift.io"                 optional
check_crd "Run:AI (Phase 2)"          "runaijobs.run.ai"                                        optional

# GPU capacity: any node advertising the vendor GPU resource?
GPU_NODES="$(oc get nodes -o jsonpath="{range .items[*]}{.status.allocatable.${GPU_RESOURCE}}{'\n'}{end}" 2>/dev/null \
  | grep -vc '^$' || true)"
if [[ "${GPU_NODES:-0}" -gt 0 ]]; then
  add_row "GPU nodes (${GPU_RESOURCE})" "PRESENT" "${GPU_NODES} node(s) advertise GPUs"
else
  add_row "GPU nodes (${GPU_RESOURCE})" "absent" "no allocatable ${GPU_RESOURCE} found"
fi

# ── render table ──────────────────────────────────────────────────────────────
echo
printf '  %-28s %-9s %s\n' "CAPABILITY" "STATUS" "DETAIL"
printf '  %-28s %-9s %s\n' "----------" "------" "------"
MISSING_REQUIRED=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r name status detail <<<"$row"
  printf '  %-28s %-9s %s\n' "$name" "$status" "$detail"
  [[ "$status" == "MISSING" ]] && MISSING_REQUIRED=$((MISSING_REQUIRED + 1))
done
echo

if [[ "$MISSING_REQUIRED" -gt 0 ]]; then
  die "$MISSING_REQUIRED required capability(ies) MISSING. Install/enable them before deploying."
fi
ok "All required capabilities present. Vendor profile: ${GPU_VENDOR} (overlay: ${KSERVE_OVERLAY})."
log "Next: bash scripts/01-create-projects.sh"
