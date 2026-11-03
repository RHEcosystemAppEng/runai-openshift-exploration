#!/usr/bin/env bash
# Autonomous SWE-bench K8s benchmark runner.
# Runs unattended for up to 7 days on an OpenShift cluster.
# Replaces Docker containers with K8s Jobs.
#
# Phase 1: Run all instances (skips already-resolved in verified/)
# Phase 2: Retry failed instances up to 10 rounds
# Stop:    10 consecutive rounds with 0 new flips
# Archive: After each run, move failed instances to runs/run{N}/, keep only resolved in verified/
#
# Usage: nohup bash autonomous-k8s-monitor.sh <language> > /workspace/logs/run.log 2>&1 &
#   Languages: go (138), lite (300), java (109), rust (94), ts-js (204), cpp, cs
#
# Output: /workspace/verified/<language>/<model-slug>/<instance-id>/  (only resolved instances)
#         /workspace/runs/run{N}/<instance-id>/                      (failed instances, archived)
#
# Environment (Kueue wiring for the agent + eval Jobs this monitor generates):
#   KUEUE_ENABLED     Emit Kueue labels + spec.suspend on every Job (default: 1).
#                     Set to 0 to run on a cluster without Kueue (no labels/suspend).
#   LOCAL_QUEUE       Kueue LocalQueue name for the queue-name label (default: default)
#   PRIORITY_CLASS    Kueue WorkloadPriorityClass for the priority-class label
#                     (default: squad-standard)

set -o pipefail

# Ensure workspace tools (jq, oc, ami) are on PATH
export PATH="/workspace/bin:/workspace/ami:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

# ═══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════

WORKSPACE="${WORKSPACE:-/workspace}"
NAMESPACE="${NAMESPACE:-ccamacho-test-bench}"
LANGUAGE="${1:-go}"
MODEL="${AI_MODEL:-Qwen/Qwen3-32B}"
MODEL_SLUG="$(echo "$MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9.-]/-/g')"
CONFIG_TAG="${CONFIG_TAG:-}"
PARALLEL="${PARALLEL:-4}"
MAX_RETRIES=10
MAX_TURNS="${MAX_TURNS:-100}"
HUNG_THRESHOLD_SEC=14400  # 4 hours — matches ~100 turns at 2-2.5 min/turn
STATUS_INTERVAL_SEC=60    # log status every 60s

API_KEY="${AI_API_KEY:-swebench-token}"
BASE_URL="${AI_BASE_URL:-http://qwen-inference.ccamacho-test-bench.svc.cluster.local:8000/v1}"
PROVIDER="${AI_PROVIDER:-openai}"

JSONL_FILE="${JSONL_FILE:-$WORKSPACE/data/swebench-multilang-${LANGUAGE}.jsonl}"
if [[ ! -f "$JSONL_FILE" ]]; then
  # Fallback: try alternate naming conventions (e.g., swebench-live-lite.jsonl)
  for alt in "$WORKSPACE/data/swebench-live-${LANGUAGE}.jsonl" \
             "$WORKSPACE/data/swebench-${LANGUAGE}.jsonl"; do
    if [[ -f "$alt" ]]; then
      JSONL_FILE="$alt"
      break
    fi
  done
fi
if [[ ! -f "$JSONL_FILE" ]]; then
  echo "ERROR: Dataset not found: $JSONL_FILE" >&2
  echo "Usage: $0 <language>  (go, lite, java, rust, ts-js, cpp, cs)" >&2
  echo "  Or set JSONL_FILE=/path/to/dataset.jsonl" >&2
  exit 1
fi
TOTAL_INSTANCES=$(wc -l < "$JSONL_FILE")
AMI_BINARY="$WORKSPACE/ami/ami"

# Directory layout:
# Directory layout:
#   verified/<lang>/<model>/<instance>/  ← shared golden set (same model, all configs)
#   runs/<lang>/<model>[-tag]/runN/      ← archived failures per config+round
# CONFIG_TAG only affects runs/ and logs, NOT verified/ — so all configs
# share the same resolved pool and never re-run solved instances.
VERIFIED_DIR="$WORKSPACE/verified/${LANGUAGE}/$MODEL_SLUG"
RUNS_TAG="$MODEL_SLUG"
[[ -n "$CONFIG_TAG" ]] && RUNS_TAG="${MODEL_SLUG}-${CONFIG_TAG}"
RUNS_DIR="$WORKSPACE/runs/${LANGUAGE}/$RUNS_TAG"
LOG_DIR="$WORKSPACE/logs"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOG_FILE="$LOG_DIR/autonomous-${LANGUAGE}-${RUNS_TAG}-${TIMESTAMP}.log"

PVC_CLAIM="${PVC_CLAIM:-benchmark-workspace}"

# ── Kueue wiring (gated by KUEUE_ENABLED; default on) ────────────────────
# When enabled, every agent + eval Job this monitor generates carries the
# queue-name + priority-class labels and is created suspended, so Kueue admits
# it against the squad ClusterQueue quota. When KUEUE_ENABLED=0 the Jobs are
# emitted without them (runs on a non-Kueue cluster exactly as before).
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

mkdir -p "$VERIFIED_DIR" "$RUNS_DIR" "$LOG_DIR" "$WORKSPACE/staging/$LANGUAGE"

# ═══════════════════════════════════════════════════════════════════════
# LOGGING
# ═══════════════════════════════════════════════════════════════════════

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════
# COUNTING HELPERS
# ═══════════════════════════════════════════════════════════════════════

count_resolved() {
  local resolved=0
  for d in "$VERIFIED_DIR"/*/; do
    [[ ! -d "$d" ]] && continue
    if [[ -f "${d}eval-results/report.json" ]]; then
      local r
      r=$(python3 -c "import json; print(json.load(open('${d}eval-results/report.json')).get('resolved',False))" 2>/dev/null)
      [[ "$r" == "True" ]] && resolved=$((resolved + 1))
    fi
  done
  echo "$resolved"
}

count_evaluated() {
  local total=0
  for d in "$VERIFIED_DIR"/*/; do
    [[ ! -d "$d" ]] && continue
    local name
    name=$(basename "$d")
    [[ "$name" == run* ]] && continue
    [[ -f "${d}eval-results/report.json" ]] && total=$((total + 1))
  done
  echo "$total"
}

