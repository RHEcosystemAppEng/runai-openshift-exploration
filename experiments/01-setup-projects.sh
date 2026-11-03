#!/usr/bin/env bash
# Create the Team A project (deserved GPUs) and enable over-quota so Team B's
# deserved-0 GPU workloads can be BORROWED and then RECLAIMED by Team A.
# Idempotent: skips the project if it already exists.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

echo ">> Enabling over-quota (project.quota.manual_over_quota=true)"
api PUT /v1/k8s/setting -d '{"key":"project.quota.manual_over_quota","value":true}' >/dev/null
echo "   done."

existing=$(api GET /api/v1/org-unit/projects \
  | python3 -I -c "import sys,json;print(next((p['id'] for p in json.load(sys.stdin)['projects'] if p['name']=='${TEAM_A_PROJECT}'),''))")

if [[ -n "$existing" ]]; then
  echo ">> Project '${TEAM_A_PROJECT}' already exists (id=$existing)"
else
  echo ">> Creating project '${TEAM_A_PROJECT}' (GPU deserved=${TEAM_A_GPU_DESERVED})"
  existing=$(render team-a-project.json | api POST /api/v1/org-unit/projects --data-binary @- \
    | python3 -I -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',''))")
  echo "   created id=$existing"
fi
echo "TEAM_A_PROJECT_ID=$existing  # export this (already defaulted in env.sh)"
