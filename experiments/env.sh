#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# ai-dev06 cluster adaptation of the swebench-live-vllm demo.
#
# WHY THIS OVERLAY EXISTS
#   The repo's base templates (deploy/base, deploy/runai) target an 8-GPU cluster
#   with 4-GPU nodes, Kueue OR run.ai/v2alpha1 CRDs, and Qwen3-32B (tensor-parallel
#   4). The live cluster ai-dev06 is different:
#     - 5 GPUs on 5 SINGLE-GPU nodes (4x NVIDIA-A10G 24GB + 1x NVIDIA-L40S 48GB)
#       => no pod can get 4 GPUs; tensor-parallel 4 is impossible. We serve a
#          model that fits ONE A10G instead.
#     - Scheduler is NVIDIA Run:ai / KAI (runai-scheduler), NOT Kueue.
#     - Projects/Departments are kai.resources CRs synced from the Run:ai control
#       plane; they are created via the REST API, not `oc apply` of a CRD.
#     - GPU nodes carry taints g5-gpu (A10G) / g6e-gpu (L40S) that workloads must
#       tolerate.
#
#   So this overlay drives the Run:ai REST API with versioned JSON payloads
#   (team-*.json) applied by the numbered scripts. That is the reproducible,
#   committable path for THIS cluster.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# --- Control plane / cluster ----------------------------------------------------
: "${RUNAI_CP:=https://runai.apps.<your-cluster>}"
: "${RUNAI_CLUSTER_ID:?export RUNAI_CLUSTER_ID (the Run:ai cluster UUID)}"
: "${RUNAI_DEPARTMENT_ID:=4500000}"      # department "default"
: "${RUNAI_NODEPOOL_ID:=100000}"         # nodepool "default"
: "${RUNAI_NODEPOOL_NAME:=default}"

# --- Auth (NEVER hard-code the password; export these before running) -----------
# For ai-dev06 the built-in system-administrator is test@run.ai. Its password and
# the Keycloak master-admin creds live in cluster secrets (see README.md ->
# "Getting an admin token"). Export RUNAI_USER / RUNAI_PASSWORD in your shell.
: "${RUNAI_USER:=test@run.ai}"
: "${RUNAI_PASSWORD:?export RUNAI_PASSWORD before running (see README.md)}"
: "${RUNAI_OIDC_CLIENT:=runai}"          # public ROPC client in realm 'runai'

# --- Projects (team-a = high priority, team-b-lora = standard/over-quota) --------
: "${TEAM_A_PROJECT:=team-a}"
: "${TEAM_A_PROJECT_ID:=4500005}"        # filled in by 01-setup-projects.sh
: "${TEAM_A_GPU_DESERVED:=4}"            # Team A guaranteed 4 GPUs (reclaimable)
: "${TEAM_B_PROJECT:=team-b-lora}"
: "${TEAM_B_PROJECT_ID:=4500002}"

# --- GPU node taints (tolerated by every workload we submit) ---------------------
# A10G nodes: g5-gpu=true:NoSchedule ; L40S node: g6e-gpu=true:NoSchedule
export RUNAI_TOLERATIONS_JSON='[{"key":"g5-gpu","operator":"Equal","value":"true","effect":"NoSchedule"},{"key":"g6e-gpu","operator":"Equal","value":"true","effect":"NoSchedule"}]'

# --- Inference model (must fit ONE A10G 24GB; Team A reclaims A10Gs) -------------
# Swap MODEL_ID for a larger model if you pin the endpoint to the L40S (48GB).
: "${MODEL_ID:=Qwen/Qwen2.5-3B-Instruct}"
: "${SERVED_MODEL_NAME:=Qwen/Qwen2.5-3B-Instruct}"
: "${MAX_MODEL_LEN:=8192}"
: "${TOOL_CALL_PARSER:=hermes}"          # qwen2.5 => hermes ; qwen3 => qwen3_xml
: "${VLLM_IMAGE:=quay.io/modh/vllm:rhoai-2.16-cuda}"   # CUDA (A10G) variant; base template's :rhoai-2.16 is a 404
: "${VLLM_API_KEY:=swebench-token}"

export RUNAI_CP RUNAI_CLUSTER_ID RUNAI_DEPARTMENT_ID RUNAI_NODEPOOL_ID RUNAI_NODEPOOL_NAME \
  RUNAI_USER RUNAI_PASSWORD RUNAI_OIDC_CLIENT \
  TEAM_A_PROJECT TEAM_A_PROJECT_ID TEAM_A_GPU_DESERVED TEAM_B_PROJECT TEAM_B_PROJECT_ID \
  MODEL_ID SERVED_MODEL_NAME MAX_MODEL_LEN TOOL_CALL_PARSER VLLM_IMAGE VLLM_API_KEY