count_with_results() {
  local total=0
  for d in "$VERIFIED_DIR"/*/; do
    [[ ! -d "$d" ]] && continue
    local name
    name=$(basename "$d")
    [[ "$name" == run* ]] && continue
    total=$((total + 1))
  done
  echo "$total"
}

# ═══════════════════════════════════════════════════════════════════════
# K8s JOB HELPERS
# ═══════════════════════════════════════════════════════════════════════

job_name_for_instance() {
  local instance_id="$1"
  echo "swebench-$(echo "$instance_id" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-60)"
}

count_active_jobs() {
  local count
  count=$(timeout 30 oc get jobs -l app=swebench-instance -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.status.active}{"\n"}{end}' 2>/dev/null | \
    awk '$1 > 0 {c++} END {print c+0}')
  echo "$count"
}

kill_hung_jobs() {
  local killed=0
  local now_epoch
  now_epoch=$(date +%s)

  while IFS=' ' read -r job_name start_time; do
    [[ -z "$job_name" ]] && continue
    local start_epoch
    start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo 0)
    [[ "$start_epoch" -eq 0 ]] && continue
    local age=$(( now_epoch - start_epoch ))
    if [[ $age -gt $HUNG_THRESHOLD_SEC ]]; then
      log "KILLING hung job $job_name (age: ${age}s > ${HUNG_THRESHOLD_SEC}s)"
      timeout 30 oc delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
      killed=$((killed + 1))
    fi
  done < <(timeout 30 oc get jobs -l app=swebench-instance -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.metadata.creationTimestamp}{"\n"}{end}' 2>/dev/null || true)

  [[ $killed -gt 0 ]] && log "Killed $killed hung jobs"
}

cleanup_completed_jobs() {
  timeout 30 oc delete jobs -l app=swebench-instance -n "$NAMESPACE" \
    --field-selector=status.successful=1 2>/dev/null || true
}

wait_for_job() {
  local job_name="$1"
  local timeout="${2:-10800}"
  timeout $((timeout + 30)) oc wait --for=condition=complete "job/$job_name" -n "$NAMESPACE" \
    --timeout="${timeout}s" 2>/dev/null || {
    local status
    status=$(timeout 30 oc get job "$job_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "Unknown")
    log "Job $job_name ended: $status"
  }
}

# ═══════════════════════════════════════════════════════════════════════
# STAGING: prepare per-instance files on PVC
# ═══════════════════════════════════════════════════════════════════════

stage_instance() {
  local instance_id="$1"
  local staging_dir="$WORKSPACE/staging/$LANGUAGE/$instance_id"
  local eval_staging_dir="$WORKSPACE/staging/$LANGUAGE/${instance_id}-eval"
  local result_dir="$VERIFIED_DIR/$instance_id/results"

  mkdir -p "$staging_dir" "$eval_staging_dir" "$result_dir"

  local instance_json
  instance_json=$(jq -c "select(.instance_id == \"$instance_id\")" "$JSONL_FILE" | head -1)
  [[ -z "$instance_json" ]] && { log "ERROR: Instance $instance_id not found in dataset"; return 1; }

  local repo problem_statement test_patch hints_text fail_to_pass rebuild_cmds test_cmds
  repo=$(echo "$instance_json" | jq -r '.repo')
  problem_statement=$(echo "$instance_json" | jq -r '.problem_statement')
  test_patch=$(echo "$instance_json" | jq -r '.test_patch')
  hints_text=$(echo "$instance_json" | jq -r '.hints_text // ""')
  fail_to_pass=$(echo "$instance_json" | jq -c '.FAIL_TO_PASS')
  rebuild_cmds=$(echo "$instance_json" | jq -r '.rebuild_cmds[0] // ""' | sed 's|/testbed|/tmp/testbed|g')
  test_cmds=$(echo "$instance_json" | jq -r '.test_cmds[0] // ""' | sed 's|/testbed|/tmp/testbed|g')

  # Build prompt (SWE-bench-Live compliant: problem_statement only)
  # Do NOT include FAIL_TO_PASS test names, hints_text, or any other
  # dataset fields — only problem_statement is allowed per protocol.
  local lang_label="$LANGUAGE"
  [[ "$LANGUAGE" == "lite" ]] && lang_label="Python"

  local prompt="You are an expert $lang_label engineer. Fix the bug described below in the \`$repo\` repository so that the failing tests pass without introducing regressions in any existing tests.

## Bug Report

$problem_statement"

  if [[ -n "$test_cmds" && "$test_cmds" != "null" ]]; then
    prompt="$prompt

## Test Command

\`\`\`
$test_cmds
\`\`\`"
  fi

  if [[ -n "$rebuild_cmds" && "$rebuild_cmds" != "null" ]]; then
    prompt="$prompt

## Build Command

\`\`\`
$rebuild_cmds
\`\`\`"
  fi

  # Language-specific ecosystem notes
  local ecosystem_notes=""
  case "$LANGUAGE" in
    go)
      ecosystem_notes="## Go Ecosystem Notes

- Run specific tests: \`go test -v -run TestName ./pkg/...\`
- Run all tests in a package: \`go test ./...\` (exit 0 = all pass, non-zero = failures)
- Check compilation without running: \`go build ./...\`
- Module root is defined in \`go.mod\`; imports must match module paths exactly
- Table-driven tests iterate subtests — a fix that breaks ANY subcase fails the test"
      ;;
    lite)
      ecosystem_notes="## Python Ecosystem Notes

- Run tests: \`pytest -xvs test_file.py::TestClass::test_method\` for a specific test
- Run all tests: \`pytest -rA\` (shows all results including passed/failed/skipped)
- Install in dev mode: \`pip install -e .\` or \`pip install -e '.[dev]'\`
- Check \`setup.py\`, \`setup.cfg\`, \`pyproject.toml\` for project config and dependencies
- Parametrized tests (\`@pytest.mark.parametrize\`) — fixing one case must not break others
- If tests use fixtures, check \`conftest.py\` files in the test directory hierarchy
- When pytest output is long, read the LAST lines for the summary (e.g. '3 passed, 1 failed')
- Read the full traceback to identify the ROOT CAUSE — do not guess from the test name alone
- ALWAYS use file_edit to change source code. Bash echo/sed/cat writes are NOT captured in the patch"
      ;;
    java)
      ecosystem_notes="## Java Ecosystem Notes

- Run tests: \`mvn test -pl module -Dtest=TestClass#testMethod\` or \`gradle test --tests TestClass.testMethod\`
- Full test suite: \`mvn test\` or \`gradle test\`
- Check \`pom.xml\` or \`build.gradle\` for project structure and dependencies"
      ;;
    *)
      ecosystem_notes="## Notes
"
      ;;
  esac

  # Language-specific test sacred rule
  local test_sacred_rule=""
  case "$LANGUAGE" in
    go)
      test_sacred_rule="TESTS ARE SACRED: NEVER modify *_test.go files or testdata/. The test defines the expected behavior. If tests use golden files (expected output snapshots), your template/format changes will cause golden file mismatches — that is EXPECTED. Verify your change is semantically correct, then STOP."
      ;;
    lite)
      test_sacred_rule="TESTS ARE SACRED: NEVER modify test files (test_*.py, *_test.py, conftest.py) or test fixtures/data. The test defines the expected behavior. If tests use snapshots or golden files, your changes will cause mismatches — that is EXPECTED. Verify your change is semantically correct, then STOP."
      ;;
    *)
      test_sacred_rule="TESTS ARE SACRED: NEVER modify test files or test data. The test defines the expected behavior."
      ;;
  esac

  prompt="$prompt

$ecosystem_notes

## MANDATORY RULES

1. $test_sacred_rule
2. ALWAYS use file_edit to modify source code. NEVER use bash echo/cat/sed/tee — bash writes are NOT captured in the patch and your fix will be LOST.
3. STOP immediately once tests pass with no regressions. Do not clean up, re-run, or narrate — call task_complete.
4. If you see 'BLOCKED' or 'guardrail' in a response, do NOT retry the same request. Rephrase using a different tool or approach.

## Workflow

STEP 1 — ANALYZE: Read the bug report above carefully. Identify the symptom and likely location.
          Use grep/find to locate the relevant source code. Read the source file(s).

STEP 2 — UNDERSTAND THE TEST: Find and read the test that covers the buggy behavior.
          The test tells you EXACTLY what the code should do.

STEP 3 — FIX: Use file_edit to make a minimal, precise change. Most bugs need 1-5 lines.
          EDIT CHECKPOINT — CRITICAL: You MUST call file_edit at least once before turn 5.
          Do NOT spend more than 4 turns reading/searching. Make your best-guess edit EARLY.
          An imperfect edit that can be refined beats endless analysis. EDIT FIRST, then iterate.

STEP 4 — VERIFY: Run the test command to check your fix. Read the FULL output including tracebacks.
          If tests fail, change code first (do NOT re-run the same test without code changes).
          After 3 failed attempts at the same approach, try a COMPLETELY different strategy.

STEP 5 — REGRESSION CHECK: Run the full test suite. If regressions, revert and make a more surgical change.

STEP 6 — DONE: All tests pass → STOP immediately.

NO WEB SEARCH: NEVER use web_search or web_fetch. The fix is in the local repository.
NO LOOPING: Never run the same command twice with identical arguments.
NO NARRATION: Do not explain what you will do. Just call the tool directly.

The repository is already cloned. You are in the repo root."

  # ── Agent-accessible files (mounted to agent container) ──
  echo "$prompt" > "$staging_dir/prompt.txt"
  echo "$rebuild_cmds" > "$staging_dir/rebuild_cmds.txt"
  echo "$test_cmds" > "$staging_dir/test_cmds.txt"

  # ── Eval-only files (NOT mounted to agent - SWE-bench-Live protocol compliance) ──
  # These contain solution-revealing information and must ONLY be accessible during evaluation
  echo "$test_patch" > "$eval_staging_dir/test_patch.diff"
  echo "$fail_to_pass" > "$eval_staging_dir/fail_to_pass.json"
  local pass_to_pass
  pass_to_pass=$(echo "$instance_json" | jq -c '.PASS_TO_PASS')
  echo "$pass_to_pass" > "$eval_staging_dir/pass_to_pass.json"
  # CRITICAL FIX: test_cmds and rebuild_cmds must also be in eval staging dir.
  # The eval container mounts ${instance_id}-eval at /staging, not ${instance_id}.
  # Without these, TEST_CMD is empty and tests never run → false negatives for all instances.
  # These are NOT solution-revealing (same commands the agent already has access to).
  echo "$rebuild_cmds" > "$eval_staging_dir/rebuild_cmds.txt"
  echo "$test_cmds" > "$eval_staging_dir/test_cmds.txt"
  # print_cmds: how to retrieve test output (e.g., "cat reports/go-test-results.json")
  local print_cmds
  print_cmds=$(echo "$instance_json" | jq -r '.print_cmds[0] // ""')
  echo "$print_cmds" > "$eval_staging_dir/print_cmds.txt"
  # log_parser: instance-specific Python parser function
  local log_parser
  log_parser=$(echo "$instance_json" | jq -r '.log_parser // ""')
  echo "$log_parser" > "$eval_staging_dir/log_parser.py"
  # AMI config: thinking OFF — no reasoning tokens, model answers directly
  # CRITICAL: detachedMode enables anti-paralysis guardrails in SWE-bench evaluation
  # tokenBudget: 200k (safe for Qwen 262k context, triggers compaction at 160k)
  cat > "$staging_dir/ami-config.json" << 'AMICONF'
{
  "detachedMode": true,
  "tokenBudget": 200000,
  "timeout": 600000,
  "extraBody": {
    "chat_template_kwargs": {
      "enable_thinking": false
    }
  }
}
AMICONF
  # Copy shared eval parser to BOTH directories
  # Agent dir (for reference, not actually used by agent)
  cp "$WORKSPACE/scripts/eval_parse.py" "$staging_dir/eval_parse.py" 2>/dev/null || true
  # Eval dir (CRITICAL: eval container mounts this as /staging/)
  cp "$WORKSPACE/scripts/eval_parse.py" "$eval_staging_dir/eval_parse.py" 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# RUN INSTANCE JOB: create and submit a K8s Job for one instance
# ═══════════════════════════════════════════════════════════════════════

run_instance_job() {
  local instance_id="$1"

  local instance_json
  instance_json=$(jq -c "select(.instance_id == \"$instance_id\")" "$JSONL_FILE" | head -1)
  [[ -z "$instance_json" ]] && { log "ERROR: Instance $instance_id not found"; return 1; }

  local docker_image
  docker_image=$(echo "$instance_json" | jq -r '.docker_image // ""')
  if [[ -z "$docker_image" ]]; then
    local image_prefix="${DOCKER_IMAGE_PREFIX:-starryzhang}"
    docker_image="${image_prefix}/sweb.eval.x86_64.$(echo "$instance_id" | sed 's/__/_1776_/g' | tr '[:upper:]' '[:lower:]')"
  fi

  local repo
  repo=$(echo "$instance_json" | jq -r '.repo')

  # Stage files
  stage_instance "$instance_id" || return 1

  local job_name
  job_name=$(job_name_for_instance "$instance_id")
  local label_safe
  label_safe=$(echo "$instance_id" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-63)

  # Delete any previous job with this name
  timeout 30 oc delete job "$job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

  cat <<JOBYAML | timeout 60 oc apply -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: $job_name
  namespace: $NAMESPACE
  labels:
    app: swebench-instance
    instance: $label_safe
    language: $LANGUAGE
$KUEUE_LABELS
spec:
$KUEUE_SUSPEND
  backoffLimit: 0
  activeDeadlineSeconds: 18000
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: swebench-instance
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: dockerhub-auth
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: benchmark-runner
            topologyKey: kubernetes.io/hostname
      containers:
        - name: instance
          image: $docker_image
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -o pipefail

              # ── copy testbed to writable location (OCP image layers are read-only) ──
              cp -a /testbed /tmp/testbed 2>/dev/null || true
              find /tmp/testbed -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
              find /tmp/testbed -name '*.pyc' -delete 2>/dev/null || true

              # ── auto-detect repo dir ──
              if [ -d /tmp/testbed/.git ]; then
                REPO_DIR=/tmp/testbed
              elif [ -d /tmp/testbed/repo/.git ]; then
                REPO_DIR=/tmp/testbed/repo
              else
                FOUND=\$(find /tmp/testbed -maxdepth 2 -mindepth 2 -type d -name .git -print -quit 2>/dev/null || true)
                REPO_DIR="\${FOUND%/.git}"
              fi
              [ -z "\$REPO_DIR" ] && echo "ERROR: No git repo found" >&2 && exit 1

              git config --global --add safe.directory "\$REPO_DIR"
              git config --global user.email "swebench@test.local"
              git config --global user.name "SWE-bench"

              # ── test_patch applied at eval time only (SWE-bench-Live compliant) ──
              # Do NOT apply test_patch here — agent must not see test files.
              cd "\$REPO_DIR"
              # ── clean image dirt so patch captures only agent changes ──
              git checkout -- . 2>/dev/null || true
              git clean -fd 2>/dev/null || true
              TEST_PATCH_COMMIT=\$(git rev-parse HEAD)

              # ── trap: always produce patch even if killed/timed-out ──
              _produce_patch() {
                local repo="\${REPO_DIR:-/tmp/testbed}"
                local base="\${TEST_PATCH_COMMIT:-HEAD}"
                local patch_file="/results/ami-${MODEL_SLUG}-diff.patch"
                [ -f "\$patch_file" ] && return 0  # already written
                cd "\$repo" 2>/dev/null || return
                # Stage all changes including new files (test artifacts excluded by .gitignore)
                git add -A 2>/dev/null || true
                git commit --no-verify --quiet -m "agent_changes_trap" 2>/dev/null || true
                local head=\$(git rev-parse HEAD 2>/dev/null || echo "\$base")
                # Exclude test artifacts and build outputs from patch
                git --no-pager diff "\$base" "\$head" \
                  -- ':(exclude)*.rej' ':(exclude)*.orig' ':(exclude)reports/' \
                     ':(exclude)*.log' ':(exclude)**/logs/' \
                     ':(exclude).superinference/' ':(exclude).claude/' ':(exclude)*.jsonl' \
                     ':(exclude)test-results.json' ':(exclude)**/test-results.json' \
                     ':(exclude)out.json' ':(exclude)**/out.json' \
                     ':(exclude)test-output.json' ':(exclude)**/test-output.json' \
                     ':(exclude)*-output.json' ':(exclude)**/*-output.json' \
                     ':(exclude)go-test-results.json' ':(exclude)**/go-test-results.json' \
                     ':(exclude)coverage.out' ':(exclude)**/coverage.out' \
                     ':(exclude)*.test' ':(exclude)**/*.test' \
                     ':(exclude).gitignore' \
                     ':(exclude).local/' ':(exclude)**/.local/' \
                     ':(exclude)vendor/' ':(exclude)**/vendor/' \
                     ':(exclude)node_modules/' ':(exclude)**/node_modules/' \
                     ':(exclude)go.sum' ':(exclude)**/go.sum' \
                     ':(exclude)__pycache__/' ':(exclude)**/__pycache__/' \
                     ':(exclude)*.pyc' ':(exclude)**/*.pyc' \
                     ':(exclude).pytest_cache/' ':(exclude)**/.pytest_cache/' \
                     ':(exclude).tox/' ':(exclude)**/.tox/' \
                     ':(exclude)htmlcov/' ':(exclude)**/htmlcov/' \
                     ':(exclude).coverage' ':(exclude)**/.coverage' \
                     ':(exclude)poetry.lock' ':(exclude)Pipfile.lock' ':(exclude)pdm.lock' \
                  > "\$patch_file" 2>/dev/null || touch "\$patch_file"
                echo "TRAP: patch written (\$(wc -c < \"\$patch_file\")B)"
              }
              trap '_produce_patch' EXIT

              # ── pre-build if rebuild_cmds provided ──
              # staging/rebuild_cmds.txt is already written with /tmp/testbed by stage_instance()
              REBUILD_CMDS=\$(cat /staging/rebuild_cmds.txt 2>/dev/null || true)
              if [ -n "\$REBUILD_CMDS" ]; then
                echo "Building project..."
                cd /tmp/testbed
                eval "\$REBUILD_CMDS" 2>&1 | tail -20 || true
              fi

              # ── add test artifacts to .gitignore (append, then commit so agent doesn't see it as dirty) ──
              cd "\$REPO_DIR"
              printf '*.jsonl\n*-output.json\ntest-output.json\ngo-test-results.json\ncoverage.out\n*.test\n*.log\n.superinference/\n.claude/\n__pycache__/\n*.pyc\n.pytest_cache/\n.tox/\nhtmlcov/\n.coverage\n' >> .gitignore
              git add .gitignore 2>/dev/null && git commit --no-verify --quiet -m "harness: ignore test artifacts" 2>/dev/null || true

              # ── run AMI ──
              echo "Running AMI ($MODEL)..."
              LD_LIBRARY_PATH=/workspace/ami:\$LD_LIBRARY_PATH /workspace/ami/ami \
                --base-url "$BASE_URL" \
                --api-key "$API_KEY" \
                --model "$MODEL" \
                --prompt "\$(cat /staging/prompt.txt)" \
                --max-turns $MAX_TURNS \
                --config /staging/ami-config.json \
                --yolo \
                --output-format jsonl \
                --quiet 2>/results/ami-${MODEL_SLUG}.stderr.log | tee /results/ami-${MODEL_SLUG}-output.jsonl > /dev/null || true

              # ── DEBUG: check git state immediately after AMI exits ──
              cd "\$REPO_DIR"
              DBGLOG=/results/debug-post-ami.log
              {
                echo "DEBUG[0] AMI exited at \$(date -u +%H:%M:%S)"
                echo "DEBUG[0] pwd=\$(pwd)"
                echo "DEBUG[0] REPO_DIR=\$REPO_DIR"
                echo "DEBUG[0] git diff --stat:"
                git diff --stat 2>&1
                echo "DEBUG[0] git status --short:"
                git status --short 2>&1
                echo "DEBUG[0] ls .superinference/file-history/ 2>/dev/null:"
                ls -la .superinference/file-history/ 2>/dev/null || echo "(no file-history)"
                echo "DEBUG[0] find modified .py files:"
                find "\$REPO_DIR" -name '*.py' -newer /results/ami-${MODEL_SLUG}-output.jsonl -not -path '*/.superinference/*' -not -path '*/__pycache__/*' 2>/dev/null | head -20 || echo "(none)"
              } > "\$DBGLOG" 2>&1

              # ── clean artifacts ──
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true
              find "\$REPO_DIR" -name '*.orig' -delete 2>/dev/null || true
              echo "DEBUG[1] after rej/orig cleanup: \$(git diff --stat 2>&1 | wc -l) diff lines" >> "\$DBGLOG"

              # ── preserve analytics before cleanup ──
              if [ -f "\$REPO_DIR/.superinference/analytics/analytics.jsonl" ]; then
                cp "\$REPO_DIR/.superinference/analytics/analytics.jsonl" /results/analytics.jsonl 2>/dev/null || true
                echo "Preserved analytics: \$(wc -l < /results/analytics.jsonl 2>/dev/null || echo 0) events"
              fi

              echo "DEBUG[2] before session cleanup: \$(git diff --stat 2>&1 | wc -l) diff lines" >> "\$DBGLOG"
              rm -rf "\$REPO_DIR/.superinference" "\$REPO_DIR/.claude" 2>/dev/null || true
              echo "DEBUG[3] after session cleanup: \$(git diff --stat 2>&1 | wc -l) diff lines" >> "\$DBGLOG"
              # Note: test artifacts (*.jsonl, *-output.json, etc.) are left in place
              # They're in .gitignore so git add -A won't stage them
              # Agents can reference them for debugging
              git add -A 2>/dev/null || true
              echo "DEBUG[4] git add -A done, git status:" >> "\$DBGLOG"
              git status --short 2>&1 >> "\$DBGLOG"
              git commit --no-verify --quiet -m "agent_changes" 2>&1 >> "\$DBGLOG" || true
              echo "DEBUG[5] git commit done, HEAD=\$(git rev-parse --short HEAD)" >> "\$DBGLOG"
              AGENT_HEAD=\$(git rev-parse HEAD)

              # ── restore ONLY agent-modified test files (language-aware patterns) ──
              # Use :(glob) for recursive matching — plain **/dir/** misses root-level dirs
              MODIFIED_TESTS=\$(git diff --name-only "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" -- \
                '*_test.go' ':(glob)**/testdata/**' ':(glob)**/tests/**' ':(glob)**/testing/**' \
                ':(glob)**/test_*.py' '*_test.py' ':(glob)**/conftest.py' 'conftest.py' \
                '*Test.java' '*Tests.java' ':(glob)**/src/test/**' \
                2>/dev/null || true)
              if [ -n "\$MODIFIED_TESTS" ]; then
                echo "Restoring agent-modified test files..."
                echo "\$MODIFIED_TESTS" | while read -r tf; do
                  [ -n "\$tf" ] && git checkout "\$TEST_PATCH_COMMIT" -- "\$tf" 2>/dev/null || true
                done
              fi

              # ── restore lock files if manifest was not changed ──
              GOMOD_CHANGED=\$(git diff --name-only "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" -- go.mod 2>/dev/null || true)
              if [ -z "\$GOMOD_CHANGED" ]; then
                git checkout "\$TEST_PATCH_COMMIT" -- go.sum 2>/dev/null || true
              fi
              PYREQS_CHANGED=\$(git diff --name-only "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" -- setup.py setup.cfg pyproject.toml requirements.txt 2>/dev/null || true)
              if [ -z "\$PYREQS_CHANGED" ]; then
                git checkout "\$TEST_PATCH_COMMIT" -- poetry.lock Pipfile.lock pdm.lock 2>/dev/null || true
              fi

              # Stage all changes including new files (test artifacts excluded by .gitignore)
              git add -A 2>/dev/null || true
              git commit --no-verify --quiet -m "agent_changes_clean" 2>/dev/null || true
              # Clean untracked files (test output, downloads, build artifacts)
              git clean -fd 2>/dev/null || true
              AGENT_HEAD=\$(git rev-parse HEAD)

              # ── capture diff (exclude test artifacts and build outputs) ──
              git --no-pager diff "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" \
                -- ':(exclude)*.rej' ':(exclude)*.orig' ':(exclude)reports/' \
                   ':(exclude)*.log' ':(exclude)**/logs/' \
                   ':(exclude).superinference/' ':(exclude).claude/' ':(exclude)*.jsonl' \
                   ':(exclude)test-results.json' ':(exclude)**/test-results.json' \
                   ':(exclude)out.json' ':(exclude)**/out.json' \
                   ':(exclude)test-output.json' ':(exclude)**/test-output.json' \
                   ':(exclude)*-output.json' ':(exclude)**/*-output.json' \
                   ':(exclude)go-test-results.json' ':(exclude)**/go-test-results.json' \
                   ':(exclude)coverage.out' ':(exclude)**/coverage.out' \
                   ':(exclude)*.test' ':(exclude)**/*.test' \
                   ':(exclude).gitignore' \
                   ':(exclude).local/' ':(exclude)**/.local/' \
                   ':(exclude)vendor/' ':(exclude)**/vendor/' \
                   ':(exclude)node_modules/' ':(exclude)**/node_modules/' \
                   ':(exclude)go.sum' ':(exclude)**/go.sum' \
                   ':(exclude)__pycache__/' ':(exclude)**/__pycache__/' \
                   ':(exclude)*.pyc' ':(exclude)**/*.pyc' \
                   ':(exclude).pytest_cache/' ':(exclude)**/.pytest_cache/' \
                   ':(exclude).tox/' ':(exclude)**/.tox/' \
                   ':(exclude)htmlcov/' ':(exclude)**/htmlcov/' \
                   ':(exclude).coverage' ':(exclude)**/.coverage' \
                   ':(exclude)poetry.lock' ':(exclude)Pipfile.lock' ':(exclude)pdm.lock' \
                > /results/ami-${MODEL_SLUG}-diff.patch 2>/dev/null || true

              # ── sanitize patch (strip binary diffs) ──
              python3 /staging/eval_parse.py --sanitize-patch /results/ami-${MODEL_SLUG}-diff.patch 2>/dev/null || true

              PATCH_SIZE=\$(wc -c < /results/ami-${MODEL_SLUG}-diff.patch 2>/dev/null || echo 0)
              PATCH_LINES=\$(wc -l < /results/ami-${MODEL_SLUG}-diff.patch 2>/dev/null || echo 0)

              # ── validate patch size (detect contamination) ──
              if [ "\$PATCH_LINES" -gt 5000 ]; then
                echo "WARNING: Patch is \$PATCH_LINES lines (>5000 threshold)"
                echo "Likely contamination. Checking for artifacts..."
                git diff --name-only "\$TEST_PATCH_COMMIT" "\$AGENT_HEAD" > /results/patch-files.txt 2>/dev/null || true
                if grep -E '\.(jsonl|log|pyc)$|test-output|coverage\.out|go-test-results|__pycache__|\.pytest_cache|\.tox/' /results/patch-files.txt 2>/dev/null; then
                  echo "CONTAMINATION DETECTED: Test artifacts in patch!"
                  cat /results/patch-files.txt | grep -E '\.(jsonl|log|pyc)$|test-output|coverage\.out|go-test-results|__pycache__|\.pytest_cache|\.tox/' || true
                fi
              fi

              echo "Agent done. Patch: \$PATCH_SIZE bytes (\$PATCH_LINES lines)"
          env:
            - name: AI_API_KEY
              value: "$API_KEY"
            - name: AI_PROVIDER
              value: "$PROVIDER"
            - name: AI_BASE_URL
              value: "$BASE_URL"
            - name: OPENAI_API_KEY
              value: "$API_KEY"
            - name: HOME
              value: /tmp
          volumeMounts:
            - name: workspace
              mountPath: /workspace/ami
              subPath: ami
              readOnly: true
            - name: workspace
              mountPath: /staging
              subPath: staging/$LANGUAGE/$instance_id
              readOnly: true
            - name: workspace
              mountPath: /results
              subPath: verified/$LANGUAGE/$MODEL_SLUG/$instance_id/results
            - name: dshm
              mountPath: /dev/shm
            - name: tmpdir
              mountPath: /tmp
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
            claimName: $PVC_CLAIM
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 5Gi
        - name: tmpdir
          emptyDir: {}
