#!/usr/bin/env bash
# Launch Team A SWE-bench batch jobs (CPU-only) that call Team A's vLLM endpoint.
# These are the "inference SWE-bench batch jobs": each makes a real completion
# request against the in-cluster endpoint. The GPU is held by the vLLM endpoint,
# not by these jobs.
# Usage: ./04-launch-team-a-batch.sh [COUNT]   (default 3 instances)
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh
COUNT="${1:-3}"

# Encode the agent script once; injected into each Job as base64 (keeps JSON clean).
export AGENT_B64="$(base64 -w0 swebench_agent.py)"

for n in $(seq 1 "$COUNT"); do
  export INSTANCE_ID="lite-$(printf '%03d' "$n")"
  export BATCH_NAME="team-a-swebench-${INSTANCE_ID}"
  if [[ -n "$(workload_id "$BATCH_NAME")" ]]; then
    echo ">> $BATCH_NAME already exists; skipping"
    continue
  fi
  render team-a-swebench-batch.json | api POST /api/v1/workloads/trainings --data-binary @- \
    | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   ${BATCH_NAME} ->',d.get('workloadId','ERR '+json.dumps(d)[:200]))"
done
