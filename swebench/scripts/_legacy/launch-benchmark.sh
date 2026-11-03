#!/usr/bin/env bash
# One-click SWE-bench benchmark launcher for OpenShift.
#
# Deploys infrastructure, copies assets, and starts the autonomous run
# from a local machine with oc CLI access.
#
# Usage:
#   ./launch-benchmark.sh [--language go|java|lite|rust|ts-js|cpp|cs] [--parallel N] [--dry-run]

set -euo pipefail

# ── paths ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OCP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHALLENGES_DIR="$(cd "$OCP_DIR/.." && pwd)"
DEPLOY_DIR="$OCP_DIR/deploy"
BENCHMARK_DIR="$OCP_DIR/benchmark"
TOKEN_FILE="$OCP_DIR/token.md"
NAMESPACE="ccamacho-test-bench"

# ── defaults ───────────────────────────────────────────────────────
LANGUAGE="go"
PARALLEL=3
DRY_RUN=0

# ── parse flags ────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --language)  LANGUAGE="$2"; shift 2 ;;
    --parallel)  PARALLEL="$2"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)
      echo "Usage: $0 [--language go|java|lite|rust|ts-js|cpp|cs] [--parallel N] [--dry-run]"
      exit 0
      ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

VALID_LANGS="go java lite rust ts-js cpp cs"
if ! echo "$VALID_LANGS" | grep -qw "$LANGUAGE"; then
  echo "ERROR: --language must be one of: $VALID_LANGS" >&2
  exit 1
fi

# ── helpers ────────────────────────────────────────────────────────
step_count=0
step() {
  step_count=$((step_count + 1))
  echo ""
  echo "==== Step $step_count: $1 ===="
}

fail() {
  echo "FATAL: $1" >&2
  exit 1
}

check_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "'$1' not found in PATH"
}

# ── pre-flight checks ─────────────────────────────────────────────
check_cmd oc
check_cmd curl

DATASET_FILE="$CHALLENGES_DIR/swebench/$LANGUAGE/data/swebench-multilang-${LANGUAGE}.jsonl"
if [[ ! -f "$DATASET_FILE" ]]; then
  for alt in "$CHALLENGES_DIR/swebench/$LANGUAGE/data/swebench-live-${LANGUAGE}.jsonl" \
             "$CHALLENGES_DIR/swebench/$LANGUAGE/data/swebench-${LANGUAGE}.jsonl"; do
    [[ -f "$alt" ]] && DATASET_FILE="$alt" && break
  done
fi
[[ -f "$DATASET_FILE" ]] || fail "Dataset not found. Tried: swebench-multilang-${LANGUAGE}.jsonl, swebench-live-${LANGUAGE}.jsonl"
[[ -d "$DEPLOY_DIR" ]]   || fail "Deploy manifests not found: $DEPLOY_DIR"
[[ -d "$BENCHMARK_DIR" ]] || fail "Benchmark scripts not found: $BENCHMARK_DIR"

AMI_BINARY="${AMI_BINARY:-$HOME/.local/bin/ami}"
[[ -f "$AMI_BINARY" ]] || fail "AMI binary not found at $AMI_BINARY (set AMI_BINARY env var)"

INSTANCE_COUNT=$(wc -l < "$DATASET_FILE")

echo "==========================================="
echo "  SWE-bench Benchmark Launcher"
echo "==========================================="
echo "  Language:   $LANGUAGE"
echo "  Parallel:   $PARALLEL"
echo "  Dataset:    $INSTANCE_COUNT instances"
echo "  AMI binary: $AMI_BINARY"
echo "  Namespace:  $NAMESPACE"
echo "  Dry run:    $( [[ "$DRY_RUN" == 1 ]] && echo "yes" || echo "no" )"
echo "==========================================="

if [[ "$DRY_RUN" == 1 ]]; then
  echo ""
  echo "[DRY RUN] Would perform all steps below without executing."
  echo ""
fi

# ── Step 1: OCP login ─────────────────────────────────────────────
step "Login to OCP cluster"

if oc whoami >/dev/null 2>&1; then
  echo "Already logged in as: $(oc whoami)"
else
  [[ -f "$TOKEN_FILE" ]] || fail "Token file not found: $TOKEN_FILE"
  TOKEN=$(grep 'sha256~' "$TOKEN_FILE" | head -1 | grep -oP 'sha256~[A-Za-z0-9_-]+')
  SERVER=$(grep -- '--server=' "$TOKEN_FILE" | grep -oP 'https://[^ ]+')
  [[ -n "$TOKEN" ]]  || fail "Could not parse token from $TOKEN_FILE"
  [[ -n "$SERVER" ]] || fail "Could not parse server URL from $TOKEN_FILE"
  echo "Logging in to $SERVER ..."
  if [[ "$DRY_RUN" == 0 ]]; then
    oc login --token="$TOKEN" --server="$SERVER" --insecure-skip-tls-verify=true \
      || fail "oc login failed"
  fi