JOBYAML

  if [[ $? -ne 0 ]]; then
    log "ERROR: Failed to create job for $instance_id"
    return 1
  fi
  log "Job $job_name created for $instance_id (image: $docker_image)"
}

# ═══════════════════════════════════════════════════════════════════════
# POST-PROCESS: rename outputs and extract metrics after job completes
# ═══════════════════════════════════════════════════════════════════════

postprocess_instance() {
  local instance_id="$1"
  local result_dir="$VERIFIED_DIR/$instance_id/results"

  # Rename output files
  # Legacy rename (in case inner script used old name)
  if [[ -f "$result_dir/agent.patch" && ! -f "$result_dir/ami-${MODEL_SLUG}-diff.patch" ]]; then
    mv "$result_dir/agent.patch" "$result_dir/ami-${MODEL_SLUG}-diff.patch" 2>/dev/null || true
  fi
  if [[ -f "$result_dir/ami-output.jsonl" ]]; then
    mv "$result_dir/ami-output.jsonl" "$result_dir/ami-${MODEL_SLUG}-output.jsonl" 2>/dev/null || true
  fi

  # Extract metrics
  local ami_jsonl="$result_dir/ami-${MODEL_SLUG}-output.jsonl"
  local turns=0 cost=0 tokens=0
  if [[ -f "$ami_jsonl" ]]; then
    { grep '"type":"usage_update"' "$ami_jsonl" || true; } | tail -1 > "$result_dir/ami-usage.json"
    turns=$(jq -r '.stats.turnCount // 0' "$result_dir/ami-usage.json" 2>/dev/null || echo 0)
    cost=$(jq -r '.stats.totalCost // 0' "$result_dir/ami-usage.json" 2>/dev/null || echo 0)
    tokens=$(jq -r '.stats.totalTokens // 0' "$result_dir/ami-usage.json" 2>/dev/null || echo 0)
  fi

  local repo
  repo=$(jq -r "select(.instance_id == \"$instance_id\") | .repo" "$JSONL_FILE" | head -1)

  cat > "$result_dir/ami-${MODEL_SLUG}.json" <<RESULT
{
  "runner": "ami",
  "model": "$MODEL",
  "provider": "$PROVIDER",
  "language": "$LANGUAGE",
  "execution": "k8s-job",
  "instanceId": "$instance_id",
  "repo": "$repo",
  "turns": $turns,
  "estimatedCost": $cost,
  "tokens": {"total": $tokens},
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
}
RESULT

  local patch_size=0
  [[ -f "$result_dir/ami-${MODEL_SLUG}-diff.patch" ]] && \
    patch_size=$(wc -c < "$result_dir/ami-${MODEL_SLUG}-diff.patch")
  log "  $instance_id: patch=${patch_size}B turns=$turns"
}

