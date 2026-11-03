#!/usr/bin/env bash
# One-time setup for the reclaim demo:
#   1. Enable cluster-wide over-quota so Team B's deserved-0 GPU jobs can BORROW idle
#      GPUs (and then be RECLAIMED by Team A).
#   2. Create the Team A project with guaranteed GPUs (deserved=${TEAM_A_GPU_DESERVED}).
# Idempotent: skips the project if it already exists.
#
# Team B's project (team-b-lora) is created the RHOAI-first way (Data Science Project +
# Kyverno enrollment, see ../orchestration/kyverno-runai-enroll.yaml) or already exists.
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
set -e

echo ">> Enabling over-quota (project.quota.manual_over_quota=true)"
api PUT /v1/k8s/setting -d '{"key":"project.quota.manual_over_quota","value":true}' >/dev/null
echo "   done."

existing=$(api GET /api/v1/org-unit/projects \
  | python3 -I -c "import sys,json;print(next((p['id'] for p in json.load(sys.stdin)['projects'] if p['name']=='${TEAM_A_PROJECT}'),''))")

if [[ -n "$existing" ]]; then
  echo ">> Project '${TEAM_A_PROJECT}' already exists (id=$existing)"
else
  echo ">> Creating project '${TEAM_A_PROJECT}' (GPU deserved=${TEAM_A_GPU_DESERVED})"
  existing=$(render "$HERE/team-a-project.json" | api POST /api/v1/org-unit/projects --data-binary @- \
    | python3 -I -c "import sys,json;d=json.load(sys.stdin);print(d.get('id',''))")
  echo "   created id=$existing"
fi
echo "TEAM_A_PROJECT_ID=$existing  # export this (already defaulted in _common/env.sh)"
