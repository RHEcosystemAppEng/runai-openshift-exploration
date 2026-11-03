#!/usr/bin/env bash
# Launch Team B preemptible training "victims" that fill the free A10G GPUs.
# Team B has GPU deserved=0, so every GPU it grabs is OVER-QUOTA and reclaimable.
# Usage: ./03-launch-team-b-victims.sh [COUNT]   (default 3 = the 3 free A10Gs)
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh
COUNT="${1:-3}"

for n in $(seq 1 "$COUNT"); do
  export VICTIM_NAME="team-b-victim-$n"
  if [[ -n "$(workload_id "$VICTIM_NAME")" ]]; then
    echo ">> $VICTIM_NAME already exists; skipping"
    continue
  fi
  render team-b-victim.json | api POST /api/v1/workloads/trainings --data-binary @- \
    | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   ${VICTIM_NAME} ->',d.get('workloadId','ERR'))"
done

echo ">> Current GPU holders:"
gpu_holders
