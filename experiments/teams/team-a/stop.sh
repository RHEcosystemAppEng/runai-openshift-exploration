#!/usr/bin/env bash
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/_common.sh"
echo ">> team-a stop: inference + swebench + bursts"
oc delete llminferenceservice team-a-qwen -n runai-team-a --ignore-not-found 2>/dev/null || true
del_by_prefix team-a-swebench
del_by_prefix team-a-burst
