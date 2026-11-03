#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# swebench-live-vllm — central configuration (single source of truth)
#
# Every script sources this file via scripts/lib/common.sh. Every kustomize
# overlay mirrors the vendor-specific values here. Change a value in ONE place.
#
# Override any value from your shell, e.g.:
#   GPU_VENDOR=amd CLUSTER_SERVER=https://api.my-amd-cluster:6443 bash scripts/00-preflight.sh
# ─────────────────────────────────────────────────────────────────────────────

# ── Cluster target ───────────────────────────────────────────────────────────
# The scripts refuse to run unless `oc whoami --show-server` matches this.
# NVIDIA baseline target is the dev06 RHOAI cluster (same as the post-training
# reference / sibling ticket NVIDIA-1537).
: "${CLUSTER_SERVER:=https://api.<your-cluster>:6443}"
: "${DASHBOARD_HOST:=rhods-dashboard-redhat-ods-applications.apps.<your-cluster>}"

# ── GPU vendor (vendor-parameterized: nvidia | amd) ──────────────────────────
# Selects the resource name, kustomize overlay, accelerator flavor, storage
# class, and node taint tolerations used across every template.
: "${GPU_VENDOR:=nvidia}"

if [[ "${GPU_VENDOR}" == "amd" ]]; then
  : "${GPU_RESOURCE:=amd.com/gpu}"
  : "${STORAGE_CLASS:=managed-csi}"
  : "${RWX_STORAGE_CLASS:=managed-csi}"
  : "${ACCELERATOR_FLAVOR:=amd-mi300x}"          # Kueue ResourceFlavor name
  : "${ACCELERATOR_LABEL:=amd.com/gpu.product}"  # node label selected by the flavor
  : "${ACCELERATOR_LABEL_VALUE:=Instinct-MI300X}"
  : "${GPU_TAINT_KEY:=amd-gpu}"                   # node taint the workloads tolerate
  : "${VLLM_IMAGE:=vllm/vllm-openai-rocm:latest}"
  : "${KSERVE_OVERLAY:=amd}"
  # NOTE: one MI300X = 192GB, so Qwen3-32B fits on ONE GPU. On the AMD/MI300X
  # overlay the vLLM endpoint uses amd.com/gpu: "1" and --tensor-parallel-size 1
  # (TP is patched down from the NVIDIA baseline of 4). The amd overlay also
  # renames the base ResourceFlavor nvidia-a10g -> amd-mi300x.
else
  : "${GPU_RESOURCE:=nvidia.com/gpu}"
  : "${STORAGE_CLASS:=gp3-csi}"
  : "${RWX_STORAGE_CLASS:=ocs-storagecluster-cephfs}"  # RWX for shared squad workspace
  # Primary NVIDIA target is now the A10G (AWS g5) GPU worker pool. Qwen3-32B needs
  # 4x A10G (24GB each) with tensor-parallel-size 4 to fit weights + KV cache.
  : "${ACCELERATOR_FLAVOR:=nvidia-a10g}"
  : "${ACCELERATOR_LABEL:=nvidia.com/gpu.product}"
  : "${ACCELERATOR_LABEL_VALUE:=NVIDIA-A10G}"
  : "${GPU_TAINT_KEY:=g5-gpu}"
  : "${VLLM_IMAGE:=quay.io/modh/vllm:rhoai-2.16}"   # RHOAI-supported vLLM runtime image
  : "${KSERVE_OVERLAY:=nvidia}"
fi

# ── Model served by every squad's vLLM endpoint ──────────────────────────────
# NOTE: this string must match a model that is actually available on the target
# cluster / model registry (pullable from Hugging Face, or mirrored to the OCI/S3/PVC
# source you point storageUri at for air-gapped runs). Keep MODEL_ID, SERVED_MODEL_NAME,
# and the kustomize serving manifests in lockstep with this value.
#
# Qwen3-32B is the largest/latest Qwen3 dense model that fits on 4x A10G (24GB each)
# with tensor-parallel-size 4, bfloat16 weights, and gpu-memory-utilization 0.90.
# MAX_MODEL_LEN is capped at 32768 so the KV cache fits across the 4x A10G shard; the
# cache fits alongside the weights across the 4-GPU shard.
: "${MODEL_ID:=Qwen/Qwen3-32B}"
: "${SERVED_MODEL_NAME:=Qwen/Qwen3-32B}"
: "${MODEL_SLUG:=qwen-qwen3-32b}"
: "${MAX_MODEL_LEN:=32768}"
: "${TOOL_CALL_PARSER:=qwen3_xml}"
: "${VLLM_API_KEY:=swebench-token}"

# ── vLLM parallelism / GPUs per endpoint ─────────────────────────────────────
# Each squad's vLLM endpoint shards Qwen3-32B across 4 A10G GPUs (TP=4). On the
# AMD/MI300X overlay the endpoint instead runs on 1 GPU with TP=1 (see amd branch).
: "${TENSOR_PARALLEL:=4}"          # --tensor-parallel-size for the NVIDIA baseline
: "${GPUS_PER_ENDPOINT:=4}"        # nvidia.com/gpu requested+limited per vLLM pod

