#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# swebench-live-vllm — shared helpers for the key-scenario drivers
#
# This file is SOURCED by scripts/scenarios/scenario-*.sh. It is not meant to be
# executed directly. It provides:
#   - bootstrap of the single source of truth (config/env.sh, via scripts/lib/
#     common.sh when Phase-1 has created it)
#   - a server guard matching $CLUSTER_SERVER (same contract as the reference
#     post-training scripts' EXPECTED_SERVER check)
#   - a --scheduler rhoai|runai switch so the SAME scenario runs on BOTH the
#     OpenShift AI (Kueue) baseline and the Run:AI stack for apples-to-apples
#     comparison
#   - submit_gpu_job(): emits a REAL, apply-ready GPU Job that carries the exact
#     labels / queue bindings from the naming contract. The Job is a controllable
#     GPU-holding stand-in for a squad's vLLM/agent GPU workload — it lets Kueue
#     (or the Run:AI scheduler) actually perform admission, quota borrowing,
#     reclamation/preemption and GPU sharing so the operator can observe them.
#   - report/observation helpers that write a timestamped Markdown summary under
#     reports/ while also streaming to the terminal.
#
# Shell scripts (which source config/env.sh) MAY use ${VARS}; kustomize bases
# never do. This file is a shell script, so it uses ${VARS} freely.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Bootstrap: repo root + single source of truth ────────────────────────────
SCN_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCN_LIB_DIR/../.." && pwd)"

if [[ -f "$REPO_ROOT/scripts/lib/common.sh" ]]; then
  # Phase-1 shared library (it sources config/env.sh itself).
  # shellcheck source=/dev/null
  source "$REPO_ROOT/scripts/lib/common.sh"
else
  # Standalone fallback: source the single source of truth directly so the
  # scenario drivers still work before the Phase-1 library lands.
  # shellcheck source=/dev/null
  source "$REPO_ROOT/config/env.sh"
fi

# ── Fallback helpers (defined only if common.sh did not already provide them) ─
declare -F log  >/dev/null 2>&1 || log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
declare -F warn >/dev/null 2>&1 || warn() { printf '[%s] WARN: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
declare -F die  >/dev/null 2>&1 || die()  { printf 'FATAL: %s\n' "$*" >&2; exit 1; }

declare -F require_server >/dev/null 2>&1 || require_server() {
  command -v oc >/dev/null 2>&1 || die "'oc' not found in PATH"
  local current expected="${CLUSTER_SERVER%/}"
  current="$(oc whoami --show-server 2>/dev/null || true)"
  [[ -n "$current" ]] || die "Not logged in to OpenShift. Run 'oc login' first."
  if [[ "${current%/}" != "$expected" ]]; then
    die "Refusing to run: current server is '${current}'; expected '${expected}' (config/env.sh CLUSTER_SERVER). Override with CLUSTER_SERVER=..."
  fi
}

# ── Scenario-wide state (scenarios set SCENARIO_ID / SCENARIO_TITLE first) ────
SCENARIO_ID="${SCENARIO_ID:-0}"
SCENARIO_TITLE="${SCENARIO_TITLE:-scenario}"
SCHEDULER="rhoai"     # rhoai (Kueue) | runai
DRYRUN=0
DO_CLEANUP=0
HOLD="${HOLD:-900}"   # seconds each GPU job holds its GPU (demo window)
declare -a EXTRA_ARGS=()

# parse_common_args "$@": consumes the flags every scenario understands and
# leaves anything else in EXTRA_ARGS for the scenario to interpret.
parse_common_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --scheduler) SCHEDULER="${2:?--scheduler needs rhoai|runai}"; shift 2 ;;
      --hold)      HOLD="${2:?--hold needs seconds}"; shift 2 ;;
      --dry-run)   DRYRUN=1; shift ;;
      --cleanup)   DO_CLEANUP=1; shift ;;
      -h|--help)   print_help; exit 0 ;;
      *)           EXTRA_ARGS+=("$1"); shift ;;
    esac
  done
  case "$SCHEDULER" in
    rhoai|runai) : ;;
    *) die "--scheduler must be 'rhoai' or 'runai' (got '$SCHEDULER')" ;;
  esac
}