fi

if [[ "$DRY_RUN" == 0 ]]; then
  oc project "$NAMESPACE" 2>/dev/null || fail "Cannot switch to namespace $NAMESPACE"
fi

# ── Step 2: Apply K8s manifests ────────────────────────────────────
step "Apply K8s manifests"

echo "Applying kustomize from $DEPLOY_DIR ..."
if [[ "$DRY_RUN" == 0 ]]; then
  oc apply -k "$DEPLOY_DIR" || fail "oc apply -k failed"
  echo "Manifests applied."
else
  echo "[DRY RUN] oc apply -k $DEPLOY_DIR"
fi

# ── Step 3: Wait for vLLM pod ─────────────────────────────────────
step "Wait for vLLM pod to become Ready (model loading may take 10-30 min)"

if [[ "$DRY_RUN" == 0 ]]; then
  echo "Waiting for vLLM deployment rollout ..."
  oc rollout status deployment/vllm-qwen -n "$NAMESPACE" --timeout=3600s \
    || fail "vLLM deployment did not become ready within 60 minutes"
  echo "vLLM pod is Ready."
else
  echo "[DRY RUN] oc rollout status deployment/vllm-qwen --timeout=3600s"
fi

# ── Step 4: Wait for coordinator pod ──────────────────────────────
step "Wait for coordinator pod to become Ready"

