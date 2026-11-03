#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# End-to-end reclamation demo for ai-dev06 (Team A reclaims GPUs from Team B).
#
#   Phase 1  Team B fills the free A10G GPUs with preemptible over-quota training.
#   Phase 2  Team A deploys its vLLM inference (deserved GPUs) -> Run:ai preempts
#            a Team B victim so Team A is admitted to its guaranteed share.
#   Phase 3  Team A launches SWE-bench batch jobs that call the live endpoint.
#
# This is the ai-dev06, single-GPU-node, Run:ai equivalent of
# scripts/scenarios/scenario-3-reclamation.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

line() { printf '\n──────── %s ────────\n' "$1"; }

line "Phase 0: projects + over-quota"
./01-setup-projects.sh

line "Phase 1: Team B fills the free GPUs (preemptible, over-quota)"
./03-launch-team-b-victims.sh "${TEAM_B_VICTIMS:-3}"
sleep 15
echo ">> BEFORE — GPU holders:"; gpu_holders

line "Phase 2: Team A deploys vLLM inference -> reclaim"
./02-deploy-inference.sh || true   # may still be pulling; reclaim happens at schedule time
echo ">> Preemption / eviction events:"
oc get events -A --field-selector type=Normal 2>/dev/null | grep -Ei 'preempt|evict' | tail -10 || true
echo ">> AFTER — GPU holders:"; gpu_holders

line "Phase 3: Team A SWE-bench batch jobs (call the endpoint)"
./04-launch-team-a-batch.sh "${TEAM_A_BATCH:-3}"

line "Done. Watch in the Run:ai UI -> Workloads (project team-a vs team-b-lora)."
