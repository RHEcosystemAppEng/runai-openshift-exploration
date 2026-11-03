#!/usr/bin/env bash
# Evaluate a single SWE-bench instance patch as a K8s Job.
# Applies the agent's patch + test_patch, runs tests, produces report.json.
#
# Usage: ./eval-instance-k8s.sh <language> <instance-id> [model-slug]
#
# This replaces the Docker-based evaluation.py with a K8s-native approach.
# The eval Job uses the same instance Docker image, applies patches,
# runs the test commands, and parses FAIL_TO_PASS / PASS_TO_PASS results.
#
# Environment:
#   KUEUE_ENABLED     Emit Kueue labels + spec.suspend on the Job (default: 1).
#                     Set to 0 to run on a cluster without Kueue (no labels/suspend).
#   LOCAL_QUEUE       Kueue LocalQueue name for the queue-name label (default: default)
#   PRIORITY_CLASS    Kueue WorkloadPriorityClass for the priority-class label
#                     (default: squad-standard)

set -euo pipefail

LANGUAGE="${1:?Usage: $0 <language> <instance-id> [model-slug]}"
INSTANCE_ID="${2:?Usage: $0 <language> <instance-id> [model-slug]}"
MODEL_SLUG="${3:-qwen-qwen3-32b}"

WORKSPACE="${WORKSPACE:-/workspace}"
NAMESPACE="${NAMESPACE:-ccamacho-test-bench}"
JSONL_FILE="$WORKSPACE/data/swebench-multilang-${LANGUAGE}.jsonl"
RESULTS_DIR="$WORKSPACE/results/${LANGUAGE}/$MODEL_SLUG/$INSTANCE_ID"
EVAL_DIR="$WORKSPACE/eval-results/${LANGUAGE}/$MODEL_SLUG/$INSTANCE_ID"
PATCH_FILE="$RESULTS_DIR/ami-${MODEL_SLUG}-diff.patch"

export PATH="/workspace/ami:$PATH"

# ── Kueue wiring (gated by KUEUE_ENABLED; default on) ───────────────
# When enabled the eval Job carries the queue-name + priority-class labels and is
# created suspended, so Kueue admits it against the squad ClusterQueue quota.
# When KUEUE_ENABLED=0 the Job is emitted without them (runs on a non-Kueue cluster).
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

if [[ ! -f "$PATCH_FILE" ]] || [[ ! -s "$PATCH_FILE" ]]; then
  echo "SKIP $INSTANCE_ID (no patch or empty)"
  exit 0
fi

if [[ -f "$EVAL_DIR/report.json" ]]; then
  echo "SKIP $INSTANCE_ID (already evaluated)"
  exit 0
fi

INSTANCE_JSON=$(jq -c "select(.instance_id == \"$INSTANCE_ID\")" "$JSONL_FILE" | head -1)
if [[ -z "$INSTANCE_JSON" ]]; then
  echo "ERROR: Instance not found" >&2
  exit 1
fi

DOCKER_IMAGE=$(echo "$INSTANCE_JSON" | jq -r '.docker_image // ""')
TEST_PATCH=$(echo "$INSTANCE_JSON" | jq -r '.test_patch')
TEST_CMDS=$(echo "$INSTANCE_JSON" | jq -r '.test_cmds[0] // ""')
REBUILD_CMDS=$(echo "$INSTANCE_JSON" | jq -r '.rebuild_cmds[0] // ""')
PRINT_CMDS=$(echo "$INSTANCE_JSON" | jq -r '.print_cmds[0] // ""')
LOG_PARSER=$(echo "$INSTANCE_JSON" | jq -r '.log_parser // ""')
FAIL_TO_PASS=$(echo "$INSTANCE_JSON" | jq -c '.FAIL_TO_PASS')
PASS_TO_PASS=$(echo "$INSTANCE_JSON" | jq -c '.PASS_TO_PASS')
REPO=$(echo "$INSTANCE_JSON" | jq -r '.repo')

if [[ -z "$DOCKER_IMAGE" ]]; then
  DOCKER_IMAGE="starryzhang/sweb.eval.x86_64.$(echo "$INSTANCE_ID" | sed 's/__/_1776_/g' | tr '[:upper:]' '[:lower:]')"
