#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared base for the SYMMETRIC per-team interface.
#
# teams/team-a and teams/team-b each expose the SAME verbs:
#   ./deploy.sh [up|down]   team's long-running workload   (A: vLLM inference / Deploy
#                                                           B: Jupyter workspace / Build)
#   ./submit.sh [N]         team's batch/training jobs      (A: SWE-bench agents / Train
#                                                           B: LoRA fine-tuning / Train)
#   ./status.sh             this team's Run:ai workloads
#   ./stop.sh               delete this team's demo workloads
#
# Everything runs through the Run:ai REST API (UI-visible, runai-scheduled,
# preemptible per category), using the shared experiments/env.sh + lib.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
export AUTO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AUTO_DIR/env.sh"
source "$AUTO_DIR/lib.sh"

FMT() { python3 -I "$AUTO_DIR/_runai_fmt.py" "$@"; }

show_team() {  # $1 = project name
  api GET "/api/v1/workloads?clusterId=${RUNAI_CLUSTER_ID}&limit=200" | FMT team "$1"
}

# delete every workload whose name starts with the given prefix (any type)
del_by_prefix() {  # $1 = name prefix
  P="$1" api GET "/api/v1/workloads?clusterId=${RUNAI_CLUSTER_ID}&limit=200" \
   | P="$1" python3 -I -c '
import sys,json,os
pfx=os.environ["P"]
for w in json.load(sys.stdin)["workloads"]:
    if w["name"].startswith(pfx) and w.get("phase") not in ("Deleted","Deleting"):
        print(w["id"], w["type"])' \
   | while read -r id typ; do
       ep=trainings
       [ "$typ" = Inference ] && ep=inferences
       [ "$typ" = Workspace ] && ep=workspaces
       [ -n "$id" ] && api DELETE "/api/v1/workloads/$ep/$id" -o /dev/null -w "  deleted $id ($typ)\n"
     done
}
