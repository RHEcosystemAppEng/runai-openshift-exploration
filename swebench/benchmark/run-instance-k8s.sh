#!/usr/bin/env bash
# Run a single SWE-bench instance as a K8s Job (replaces docker run).
# Designed to run FROM the coordinator pod, creating Jobs in the same namespace.
#
# Usage: ./run-instance-k8s.sh <language> <instance-id>
#
# Environment:
#   AI_MODEL          Model name (default: Qwen/Qwen3-32B)
#   AI_API_KEY        API key (default: swebench-token)
#   AI_BASE_URL   vLLM endpoint (default: internal service URL)
#   MAX_TURNS         Max agent turns (default: 200)
#   SKIP_EXISTING     Skip if result already exists
#   SKIP_EVAL         Skip evaluation after run
#   KUEUE_ENABLED     Emit Kueue labels + spec.suspend on the Job (default: 1).
#                     Set to 0 to run on a cluster without Kueue (no labels/suspend).
#   LOCAL_QUEUE       Kueue LocalQueue name for the queue-name label (default: default)
#   PRIORITY_CLASS    Kueue WorkloadPriorityClass for the priority-class label
#                     (default: squad-standard)

set -euo pipefail

LANGUAGE="${1:?Usage: $0 <language> <instance-id>}"
INSTANCE_ID="${2:?Usage: $0 <language> <instance-id>}"

WORKSPACE="${WORKSPACE:-/workspace}"
NAMESPACE="${NAMESPACE:-ccamacho-test-bench}"
MODEL="${AI_MODEL:-Qwen/Qwen3-32B}"
MODEL_SLUG="$(echo "$MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')"
MAX_TURNS="${MAX_TURNS:-200}"
API_KEY="${AI_API_KEY:-swebench-token}"
BASE_URL="${AI_BASE_URL:-http://qwen-inference.ccamacho-test-bench.svc.cluster.local:8000/v1}"

# ── Kueue wiring (gated by KUEUE_ENABLED; default on) ───────────────
# When enabled the Job carries the queue-name + priority-class labels and is
# created suspended, so Kueue admits it against the squad ClusterQueue quota.
# When KUEUE_ENABLED=0 the Job is emitted without them (runs on a non-Kueue
# cluster exactly as before).
KUEUE_ENABLED="${KUEUE_ENABLED:-1}"
LOCAL_QUEUE="${LOCAL_QUEUE:-default}"
PRIORITY_CLASS="${PRIORITY_CLASS:-squad-standard}"
KUEUE_LABELS=""
KUEUE_SUSPEND=""
if [[ "$KUEUE_ENABLED" == "1" ]]; then
  KUEUE_LABELS="    kueue.x-k8s.io/queue-name: ${LOCAL_QUEUE}
    kueue.x-k8s.io/priority-class: ${PRIORITY_CLASS}"
  KUEUE_SUSPEND="  suspend: true"
fi

JSONL_FILE="$WORKSPACE/data/swebench-multilang-${LANGUAGE}.jsonl"
AMI_BINARY="$WORKSPACE/ami/ami"
RESULTS_DIR="$WORKSPACE/results/$MODEL_SLUG/$INSTANCE_ID"
STAGING_DIR="$WORKSPACE/staging/$INSTANCE_ID"

# ── skip check ──────────────────────────────────────────────────────
if [[ "${SKIP_EXISTING:-0}" == "1" && -f "$RESULTS_DIR/ami-${MODEL_SLUG}-diff.patch" ]]; then
  echo "Skipping $INSTANCE_ID (already attempted)"
  exit 0
fi

# ── look up instance ────────────────────────────────────────────────
if [[ ! -f "$JSONL_FILE" ]]; then
  echo "ERROR: Dataset not found at $JSONL_FILE" >&2
  exit 1
fi

INSTANCE_JSON=$(jq -c "select(.instance_id == \"$INSTANCE_ID\")" "$JSONL_FILE" | head -1)
if [[ -z "$INSTANCE_JSON" ]]; then
  echo "ERROR: Instance '$INSTANCE_ID' not found" >&2
  exit 1
fi

REPO=$(echo "$INSTANCE_JSON" | jq -r '.repo')
PROBLEM_STATEMENT=$(echo "$INSTANCE_JSON" | jq -r '.problem_statement')
TEST_PATCH=$(echo "$INSTANCE_JSON" | jq -r '.test_patch')
HINTS_TEXT=$(echo "$INSTANCE_JSON" | jq -r '.hints_text // ""')
FAIL_TO_PASS=$(echo "$INSTANCE_JSON" | jq -c '.FAIL_TO_PASS')
REBUILD_CMDS=$(echo "$INSTANCE_JSON" | jq -r '.rebuild_cmds[0] // ""')
TEST_CMDS=$(echo "$INSTANCE_JSON" | jq -r '.test_cmds[0] // ""')
DOCKER_IMAGE=$(echo "$INSTANCE_JSON" | jq -r '.docker_image // ""')

