#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 10-enable-runai.sh — Phase 2: re-target the SAME workloads onto Run:AI
#
# This flips the shared-GPU-cluster workloads from the OpenShift AI / Kueue
# baseline onto the Run:AI scheduler WITHOUT rewriting them. For each squad it:
#   1. applies the Run:AI-specific manifests in deploy/runai/
#   2. maps the squad namespace to a Run:AI project (namespace label runai/queue)
#   3. patches every part-of=swebench-live-vllm Deployment/StatefulSet to use
#      schedulerName=$RUNAI_SCHEDULER and to carry the Run:AI project annotation
#
# Idempotent (re-running makes no further change) and reversible (--revert
# restores default-scheduler and removes the Run:AI annotations/labels). The
# per-instance agent/eval Jobs are re-targeted at submit time by passing
# `--scheduler runai` to the scenario drivers, so nothing here needs to touch
# them.
#
# Usage:
#   bash scripts/runai/10-enable-runai.sh [--squad a|b|c] [--dry-run] [--revert]
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/scripts/lib/common.sh" ]]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/common.sh"
else
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/env.sh"
fi

declare -F log  >/dev/null 2>&1 || log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
declare -F die  >/dev/null 2>&1 || die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }
declare -F require_server >/dev/null 2>&1 || require_server() {
  command -v oc >/dev/null 2>&1 || die "'oc' not found in PATH"
  local current expected="${CLUSTER_SERVER%/}"
  current="$(oc whoami --show-server 2>/dev/null || true)"
  [[ -n "$current" ]] || die "Not logged in to OpenShift. Run 'oc login' first."
  [[ "${current%/}" == "$expected" ]] || die "Refusing to run: current server '${current}' != expected '${expected}' (config/env.sh CLUSTER_SERVER)."
}

DRYRUN=0
REVERT=0
ONLY_SQUAD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad)   ONLY_SQUAD="${2:?}"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --revert)  REVERT=1; shift ;;
    -h|--help)
      grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

run() { if [[ "$DRYRUN" == 1 ]]; then echo "+ $*"; else "$@"; fi; }

require_server

squads_to_process=("${SQUADS[@]}")
[[ -n "$ONLY_SQUAD" ]] && squads_to_process=("$ONLY_SQUAD")

# ── Apply / remove the Run:AI manifests ──────────────────────────────────────
RUNAI_DIR="$REPO_ROOT/deploy/runai"
apply_runai_manifests() {
  if [[ ! -d "$RUNAI_DIR" ]]; then
    warn "deploy/runai not found — skipping manifest apply (authored by the deploy owner)."
    return 0
  fi
  if [[ -f "$RUNAI_DIR/kustomization.yaml" || -f "$RUNAI_DIR/kustomization.yml" ]]; then
    log "applying deploy/runai (kustomize)"
    run oc apply -k "$RUNAI_DIR"
  else
    log "applying deploy/runai/*.yaml"
    run oc apply -f "$RUNAI_DIR"
  fi
}
remove_runai_manifests() {
  [[ -d "$RUNAI_DIR" ]] || return 0
  if [[ -f "$RUNAI_DIR/kustomization.yaml" || -f "$RUNAI_DIR/kustomization.yml" ]]; then
    run oc delete -k "$RUNAI_DIR" --ignore-not-found
  else
    run oc delete -f "$RUNAI_DIR" --ignore-not-found
  fi
}

# ── Patch helpers ────────────────────────────────────────────────────────────
enable_ns() {   # map namespace → Run:AI project
  local ns="$1"
  run oc label   namespace "$ns" "runai/queue=${ns}" --overwrite
  # project= is the Run:AI project annotation; the swebench-live-vllm/* key is our
  # own informational marker recording which scheduler this namespace is pinned to.
  run oc annotate namespace "$ns" "project=${ns}" "swebench-live-vllm/scheduler=${RUNAI_SCHEDULER}" --overwrite
}
revert_ns() {
  local ns="$1"
  run oc label    namespace "$ns" "runai/queue-" --overwrite 2>/dev/null || true
  run oc annotate namespace "$ns" "project-" "swebench-live-vllm/scheduler-" 2>/dev/null || true
}

patch_workloads() {  # <ns> <enable|revert>
  local ns="$1" mode="$2"
  local objs; objs="$(oc get deploy,statefulset -n "$ns" \
    -l app.kubernetes.io/part-of=swebench-live-vllm -o name 2>/dev/null || true)"
  if [[ -z "$objs" ]]; then
    warn "no part-of=swebench-live-vllm Deployments/StatefulSets in $ns yet"
    return 0
  fi
  local o patch
  for o in $objs; do
    if [[ "$mode" == "enable" ]]; then
      patch='{"spec":{"template":{"metadata":{"annotations":{"runai/queue":"'"$ns"'","project":"'"$ns"'"}},"spec":{"schedulerName":"'"$RUNAI_SCHEDULER"'"}}}}'
      log "  $ns/$o → schedulerName=$RUNAI_SCHEDULER (+runai annotations)"
    else
      patch='{"spec":{"template":{"metadata":{"annotations":{"runai/queue":null,"project":null}},"spec":{"schedulerName":"default-scheduler"}}}}'
      log "  $ns/$o → schedulerName=default-scheduler (annotations removed)"
    fi
    run oc patch "$o" -n "$ns" --type=merge -p "$patch"
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
if [[ "$REVERT" == 1 ]]; then
  log "REVERTING Run:AI enablement (restoring default-scheduler)"
  for s in "${squads_to_process[@]}"; do
    ns="${SQUAD_NS[$s]}"
    oc get ns "$ns" >/dev/null 2>&1 || { warn "namespace $ns missing — skip"; continue; }
    patch_workloads "$ns" revert
    revert_ns "$ns"
  done
  remove_runai_manifests
  log "Revert complete. Workloads are back on default-scheduler; re-run the RHOAI baseline deploy to restore Kueue bindings."
  exit 0
fi

log "ENABLING Run:AI for: ${squads_to_process[*]}  (scheduler=$RUNAI_SCHEDULER, department=$RUNAI_DEPARTMENT)"
apply_runai_manifests
for s in "${squads_to_process[@]}"; do
  ns="${SQUAD_NS[$s]}"
  oc get ns "$ns" >/dev/null 2>&1 || { warn "namespace $ns missing — run Phase-1 project bootstrap first; skipping"; continue; }
  log "squad $s → project $ns"
  enable_ns "$ns"
  patch_workloads "$ns" enable
done

cat <<EOF

Run:AI enablement applied.
  - Namespaces mapped to Run:AI projects via label runai/queue=<namespace>.
  - vLLM / coordinator Deployments now use schedulerName=${RUNAI_SCHEDULER}.
  - Apply over-quota/priority/admission policies: scripts/runai/11-apply-runai-policies.sh
  - Check status:                                scripts/runai/12-runai-status.sh
  - Run a scenario on Run:AI:                    scripts/scenarios/scenario-1-multiteam-allocation.sh --scheduler runai
  - REVERSIBLE: re-run this script with --revert to restore default-scheduler.
EOF