fi

echo "EVAL $INSTANCE_ID (image: $DOCKER_IMAGE)"

mkdir -p "$EVAL_DIR"

# Write eval staging files
EVAL_STAGING="$WORKSPACE/staging/${LANGUAGE}/eval_${INSTANCE_ID}"
mkdir -p "$EVAL_STAGING"
echo "$TEST_PATCH" > "$EVAL_STAGING/test_patch.diff"
cp "$PATCH_FILE" "$EVAL_STAGING/agent_patch.diff"
echo "$REBUILD_CMDS" > "$EVAL_STAGING/rebuild_cmds.txt"
echo "$TEST_CMDS" > "$EVAL_STAGING/test_cmds.txt"

# Write the test parser + report generator
cat > "$EVAL_STAGING/parse_results.py" << 'PYEOF'
import json, sys, re, os

log_file = sys.argv[1]
f2p_json = sys.argv[2]
p2p_json = sys.argv[3]
output_file = sys.argv[4]
log_parser = sys.argv[5] if len(sys.argv) > 5 else ""

with open(log_file, errors='replace') as f:
    log = f.read()

f2p_ids = json.loads(f2p_json)
p2p_ids = json.loads(p2p_json)

def check_test_status(test_id, log_text, language):
    """Check if a test passed based on log output."""
    if language == "go":
        if f"--- PASS: {test_id}" in log_text or f"ok  \t" in log_text:
            for line in log_text.split('\n'):
                if test_id in line and ('PASS' in line or '--- PASS' in line):
                    return 'pass'
                if test_id in line and ('FAIL' in line or '--- FAIL' in line):
                    return 'fail'
        if f"--- FAIL: {test_id}" in log_text:
            return 'fail'
        # Check for "ok" in package-level results
        return 'pass' if f"--- PASS: {test_id}" in log_text else 'fail'
    elif language == "java":
        if f"Tests run:" in log_text:
            for line in log_text.split('\n'):
                if test_id in line and 'PASS' in line.upper():
                    return 'pass'
        return 'fail'
    else:
        # Generic: look for PASSED/FAILED markers
        for line in log_text.split('\n'):
            if test_id in line:
                if 'PASSED' in line or 'PASS' in line or 'ok' in line:
                    return 'pass'
                if 'FAILED' in line or 'FAIL' in line:
                    return 'fail'
        return 'fail'

language = os.environ.get('LANGUAGE', 'go')

f2p_success = []
f2p_failure = []
for tid in f2p_ids:
    status = check_test_status(tid, log, language)
    if status == 'pass':
        f2p_success.append(tid)
    else:
        f2p_failure.append(tid)

p2p_success = []
p2p_failure = []
for tid in p2p_ids:
    status = check_test_status(tid, log, language)
    if status == 'pass':
        p2p_success.append(tid)
    else:
        p2p_failure.append(tid)

resolved = len(f2p_success) == len(f2p_ids) and len(f2p_ids) > 0 and len(p2p_failure) == 0

report = {
    "resolved": resolved,
    "FAIL_TO_PASS": {"success": f2p_success, "failure": f2p_failure},
    "PASS_TO_PASS": {"success": p2p_success, "failure": p2p_failure}
}

with open(output_file, 'w') as f:
    json.dump(report, f, indent=2)

status = "RESOLVED" if resolved else "FAILED"
print(f"{status}: F2P {len(f2p_success)}/{len(f2p_ids)}, P2P regressions: {len(p2p_failure)}")
PYEOF

# Create the eval K8s Job
JOB_NAME="eval-$(echo "$INSTANCE_ID" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-55)"
oc delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

cat <<EVALJOB | oc apply -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $NAMESPACE
  labels:
    app: swebench-eval
    language: $LANGUAGE
