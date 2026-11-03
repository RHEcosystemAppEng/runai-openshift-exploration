#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/post-training.sh — root entrypoint for the post-training subproject.
#
# Gives the same verb interface as scripts/swebench.sh so "the way we run things"
# is aligned across subprojects. It delegates to the scripts the post-training
# owner ships (post-training/scripts/*); it never modifies that folder.
#
#   scripts/post-training.sh setup       # create/reuse the team-b-lora RHOAI project
#   scripts/post-training.sh deploy      # apply the RHOAI PyTorch CUDA Workbench
#   scripts/post-training.sh run         # submit the repeatable LoRA batch Job
#   scripts/post-training.sh status      # show the batch Job + pods
#   scripts/post-training.sh teardown    # print the manual cleanup commands
#
# Pass extra args after the verb; they are forwarded to the underlying script.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/$(basename -- "${BASH_SOURCE[0]}")"
ROOT="$(cd -- "$(dirname -- "$SELF")/.." && pwd)"
PT="$ROOT/post-training"
NS="${PROJECT_NAME:-team-b-lora}"

usage() {
  awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$SELF"
}

verb="${1:-help}"
shift || true

case "$verb" in
  setup)    ( cd "$PT" && bash scripts/create-project.sh "$@" ) ;;
  deploy)   ( cd "$PT" && oc apply -f deploy/workbench.yaml ) ;;
  run)      ( cd "$PT" && bash scripts/submit-batch-job.sh "$@" ) ;;
  status)   oc get jobs,pods -n "$NS" -l app.kubernetes.io/component=batch-training -o wide ;;
  teardown)
    cat <<EOF
post-training ships no teardown script (that folder is owned elsewhere and is not
modified here). To remove the batch run manually:

  oc delete job -n $NS -l app.kubernetes.io/component=batch-training
  oc delete pvc team-b-lora-batch-workspace -n $NS     # deletes adapters/checkpoints
  oc delete -f $PT/deploy/workbench.yaml                # removes the Workbench
EOF
    ;;
  help|-h|--help) usage ;;
  *) echo "post-training.sh: unknown verb '$verb'" >&2; usage; exit 1 ;;
esac
