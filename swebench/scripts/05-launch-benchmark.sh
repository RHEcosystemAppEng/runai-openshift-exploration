#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 05-launch-benchmark.sh — ONE-CLICK autonomous SWE-bench run for a squad.
#
# Resolves the squad's SWE-bench Live split, ensures serving + agents exist, copies
# the dataset + AMI binary + benchmark engine to the coordinator, then launches
# benchmark/autonomous-k8s-monitor.sh for that split (nohup, unattended). Generalises
# the proven _legacy/launch-benchmark.sh from a single namespace to per-squad
# namespace + split. The autonomous monitor fans out one K8s Job per instance.
#
# Dataset resolution (first match wins):
#   --dataset <file>                                   explicit path
#   $DATASET_DIR/swebench-multilang-<split>.jsonl      (prepare_datasets.py output)
#   $REPO_ROOT/data/swebench-multilang-<split>.jsonl   (prepare_datasets.py output)
#   $DATASET_DIR/swebench-live-<split>.jsonl
#   $REPO_ROOT/data/swebench-live-<split>.jsonl
#   $REPO_ROOT/data/swebench-<split>.jsonl
#
# Usage:
#   bash scripts/05-launch-benchmark.sh --squad a
#   bash scripts/05-launch-benchmark.sh --squad b --dataset ~/data/cpp.jsonl --parallel 5
#   AMI_BINARY=~/.local/bin/ami bash scripts/05-launch-benchmark.sh --squad c
#   bash scripts/05-launch-benchmark.sh --squad a --dry-run
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD="a"; DATASET=""; DRY_RUN=0; PAR="${PARALLEL}"
AMI_BINARY="${AMI_BINARY:-$HOME/.local/bin/ami}"
DATASET_DIR="${DATASET_DIR:-$REPO_ROOT/data}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad)    SQUAD="$2"; shift 2 ;;
    --dataset)  DATASET="$2"; shift 2 ;;
    --parallel) PAR="$2"; shift 2 ;;
    --dry-run)  DRY_RUN=1; shift ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
[[ "$SQUAD" =~ ^[abc]$ ]] || die "--squad must be a, b, or c (one squad per launch)"

