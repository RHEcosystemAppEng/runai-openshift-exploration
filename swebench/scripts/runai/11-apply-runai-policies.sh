#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 11-apply-runai-policies.sh — Phase 2: apply the Run:AI quota/priority policies
#
# Applies the policy manifests under deploy/runai/policies/ that encode the same
# over-quota / priority / admission behaviour the Kueue ClusterQueues express on
# the RHOAI baseline:
#   - Squad A  : high priority, over-quota ENABLED (may borrow the whole pool)
#   - Squad B/C: standard priority, borrow when others are idle, reclaimable
#
# After applying, it prints the effective per-squad policy (from config/env.sh)
# and verifies the shared PriorityClasses exist, so operators can confirm the
# Run:AI side matches the RHOAI side before comparing scenarios.
#
# Usage:
#   bash scripts/runai/11-apply-runai-policies.sh [--dry-run]
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
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) grep -E '^# ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done
run() { if [[ "$DRYRUN" == 1 ]]; then echo "+ $*"; else "$@"; fi; }

require_server

POLICY_DIR="$REPO_ROOT/deploy/runai/policies"
if [[ -d "$POLICY_DIR" ]]; then
  if [[ -f "$POLICY_DIR/kustomization.yaml" || -f "$POLICY_DIR/kustomization.yml" ]]; then
    log "applying deploy/runai/policies (kustomize)"
    run oc apply -k "$POLICY_DIR"
  else
    log "applying deploy/runai/policies/*.yaml"
    run oc apply -f "$POLICY_DIR"
  fi
else
  warn "deploy/runai/policies not found — authored by the deploy owner. Printing the intended policy from config/env.sh so it can be encoded there."
fi

# ── Effective policy summary (single source of truth: config/env.sh) ──────────
echo
echo "Effective per-squad Run:AI policy (cohort ${COHORT_NAME}, ${POOL_GPU_TOTAL} GPUs total):"
printf '  %-14s %-9s %-10s %-8s %-10s %s\n' "PROJECT" "PRIORITY" "NOMINAL" "BORROW" "OVERQUOTA" "SPLIT"
declare -A NOMINAL=( [a]="$SQUAD_A_GPU_NOMINAL" [b]="$SQUAD_B_GPU_NOMINAL" [c]="$SQUAD_C_GPU_NOMINAL" )
declare -A BORROW=(  [a]="$SQUAD_A_GPU_BORROW"  [b]="$SQUAD_B_GPU_BORROW"  [c]="$SQUAD_C_GPU_BORROW" )
for s in "${SQUADS[@]}"; do
  oq="disabled"
  [[ "$s" == "a" && "$RUNAI_OVERQUOTA" == "true" ]] && oq="ENABLED"
  printf '  %-14s %-9s %-10s %-8s %-10s %s\n' \
    "${SQUAD_NS[$s]}" "${SQUAD_PRIORITY[$s]}" "${NOMINAL[$s]}" "${BORROW[$s]}" "$oq" "${SQUAD_SPLIT[$s]}"
done

# ── Verify the shared priority classes exist (shared with the RHOAI stack) ────
echo
echo "PriorityClass check:"
for pc in "$PRIORITY_HIGH" "$PRIORITY_STANDARD"; do
  if oc get priorityclass "$pc" >/dev/null 2>&1; then
    echo "  OK   priorityclass/$pc"
  else
    warn "  MISSING priorityclass/$pc — create it in the Phase-1 baseline (deploy/base)."
  fi
done

echo
log "Policies applied. Verify allocation behaviour with scripts/runai/12-runai-status.sh, then exercise scenarios with --scheduler runai."
