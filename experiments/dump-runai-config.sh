#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Generate reports/runai-config.md: a reference of how Run:ai is configured on
# ai-dev06 — projects/queues/quotas, departments, priority classes, the over-quota
# setting, and the actual labels/annotations/PodGroup/scheduler on live workloads.
# Re-runnable; reads the live cluster (oc) + control-plane setting (api).
#   export RUNAI_PASSWORD=... ; ./dump-runai-config.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh
OUT="${1:-../reports/runai-config.md}"
FMT="python3 -I _runai_fmt.py"

a_pod=$(oc get pods -n runai-team-a -o name 2>/dev/null | grep -m1 qwen-kserve | cut -d/ -f2)
a_pg=$(oc get podgroups.scheduling.run.ai -n runai-team-a -o name 2>/dev/null | grep -m1 qwen | cut -d/ -f2)

{
echo "# Run:ai configuration reference — cluster ai-dev06"
echo
echo "_Generated $(date -u '+%Y-%m-%d %H:%M UTC') from the live cluster (\`experiments/dump-runai-config.sh\`)._"
echo "NVIDIA Run:ai (KAI scheduler) v3.0.20 on OpenShift. Shows how the demo's priority /"
echo "quota / preemption behaviour is actually wired."
echo
echo "## 1. Projects (\`projects.kai.resources\`) — namespace, scheduler, GPU quota"
echo '```'
oc get projects.kai.resources -o json 2>/dev/null | $FMT projects
echo '```'
echo "Team A has guaranteed GPUs (\`deserved: 4\`); Team B \`deserved: 0\` → everything it runs"
echo "on a GPU is over-quota and therefore reclaimable."
echo
echo "## 2. Scheduling queues (\`queues.scheduling.run.ai\`) — the quota hierarchy"
echo '```'
oc get queues.scheduling.run.ai -o json 2>/dev/null | $FMT queues
echo '```'
echo "Project queues → department queue \`q-4500000\` (\"default\"). An under-quota queue may"
echo "reclaim from an over-quota sibling."
echo
echo "## 3. Priority classes (category → priority → preemption)"
echo '```'
oc get priorityclass 2>/dev/null | grep -iE "NAME|^inference|^build|^train|runai-critical"
echo '```'
echo "| Category | priorityClass | preemptible |"
echo "|---|---|---|"
echo "| Deploy (Inference) | inference / very-high | No |"
echo "| Build (Workspace/Notebook) | build / high | No |"
echo "| Train (Training/Job) | train / low | Yes |"
echo
echo "## 4. Over-quota feature flag (control-plane setting)"
echo '```'
api GET /v1/k8s/setting 2>/dev/null | $FMT setting
echo '```'
echo "Must be \`true\` for \`deserved:0\` projects to borrow GPUs (and thus be reclaimed)."
echo
echo "## 5. Labels & annotations on a live workload (Team A inference pod)"
if [ -n "${a_pod:-}" ]; then
  echo '```'
  echo "pod: $a_pod"
  oc get pod "$a_pod" -n runai-team-a -o json 2>/dev/null | $FMT pod
  echo '```'
else
  echo "_(no Team A inference pod running right now)_"
fi
echo
echo "What they do:"
echo "- \`project=<name>\` + the project namespace → maps the pod to its **Queue** (quota)."
echo "- \`run.ai/workload-id\`, \`run.ai/top-owner-uid\` → group a workload's pods together."
echo "- \`pod-group-name\` annotation → the **PodGroup** (gang-scheduling unit)."
echo "- \`runai-allocated-gpus\` / \`-gpu-memory\` → what the scheduler allocated."
echo "- \`schedulerName: runai-scheduler\` → KAI schedules it (not default-scheduler)."
echo
echo "## 6. PodGroup — the scheduling unit (queue + priority + gang)"
if [ -n "${a_pg:-}" ]; then
  echo '```json'
  oc get podgroup.scheduling.run.ai "$a_pg" -n runai-team-a -o jsonpath='{.spec}' 2>/dev/null | $FMT podgroup
  echo '```'
else
  echo "_(no Team A PodGroup right now)_"
fi
echo
echo "## 7. Team A inference — RHOAI \`LLMInferenceService\` (Deploy)"
echo '```'
oc get llminferenceservice team-a-qwen -n runai-team-a -o json 2>/dev/null | $FMT llmisvc
echo '```'
echo
echo "## 8. Team B workload — real LoRA fine-tuning (Train), see \`post-training/\`"
echo "Team B's reclaimable GPU workload is the real RHOAI Training Hub LoRA SFT job"
echo "(\`post-training/deploy/batch-training-job.yaml\`, model \`Qwen/Qwen2.5-1.5B-Instruct\`,"
echo "1 GPU, image \`registry.redhat.io/rhoai/odh-workbench-...pytorch-cuda\`). Launch with"
echo "\`post-training/scripts/submit-batch-job.sh\`."
echo
echo "---"
echo "_Regenerate: \`cd experiments && ./dump-runai-config.sh\`_"
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