if [[ "$DRY_RUN" == 0 ]]; then
  echo "Waiting for coordinator deployment rollout ..."
  oc rollout status deployment/benchmark-coordinator -n "$NAMESPACE" --timeout=300s \
    || fail "Coordinator deployment did not become ready"

  COORD_POD=$(oc get pods -n "$NAMESPACE" -l app=benchmark-runner \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [[ -n "$COORD_POD" ]] || fail "No coordinator pod found"
  echo "Coordinator pod: $COORD_POD"
else
  COORD_POD="benchmark-coordinator-xxxxx"
  echo "[DRY RUN] oc rollout status deployment/benchmark-coordinator --timeout=300s"
fi

# ── Step 5: Copy dataset to coordinator ────────────────────────────
step "Copy dataset to coordinator"

echo "Copying $DATASET_FILE ..."
if [[ "$DRY_RUN" == 0 ]]; then
  oc exec "$COORD_POD" -n "$NAMESPACE" -- mkdir -p /workspace/data
  DATASET_BASENAME=$(basename "$DATASET_FILE")
  oc cp "$DATASET_FILE" "$NAMESPACE/$COORD_POD:/workspace/data/$DATASET_BASENAME" \
    || fail "Failed to copy dataset"
  echo "Dataset copied."
else
  echo "[DRY RUN] oc cp $DATASET_FILE $COORD_POD:/workspace/data/"
fi

# ── Step 6: Copy AMI binary to coordinator ─────────────────────────
step "Copy AMI binary to coordinator"

echo "Copying AMI from $AMI_BINARY ..."
if [[ "$DRY_RUN" == 0 ]]; then
  oc exec "$COORD_POD" -n "$NAMESPACE" -- mkdir -p /workspace/ami
  oc cp "$AMI_BINARY" "$NAMESPACE/$COORD_POD:/workspace/ami/ami" \
    || fail "Failed to copy AMI binary"
  oc exec "$COORD_POD" -n "$NAMESPACE" -- chmod +x /workspace/ami/ami
  echo "AMI binary copied and marked executable."
else
  echo "[DRY RUN] oc cp $AMI_BINARY $COORD_POD:/workspace/ami/ami"
fi

# ── Step 7: Copy benchmark scripts to coordinator ──────────────────
step "Copy benchmark scripts to coordinator"

echo "Copying benchmark scripts from $BENCHMARK_DIR ..."
if [[ "$DRY_RUN" == 0 ]]; then
  oc exec "$COORD_POD" -n "$NAMESPACE" -- mkdir -p /workspace/scripts
  for script in "$BENCHMARK_DIR"/*; do
    [[ -f "$script" ]] || continue
    BASENAME=$(basename "$script")
    oc cp "$script" "$NAMESPACE/$COORD_POD:/workspace/scripts/$BASENAME"
  done
  oc exec "$COORD_POD" -n "$NAMESPACE" -- chmod +x /workspace/scripts/*.sh 2>/dev/null || true
  echo "Benchmark scripts copied."
else
  echo "[DRY RUN] oc cp $BENCHMARK_DIR/* $COORD_POD:/workspace/scripts/"
fi

# ── Step 8: Install jq on coordinator ──────────────────────────────
step "Install jq on coordinator"

if [[ "$DRY_RUN" == 0 ]]; then
  HAS_JQ=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- which jq 2>/dev/null || echo "")
  if [[ -z "$HAS_JQ" ]]; then
    echo "Downloading jq static binary ..."
    oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c '
      curl -fsSL -o /usr/local/bin/jq \
        "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" \
      && chmod +x /usr/local/bin/jq \
      && jq --version
    ' || fail "Failed to install jq on coordinator"
    echo "jq installed."
  else
    echo "jq already available at $HAS_JQ"
  fi
else
  echo "[DRY RUN] install jq static binary on coordinator"
fi

# ── Step 9: Verify vLLM health from coordinator ───────────────────
step "Verify vLLM health from inside coordinator"

VLLM_INTERNAL="http://qwen-inference.${NAMESPACE}.svc.cluster.local:8000/v1"

if [[ "$DRY_RUN" == 0 ]]; then
  echo "Checking $VLLM_INTERNAL/models from coordinator ..."
  HTTP_CODE=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- \
    curl -sk -o /dev/null -w '%{http_code}' "$VLLM_INTERNAL/models" \
    -H "Authorization: Bearer swebench-token" 2>/dev/null || echo "000")
  if [[ "$HTTP_CODE" != "200" ]]; then
    fail "vLLM not healthy from coordinator (HTTP $HTTP_CODE). Check vLLM pod logs."
  fi
  MODELS=$(oc exec "$COORD_POD" -n "$NAMESPACE" -- \
    curl -sk "$VLLM_INTERNAL/models" -H "Authorization: Bearer swebench-token" 2>/dev/null \
    | jq -r '.data[].id' 2>/dev/null || echo "unknown")
  echo "vLLM healthy (HTTP 200). Serving: $MODELS"
else
  echo "[DRY RUN] curl $VLLM_INTERNAL/models from coordinator"
fi

# ── Step 10: Start autonomous benchmark run ────────────────────────
step "Start autonomous benchmark run"

echo "Launching run-all-k8s.sh $LANGUAGE --parallel $PARALLEL --skip-existing ..."
if [[ "$DRY_RUN" == 0 ]]; then
  oc exec "$COORD_POD" -n "$NAMESPACE" -- bash -c "
    nohup /workspace/scripts/run-all-k8s.sh $LANGUAGE \
      --parallel $PARALLEL \
      --skip-existing \
      > /workspace/logs/benchmark-${LANGUAGE}-\$(date +%Y%m%d_%H%M%S).log 2>&1 &
    echo \$!
  " | { read -r PID; echo "Benchmark started with PID $PID"; }
  echo "Autonomous run is now in progress."
else
  echo "[DRY RUN] nohup run-all-k8s.sh $LANGUAGE --parallel $PARALLEL --skip-existing"
fi

# ── Step 11: Print monitoring commands ─────────────────────────────
step "Status monitoring commands"

echo ""
echo "The benchmark is running autonomously. Use these commands to monitor:"
echo ""
echo "  # Watch benchmark log (live)"
echo "  oc exec $COORD_POD -n $NAMESPACE -- tail -f /workspace/logs/benchmark-${LANGUAGE}-*.log"
echo ""
echo "  # Check running K8s jobs"
echo "  oc get jobs -n $NAMESPACE -l app=swebench-instance"
echo ""
echo "  # Count completed results"
echo "  oc exec $COORD_POD -n $NAMESPACE -- bash -c 'find /workspace/results -name \"*.patch\" -not -empty | wc -l'"
echo ""
echo "  # Check vLLM pod"
echo "  oc get pods -n $NAMESPACE -l app=vllm-qwen"
echo ""
echo "  # Check coordinator pod"
echo "  oc get pods -n $NAMESPACE -l app=benchmark-runner"
echo ""
echo "  # Exec into coordinator"
echo "  oc exec -it $COORD_POD -n $NAMESPACE -- bash"
echo ""
echo "  # Collect results summary"
echo "  oc exec $COORD_POD -n $NAMESPACE -- /workspace/scripts/collect-results.sh"
echo ""
echo "==========================================="
echo "  Launch complete. Benchmark running."
echo "==========================================="