ns="$(squad_ns "$SQUAD")"; split="$(squad_split "$SQUAD")"
run()  { if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

# ── resolve dataset ────────────────────────────────────────────────────────────
if [[ -z "$DATASET" ]]; then
  for c in "$DATASET_DIR/swebench-multilang-${split}.jsonl" \
           "$REPO_ROOT/data/swebench-multilang-${split}.jsonl" \
           "$DATASET_DIR/swebench-live-${split}.jsonl" \
           "$REPO_ROOT/data/swebench-live-${split}.jsonl" \
           "$REPO_ROOT/data/swebench-${split}.jsonl"; do
    [[ -f "$c" ]] && DATASET="$c" && break
  done
fi
[[ -f "$DATASET" ]] || die "Dataset for split '${split}' not found. Pass --dataset <file> (looked in $DATASET_DIR)."
[[ -f "$AMI_BINARY" ]] || die "AMI binary not found at $AMI_BINARY (set AMI_BINARY=...)."
command -v curl >/dev/null || die "'curl' not found in PATH"
INSTANCES="$(wc -l < "$DATASET")"
DATASET_BASENAME="$(basename "$DATASET")"

require_server_guard
echo
cat <<EOF
  ============================================================
    SWE-bench Live launcher — Squad ${SQUAD} ($(squad_label "$SQUAD"))
  ============================================================
    Namespace : ${ns}
    Split     : ${split}
    Dataset   : ${DATASET_BASENAME}  (${INSTANCES} instances)
    AMI binary: ${AMI_BINARY}
    Parallel  : ${PAR}
    Model     : ${SERVED_MODEL_NAME}
    Dry run   : $([[ "$DRY_RUN" == 1 ]] && echo yes || echo no)
  ============================================================
EOF
echo

# ── ensure serving + agents exist (do not re-wait if already up) ───────────────
if ! oc -n "$ns" get svc qwen-inference >/dev/null 2>&1; then
  warn "${ns}: no vLLM Service found — run scripts/03-deploy-serving.sh --squad ${SQUAD} first."
  die  "Serving endpoint missing."
fi
COORD="$(oc -n "$ns" get pods -l app=benchmark-runner -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "$COORD" ]] || die "${ns}: coordinator pod not found — run scripts/04-deploy-agents.sh --squad ${SQUAD} first."
log "Coordinator pod: ${COORD}"

# ── verify the endpoint is healthy from inside the coordinator ─────────────────
VLLM_INTERNAL="http://qwen-inference.${ns}.svc.cluster.local:8000/v1"
if [[ "$DRY_RUN" == 0 ]]; then
  code="$(oc -n "$ns" exec "$COORD" -- curl -sk -o /dev/null -w '%{http_code}' \
    "$VLLM_INTERNAL/models" -H "Authorization: Bearer ${VLLM_API_KEY}" 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] || die "${ns}: vLLM not healthy from coordinator (HTTP ${code}). Wait for the model to load."
  ok "${ns}: vLLM healthy (HTTP 200)"
fi

# ── copy dataset, AMI binary, and the benchmark engine to the coordinator ──────
log "Staging dataset, AMI, and benchmark scripts into ${COORD}:/workspace ..."
run oc -n "$ns" exec "$COORD" -- mkdir -p /workspace/data /workspace/ami /workspace/scripts /workspace/logs
run oc -n "$ns" cp "$DATASET" "${ns}/${COORD}:/workspace/data/${DATASET_BASENAME}"
run oc -n "$ns" cp "$AMI_BINARY" "${ns}/${COORD}:/workspace/ami/ami"
run oc -n "$ns" exec "$COORD" -- chmod +x /workspace/ami/ami
if [[ "$DRY_RUN" == 0 ]]; then
  for f in "$BENCHMARK_DIR"/*; do
    [[ -f "$f" ]] || continue
    oc -n "$ns" cp "$f" "${ns}/${COORD}:/workspace/scripts/$(basename "$f")"
  done
  oc -n "$ns" exec "$COORD" -- bash -c 'chmod +x /workspace/scripts/*.sh 2>/dev/null || true'
else
  echo "  [dry-run] oc cp ${BENCHMARK_DIR}/* ${COORD}:/workspace/scripts/"
fi
ok "Staging complete"

# ── launch the autonomous monitor for this split ───────────────────────────────
log "Launching autonomous-k8s-monitor.sh for split '${split}' ..."
LAUNCH="
  export PATH=/workspace/bin:/workspace/ami:\$PATH
  export NAMESPACE='${ns}'
  export JSONL_FILE='/workspace/data/${DATASET_BASENAME}'
  export AI_BASE_URL='${VLLM_INTERNAL}'
  export AI_API_KEY='${VLLM_API_KEY}'
  export AI_MODEL='${MODEL_ID}'
  export AI_PROVIDER='openai'
  export PARALLEL='${PAR}'
  export MAX_TURNS='${MAX_TURNS}'
  export PVC_CLAIM='benchmark-workspace'
  export KUEUE_ENABLED='${KUEUE_ENABLED:-1}'
  export LOCAL_QUEUE='${LOCAL_QUEUE}'
  export PRIORITY_CLASS='$(squad_priority "$SQUAD")'
  nohup bash /workspace/scripts/autonomous-k8s-monitor.sh '${split}' \
    > /workspace/logs/autonomous-${split}-\$(date +%Y%m%d_%H%M%S).log 2>&1 &
  echo \$!
"
if [[ "$DRY_RUN" == 1 ]]; then
  echo "  [dry-run] oc exec ${COORD} -- bash -c '<launch autonomous-k8s-monitor.sh ${split}>'"
else
  PID="$(oc -n "$ns" exec "$COORD" -- bash -c "$LAUNCH" | tail -1)"
  ok "${ns}: autonomous run started (coordinator PID ${PID})"
fi

echo
log "Monitor with:"
echo "    bash scripts/06-status.sh --squad ${SQUAD}"
echo "    oc -n ${ns} exec ${COORD} -- tail -f \$(oc -n ${ns} exec ${COORD} -- bash -c 'ls -t /workspace/logs/autonomous-${split}-*.log | head -1')"
echo "    oc -n ${ns} get jobs -l app=swebench-instance"