if [[ -z "$DOCKER_IMAGE" ]]; then
  DOCKER_IMAGE="starryzhang/sweb.eval.x86_64.$(echo "$INSTANCE_ID" | sed 's/__/_1776_/g' | tr '[:upper:]' '[:lower:]')"
fi

F2P_TEST_LIST=$(echo "$FAIL_TO_PASS" | jq -r '.[0:10] | .[]')
F2P_COUNT=$(echo "$FAIL_TO_PASS" | jq 'length')

echo "Instance:  $INSTANCE_ID"
echo "Repo:      $REPO"
echo "Language:  $LANGUAGE"
echo "Docker:    $DOCKER_IMAGE"
echo "Model:     $MODEL"
echo "Endpoint:  $BASE_URL"

# ── build prompt ────────────────────────────────────────────────────
PROMPT="You are fixing a bug in the $REPO repository ($LANGUAGE).

## Bug Report

$PROBLEM_STATEMENT"

if [[ -n "$HINTS_TEXT" && "$HINTS_TEXT" != "null" ]]; then
  PROMPT="$PROMPT

## Hints

$HINTS_TEXT"
fi

PROMPT="$PROMPT

## Failing Tests

These tests currently FAIL. Your fix must make them pass:
\`\`\`
$F2P_TEST_LIST
\`\`\`"

if [[ -n "$TEST_CMDS" && "$TEST_CMDS" != "null" ]]; then
  PROMPT="$PROMPT

## Test Command

To run tests:
\`\`\`
$TEST_CMDS
\`\`\`"
fi

if [[ -n "$REBUILD_CMDS" && "$REBUILD_CMDS" != "null" ]]; then
  PROMPT="$PROMPT

## Build Command

To rebuild after changes:
\`\`\`
$REBUILD_CMDS
\`\`\`"
fi

PROMPT="$PROMPT

## Workflow

1. Run the failing test(s) first to see the exact error.
2. Read the failing test code to understand what behavior is expected.
3. Use grep to find the source code responsible for the failure.
4. Read the relevant source file(s). Identify the EXACT line(s) that need to change.
5. Make ONE small, precise edit. A correct bug fix is almost always 1-5 lines.
6. Rebuild if needed, then run ONLY the failing tests again.
7. If the failing tests pass → STOP IMMEDIATELY. You are done.
8. If tests still fail → re-read the error, try a different approach.

## Rules

1. SURGICAL PRECISION. Change only the lines that cause the bug. 1-5 lines.
2. ONE BUG, ONE FIX. Do not refactor or improve anything.
3. DO NOT MODIFY TESTS.
4. USE file_edit with small, precise old_string/new_string.
5. STOP WHEN TESTS PASS.
6. NEVER USE BASH REDIRECTS TO WRITE FILES.

The repository is already cloned at the correct commit. You are in the repo root directory."

# ── write staging files ─────────────────────────────────────────────
mkdir -p "$STAGING_DIR" "$RESULTS_DIR"
echo "$TEST_PATCH" > "$STAGING_DIR/test_patch.diff"
echo "$PROMPT" > "$STAGING_DIR/prompt.txt"
echo "$REBUILD_CMDS" > "$STAGING_DIR/rebuild_cmds.txt"
cat > "$STAGING_DIR/ami-config.json" << 'AMICONF'
{"tokenBudget": 200000}
AMICONF

# ── create K8s Job ──────────────────────────────────────────────────
JOB_NAME="swebench-$(echo "$INSTANCE_ID" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-60)"

# Delete any previous job with this name
oc delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

cat <<JOBYAML | oc apply -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: swebench-instance
    instance: $(echo "$INSTANCE_ID" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63)
    language: $LANGUAGE
$KUEUE_LABELS
spec:
$KUEUE_SUSPEND
  backoffLimit: 0
  activeDeadlineSeconds: 10800
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: swebench-instance
    spec:
      restartPolicy: Never
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: benchmark-runner
            topologyKey: kubernetes.io/hostname
      containers:
        - name: instance
          image: $DOCKER_IMAGE
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail

              # Auto-detect repo location
              if [ -d /testbed/.git ]; then
                REPO_DIR=/testbed
              elif [ -d /testbed/repo/.git ]; then
                REPO_DIR=/testbed/repo
              else
                FOUND=\$(find /testbed -maxdepth 2 -mindepth 2 -type d -name .git -print -quit 2>/dev/null || true)
                REPO_DIR="\${FOUND%/.git}"
              fi
              [ -z "\$REPO_DIR" ] && echo "ERROR: No git repo found" >&2 && exit 1
              git config --global --add safe.directory "\$REPO_DIR"
              git config --global user.email "swebench@test.local"
              git config --global user.name "SWE-bench"

              # Apply test patch
              cd "\$REPO_DIR"
              echo "Applying test patch..."
              git apply --allow-empty /staging/test_patch.diff 2>&1 || \
                git apply --3way /staging/test_patch.diff 2>&1 || \
                patch -p1 --force --no-backup-if-mismatch < /staging/test_patch.diff 2>&1 || true
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true
              git add -A && git commit --no-verify --quiet -m "test_patch" 2>/dev/null || true
              TEST_PATCH_COMMIT=\$(git rev-parse HEAD)

              # Pre-build
              REBUILD_CMDS=\$(cat /staging/rebuild_cmds.txt)
              if [ -n "\$REBUILD_CMDS" ]; then
                echo "Building project..."
                cd /testbed
                eval "\$REBUILD_CMDS" 2>&1 | tail -20 || true
              fi

              # Run AMI
              cd "\$REPO_DIR"
              echo "Running AMI ($MODEL)..."
              /workspace/ami/ami \
                --api-key "$API_KEY" \
                --model "$MODEL" \
                --prompt "\$(cat /staging/prompt.txt)" \
                --max-turns $MAX_TURNS \
                --config /staging/ami-config.json \
                --yolo \
                --output-format jsonl \
                --quiet 2>/results/ami-stderr.log | tee /results/ami-output.jsonl > /dev/null || true

              # Capture diff
              cd "\$REPO_DIR"
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true
              rm -rf "\$REPO_DIR/.superinference" "\$REPO_DIR/.claude" 2>/dev/null || true
              git add -A 2>/dev/null || true
              git commit --no-verify --quiet -m "agent_changes" 2>/dev/null || true
              AGENT_HEAD=\$(git rev-parse HEAD)
              git --no-pager diff "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" \
                -- ':!*.rej' ':!*.orig' ':!.superinference/' ':!.claude/' ':!*.jsonl' \
                > /results/agent.patch 2>/dev/null || true

              echo "Container work complete."
          env:
            - name: AI_API_KEY
              value: "$API_KEY"
            - name: AI_PROVIDER
              value: "openai"
            - name: AI_BASE_URL
              value: "$BASE_URL"
            - name: OPENAI_API_KEY
              value: "$API_KEY"
            - name: HOME
              value: /tmp
          volumeMounts:
            - name: workspace
              mountPath: /workspace
              readOnly: true
            - name: workspace
              mountPath: /staging
              subPath: staging/$INSTANCE_ID
              readOnly: true
            - name: workspace
              mountPath: /results
              subPath: results/$MODEL_SLUG/$INSTANCE_ID
          resources:
            requests:
              cpu: "2"
              memory: 4Gi
            limits:
              cpu: "8"
              memory: 16Gi
      volumes:
        - name: workspace
          persistentVolumeClaim:
            claimName: benchmark-workspace
JOBYAML

echo ""
echo "Job $JOB_NAME created. Monitoring..."

# ── wait for job completion ─────────────────────────────────────────
oc wait --for=condition=complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout=10800s 2>/dev/null || {
  STATUS=$(oc get job "$JOB_NAME" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
  echo "Job ended with status: $STATUS"
}

# ── rename output files ─────────────────────────────────────────────
if [[ -f "$RESULTS_DIR/agent.patch" ]]; then
  mv "$RESULTS_DIR/agent.patch" "$RESULTS_DIR/ami-${MODEL_SLUG}-diff.patch" 2>/dev/null || true
fi
if [[ -f "$RESULTS_DIR/ami-output.jsonl" ]]; then
  mv "$RESULTS_DIR/ami-output.jsonl" "$RESULTS_DIR/ami-${MODEL_SLUG}-output.jsonl" 2>/dev/null || true
fi

# ── extract metrics ─────────────────────────────────────────────────
AMI_JSONL="$RESULTS_DIR/ami-${MODEL_SLUG}-output.jsonl"
if [[ -f "$AMI_JSONL" ]]; then
  { grep '"type":"usage_update"' "$AMI_JSONL" || true; } | tail -1 > "$RESULTS_DIR/ami-usage.json"
  TURNS=$(jq -r '.stats.turnCount // 0' "$RESULTS_DIR/ami-usage.json" 2>/dev/null || echo 0)
  COST=$(jq -r '.stats.totalCost // 0' "$RESULTS_DIR/ami-usage.json" 2>/dev/null || echo 0)
  TOKENS=$(jq -r '.stats.totalTokens // 0' "$RESULTS_DIR/ami-usage.json" 2>/dev/null || echo 0)
else
  TURNS=0; COST=0; TOKENS=0
fi

cat > "$RESULTS_DIR/ami-${MODEL_SLUG}.json" <<RESULT
{
  "runner": "ami",
  "model": "$MODEL",
  "provider": "openai",
  "language": "$LANGUAGE",
  "execution": "k8s-job",
  "instanceId": "$INSTANCE_ID",
  "repo": "$REPO",
  "turns": $TURNS,
  "estimatedCost": $COST,
  "tokens": {"total": $TOKENS},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
RESULT

PATCH_SIZE=0
[[ -f "$RESULTS_DIR/ami-${MODEL_SLUG}-diff.patch" ]] && PATCH_SIZE=$(wc -c < "$RESULTS_DIR/ami-${MODEL_SLUG}-diff.patch")

echo "Done: $INSTANCE_ID — patch=${PATCH_SIZE}B, turns=$TURNS, cost=\$$COST"
