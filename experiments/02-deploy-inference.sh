#!/usr/bin/env bash
# Deploy Team A's inference endpoint as a RHOAI-standard KServe LLMInferenceService.
# Single GPU, model sized for one A10G. Scheduled by runai-scheduler so it reclaims
# GPUs from Team B. Idempotent (oc apply).
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

echo ">> Applying LLMInferenceService (team-a-qwen, ${MODEL_ID})"
oc apply -f team-a-llminferenceservice.yaml

echo ">> Waiting for the endpoint to become Ready (image+model pull can take several minutes)..."
for i in $(seq 1 120); do
  ready=$(oc get llminferenceservice team-a-qwen -n runai-team-a -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  pod=$(oc get pods -n runai-team-a 2>/dev/null | awk '/team-a-qwen-kserve/{print $2" "$3; exit}')
  echo "   [$i] LLMISVC Ready=$ready pod=$pod"
  [[ "$ready" == "True" ]] && { echo ">> Endpoint READY:"; echo "   in-cluster: http://team-a-qwen-kserve-workload-svc.runai-team-a.svc.cluster.local:8000/v1"; exit 0; }
  sleep 10
done
echo "!! Not Ready yet; check: oc logs -n runai-team-a deploy/team-a-qwen-kserve -c main"
exit 1
