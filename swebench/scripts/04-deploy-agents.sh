#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 04-deploy-agents.sh — deploy the agent plane (coordinator + workspace) per squad.
#
# For each squad it:
#   1. creates the per-squad ConfigMap 'agent-config' (vLLM URL, model, split,
#      Kueue queue, parallelism) so the coordinator pod knows how to reach its
#      own namespace's endpoint;
#   2. applies the agents overlay (workspace PVC + RBAC Role + coordinator Deployment);
#   3. binds the coordinator's RoleBinding to the namespace default ServiceAccount;
#   4. waits for the coordinator to become Ready.
#
# Usage:
#   bash scripts/04-deploy-agents.sh --squad a
#   bash scripts/04-deploy-agents.sh --squad all
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="a"; WAIT=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad)   SQUAD_ARG="$2"; shift 2 ;;
    --no-wait) WAIT=0; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_server_guard
echo

deploy_one() {
  local s="$1" ns split priority
  ns="$(squad_ns "$s")"; split="$(squad_split "$s")"; priority="$(squad_priority "$s")"
  oc get namespace "$ns" >/dev/null 2>&1 || die "Namespace $ns missing — run 01-create-projects.sh first."

  log "Squad $s (${ns}): creating agent-config ConfigMap"
  oc create configmap agent-config -n "$ns" \
    --from-literal=NAMESPACE="$ns" \
    --from-literal=SWEBENCH_SPLIT="$split" \
    --from-literal=AI_MODEL="$MODEL_ID" \
    --from-literal=AI_PROVIDER="openai" \
    --from-literal=AI_BASE_URL="http://qwen-inference.${ns}.svc.cluster.local:8000/v1" \
    --from-literal=AI_API_KEY="$VLLM_API_KEY" \
    --from-literal=OPENAI_API_KEY="$VLLM_API_KEY" \
    --from-literal=KUEUE_ENABLED="${KUEUE_ENABLED:-1}" \
    --from-literal=LOCAL_QUEUE="$LOCAL_QUEUE" \
    --from-literal=PRIORITY_CLASS="$priority" \
    --from-literal=PARALLEL="$PARALLEL" \
    --from-literal=MAX_TURNS="$MAX_TURNS" \
    --from-literal=MAX_RETRIES="$MAX_RETRIES" \
    --dry-run=client -o yaml | oc apply -n "$ns" -f -

  log "${ns}: applying agent plane (coordinator + workspace + RBAC)"
  apply_overlay agents "$ns"

  # Bind the Role to the namespace default SA (subject namespace must be concrete).
  oc create rolebinding coordinator-job-manager -n "$ns" \
    --role=job-manager --serviceaccount="${ns}:default" \
    --dry-run=client -o yaml | oc apply -n "$ns" -f -

  label_squad "$ns" "$s" "$split"

  if [[ "$WAIT" == 1 ]]; then
    log "${ns}: waiting for coordinator ..."
    oc -n "$ns" rollout status deployment/benchmark-coordinator --timeout=300s \
      || die "${ns}: coordinator not ready (check: oc logs -n $ns deploy/benchmark-coordinator)"
  fi
  ok "${ns}: agent plane ready"
}

for s in $(resolve_squads "$SQUAD_ARG"); do deploy_one "$s"; echo; done

log "Next: bash scripts/05-launch-benchmark.sh --squad ${SQUAD_ARG}"
