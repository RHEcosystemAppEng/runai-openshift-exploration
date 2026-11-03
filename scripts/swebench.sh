#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/swebench.sh — root entrypoint for the swebench subproject.
#
# Gives the same verb interface as scripts/post-training.sh so "the way we run
# things" is aligned across subprojects. It delegates to swebench/, which drives
# everything through its Makefile (run `scripts/swebench.sh make help` for the
# full target list, including the Run:ai phase and scenarios).
#
#   scripts/swebench.sh setup       # preflight + create the squad projects
#   scripts/swebench.sh deploy      # scheduling + serving + agents
#   scripts/swebench.sh run         # launch the autonomous SWE-bench run (ARGS below)
#   scripts/swebench.sh status      # queues, workloads, GPU allocation, progress
#   scripts/swebench.sh teardown    # remove workloads/queues (keeps PVCs by default)
#   scripts/swebench.sh make <t>    # passthrough to ANY Makefile target
#
# Pass extra args after the verb, e.g.:
#   scripts/swebench.sh run --squad a
#   scripts/swebench.sh teardown --squad all --delete-pvc
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
ROOT="$(cd -- "$(dirname -- "$SELF")/.." && pwd)"
cd "$ROOT/swebench"

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$SELF"
}

verb="${1:-help}"
shift || true

case "$verb" in
  setup)          make preflight projects ;;
  deploy)         make scheduling serving agents ;;
  run)            make launch ARGS="$*" ;;
  status)         make status ;;
  teardown)       make teardown ARGS="$*" ;;
  make)           make "$@" ;;
  help|-h|--help) usage ;;
  *) echo "swebench.sh: unknown verb '$verb'" >&2; usage; exit 1 ;;
esac
