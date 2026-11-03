#!/usr/bin/env bash
# Tear down the demo workloads for BOTH teams. Flags:
#   (no args)         delete Team A (inference + swebench) and Team B (LoRA + workspace)
#   --project         ALSO delete the team-a project
#   --revert-setting  ALSO set project.quota.manual_over_quota back to false
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"

echo ">> Team A teardown"; "$HERE/../team-a/stop.sh" || true
echo ">> Team B teardown"; "$HERE/../team-b/stop.sh" || true

for arg in "$@"; do
  case "$arg" in
    --project)
      echo ">> Deleting team-a project (id=${TEAM_A_PROJECT_ID})"
      api DELETE "/api/v1/org-unit/projects/${TEAM_A_PROJECT_ID}" -o /dev/null -w "   project ${TEAM_A_PROJECT_ID} -> %{http_code}\n" ;;
    --revert-setting)
      echo ">> Reverting over-quota setting to false"
      api PUT /v1/k8s/setting -d '{"key":"project.quota.manual_over_quota","value":false}' >/dev/null ;;
  esac
done
echo ">> Done."
