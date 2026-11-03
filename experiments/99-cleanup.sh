#!/usr/bin/env bash
# Tear down the demo workloads. Flags:
#   (no args)      delete Team A inference + Team A batch + Team B victims
#   --project      ALSO delete the team-a project
#   --revert-setting  ALSO set project.quota.manual_over_quota back to false
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

del() {  # del <kind> <name>
  local kind="$1" name="$2" id; id="$(workload_id "$name")"
  [[ -z "$id" ]] && return 0
  api DELETE "/api/v1/workloads/${kind}/${id}" -o /dev/null -w "   deleted ${name} (${kind}) -> %{http_code}\n"
}

echo ">> Deleting Team A inference (LLMInferenceService)"
oc delete llminferenceservice team-a-qwen -n runai-team-a --ignore-not-found 2>/dev/null || true
echo ">> Deleting Team A batch jobs"
for n in $(seq 1 12); do del trainings "team-a-swebench-lite-$(printf '%03d' "$n")"; done
echo ">> Deleting Team B victims"
for n in $(seq 1 12); do del trainings "team-b-victim-$n"; done

if [[ "${1:-}" == "--project" || "${2:-}" == "--project" ]]; then
  echo ">> Deleting team-a project"
  api DELETE "/api/v1/org-unit/projects/${TEAM_A_PROJECT_ID}" -o /dev/null -w "   project ${TEAM_A_PROJECT_ID} -> %{http_code}\n"
fi
if [[ "${1:-}" == "--revert-setting" || "${2:-}" == "--revert-setting" ]]; then
  echo ">> Reverting over-quota setting to false"
  api PUT /v1/k8s/setting -d '{"key":"project.quota.manual_over_quota","value":false}' >/dev/null
fi
echo ">> Done."
