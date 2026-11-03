# swebench-live-vllm — convenience wrappers around the numbered scripts.
#
# Every script sources config/env.sh (the single source of truth) and refuses to
# run unless `oc whoami --show-server` matches $CLUSTER_SERVER. These targets add
# no logic of their own; they just invoke the scripts so the common flow is
# discoverable via `make help`. Override config from the shell, e.g.:
#   make serving    GPU_VENDOR=amd
#   make scenario-1 SCHEDULER=runai
#   make launch     ARGS="--squad a"
#
# NVIDIA-1535 — Multi-Tenant Autonomous Coding Agents on a Shared GPU Cluster.

SHELL := /usr/bin/env bash

# Scheduler used by the scenario targets: rhoai (Phase 1) or runai (Phase 2).
SCHEDULER ?= rhoai

.DEFAULT_GOAL := help

.PHONY: help preflight projects scheduling serving agents launch status \
        runai-enable scenario-1 scenario-2 scenario-3 scenario-4 scenario-5 teardown

help: ## Show this help
	@echo "swebench-live-vllm — targets (run them in order for Phase 1):"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) \
	  | sed -E 's/^([a-zA-Z0-9_-]+):.*## /  \1\t/' \
	  | sort | column -t -s $$'\t'
	@echo ""
	@echo "Config comes from config/env.sh; override on the CLI (e.g. SCHEDULER=runai, GPU_VENDOR=amd)."

## ── Phase 1: RHOAI baseline (Kueue + DRA + hardware profiles) ────────────────

preflight: ## Verify oc login matches CLUSTER_SERVER and RHOAI/Kueue/DRA are present
	bash scripts/00-preflight.sh

projects: ## Create the three squad namespaces/projects and the RHOAI dashboard label
	bash scripts/01-create-projects.sh

scheduling: ## Deploy cohort, ClusterQueues, ResourceFlavor, DRA, PriorityClasses, and per-squad LocalQueues
	bash scripts/02-deploy-scheduling.sh

serving: ## Deploy the vLLM (Qwen3.8-27B) ServingRuntime + InferenceService + HardwareProfile per squad
	bash scripts/03-deploy-serving.sh

agents: ## Deploy the AMI agent coordinator, RBAC, and workspace PVCs per squad
	bash scripts/04-deploy-agents.sh

launch: ## Start the autonomous per-squad SWE-bench Live run (pass ARGS="--squad a")
	bash scripts/05-launch-benchmark.sh $(ARGS)

status: ## Show queues, workloads, GPU allocation, and run progress
	bash scripts/06-status.sh

## ── Phase 2: Run:ai (re-target the same workloads) ───────────────────────────

runai-enable: ## Install/enable Run:ai and apply the Run:ai quota/priority policies
	bash scripts/runai/10-enable-runai.sh
	bash scripts/runai/11-apply-runai-policies.sh

## ── Scheduling scenarios (add SCHEDULER=runai to compare) ────────────────────

scenario-1: ## Multi-team allocation: all squads contend for the shared pool at once
	bash scripts/scenarios/scenario-1-multiteam-allocation.sh --scheduler $(SCHEDULER)

scenario-2: ## Dynamic utilization: idle squad's GPUs lent to a busy squad
	bash scripts/scenarios/scenario-2-dynamic-utilization.sh --scheduler $(SCHEDULER)

scenario-3: ## Reclamation/preemption: owner bursts and reclaims lent GPUs
	bash scripts/scenarios/scenario-3-reclamation.sh --scheduler $(SCHEDULER)

scenario-4: ## GPU sharing: fractional / time-sliced GPU across small agent jobs
	bash scripts/scenarios/scenario-4-gpu-sharing.sh --scheduler $(SCHEDULER)

scenario-5: ## Coordinated observability: gang scheduling + per-squad allocation visibility
	bash scripts/scenarios/scenario-5-coordinated-observability.sh --scheduler $(SCHEDULER)

## ── Cleanup ──────────────────────────────────────────────────────────────────

teardown: ## Remove deployed workloads/queues (pass ARGS="--squad all" etc.)
	bash scripts/teardown.sh $(ARGS)