# Scenarios may override print_help; provide a sane default.
declare -F print_help >/dev/null 2>&1 || print_help() {
  cat <<EOF
Scenario ${SCENARIO_ID}: ${SCENARIO_TITLE}
Usage: $(basename "${BASH_SOURCE[1]:-scenario.sh}") [--scheduler rhoai|runai] [--hold SECONDS] [--dry-run] [--cleanup]

  --scheduler   Run on the OpenShift AI/Kueue baseline (rhoai, default) or Run:AI (runai).
  --hold        Seconds each GPU job holds its GPU (default: ${HOLD}).
  --dry-run     Render manifests with 'oc apply --dry-run=client'; change nothing.
  --cleanup     Delete this scenario's jobs across all squad namespaces, then exit.
EOF
}

# ── Apply wrapper honouring --dry-run ────────────────────────────────────────
kapply() {
  if [[ "$DRYRUN" == "1" ]]; then
    oc apply --dry-run=client -f -
  else
    oc apply -f -
  fi
}

# ── Namespace preflight (warn, never hard-fail, so --dry-run stays usable) ────
check_namespaces() {
  local s miss=0
  for s in "${SQUADS[@]}"; do
    if ! oc get ns "${SQUAD_NS[$s]}" >/dev/null 2>&1; then
      warn "namespace ${SQUAD_NS[$s]} not found — run the Phase-1 project bootstrap (scripts/01-*/create) first"
      miss=1
    fi
  done
  return 0
}

# ── GPU Job emitter ──────────────────────────────────────────────────────────
# submit_gpu_job <squad> <suffix> <gpus-per-pod> <hold-seconds> [parallelism]
#
# rhoai mode : Job is created suspended with the Kueue LocalQueue label so the
#              ClusterQueue admits it (and borrows/preempts per quota). The
#              WorkloadPriorityClass label carries the squad priority.
# runai mode : Job is scheduled by $RUNAI_SCHEDULER and tagged with the Run:AI
#              project (runai/queue + project annotation) = the squad namespace.
submit_gpu_job() {
  local squad="$1" suffix="$2" gpus="$3" hold="$4" par="${5:-1}"
  local ns="${SQUAD_NS[$squad]}" split="${SQUAD_SPLIT[$squad]}" prio="${SQUAD_PRIORITY[$squad]}"
  local name="scn${SCENARIO_ID}-squad-${squad}-${suffix}"
  local deadline=$(( hold + 600 ))

  local kueue_labels="" anno_block="" tmpl_runai_label="" suspend_line="" sched_line=""
  if [[ "$SCHEDULER" == "runai" ]]; then
    sched_line="      schedulerName: ${RUNAI_SCHEDULER}"
    anno_block="$(printf '  annotations:\n    runai/queue: "%s"\n    project: "%s"' "$ns" "$ns")"
    tmpl_runai_label="$(printf '        runai/queue: "%s"' "$ns")"
  else
    kueue_labels="$(printf '    kueue.x-k8s.io/queue-name: %s\n    kueue.x-k8s.io/priority-class: %s' "$LOCAL_QUEUE" "$prio")"
    suspend_line="  suspend: true"
  fi

  log "submit ${name} → ns=${ns} gpus=${gpus}x${par} prio=${prio} scheduler=${SCHEDULER}"

  cat <<EOF | kapply
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${ns}
  labels:
    app.kubernetes.io/part-of: swebench-live-vllm
    app: swebench-instance
    squad: ${squad}
    split: ${split}
    scenario: "${SCENARIO_ID}"
    scheduler: ${SCHEDULER}
${kueue_labels}
${anno_block}
spec:
${suspend_line}
  backoffLimit: 0
  completions: ${par}
  parallelism: ${par}
  ttlSecondsAfterFinished: 1800
  activeDeadlineSeconds: ${deadline}
  template:
    metadata:
      labels:
        app.kubernetes.io/part-of: swebench-live-vllm
        app: swebench-instance
        squad: ${squad}
        split: ${split}
        scenario: "${SCENARIO_ID}"
${tmpl_runai_label}
    spec:
${sched_line}
      restartPolicy: Never
      priorityClassName: ${prio}
      terminationGracePeriodSeconds: 10
      tolerations:
        - key: ${GPU_TAINT_KEY}
          operator: Exists
          effect: NoSchedule
      containers:
        - name: gpu-hold
          image: registry.access.redhat.com/ubi9/ubi-minimal:latest
          command: ["/bin/sh", "-c"]
          args:
            - |
              echo "scenario=${SCENARIO_ID} squad=${squad} split=${split} ns=${ns}"
              echo "holding ${gpus}x${GPU_RESOURCE} for ${hold}s on \$(hostname) (scheduler=${SCHEDULER}, prio=${prio})"
              sleep ${hold}
              echo "released GPU(s)"
          resources:
            requests:
              cpu: "1"
              memory: 2Gi
              ${GPU_RESOURCE}: "${gpus}"
            limits:
              cpu: "2"
              memory: 4Gi
              ${GPU_RESOURCE}: "${gpus}"
EOF
}

