#!/usr/bin/env bash
# Team A long-running workload: vLLM inference (RHOAI LLMInferenceService, Deploy).
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/_common.sh"
case "${1:-up}" in
  up)   echo ">> team-a deploy up: vLLM inference (Deploy)"; oc apply -f "$AUTO_DIR/team-a-llminferenceservice.yaml";
        echo "   applied. Readiness (image+model pull takes minutes): ./status.sh" ;;
  down) echo ">> team-a deploy down"; oc delete llminferenceservice team-a-qwen -n runai-team-a --ignore-not-found ;;
  *)    echo "usage: $0 [up|down]"; exit 1 ;;
esac