# ═══════════════════════════════════════════════════════════════════════
# RUN EVALUATION: launch a SEPARATE clean K8s Job to evaluate the agent's patch
# This ensures the eval is not contaminated by agent-left state.
# ═══════════════════════════════════════════════════════════════════════

run_evaluation() {
  local instance_id="$1"
  local result_dir="$VERIFIED_DIR/$instance_id/results"
  local eval_dir="$VERIFIED_DIR/$instance_id/eval-results"
  local patch="$result_dir/ami-${MODEL_SLUG}-diff.patch"
  local staging_dir="$WORKSPACE/staging/$LANGUAGE/$instance_id"
  local eval_staging_dir="$WORKSPACE/staging/$LANGUAGE/${instance_id}-eval"

  # If a previous (premature) run wrote empty_patch but patch now exists → re-evaluate
  if [[ -f "$eval_dir/report.json" && -f "$patch" && -s "$patch" ]]; then
    local prev_err
    prev_err=$(python3 -c "import json; print(json.load(open('$eval_dir/report.json')).get('error',''))" 2>/dev/null || echo "")
    if [[ "$prev_err" == "empty_patch" ]]; then
      log "  Stale empty_patch report for $instance_id — patch now exists, re-evaluating"
      rm -f "$eval_dir/report.json"
    fi
  fi

  # Empty patch = agent made no changes → unresolved, write report and skip eval
  if [[ ! -f "$patch" || ! -s "$patch" ]]; then
    mkdir -p "$eval_dir"
    echo '{"resolved": false, "error": "empty_patch", "FAIL_TO_PASS": {"success": [], "failure": []}, "PASS_TO_PASS": {"success": [], "failure": []}}' \
      > "$eval_dir/report.json"
    log "  SKIP eval $instance_id (no patch — marked unresolved)"
    return 0
  fi

  # Skip if already evaluated (validate the file is non-empty and contains "resolved" key)
  if [[ -f "$eval_dir/report.json" ]]; then
    local valid
    valid=$(python3 -c "import json,sys; d=json.load(open('$eval_dir/report.json')); sys.exit(0 if 'resolved' in d else 1)" 2>/dev/null && echo yes || echo no)
    [[ "$valid" == "yes" ]] && return 0
    log "  report.json for $instance_id is invalid/stale — re-evaluating"
    rm -f "$eval_dir/report.json"
  fi

  # Re-stage if staging files missing (happens after restarts)
  # FIX: test_patch.diff is in eval staging dir, not agent staging dir
  if [[ ! -f "$eval_staging_dir/test_patch.diff" ]]; then
    stage_instance "$instance_id" || return 0
  fi

  mkdir -p "$eval_dir"

  # Get docker image for this instance
  local instance_json
  instance_json=$(jq -c "select(.instance_id == \"$instance_id\")" "$JSONL_FILE" | head -1)
  local docker_image
  docker_image=$(echo "$instance_json" | jq -r '.docker_image // ""')
  if [[ -z "$docker_image" ]]; then
    local image_prefix="${DOCKER_IMAGE_PREFIX:-starryzhang}"
    docker_image="${image_prefix}/sweb.eval.x86_64.$(echo "$instance_id" | sed 's/__/_1776_/g' | tr '[:upper:]' '[:lower:]')"
  fi

  local eval_job_name="eval-$(echo "$instance_id" | tr '[:upper:]_' '[:lower:]-' | sed 's/[^a-z0-9-]/-/g' | cut -c1-55)"

  timeout 30 oc delete job "$eval_job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

  log "  EVAL $instance_id (fresh container: $docker_image)"

  cat <<EVALJOB | timeout 60 oc apply -f - 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: $eval_job_name
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
      imagePullSecrets:
        - name: dockerhub-auth
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: benchmark-runner
            topologyKey: kubernetes.io/hostname
      containers:
        - name: eval
          image: $docker_image
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -o pipefail
              echo "=== EVAL: $instance_id (clean container) ==="

              # Ensure report.json is written even on unexpected termination
              _eval_cleanup() {
                if [ ! -f /eval-results/report.json ]; then
                  echo "EVAL: Container terminating without report — running parser..."
                  python3 /staging/eval_parse.py 2>/dev/null || true
                  if [ ! -f /eval-results/report.json ]; then
                    echo '{"resolved": false, "error": "container_terminated"}' > /eval-results/report.json
                  fi
                fi
              }
              trap _eval_cleanup EXIT

              # Fresh copy of testbed (read-only image layer)
              cp -a /testbed /tmp/testbed 2>/dev/null || true
              find /tmp/testbed -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
              find /tmp/testbed -name '*.pyc' -delete 2>/dev/null || true
              REPO_DIR=/tmp/testbed
              [ ! -d "\$REPO_DIR/.git" ] && REPO_DIR=\$(find /tmp/testbed -maxdepth 2 -type d -name .git -print -quit 2>/dev/null | sed 's/\/.git\$//')
              [ -z "\$REPO_DIR" ] && echo "ERROR: No repo" && exit 1
              git config --global --add safe.directory "\$REPO_DIR"
              git config --global user.email swebench@test.local
              git config --global user.name SWE-bench
              cd "\$REPO_DIR"

              # ── BASELINE RUN: identify pre-existing P2P failures ──
              # Apply ONLY the test patch (no agent patch) and run tests to find
              # tests that already fail in the Docker environment.
              echo "Running baseline (test_patch only, no agent patch)..."
              if git apply --allow-empty /staging/test_patch.diff 2>/dev/null || \
                 git apply --allow-empty --3way /staging/test_patch.diff 2>/dev/null || \
                 patch -p1 --force --no-backup-if-mismatch < /staging/test_patch.diff 2>/dev/null; then

                BASELINE_TEST_CMD=\$(cat /staging/test_cmds.txt 2>/dev/null || true)
                if [ -n "\$BASELINE_TEST_CMD" ]; then
                  # Poetry: install deps for baseline too
                  if echo "\$BASELINE_TEST_CMD" | grep -q "poetry"; then
                    cd /tmp/testbed
                    poetry install --with dev --no-interaction 2>/dev/null | tail -3 || \
                      poetry install --no-interaction 2>/dev/null | tail -3 || true
                    cd "\$REPO_DIR"
                  fi
                  find "\$REPO_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
                  timeout 900 bash -c "\$BASELINE_TEST_CMD" > /eval-results/test-baseline.log 2>&1 || true
                fi

                # Reset repo to clean state for actual eval
                git checkout -f . 2>/dev/null || true
                git clean -fd 2>/dev/null || true
              else
                echo "EVAL: Baseline test_patch apply failed (non-fatal, skipping baseline)"
              fi

              # ── ACTUAL EVAL: apply agent patch + test patch ──
              echo "Applying agent patch..."
              if ! git apply --allow-empty /agent-patch/ami-${MODEL_SLUG}-diff.patch 2>&1 && \
                 ! patch -p1 --force --no-backup-if-mismatch < /agent-patch/ami-${MODEL_SLUG}-diff.patch 2>&1; then
                echo "EVAL FATAL: Agent patch failed to apply — marking as unresolved"
                echo '{"resolved": false, "error": "patch_apply_failed"}' > /eval-results/report.json
                exit 0
              fi

              echo "Applying test patch..."
              if ! git apply --allow-empty /staging/test_patch.diff 2>&1 && \
                 ! git apply --allow-empty --3way /staging/test_patch.diff 2>&1 && \
                 ! patch -p1 --force --no-backup-if-mismatch < /staging/test_patch.diff 2>&1; then
                echo "EVAL FATAL: test_patch failed to apply — FAIL_TO_PASS tests not present"
                echo "Reject files:" && find "\$REPO_DIR" -name '*.rej' -exec cat {} \; 2>/dev/null || true
                echo '{"resolved": false, "error": "test_patch_apply_failed"}' > /eval-results/report.json
                exit 0
              fi
              find "\$REPO_DIR" -name '*.rej' -delete 2>/dev/null || true
              FAIL_TESTS=\$(cat /staging/fail_to_pass.json 2>/dev/null || echo '[]')
              FIRST_TEST=\$(echo "\$FAIL_TESTS" | python3 -c "import json,sys; ts=json.load(sys.stdin); n=ts[0] if ts else ''; print(n.split('::')[-1].split('[')[0] if n else '')" 2>/dev/null || true)
              if [ -n "\$FIRST_TEST" ]; then
                if ! grep -Frq "\$FIRST_TEST" "\$REPO_DIR" 2>/dev/null; then
                  echo "EVAL WARNING: test_patch applied but test function \$FIRST_TEST not found in source — continuing anyway"
                fi
              fi

              # Rebuild (rebuild_cmds.txt already contains /tmp/testbed — no sed needed)
              REBUILD_CMDS=\$(cat /staging/rebuild_cmds.txt 2>/dev/null || true)
              if [ -n "\$REBUILD_CMDS" ]; then
                echo "Rebuilding..."
                cd /tmp/testbed
                eval "\$REBUILD_CMDS" 2>&1 | tail -10 || true
                cd "\$REPO_DIR"
              fi

              # Run tests — clear caches to ensure test_patch files are picked up
              TEST_CMD=\$(cat /staging/test_cmds.txt 2>/dev/null || true)
              if [ -n "\$TEST_CMD" ]; then
                echo "Running tests: \$TEST_CMD"
                cd "\$REPO_DIR"

                # Poetry projects: ensure test deps are installed in the virtualenv
                if echo "\$TEST_CMD" | grep -q "poetry"; then
                  echo "Detected poetry test command — installing dependencies..."
                  cd /tmp/testbed
                  poetry install --with dev --no-interaction 2>&1 | tail -5 || \
                    poetry install --no-interaction 2>&1 | tail -5 || true
                  if ! poetry run pytest --version 2>/dev/null; then
                    echo "EVAL: pytest not in poetry env, installing..."
                    poetry run pip install pytest 2>/dev/null || true
                  fi
                  cd "\$REPO_DIR"
                elif echo "\$TEST_CMD" | grep -q "pipenv"; then
                  echo "Detected pipenv test command — installing dependencies..."
                  cd /tmp/testbed
                  pipenv install --dev 2>&1 | tail -5 || true
                  cd "\$REPO_DIR"
                fi

                # Language-specific cache clearing
                go clean -testcache 2>/dev/null || true
                find "\$REPO_DIR" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
                find "\$REPO_DIR" -type d -name .pytest_cache -exec rm -rf {} + 2>/dev/null || true
                mkdir -p reports 2>/dev/null || true
                timeout 1800 bash -c "\$TEST_CMD" > /eval-results/test-stdout.log 2>&1 || true
              fi

              # Retrieve test output via print_cmds
              PRINT_CMD=\$(cat /staging/print_cmds.txt 2>/dev/null || true)
              if [ -n "\$PRINT_CMD" ]; then
                cd "\$REPO_DIR"
                eval "\$PRINT_CMD" > /eval-results/test-output.log 2>/dev/null || true
              fi
              for rf in reports/go-test-results.json reports/test-results.json test-results.json; do
                [ -f "\$REPO_DIR/\$rf" ] && cp "\$REPO_DIR/\$rf" /eval-results/ 2>/dev/null || true
              done
              if [ ! -s /eval-results/test-output.log ]; then
                for rf in /eval-results/go-test-results.json /eval-results/test-results.json /eval-results/test-stdout.log; do
                  [ -s "\$rf" ] && { cp "\$rf" /eval-results/test-output.log; break; }
                done
              fi

              # Parse results
              python3 /staging/eval_parse.py 2>&1 || echo "EVAL: Parse error"
              echo "Eval complete."
          env:
            - name: HOME
              value: /tmp
            - name: PYTEST_ADDOPTS
              value: "--import-mode=importlib -p no:cacheprovider --continue-on-collection-errors"
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            - name: OPENBLAS_NUM_THREADS
              value: "1"
          volumeMounts:
            - name: workspace
              mountPath: /staging
              subPath: staging/$LANGUAGE/${instance_id}-eval
              readOnly: true
            - name: workspace
              mountPath: /agent-patch
              subPath: verified/$LANGUAGE/$MODEL_SLUG/$instance_id/results
              readOnly: true
            - name: workspace
              mountPath: /eval-results
              subPath: verified/$LANGUAGE/$MODEL_SLUG/$instance_id/eval-results
            - name: dshm
              mountPath: /dev/shm
            - name: tmpdir
              mountPath: /tmp
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
            claimName: $PVC_CLAIM
        - name: dshm
          emptyDir:
            medium: Memory
            sizeLimit: 5Gi
        - name: tmpdir
          emptyDir: {}
EVALJOB

  # Wait for eval job to complete or fail (max 2h)
  local wait_start=$SECONDS
  while (( SECONDS - wait_start < 7200 )); do
    local job_status
    job_status=$(oc get job "$eval_job_name" -n "$NAMESPACE" \
      -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
    if [[ "$job_status" == "Complete" || "$job_status" == "SuccessCriteriaMet" || "$job_status" == "Failed" ]]; then
      [[ "$job_status" == "Failed" ]] && log "  Eval job failed for $instance_id"
      break
    fi
    if [[ -z "$job_status" ]]; then
      # Job may have been cleaned up by TTL — check if it still exists
      if ! oc get job "$eval_job_name" -n "$NAMESPACE" &>/dev/null; then
        log "  Eval job gone (TTL cleanup) for $instance_id"
        break
      fi
    fi
    sleep 15
  done
  if (( SECONDS - wait_start >= 7200 )); then
    log "  Eval job timed out for $instance_id"
  fi

  # Check result
  if [[ -f "$eval_dir/report.json" ]]; then
    local resolved
    resolved=$(python3 -c "import json; print(json.load(open('$eval_dir/report.json')).get('resolved','?'))" 2>/dev/null)
    log "  EVAL $instance_id: $resolved"
  else
    log "  EVAL $instance_id: no report generated"
  fi

  # Cleanup eval job
  timeout 30 oc delete job "$eval_job_name" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════
# RUN ALL INSTANCES: Phase 1 initial run or retry batch
# ═══════════════════════════════════════════════════════════════════════

run_batch() {
  local instance_file="$1"
  local batch_name="$2"
  local total
  total=$(wc -l < "$instance_file")
  local started=0
  local running=0

  log "Starting batch '$batch_name': $total instances, parallel=$PARALLEL"

  # Track which instances have been post-processed
  local processed_file
  processed_file=$(mktemp /tmp/processed-XXXXXX.txt)
  > "$processed_file"

  # Function to post-process + eval any completed instances
  process_completed() {
    # Snapshot ALL existing swebench job names (running, pending, completing, ttl-pending).
    # Using output.jsonl as a "done" signal is only safe when the job has fully disappeared
    # (ttl'd). status.active!=0 misses jobs whose pods are still in ContainerCreating —
    # a freshly-submitted job can have status.active=0 for the first 30-60s.
    local existing_jobs_snap
    existing_jobs_snap=$(timeout 30 oc get jobs -n "$NAMESPACE" -l app=swebench-instance \
      --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ':' || echo "")

    while IFS= read -r iid; do
      [[ -z "$iid" ]] && continue
      grep -qx "$iid" "$processed_file" 2>/dev/null && continue
      local job_name
      job_name=$(job_name_for_instance "$iid")
      # Check if this instance's agent job completed
      local job_status
      job_status=$(timeout 30 oc get job "$job_name" -n "$NAMESPACE" -o jsonpath='{.status.conditions[0].type}' 2>/dev/null || echo "")
      # Only treat output.jsonl as "done" when the job is no longer active in K8s.
      # output.jsonl is streamed live, so it exists for running jobs too.
      local has_results=0
      local res_dir="$VERIFIED_DIR/$iid/results"
      [[ -f "$res_dir/ami-${MODEL_SLUG}-diff.patch" && -s "$res_dir/ami-${MODEL_SLUG}-diff.patch" ]] && has_results=1
      [[ -f "$res_dir/ami-${MODEL_SLUG}.json" ]] && has_results=1
      if [[ ":$existing_jobs_snap:" != *":$job_name:"* ]]; then
        # Job no longer exists in K8s (ttl'd after finish) — output.jsonl safe to use
        [[ -f "$res_dir/ami-${MODEL_SLUG}-output.jsonl" ]] && has_results=1
      fi
      # Ensure patch file exists before eval (killed jobs may have output but no patch)
      if [[ $has_results -eq 1 && ! -f "$res_dir/ami-${MODEL_SLUG}-diff.patch" ]]; then
        touch "$res_dir/ami-${MODEL_SLUG}-diff.patch"
      fi
      if [[ "$job_status" == "Complete" || "$job_status" == "SuccessCriteriaMet" || "$job_status" == "Failed" || $has_results -eq 1 ]]; then
        echo "$iid" >> "$processed_file"
        postprocess_instance "$iid"
        run_evaluation "$iid"
      fi
    done < "$instance_file"
  }

  while IFS= read -r instance_id; do
    [[ -z "$instance_id" ]] && continue
    started=$((started + 1))

    log "[$started/$total] Launching $instance_id"

    # Submit the job (non-blocking)
    run_instance_job "$instance_id" || {
      log "ERROR: Could not create job for $instance_id, skipping"
      continue
    }

    running=$((running + 1))

    # Throttle: wait if at parallelism limit
    while true; do
      local active
      active=$(count_active_jobs)
      if [[ "$active" -lt "$PARALLEL" ]]; then
        break
      fi
      sleep 15
      kill_hung_jobs
      # While waiting, process+eval any completed agent jobs
      process_completed
    done
  done < "$instance_file"

  # Wait for all remaining jobs to finish
  log "All jobs submitted for '$batch_name'. Waiting for completion..."
  wait_for_all_jobs "$batch_name"

  # Final pass: post-process + eval anything still pending
  log "Final post-processing for '$batch_name'..."
  while IFS= read -r instance_id; do
    [[ -z "$instance_id" ]] && continue
    grep -qx "$instance_id" "$processed_file" 2>/dev/null && continue
    postprocess_instance "$instance_id"
    run_evaluation "$instance_id"
  done < "$instance_file"

  rm -f "$processed_file"
  cleanup_completed_jobs
}

# ═══════════════════════════════════════════════════════════════════════
# WAIT FOR ALL JOBS: poll until no active swebench jobs remain
# ═══════════════════════════════════════════════════════════════════════

wait_for_all_jobs() {
  local batch_name="$1"
  local last_status_time=0

  while true; do
    local active
    active=$(count_active_jobs)
    [[ "$active" -eq 0 ]] && break

    kill_hung_jobs

    local now
    now=$(date +%s)
    if [[ $(( now - last_status_time )) -ge $STATUS_INTERVAL_SEC ]]; then
      local done_count eval_count resolved
      done_count=$(count_with_results)
      eval_count=$(count_evaluated)
      resolved=$(count_resolved)
      log "STATUS [$batch_name]: active_jobs=$active results=$done_count eval=$eval_count resolved=$resolved/$TOTAL_INSTANCES"
      last_status_time=$now
    fi

    sleep 15
  done

  log "All jobs complete for '$batch_name'"
}

# ═══════════════════════════════════════════════════════════════════════
# SMART RETRY CATEGORIZATION
# ═══════════════════════════════════════════════════════════════════════

build_retry_list() {
  local run_num="$1"
  local retry_file="$WORKSPACE/logs/retry-list-run${run_num}.txt"
  > "$retry_file"
  local skipped=0

  local all_instances
  all_instances=$(jq -r '.instance_id' "$JSONL_FILE")

  # Simple rule: retry EVERYTHING not in verified/ (resolved)
  for inst in $all_instances; do
    if [[ -d "$VERIFIED_DIR/$inst" ]]; then
      # Check it's actually resolved (not just leftover from current run)
      if [[ -f "$VERIFIED_DIR/$inst/eval-results/report.json" ]]; then
        local r
        r=$(python3 -c "import json; print(json.load(open('$VERIFIED_DIR/$inst/eval-results/report.json')).get('resolved',False))" 2>/dev/null)
        [[ "$r" == "True" ]] && { skipped=$((skipped + 1)); continue; }
      fi
    fi
    # Not resolved — retry it
    echo "$inst" >> "$retry_file"
  done

  # Randomize retry order to avoid systematic positional bias across rounds
  if command -v shuf &>/dev/null; then
    shuf "$retry_file" -o "$retry_file"
  fi

  log "Retry list: $(wc -l < "$retry_file") to retry, $skipped skipped" >&2
  echo "$retry_file"
}

# ═══════════════════════════════════════════════════════════════════════
# FAILURE ANALYSIS
# ═══════════════════════════════════════════════════════════════════════

analyze_failures() {
  local close_miss=0 partial=0 wrong=0 build=0 empty=0 nopatch=0 patched=0
  local all_instances
  all_instances=$(jq -r '.instance_id' "$JSONL_FILE")

  for inst in $all_instances; do
    local evdir="$VERIFIED_DIR/$inst/eval-results"
    local resdir="$VERIFIED_DIR/$inst/results"
    [[ "$(basename "$evdir")" == run* ]] && continue

    if [[ -f "$evdir/report.json" ]]; then
      local r
      r=$(python3 -c "import json; print(json.load(open('$evdir/report.json')).get('resolved','?'))" 2>/dev/null)
      [[ "$r" == "True" ]] && continue

      local f2p_s f2p_f f2p_total
      f2p_s=$(python3 -c "import json; d=json.load(open('$evdir/report.json')); print(len(d.get('FAIL_TO_PASS',{}).get('success',[])))" 2>/dev/null)
      f2p_f=$(python3 -c "import json; d=json.load(open('$evdir/report.json')); print(len(d.get('FAIL_TO_PASS',{}).get('failure',[])))" 2>/dev/null)
      f2p_total=$((f2p_s + f2p_f))

      if [[ $f2p_total -gt 0 && $f2p_s -eq $f2p_total ]]; then
        close_miss=$((close_miss + 1))
      elif [[ $f2p_total -gt 0 && $f2p_s -gt 0 ]]; then
        partial=$((partial + 1))
      elif [[ $f2p_total -gt 0 ]]; then
        wrong=$((wrong + 1))
      else
        build=$((build + 1))
      fi
    elif [[ -f "$resdir/ami-${MODEL_SLUG}-diff.patch" ]] && [[ -s "$resdir/ami-${MODEL_SLUG}-diff.patch" ]]; then
      patched=$((patched + 1))
    elif [[ -d "$resdir" ]]; then
      empty=$((empty + 1))
    else
      nopatch=$((nopatch + 1))
    fi
  done

  log "FAILURE ANALYSIS: close_miss=$close_miss partial=$partial wrong=$wrong build=$build empty=$empty nopatch=$nopatch patched=$patched"
}

# ═══════════════════════════════════════════════════════════════════════
# ARCHIVE FAILURES: move unresolved instances from verified/ to runN/
# Jobs write directly to verified/. After eval, unresolved get moved out.
# verified/ keeps only resolved instances (the golden set).
# runN/ preserves each failed attempt for post-mortem analysis.
# ═══════════════════════════════════════════════════════════════════════

promote_and_archive() {
  local run_label="$1"
  local run_dir="$RUNS_DIR/run${run_label}"
  local kept=0
  local archived=0

  log "Archiving unresolved from verified/ → runs/run${run_label}/"

  for d in "$VERIFIED_DIR"/*/; do
    [[ ! -d "$d" ]] && continue
    local inst
    inst=$(basename "$d")
    local report="$d/eval-results/report.json"

    if [[ -f "$report" ]]; then
      local resolved
      resolved=$(python3 -c "import json; print(json.load(open('$report')).get('resolved',False))" 2>/dev/null)

      if [[ "$resolved" == "True" ]]; then
        # KEEP in verified/ — it's resolved
        kept=$((kept + 1))
      else
        # MOVE to runN/ — failed, preserve for analysis
        mkdir -p "$run_dir"
        rm -rf "$run_dir/$inst" 2>/dev/null || true
        mv "$d" "$run_dir/$inst" 2>/dev/null || cp -a "$d" "$run_dir/$inst" 2>/dev/null
        rm -rf "$VERIFIED_DIR/$inst" 2>/dev/null || true
        archived=$((archived + 1))
      fi
    else
      # No eval report (empty patch, agent didn't produce fix) — move out
      mkdir -p "$run_dir"
      rm -rf "$run_dir/$inst" 2>/dev/null || true
      cp -a "$d" "$run_dir/$inst" 2>/dev/null || true
      [[ -d "$run_dir/$inst" ]] && rm -rf "$VERIFIED_DIR/$inst" 2>/dev/null || true
      archived=$((archived + 1))
    fi
  done

  log "Kept $kept resolved in verified/, archived $archived to runs/run${run_label}/"
}

# ═══════════════════════════════════════════════════════════════════════
# RETRY: clear old results and rerun a batch
# ═══════════════════════════════════════════════════════════════════════

run_retry() {
  local run_num="$1"
  local retry_file="$2"
  local retry_count
  retry_count=$(wc -l < "$retry_file")

  if [[ $retry_count -eq 0 ]]; then
    log "No instances to retry in run $run_num"
    return 1
  fi

  log "=== RETRY RUN $run_num: $retry_count instances ==="

  # Backup and clear old results for retry instances
  local pre_retry_backup="$RUNS_DIR/pre-retry-${run_num}"
  mkdir -p "$pre_retry_backup"
  while IFS= read -r inst; do
    [[ -z "$inst" ]] && continue
    # Backup any existing data before clearing (never lose anything)
    if [[ -d "$VERIFIED_DIR/$inst" ]]; then
      mkdir -p "$pre_retry_backup/$inst"
      cp -a "$VERIFIED_DIR/$inst"/* "$pre_retry_backup/$inst/" 2>/dev/null || true
      rm -rf "$VERIFIED_DIR/$inst/results" 2>/dev/null || true
      rm -rf "$VERIFIED_DIR/$inst/eval-results" 2>/dev/null || true
    fi
    # Also delete any leftover K8s job
    local jn
    jn=$(job_name_for_instance "$inst")
    timeout 30 oc delete job "$jn" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  done < "$retry_file"
  log "Backed up $pre_retry_backup before clearing for retry"

  run_batch "$retry_file" "retry-run${run_num}"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════
# HEALTH CHECK: verify vLLM is reachable before starting
# ═══════════════════════════════════════════════════════════════════════

check_vllm_health() {
  log "Checking vLLM at $BASE_URL ..."
  local http_code
  http_code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE_URL/models" \
    -H "Authorization: Bearer $API_KEY" 2>/dev/null || echo "000")
  if [[ "$http_code" != "200" ]]; then
    log "WARNING: vLLM not healthy (HTTP $http_code). Will retry in 60s..."
    sleep 60
    http_code=$(curl -sk -o /dev/null -w '%{http_code}' "$BASE_URL/models" \
      -H "Authorization: Bearer $API_KEY" 2>/dev/null || echo "000")
    if [[ "$http_code" != "200" ]]; then
      log "ERROR: vLLM still not healthy (HTTP $http_code). Aborting."
      exit 1
    fi
  fi
  log "vLLM healthy (HTTP 200)"
}

# ═══════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════

log "=========================================="
log "AUTONOMOUS K8s BENCHMARK MONITOR STARTING"
log "Model:       $MODEL"
log "Model slug:  $MODEL_SLUG"
log "Language:    $LANGUAGE"
log "Parallel:    $PARALLEL"
log "Max retries: $MAX_RETRIES"
log "Hung threshold: ${HUNG_THRESHOLD_SEC}s"
log "Namespace:   $NAMESPACE"
log "Workspace:   $WORKSPACE"
log "vLLM:        $BASE_URL"
log "Log file:    $LOG_FILE"
log "=========================================="

# Preflight checks
if [[ ! -f "$JSONL_FILE" ]]; then
  log "ERROR: Dataset not found at $JSONL_FILE"
  exit 1
fi
if [[ ! -f "$AMI_BINARY" ]]; then
  log "ERROR: AMI binary not found at $AMI_BINARY"
  exit 1
fi

check_vllm_health

# ── Backlog eval sweep: eval any instances with results but no report ──
# Catches instances whose agent jobs auto-deleted (ttlSecondsAfterFinished)
# before process_completed could see their Complete status.
log "Sweeping for unevaluated backlog instances..."
# Snapshot ALL existing swebench jobs (running, pending, just-completed-ttl-pending).
# output.jsonl is only safe to use as a "done" signal when the job has fully disappeared.
# status.active!=0 misses pods in ContainerCreating — use the full job list instead.
backlog_existing_snap=$(timeout 30 oc get jobs -n "$NAMESPACE" -l app=swebench-instance \
  --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ':' || echo "")
backlog_count=0
while IFS= read -r inst; do
  [[ -z "$inst" ]] && continue
  res_dir="$VERIFIED_DIR/$inst/results"
  eval_dir="$VERIFIED_DIR/$inst/eval-results"
  job_name=$(job_name_for_instance "$inst")
  # Skip instances whose job still exists in K8s (running, starting, or within ttl window)
  if [[ ":$backlog_existing_snap:" == *":$job_name:"* ]]; then
    continue
  fi
  # If a previous premature run wrote empty_patch but job later produced a real patch, clear it
  if [[ -f "$eval_dir/report.json" && -f "$res_dir/ami-${MODEL_SLUG}-diff.patch" && -s "$res_dir/ami-${MODEL_SLUG}-diff.patch" ]]; then
    prev_err=$(python3 -c "import json; print(json.load(open('$eval_dir/report.json')).get('error',''))" 2>/dev/null || echo "")
    if [[ "$prev_err" == "empty_patch" ]]; then
      log "  Clearing stale empty_patch report for $inst (patch now exists)"
      rm -f "$eval_dir/report.json"
    fi
  fi
  # Has results but no valid eval report (also catches killed jobs with output.jsonl but no patch)
  has_output=0
  [[ -f "$res_dir/ami-${MODEL_SLUG}-diff.patch" ]] && has_output=1
  [[ -f "$res_dir/ami-${MODEL_SLUG}.json" ]] && has_output=1
  [[ -f "$res_dir/ami-${MODEL_SLUG}-output.jsonl" ]] && has_output=1
  if [[ $has_output -eq 1 ]]; then
    # Ensure patch file exists (touch if missing — killed jobs produce no patch)
    [[ ! -f "$res_dir/ami-${MODEL_SLUG}-diff.patch" ]] && touch "$res_dir/ami-${MODEL_SLUG}-diff.patch"
    if [[ ! -f "$eval_dir/report.json" ]]; then
      log "  Backlog eval: $inst"
      postprocess_instance "$inst" 2>/dev/null || true
      run_evaluation "$inst"
      backlog_count=$((backlog_count + 1))
    fi
  fi
done < <(jq -r '.instance_id' "$JSONL_FILE")
log "Backlog sweep done: $backlog_count instances evaluated"

# ── Phase 1: Initial run ──────────────────────────────────────────────

existing=$(count_with_results)
if [[ $existing -ge $TOTAL_INSTANCES ]]; then
  log "All $TOTAL_INSTANCES instances already have results, skipping to retry phase"
else
  log "Phase 1: Running all $TOTAL_INSTANCES instances ($existing already done)"

  # Build instance list (skip already-completed)
  INITIAL_LIST="$WORKSPACE/logs/initial-instances.txt"
  > "$INITIAL_LIST"
  while IFS= read -r inst; do
    [[ -z "$inst" ]] && continue
    # Skip if already verified (resolved in a prior run)
    [[ -d "$VERIFIED_DIR/$inst" ]] && continue
    # Skip if already has results in working dir
    local_result="$VERIFIED_DIR/$inst/results"
    if [[ -f "$local_result/ami-${MODEL_SLUG}-diff.patch" || -f "$local_result/ami-${MODEL_SLUG}.json" ]]; then
      continue
    fi
    echo "$inst" >> "$INITIAL_LIST"
  done < <(jq -r '.instance_id' "$JSONL_FILE")

  initial_count=$(wc -l < "$INITIAL_LIST")
  if [[ $initial_count -gt 0 ]]; then
    log "Launching $initial_count instances (skipping $existing existing)..."
    run_batch "$INITIAL_LIST" "initial-run"
  else
    log "All instances already attempted"
  fi

  log "Phase 1 COMPLETE"
  promote_and_archive "initial"
  resolved=$(count_resolved)
  log "After initial run: $resolved/$TOTAL_INSTANCES resolved (in verified/)"
fi

# ── Phase 2: Retry loop ──────────────────────────────────────────────

prev_resolved=$(count_resolved)
log "Starting retry phase. Current resolved: $prev_resolved/$TOTAL_INSTANCES"

consecutive_no_flip=0

# Find first available backup number (skip existing backups)
next_backup=1
while [[ -d "$RUNS_DIR/run${next_backup}" ]]; do
  next_backup=$((next_backup + 1))
done
log "Starting retries from backup $next_backup"

for retry_round in $(seq 1 $MAX_RETRIES); do
  run_num=$((next_backup + retry_round - 1))

  log ""
  log "=========================================="
  log "RETRY ROUND $retry_round / $MAX_RETRIES (backup: run$run_num)"
  log "=========================================="

  # Re-check vLLM health before each retry
  check_vllm_health

  # Build retry list (use logical retry_round for filtering rules)
  retry_file=$(build_retry_list "$retry_round")
  retry_count=$(wc -l < "$retry_file")

  if [[ $retry_count -eq 0 ]]; then
    log "ALL $TOTAL_INSTANCES INSTANCES RESOLVED! Perfect score!"
    break
  fi

  log "Retry candidates: $retry_count instances"

  # Backup current results before overwriting
  promote_and_archive "$run_num"

  # Run retry
  run_retry "$run_num" "$retry_file" || {
    log "Retry run $run_num had no instances to run"
    break
  }

  # Check for flips
  new_resolved=$(count_resolved)
  flips=$((new_resolved - prev_resolved))
  log "RETRY $run_num RESULT: $new_resolved/$TOTAL_INSTANCES resolved ($flips new flips)"

  # Failure analysis
  analyze_failures

  prev_resolved=$new_resolved

  if [[ $flips -eq 0 ]]; then
    consecutive_no_flip=$((consecutive_no_flip + 1))
    log "No flips in retry round $retry_round/run$run_num ($consecutive_no_flip consecutive rounds with no flips)"
    if [[ $consecutive_no_flip -ge 10 ]]; then
      log "10 consecutive rounds with no flips -- stopping retry loop"
      promote_and_archive "final_failures"
      break
    fi
  else
    consecutive_no_flip=0
    log "Flipped $flips instances, continuing to next retry round..."
  fi
done

# Archive any remaining unresolved from the last retry round
# (promote_and_archive runs at the START of each round, so the last round's
# failures are still in verified/ when the loop exits naturally)
promote_and_archive "final"

# ── Phase 3: Final summary ───────────────────────────────────────────

final_resolved=$(count_resolved)
final_pct=$(python3 -c "print(f'{$final_resolved*100/$TOTAL_INSTANCES:.1f}')" 2>/dev/null || echo "?")

log ""
log "=========================================="
log "AUTONOMOUS K8s BENCHMARK RUN COMPLETE"
log "Final: $final_resolved/$TOTAL_INSTANCES ($final_pct%)"
log "=========================================="

# Final cleanup
cleanup_completed_jobs

log "All done. Exiting."

