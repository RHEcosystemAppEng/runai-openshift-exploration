#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Scenario 2 — Dynamic utilization (idle squad's share is borrowed)
#
# USE CASE: Squad C (SWE-bench C#) is idle today. Squads A and B want more GPUs
# than their nominal quota. This driver keeps C silent while A and B each burst
# past their own quota; the idle C share is lent out so the whole pool stays busy
# instead of sitting idle behind a static reservation.
#
#   bash scenario-2-dynamic-utilization.sh --scheduler rhoai
#   bash scenario-2-dynamic-utilization.sh --scheduler runai
# ─────────────────────────────────────────────────────────────────────────────

SCENARIO_ID=2
SCENARIO_TITLE="Dynamic utilization — borrowing fills the pool while a squad is idle"
# shellcheck source=_common.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/_common.sh"

print_help() {
  cat <<EOF
Scenario 2: ${SCENARIO_TITLE}
Usage: $(basename "$0") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup]

Squad C stays idle. Squads A and B each submit enough single-GPU jobs to fill the
${POOL_GPU_TOTAL}-GPU pool by BORROWING C's unused share. Watch total GPUs in use
climb to ${POOL_GPU_TOTAL} even though two squads are over their nominal quota.
EOF
}

parse_common_args "$@"
require_server
init_report

if [[ "$DO_CLEANUP" == 1 ]]; then cleanup_scenario; exit 0; fi
check_namespaces

# A: nominal 2, borrow up to 6 → ask 4.  B: nominal 3, borrow up to 5 → ask 4.
# 4 + 4 = 8 = whole pool, using C's idle 3 as borrowed headroom.
A_JOBS="${A_JOBS:-4}"
B_JOBS="${B_JOBS:-4}"

section "Plan"
note "Squad C submits nothing. Squad A asks for ${A_JOBS} GPUs (nominal ${SQUAD_A_GPU_NOMINAL}, borrow cap ${SQUAD_A_GPU_BORROW}); Squad B asks for ${B_JOBS} GPUs (nominal ${SQUAD_B_GPU_NOMINAL}, borrow cap ${SQUAD_B_GPU_BORROW})."
note "Target: ${POOL_GPU_TOTAL}/${POOL_GPU_TOTAL} GPUs busy by lending C's idle ${SQUAD_C_GPU_NOMINAL}-GPU share."

section "Submit (A and B only; C idle)"
for i in $(seq 1 "$A_JOBS"); do submit_gpu_job "a" "job-${i}" 1 "$HOLD"; done
for i in $(seq 1 "$B_JOBS"); do submit_gpu_job "b" "job-${i}" 1 "$HOLD"; done

settle 25

section "Admission, borrowing & utilization"
show_admission

section "Per-squad workloads & GPU accounting"
show_workloads

section "What to watch / what this proves"
note "- **rhoai:** \`oc get clusterqueues -o wide\` — \`cq-squad-a\` and \`cq-squad-b\` show BORROWING above their nominal quota; \`cq-squad-c\` shows 0 usage (its share is lent). Pool utilization approaches ${POOL_GPU_TOTAL}/${POOL_GPU_TOTAL}."
note "- **runai:** the two active projects exceed their deserved share via over-quota; the idle project's fair-share is temporarily reallocated."
note "- **Proves:** elastic sharing — idle capacity is not wasted; borrowing keeps the expensive GPUs saturated. Contrast with scenario 3, where the idle squad comes back and reclaims its share."
note "- **Compare across stacks:** diff the steady-state GPUs-in-use and the borrowing columns between the rhoai and runai reports."

finish_report
