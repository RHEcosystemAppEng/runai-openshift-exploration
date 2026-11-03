#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/lib/common.sh — shared helpers for every swebench-live-vllm script.
#
# Source this near the top of each script:
#     source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# It sources config/env.sh (the single source of truth), then defines logging,
# the cluster server guard, oc helpers, and squad iteration over the SQUAD_* maps.
# ─────────────────────────────────────────────────────────────────────────────

# Resolve repo root from this file's location (scripts/lib/common.sh -> repo root).
LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd -- "$LIB_DIR/.." && pwd)"
REPO_ROOT="$(cd -- "$SCRIPTS_DIR/.." && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy"
BENCHMARK_DIR="$REPO_ROOT/benchmark"
export REPO_ROOT SCRIPTS_DIR DEPLOY_DIR BENCHMARK_DIR

# Load the single source of truth (defines SQUADS, SQUAD_NS, SQUAD_SPLIT, etc.).
# shellcheck source=../../config/env.sh
source "$REPO_ROOT/config/env.sh"

# ── logging ──────────────────────────────────────────────────────────────────
_c_reset=$'\033[0m'; _c_blue=$'\033[34m'; _c_yellow=$'\033[33m'; _c_red=$'\033[31m'; _c_green=$'\033[32m'
log()  { printf '%s[ %s ]%s %s\n' "$_c_blue"  "$(date +%H:%M:%S)" "$_c_reset" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$_c_green" "$_c_reset" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
err()  { printf '%s[fail]%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { err "$*"; exit 1; }

# ── cluster guard (mirrors the post-training create-project.sh convention) ─────
require_oc() { command -v oc >/dev/null 2>&1 || die "'oc' not found in PATH"; }

require_login() {
  require_oc
  oc whoami >/dev/null 2>&1 || die "Not logged in. Run the OpenShift 'Copy login command' flow first."
}

require_server_guard() {
  require_login
  local current
  current="$(oc whoami --show-server)"
  if [[ "${current%/}" != "${CLUSTER_SERVER%/}" ]]; then
    die "Refusing to run: current OpenShift server is '${current}'; expected '${CLUSTER_SERVER}'.
     Override with CLUSTER_SERVER=... if you intend to target a different cluster."
  fi
  ok "Connected to $(oc whoami) @ ${current}"
}

# ── squad helpers (iterate the SQUAD_* associative arrays from env.sh) ─────────
# squad_ns a      -> squad-a-lite
# squad_split a   -> lite
# squad_priority a-> squad-high-priority
squad_ns()       { echo "${SQUAD_NS[$1]:?unknown squad '$1' (expected a|b|c)}"; }
squad_split()    { echo "${SQUAD_SPLIT[$1]:?unknown squad '$1'}"; }
squad_label()    { echo "${SQUAD_LABEL[$1]:?unknown squad '$1'}"; }
squad_priority() { echo "${SQUAD_PRIORITY[$1]:?unknown squad '$1'}"; }

# Resolve a user --squad argument ("a"/"b"/"c"/"all") to a list of squad keys.
resolve_squads() {
  local arg="${1:-all}"
  case "$arg" in
    all) printf '%s\n' "${SQUADS[@]}" ;;
    a|b|c) echo "$arg" ;;
    *) die "Invalid squad '$arg' (expected a|b|c|all)" ;;
  esac
}

# Convenience: oc scoped to a namespace.
ocn() { local ns="$1"; shift; oc -n "$ns" "$@"; }

# Apply the vendor overlay for a component into a namespace.
# apply_overlay <component> <namespace>   (component: scheduling|serving|...|agents)
apply_overlay() {
  local component="$1" ns="${2:-}"
  local dir="$DEPLOY_DIR/overlays/${KSERVE_OVERLAY}/${component}"
  [[ -d "$dir" ]] || die "Overlay not found: $dir"
  if [[ -n "$ns" ]]; then
    oc apply -n "$ns" -k "$dir"
  else
    oc apply -k "$dir"
  fi
}

# Stamp squad/split labels onto everything in a namespace that belongs to us,
# so the NAMING CONTRACT ('labels on everything') holds after an overlay apply.
label_squad() {
  local ns="$1" squad="$2" split="$3"
  oc label namespace "$ns" squad="$squad" split="$split" \
    app.kubernetes.io/part-of=swebench-live-vllm --overwrite >/dev/null
  oc label all -n "$ns" -l app.kubernetes.io/part-of=swebench-live-vllm \
    squad="$squad" split="$split" --overwrite >/dev/null 2>&1 || true
}