# ── Squads → SWE-bench Live splits (NVIDIA-1535) ─────────────────────────────
# Squad A is the high-priority / high-SLO team that may run over quota.
SQUADS=("a" "b" "c")
declare -A SQUAD_NS=(   [a]="squad-a-lite"  [b]="squad-b-cpp"    [c]="squad-c-csharp" )
declare -A SQUAD_SPLIT=([a]="lite"          [b]="cpp"            [c]="csharp" )
declare -A SQUAD_LABEL=([a]="Squad A — SWE-bench Lite" [b]="Squad B — SWE-bench C/C++" [c]="Squad C — SWE-bench C#")
declare -A SQUAD_PRIORITY=([a]="squad-high-priority" [b]="squad-standard" [c]="squad-standard")

# ── Shared GPU pool / Kueue quotas (illustrative — tune to real cluster) ─────
# One cohort shares all GPUs; each squad has nominal quota + a borrowing limit.
# The pool is 8 A10G GPUs == exactly TWO 4-GPU vLLM endpoints. Squad A (high SLO)
# is guaranteed its whole 4-GPU endpoint and can reclaim/preempt to take the entire
# pool; B and C each get 2 nominal and must borrow 2 more to stand up their own
# 4-GPU endpoint, lending/reclaiming via preemption.
#
# SQUAD_X_GPU_BORROW is the Kueue borrowingLimit: ADDITIONAL GPUs on top of nominal,
# so ceiling = nominal + borrow.
#
#   squad   nominal   borrow (additional)   ceiling (nominal + borrow)
#   A       4         4                     8   (can take the whole pool)
#   B       2         2                     4   (one 4-GPU endpoint)
#   C       2         2                     4   (one 4-GPU endpoint)
#   total   8         —                     —   (sum of nominal == pool size)
#
# Run:AI analogue (deploy/runai): deserved = nominal (4/2/2), over-quota ceiling
# maxAllowed = 8/4/4. Keep these in sync with clusterqueue-squad-{a,b,c}.yaml.
: "${COHORT_NAME:=swebench-gpu-pool}"
: "${POOL_GPU_TOTAL:=8}"          # total GPUs in the shared cohort (two 4-GPU endpoints)
: "${SQUAD_A_GPU_NOMINAL:=4}"
: "${SQUAD_B_GPU_NOMINAL:=2}"
: "${SQUAD_C_GPU_NOMINAL:=2}"
: "${SQUAD_A_GPU_BORROW:=4}"      # additional borrow => 4 + 4 = 8 ceiling (whole pool)
: "${SQUAD_B_GPU_BORROW:=2}"      # additional borrow => 2 + 2 = 4 ceiling (one endpoint)
: "${SQUAD_C_GPU_BORROW:=2}"      # additional borrow => 2 + 2 = 4 ceiling (one endpoint)
# CPU/memory quota per squad (for the test-execution jobs + coordinator)
: "${SQUAD_CPU_NOMINAL:=64}"
: "${SQUAD_MEM_NOMINAL:=256Gi}"

# ── Kueue / scheduling object names ──────────────────────────────────────────
: "${PRIORITY_HIGH:=squad-high-priority}"
: "${PRIORITY_STANDARD:=squad-standard}"
: "${DRA_DEVICE_CLASS:=gpu.${GPU_VENDOR}.com}"
: "${DRA_CLAIM_TEMPLATE:=single-gpu}"
: "${HARDWARE_PROFILE:=swebench-gpu-profile}"
: "${LOCAL_QUEUE:=default}"       # LocalQueue name inside each squad namespace

# ── Run:AI (Phase 2) ─────────────────────────────────────────────────────────
: "${RUNAI_SCHEDULER:=runai-scheduler}"
: "${RUNAI_DEPARTMENT:=swebench}"
: "${RUNAI_OVERQUOTA:=true}"      # Squad A over-quota enabled

# ── Benchmark engine knobs (from proven ocp_cluster run) ─────────────────────
: "${PARALLEL:=3}"                # concurrent agent Jobs per squad
: "${MAX_TURNS:=40}"
: "${MAX_RETRIES:=10}"

export GPU_VENDOR GPU_RESOURCE STORAGE_CLASS RWX_STORAGE_CLASS ACCELERATOR_FLAVOR \
  ACCELERATOR_LABEL ACCELERATOR_LABEL_VALUE GPU_TAINT_KEY VLLM_IMAGE KSERVE_OVERLAY \
  CLUSTER_SERVER DASHBOARD_HOST MODEL_ID SERVED_MODEL_NAME MODEL_SLUG MAX_MODEL_LEN \
  TENSOR_PARALLEL GPUS_PER_ENDPOINT \
  TOOL_CALL_PARSER VLLM_API_KEY COHORT_NAME POOL_GPU_TOTAL \
  SQUAD_A_GPU_NOMINAL SQUAD_B_GPU_NOMINAL SQUAD_C_GPU_NOMINAL \
  SQUAD_A_GPU_BORROW SQUAD_B_GPU_BORROW SQUAD_C_GPU_BORROW \
  PRIORITY_HIGH PRIORITY_STANDARD \
  DRA_DEVICE_CLASS DRA_CLAIM_TEMPLATE HARDWARE_PROFILE LOCAL_QUEUE RUNAI_SCHEDULER \
  RUNAI_DEPARTMENT RUNAI_OVERQUOTA PARALLEL MAX_TURNS MAX_RETRIES
