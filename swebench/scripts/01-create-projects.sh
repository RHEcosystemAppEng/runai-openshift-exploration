#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 01-create-projects.sh — create the three squad namespaces.
#
# Applies deploy/squads/<ns>/namespace.yaml for each squad, opts each into the
# RHOAI dashboard, and reminds you about the image-pull secret. Mirrors the
# post-training create-project.sh convention (server guard + dashboard label).
#
# Usage:
#   bash scripts/01-create-projects.sh            # all three squads
#   bash scripts/01-create-projects.sh --squad a  # just Squad A
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SQUAD_ARG="all"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --squad) SQUAD_ARG="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

require_server_guard
echo

for s in $(resolve_squads "$SQUAD_ARG"); do
  ns="$(squad_ns "$s")"; split="$(squad_split "$s")"
  log "Squad $s -> namespace ${ns} (SWE-bench ${split})"
  oc apply -f "$DEPLOY_DIR/squads/${ns}/namespace.yaml"
  # Belt-and-suspenders: ensure the dashboard + contract labels exist even if an
  # admin pre-created the namespace without them.
  oc label namespace "$ns" opendatahub.io/dashboard=true \
    app.kubernetes.io/part-of=swebench-live-vllm squad="$s" split="$split" --overwrite >/dev/null
  ok "namespace ${ns} ready"
done

echo
log "Image-pull secret note:"
cat <<EOF
  The RHOAI vLLM image (${VLLM_IMAGE}) pulls from a registry that may require
  credentials. If pods report ImagePullBackOff, add a pull secret and link it to
  the namespace's default service account, e.g.:

    oc create secret docker-registry pull-secret \\
      --docker-server=<registry> --docker-username=<user> --docker-password=<token> \\
      -n <squad-namespace>
    oc secrets link default pull-secret --for=pull -n <squad-namespace>
EOF
echo
log "Next: bash scripts/02-deploy-scheduling.sh"
