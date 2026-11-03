#!/usr/bin/env bash
# Team B long-running workload: interactive Jupyter workspace (Build).
# (Team B's GPU Build is also the existing RHOAI workbench on the L40S.)
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
export TEAM_B_WS_GPU="${TEAM_B_WS_GPU:-0}"
case "${1:-up}" in
  up)   echo ">> team-b deploy up: Jupyter workspace (Build, gpu=$TEAM_B_WS_GPU)";
        if [ -n "$(workload_id team-b-workbench-ws)" ]; then echo "   already exists"; exit 0; fi
        render "$HERE/team-b-workspace.json" | api POST /api/v1/workloads/workspaces --data-binary @-           | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   ->',d.get('workloadId','ERR '+json.dumps(d)[:200]))" ;;
  down) echo ">> team-b deploy down"; del_by_prefix team-b-workbench-ws ;;
  *)    echo "usage: $0 [up|down]"; exit 1 ;;
esac
