#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Scenario 5 — Coordinated scheduling + observability
#
# USE CASE: a squad runs a coordinated multi-pod GPU workload (e.g. a distributed
# agent fleet / multi-replica inference that must come up together). This driver
# submits a gang-style Job (several GPU pods admitted all-or-nothing), then
# deploys the shared observability stack and collects the admission, placement and
# preemption evidence operators use to audit the shared cluster — the same
# evidence the parallel 06-status.sh / 12-runai-status.sh views surface.
#
#   bash scenario-5-coordinated-observability.sh --scheduler rhoai
#   bash scenario-5-coordinated-observability.sh --scheduler runai
# ─────────────────────────────────────────────────────────────────────────────

SCENARIO_ID=5
SCENARIO_TITLE="Coordinated scheduling + observability evidence"
# shellcheck source=_common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

print_help() {
  cat <<EOF
Scenario 5: ${SCENARIO_TITLE}
Usage: $(basename "$0") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup] [GANG_SIZE]

Submits a GANG_SIZE-pod coordinated GPU Job (default 3) in Squad A that is admitted
all-or-nothing, applies deploy/base/observability, and collects admission/placement/
preemption evidence plus the status overview.
EOF
}

parse_common_args "$@"
require_server
init_report

if [[ "$DO_CLEANUP" == 1 ]]; then cleanup_scenario; exit 0; fi
check_namespaces

GANG_SIZE="${EXTRA_ARGS[0]:-3}"

section "Plan"
note "Squad A submits a single coordinated Job with parallelism=${GANG_SIZE} (${GANG_SIZE} × 1-GPU pods). Kueue admits the Workload all-or-nothing, so the gang either runs together or waits together — this is the coordinated-scheduling guarantee for multi-pod workloads."

section "Deploy shared observability stack"
OBS_DIR="$REPO_ROOT/deploy/base/observability"
if [[ -d "$OBS_DIR" ]]; then
  if [[ "$DRYRUN" == "1" ]]; then
    capture "observability (dry-run)" oc apply -k "$OBS_DIR" --dry-run=client
  else
    capture "apply observability" oc apply -k "$OBS_DIR"
  fi
else
  note "_deploy/base/observability not found — skipping (created by Phase-1 deploy author). The scenario still collects raw admission/placement evidence below._"
fi

section "Submit coordinated gang workload (Squad A)"
submit_gpu_job "a" "gang" 1 "$HOLD" "$GANG_SIZE"

settle 30

section "Admission (all-or-nothing)"
show_admission

section "Placement evidence"
capture "Gang pods and their nodes" \
  oc get pods -n "${SQUAD_NS[a]}" -l scenario="${SCENARIO_ID}" \
    -o custom-columns=POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,SCHED:.spec.schedulerName

section "Preemption / scheduling evidence"
capture "Warning events across squads (scheduling / preemption / quota)" \
  bash -c "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'preempt|evict|reclaim|quota|unschedulable|gang|insufficient' | tail -40 || echo '(none)'"

section "Status overview (parallel to 06-status / 12-runai-status)"
if [[ "$SCHEDULER" == "runai" ]]; then
  STATUS_SCRIPT="$REPO_ROOT/scripts/runai/12-runai-status.sh"
else
  STATUS_SCRIPT="$REPO_ROOT/scripts/06-status.sh"
fi
if [[ -x "$STATUS_SCRIPT" || -f "$STATUS_SCRIPT" ]]; then
  capture "$(basename "$STATUS_SCRIPT")" bash "$STATUS_SCRIPT"
else
  note "_${STATUS_SCRIPT#$REPO_ROOT/} not found — collecting the per-squad GPU/job view inline instead._"
  show_workloads
fi

section "What to watch / what this proves"
note "- **Coordinated scheduling:** the ${GANG_SIZE}-pod gang is one Kueue Workload — it is admitted only when all ${GANG_SIZE} GPUs are simultaneously available; partial admission never happens. On runai, the Run:AI gang/pod-group scheduler does the equivalent."
note "- **Observability:** the applied stack (PodMonitor/ServiceMonitor for vLLM \`/metrics\`, Kueue metrics) plus the status script give TTFT/throughput/KV-cache and admission/quota/preemption in one place."
note "- **Proves:** the shared cluster is auditable — an operator can show, with evidence, which squad holds which GPUs, what was preempted, and why a coordinated workload is pending."
note "- **Compare across stacks:** run per \`--scheduler\` and diff how coordinated admission and the collected metrics differ between Kueue and Run:AI."

finish_report