$KUEUE_LABELS
spec:
$KUEUE_SUSPEND
  backoffLimit: 0
  activeDeadlineSeconds: 7200
  ttlSecondsAfterFinished: 1800
  template:
    metadata:
      labels:
        app: swebench-eval
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
        - name: eval
          image: $DOCKER_IMAGE
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -eo pipefail
              echo "=== EVAL: $INSTANCE_ID ==="

              # Copy testbed to writable location
              cp -a /testbed /tmp/testbed 2>/dev/null || true
              REPO_DIR=/tmp/testbed
              [ ! -d "\$REPO_DIR/.git" ] && REPO_DIR=\$(find /tmp/testbed -maxdepth 2 -type d -name .git -print -quit 2>/dev/null | sed 's/\/.git\$//')
              [ -z "\$REPO_DIR" ] && { echo "ERROR: No repo found"; exit 1; }
              git config --global --add safe.directory "\$REPO_DIR"
              git config --global user.email swebench@test.local
              git config --global user.name SWE-bench
              cd "\$REPO_DIR"

              # 1. Apply the AGENT's patch first
              echo "Applying agent patch..."
              git apply --allow-empty /eval-staging/agent_patch.diff 2>&1 || \
                git apply --3way /eval-staging/agent_patch.diff 2>&1 || \
                patch -p1 --force --no-backup-if-mismatch < /eval-staging/agent_patch.diff 2>&1 || {
                echo "WARNING: Agent patch failed to apply"
              }
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true

              # 2. Apply the TEST patch
              echo "Applying test patch..."
              git apply --allow-empty /eval-staging/test_patch.diff 2>&1 || \
                git apply --3way /eval-staging/test_patch.diff 2>&1 || \
                patch -p1 --force --no-backup-if-mismatch < /eval-staging/test_patch.diff 2>&1 || {
                echo "WARNING: Test patch failed to apply"
              }
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true

              # 3. Rebuild if needed
              REBUILD=\$(cat /eval-staging/rebuild_cmds.txt 2>/dev/null || true)
              if [ -n "\$REBUILD" ]; then
                echo "Rebuilding..."
                cd /tmp/testbed
                eval "\$REBUILD" 2>&1 | tail -20 || true
                cd "\$REPO_DIR"
              fi

              # 4. Run tests
              TEST_CMD=\$(cat /eval-staging/test_cmds.txt 2>/dev/null || true)
              if [ -z "\$TEST_CMD" ]; then
                echo "ERROR: No test command"
                echo '{}' > /eval-results/test-output.log
              else
                echo "Running tests: \$TEST_CMD"
                cd "\$REPO_DIR"
                timeout 1800 bash -c "\$TEST_CMD" > /eval-results/test-output.log 2>&1 || true
              fi

              # 5. Parse results
              echo "Parsing results..."
              export LANGUAGE="$LANGUAGE"
              python3 /eval-staging/parse_results.py \
                /eval-results/test-output.log \
                '$FAIL_TO_PASS' \
                '$PASS_TO_PASS' \
                /eval-results/report.json \
                "$LOG_PARSER" 2>&1 || echo "Parse failed"

              echo "Eval complete for $INSTANCE_ID"
              [ -f /eval-results/report.json ] && cat /eval-results/report.json
          env:
            - name: HOME
              value: /tmp
          volumeMounts:
            - name: workspace
              mountPath: /eval-staging
              subPath: staging/${LANGUAGE}/eval_${INSTANCE_ID}
              readOnly: true
            - name: workspace
              mountPath: /eval-results
              subPath: eval-results/${LANGUAGE}/$MODEL_SLUG/$INSTANCE_ID
            - name: dshm
              mountPath: /dev/shm
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
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 5Gi
EVALJOB

echo "Eval job $JOB_NAME created. Waiting..."
oc wait --for=condition=complete "job/$JOB_NAME" -n "$NAMESPACE" --timeout=7200s 2>/dev/null || {
  echo "Eval job timed out or failed"
}

# Show result
if [[ -f "$EVAL_DIR/report.json" ]]; then
  echo ""
  RESOLVED=$(python3 -c "import json; r=json.load(open('$EVAL_DIR/report.json')); print('RESOLVED' if r.get('resolved') else 'FAILED')" 2>/dev/null)
  echo "=== $RESOLVED: $INSTANCE_ID ==="
  cat "$EVAL_DIR/report.json"
else
  echo "WARNING: No report.json produced"
fi