# Delete every Job this scenario created, in all squad namespaces.
cleanup_scenario() {
  local s
  for s in "${SQUADS[@]}"; do
    log "cleanup scenario=${SCENARIO_ID} in ${SQUAD_NS[$s]}"
    oc delete jobs -n "${SQUAD_NS[$s]}" -l "scenario=${SCENARIO_ID}" --ignore-not-found --wait=false 2>/dev/null || true
  done
}

# ── Reporting ────────────────────────────────────────────────────────────────
init_report() {
  REPORTS_DIR="$REPO_ROOT/reports"
  mkdir -p "$REPORTS_DIR"
  local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  REPORT="$REPORTS_DIR/scenario-${SCENARIO_ID}-${SCHEDULER}-${ts}.md"
  {
    echo "# Scenario ${SCENARIO_ID} — ${SCENARIO_TITLE}"
    echo
    echo "- Stack: **${SCHEDULER}**"
    echo "- Cluster: \`${CLUSTER_SERVER}\`"
    echo "- Cohort: \`${COHORT_NAME}\` — ${POOL_GPU_TOTAL} × \`${GPU_RESOURCE}\` (flavor \`${ACCELERATOR_FLAVOR}\`)"
    echo "- Nominal quota: A=${SQUAD_A_GPU_NOMINAL} B=${SQUAD_B_GPU_NOMINAL} C=${SQUAD_C_GPU_NOMINAL}; borrow cap: A=${SQUAD_A_GPU_BORROW} B=${SQUAD_B_GPU_BORROW} C=${SQUAD_C_GPU_BORROW}"
    echo "- Started (UTC): ${ts}"
    echo "- Dry run: $([[ "$DRYRUN" == 1 ]] && echo yes || echo no)"
    echo
  } > "$REPORT"
  log "report → $REPORT"
}

# section "Title" — markdown header + terminal banner
section() {
  { echo; echo "## $*"; echo; } >> "$REPORT"
  printf '\n==== %s ====\n' "$*"
}

# note "free text" — a paragraph in the report + terminal
note() {
  { echo "$*"; echo; } >> "$REPORT"
  printf '%s\n' "$*"
}

# capture "label" <command...> — run a command, stream to terminal, fence in report
capture() {
  local label="$1"; shift
  { echo "### ${label}"; echo '```'; } >> "$REPORT"
  printf -- '-- %s --\n' "$label"
  { "$@" 2>&1 || true; } | tee -a "$REPORT"
  { echo '```'; echo; } >> "$REPORT"
}

