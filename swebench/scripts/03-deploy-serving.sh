#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 03-deploy-serving.sh — deploy the self-hosted vLLM endpoint for a squad.
#
# Three serving modes (pick one):
#   --profile     (default) KServe InferenceService + ServingRuntime bound to the
#                 RHOAI HardwareProfile 'swebench-gpu-profile'.
#   --no-profile  KServe InferenceService + ServingRuntime, plain (no HardwareProfile).
#   --raw         raw vLLM Deployment + Service + Route (no KServe/HardwareProfile).
#
# Waits for the endpoint to become Ready (model download can take 15-30 min on the
# first run) and prints the internal URL + external route.
#
# Usage:
#   bash scripts/03-deploy-serving.sh --squad a                 # profile mode
#   bash scripts/03-deploy-serving.sh --squad b --raw
#   bash scripts/03-deploy-serving.sh --squad all --no-profile
#   bash scripts/03-deploy-serving.sh --squad a --no-wait
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="a"; MODE="profile"; WAIT=1; TIMEOUT="${TIMEOUT:-2400}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad)      SQUAD_ARG="$2"; shift 2 ;;
    --profile)    MODE="profile"; shift ;;
    --no-profile) MODE="plain";   shift ;;
    --raw)        MODE="raw";     shift ;;
    --no-wait)    WAIT=0; shift ;;
    -h|--help)    grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

case "$MODE" in
  profile) COMPONENT="serving" ;;
  plain)   COMPONENT="serving-plain" ;;
  raw)     COMPONENT="serving-raw" ;;
esac

require_server_guard
echo

deploy_one() {
  local s="$1" ns split
  ns="$(squad_ns "$s")"; split="$(squad_split "$s")"
  oc get namespace "$ns" >/dev/null 2>&1 || die "Namespace $ns missing — run 01-create-projects.sh first."

  log "Squad $s (${ns}): deploying vLLM endpoint [mode=${MODE}, vendor=${GPU_VENDOR}]"
  apply_overlay "$COMPONENT" "$ns"
  label_squad "$ns" "$s" "$split"

  if [[ "$WAIT" == 0 ]]; then
    warn "${ns}: --no-wait set; skipping readiness wait"
    return 0
  fi

  log "${ns}: waiting for the vLLM pod to become Ready (first run downloads the model) ..."
  if [[ "$MODE" == "raw" ]]; then
    oc -n "$ns" rollout status deployment/vllm-qwen --timeout="${TIMEOUT}s" \
      || die "${ns}: raw vLLM deployment not ready within ${TIMEOUT}s (check: oc logs -n $ns deploy/vllm-qwen)"
  else
    # KServe RawDeployment creates a Deployment named <isvc>-predictor.
    oc -n "$ns" wait --for=condition=Ready inferenceservice/qwen-inference --timeout="${TIMEOUT}s" \
      || warn "${ns}: InferenceService not Ready within ${TIMEOUT}s; checking pods ..."
    oc -n "$ns" get pods -l serving.kserve.io/inferenceservice=qwen-inference -o wide || true
  fi

  # Health check from the route (bearer token required).
  local host
  host="$(oc -n "$ns" get route qwen-inference -o jsonpath='{.spec.host}' 2>/dev/null || true)"
  if [[ -n "$host" ]]; then
    local code
    code="$(curl -sk -o /dev/null -w '%{http_code}' "https://${host}/v1/models" \
      -H "Authorization: Bearer ${VLLM_API_KEY}" 2>/dev/null || echo 000)"
    [[ "$code" == "200" ]] && ok "${ns}: endpoint HEALTHY (HTTP 200)" || warn "${ns}: /v1/models returned HTTP ${code}"
    log "${ns}: external  https://${host}/v1"
  fi
  log "${ns}: internal  http://qwen-inference.${ns}.svc.cluster.local:8000/v1  (model: ${SERVED_MODEL_NAME})"
}

for s in $(resolve_squads "$SQUAD_ARG"); do deploy_one "$s"; echo; done

log "Next: bash scripts/04-deploy-agents.sh --squad ${SQUAD_ARG}"
