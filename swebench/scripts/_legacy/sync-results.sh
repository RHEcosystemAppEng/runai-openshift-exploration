#!/usr/bin/env bash
# Sync entire /workspace from OCP cluster PVC to local repo.
#
# Usage: ./sync-results.sh

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NAMESPACE="ccamacho-test-bench"
LOCAL_DIR="$REPO_DIR/swebench/workspace"

# ── Login ─────────────────────────────────────────────────────────
if ! oc whoami >/dev/null 2>&1; then
  token_file="$SCRIPT_DIR/../token.md"
  if [[ -f "$token_file" ]]; then
    token=$(grep 'sha256~' "$token_file" | head -1 | grep -oP 'sha256~[A-Za-z0-9_-]+')
    server=$(grep -- '--server=' "$token_file" | grep -oP 'https://[^ ]+')
    oc login --token="$token" --server="$server" --insecure-skip-tls-verify=true 2>&1 | tail -1
  else
    echo "ERROR: Not logged in and no token.md found" >&2; exit 1
  fi
fi

# ── Find coordinator ──────────────────────────────────────────────
COORD=$(oc get pods -l app=benchmark-runner -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$COORD" ]]; then
  echo "ERROR: Coordinator pod not found in $NAMESPACE" >&2
  exit 1
fi
echo "Coordinator: $COORD"

# ── Sync ──────────────────────────────────────────────────────────
mkdir -p "$LOCAL_DIR"
echo "Syncing /workspace → $LOCAL_DIR ..."
oc rsync "$COORD:/workspace/" "$LOCAL_DIR/" --no-perms -n "$NAMESPACE"
echo ""
echo "=== Sync Complete ==="
du -sh "$LOCAL_DIR"