# ── Observation: admission / quota / placement ───────────────────────────────
# Sum of GPU requests across Running+Pending pods in a namespace.
gpu_requested_in_ns() {
  local ns="$1"
  if command -v python3 >/dev/null 2>&1; then
    oc get pods -n "$ns" -o json 2>/dev/null | GPU_RES="$GPU_RESOURCE" python3 -I -c '
import json, os, sys
res = os.environ["GPU_RES"]
try:
    d = json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
tot = 0
for p in d.get("items", []):
    if p.get("status", {}).get("phase") not in ("Running", "Pending"):
        continue
    for c in p.get("spec", {}).get("containers", []):
        v = c.get("resources", {}).get("requests", {}).get(res)
        if v:
            try: tot += int(v)
            except ValueError: pass
print(tot)
'
  else
    echo "?"
  fi
}

gpu_summary() {
  local s ns req
  printf '%-16s %-8s %-6s %s\n' "NAMESPACE" "SQUAD" "GPUs" "SPLIT"
  for s in "${SQUADS[@]}"; do
    ns="${SQUAD_NS[$s]}"
    req="$(gpu_requested_in_ns "$ns")"
    printf '%-16s %-8s %-6s %s\n' "$ns" "$s" "$req" "${SQUAD_SPLIT[$s]}"
  done
}

# Discover Run:AI CRD kinds actually installed on the cluster.
runai_kinds() {
  oc api-resources --no-headers 2>/dev/null | awk '$0 ~ /run\.ai/ {print $1}' | sort -u
}

show_runai_status() {
  if command -v runai >/dev/null 2>&1; then
    capture "runai projects" runai list projects
    capture "runai jobs" runai list jobs -A
  else
    local kinds; kinds="$(runai_kinds || true)"
    if [[ -z "$kinds" ]]; then
      note "_No Run:AI CRDs found via 'oc api-resources' — is the Run:AI operator installed? Falling back to pod/scheduler views._"
    else
      local k
      for k in $kinds; do
        capture "Run:AI resource: ${k}" oc get "$k" -A
      done
    fi
  fi
  local s
  for s in "${SQUADS[@]}"; do
    capture "Pods in ${SQUAD_NS[$s]} (scheduler/node/phase)" \
      oc get pods -n "${SQUAD_NS[$s]}" -o wide
  done
  capture "Scheduler events mentioning preempt/reclaim/quota (all squads)" \
    oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp
}

# Admission / quota view, branched by stack.
show_admission() {
  if [[ "$SCHEDULER" == "runai" ]]; then
    show_runai_status
    return
  fi
  capture "ClusterQueues (nominal quota, borrowing, admitted vs pending)" \
    oc get clusterqueues.kueue.x-k8s.io -o wide
  capture "Cohort / ResourceFlavors" \
    oc get resourceflavors.kueue.x-k8s.io -o wide
  local s
  for s in "${SQUADS[@]}"; do
    capture "LocalQueue + Workloads in ${SQUAD_NS[$s]}" \
      oc get localqueues.kueue.x-k8s.io,workloads.kueue.x-k8s.io -n "${SQUAD_NS[$s]}" -o wide
  done
}

# Per-squad jobs + GPU accounting + pod placement.
show_workloads() {
  local s
  for s in "${SQUADS[@]}"; do
    capture "Jobs/Pods in ${SQUAD_NS[$s]}" \
      oc get jobs,pods -n "${SQUAD_NS[$s]}" -l scenario="${SCENARIO_ID}" -o wide
  done
  capture "GPU requested per squad (Running+Pending)" gpu_summary
}

# Short settle so freshly-submitted workloads reach an admission decision.
settle() {
  local secs="${1:-20}"
  [[ "$DRYRUN" == "1" ]] && return 0
  log "waiting ${secs}s for admission/placement to settle ..."
  sleep "$secs"
}

finish_report() {
  note "---"
  note "Report written by $(basename "${BASH_SOURCE[1]:-scenario}") at $(date -u +%Y-%m-%dT%H:%M:%SZ). Re-run with the opposite \`--scheduler\` for a side-by-side comparison, and with \`--cleanup\` to remove this scenario's jobs."
  log "DONE — report: $REPORT"
}
