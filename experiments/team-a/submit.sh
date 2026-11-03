#!/usr/bin/env bash
# Team A batch: N SWE-bench agent jobs (Train, CPU) that call the inference endpoint.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
N="${1:-3}"
echo ">> team-a submit: $N SWE-bench agent job(s) (Train)"
export AGENT_B64="$(base64 -w0 "$HERE/swebench/agent/swebench_agent.py")"
for n in $(seq 1 "$N"); do
  export INSTANCE_ID="lite-$(printf '%03d' "$n")"; export BATCH_NAME="team-a-swebench-${INSTANCE_ID}"
  if [ -n "$(workload_id "$BATCH_NAME")" ]; then echo "   $BATCH_NAME exists, skip"; continue; fi
  render "$HERE/team-a-swebench-batch.json" | api POST /api/v1/workloads/trainings --data-binary @-     | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   $BATCH_NAME ->',d.get('workloadId','ERR')[:12])"
done
