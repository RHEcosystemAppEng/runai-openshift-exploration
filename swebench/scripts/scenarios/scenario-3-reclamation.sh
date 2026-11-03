#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Scenario 3 — Reclamation / preemption (idle squad bursts back)
#
# USE CASE: Squads A and B have borrowed the idle Squad C share and the pool is
# full (the steady state scenario 2 produces). Then Squad C wakes up and submits
# a burst equal to its nominal quota. Because that capacity was only LENT, the
# scheduler must reclaim it — preempting borrowed workloads so C gets its
# guaranteed GPUs back.
#
#   bash scenario-3-reclamation.sh --scheduler rhoai
#   bash scenario-3-reclamation.sh --scheduler runai
# ─────────────────────────────────────────────────────────────────────────────

SCENARIO_ID=3
SCENARIO_TITLE="Reclamation — idle squad bursts and preempts borrowed GPUs"
# shellcheck source=_common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

print_help() {
  cat <<EOF
Scenario 3: ${SCENARIO_TITLE}
Usage: $(basename "$0") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup]

Phase 1: A and B borrow C's idle share and fill the pool.
Phase 2: C submits a ${SQUAD_C_GPU_NOMINAL}-GPU burst (its nominal quota). Watch the
scheduler reclaim/preempt borrowed workloads so C is admitted to its guarantee.
EOF
}

parse_common_args "$@"
require_server
init_report

if [[ "$DO_CLEANUP" == 1 ]]; then cleanup_scenario; exit 0; fi
check_namespaces

A_JOBS="${A_JOBS:-4}"
B_JOBS="${B_JOBS:-4}"
C_BURST="${C_BURST:-$SQUAD_C_GPU_NOMINAL}"

section "Phase 1 — A and B borrow C's idle share (fill the pool)"
note "A asks ${A_JOBS} GPUs, B asks ${B_JOBS} GPUs; C is idle. Expect ~${POOL_GPU_TOTAL}/${POOL_GPU_TOTAL} GPUs in use with A/B over nominal."
for i in $(seq 1 "$A_JOBS"); do submit_gpu_job "a" "job-${i}" 1 "$HOLD"; done
for i in $(seq 1 "$B_JOBS"); do submit_gpu_job "b" "job-${i}" 1 "$HOLD"; done

settle 25

section "Phase 1 snapshot — borrowed steady state"
show_admission
capture "GPU requested per squad (before reclamation)" gpu_summary

section "Phase 2 — Squad C bursts and reclaims its guarantee"
note "C submits ${C_BURST} single-GPU jobs = its nominal quota. Lent capacity must be returned, so borrowed A/B workloads are preempted."
for i in $(seq 1 "$C_BURST"); do submit_gpu_job "c" "burst-${i}" 1 "$HOLD"; done

settle 40

section "Reclamation result"
show_admission

section "Preemption / reclamation evidence"
capture "Recent Warning events (preemption / eviction / reclaim)" \
  bash -c "oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | grep -Ei 'preempt|evict|reclaim|borrow|quota' | tail -40 || echo '(no matching events yet)'"
capture "GPU requested per squad (after reclamation)" gpu_summary

section "Per-squad workloads"
show_workloads

section "What to watch / what this proves"
note "- **rhoai:** Kueue preempts borrowing Workloads in \`cq-squad-a\`/\`cq-squad-b\` to satisfy \`cq-squad-c\`'s reclaimWithinCohort guarantee; preempted Workloads return to pending with a 'Preempted' condition and C's pods schedule."
note "- **runai:** the Run:AI scheduler reclaims over-quota allocations and preempts the lowest-priority borrowing pods so the reclaiming project reaches its deserved share."
note "- **Proves:** guarantees survive lending — an idle squad can always reclaim its nominal quota on demand, which is the core fairness promise of the shared pool."
note "- **Note on Squad A:** because A is high priority (\`${PRIORITY_HIGH}\`), B's borrowed workloads are preferred preemption victims over A's. Compare whose pods get evicted in the two reports."

finish_report
