#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Scenario 1 — Multi-team allocation on the shared GPU pool
#
# USE CASE: all three data-science squads share ONE RHOAI GPU cluster. They all
# want to run their autonomous coding agents at the same time. This driver has
# every squad submit GPU work concurrently so combined demand exceeds the pool,
# then shows how the scheduler arbitrates: each squad is guaranteed its nominal
# quota and the remainder is contended.
#
# Runs on BOTH stacks for comparison:
#   bash scenario-1-multiteam-allocation.sh --scheduler rhoai
#   bash scenario-1-multiteam-allocation.sh --scheduler runai
#
# A timestamped Markdown summary is written under reports/.
# ─────────────────────────────────────────────────────────────────────────────

SCENARIO_ID=1
SCENARIO_TITLE="Multi-team allocation on the shared GPU pool"
# shellcheck source=_common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

print_help() {
  cat <<EOF
Scenario 1: ${SCENARIO_TITLE}
Usage: $(basename "$0") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup] [JOBS_PER_SQUAD]

All three squads submit JOBS_PER_SQUAD single-GPU jobs at once (default 4 → 12 GPU
demand vs an ${POOL_GPU_TOTAL}-GPU pool). Watch which squads are admitted to their
nominal quota and which workloads pend.
EOF
}

parse_common_args "$@"
require_server
init_report

if [[ "$DO_CLEANUP" == 1 ]]; then cleanup_scenario; exit 0; fi
check_namespaces

PER_SQUAD="${EXTRA_ARGS[0]:-4}"

section "Plan"
note "Each squad submits ${PER_SQUAD} single-GPU jobs → combined demand $(( PER_SQUAD * 3 )) GPUs vs a ${POOL_GPU_TOTAL}-GPU pool."
note "Guaranteed nominal quota: A=${SQUAD_A_GPU_NOMINAL}, B=${SQUAD_B_GPU_NOMINAL}, C=${SQUAD_C_GPU_NOMINAL}. Squad A is high priority (\`${PRIORITY_HIGH}\`)."

section "Submit (all squads concurrently)"
for s in "${SQUADS[@]}"; do
  for i in $(seq 1 "$PER_SQUAD"); do
    submit_gpu_job "$s" "job-${i}" 1 "$HOLD"
  done
done

settle 25

section "Admission & quota decision"
show_admission

section "Per-squad workloads & GPU accounting"
show_workloads

section "What to watch / what this proves"
note "- **rhoai:** \`oc get clusterqueues\` — each \`cq-squad-*\` admits up to its nominal quota; excess Workloads show as pending/ADMITTED=false. \`oc get workloads -n <ns>\` shows the QuotaReserved/Admitted conditions."
note "- **runai:** the Run:AI scheduler fair-shares the pool across projects; pending pods carry an 'unschedulable / over quota' event."
note "- **Proves:** multi-tenant admission control — no squad can starve the others below its nominal guarantee, and the shared pool is not oversubscribed beyond ${POOL_GPU_TOTAL} GPUs."
note "- **Compare across stacks:** run once per \`--scheduler\` and diff the two reports for admitted-vs-pending counts and time-to-admission."

finish_report
