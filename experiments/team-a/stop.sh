#!/usr/bin/env bash
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
echo ">> team-a stop: inference + swebench"
oc delete llminferenceservice team-a-qwen -n runai-team-a --ignore-not-found 2>/dev/null || true
del_by_prefix team-a-swebench
del_by_prefix team-a-burst
