# NVIDIA-1535 — Multi-Tenant Autonomous Coding Agents on a Shared GPU Cluster

This project is the RHOAI-first baseline for Jira **NVIDIA-1535**. Three data-science
squads share one Red Hat OpenShift AI (RHOAI) GPU cluster. Each squad runs an
autonomous coding agent (the **AMI** agent) that solves real GitHub issues drawn from a
different SWE-bench Live split. Every agent talks to a self-hosted **vLLM** endpoint for
LLM inference (GPU) and runs the issue's real test suite (CPU) to validate the patch it
produces.

The goal is a **working OpenShift AI baseline** built from Kueue + Dynamic Resource
Allocation (DRA) + RHOAI hardware profiles, followed by a **Run:ai phase** that
re-targets the *same* workloads (same projects, same manifests, the Run:ai scheduler and
annotations, the same over-quota policies) so the two platforms can be compared on
identical work rather than on toy jobs.

Like the sibling ticket NVIDIA-1537 post-training baseline, this repo is deliberately
scoped and repeatable: the scheduling and serving stack is declarative
(`deploy/`), every action is a guarded shell script (`scripts/`), and the agent/eval
engine is the proven SWE-bench runner copied verbatim into `benchmark/`. All names and
quotas live in one place, [`config/env.sh`](../config/env.sh), which every script sources
and every overlay mirrors.

## The squads and their work

| Squad | Namespace | SWE-bench Live split | Priority / SLO | Over-quota |
|-------|-----------|----------------------|----------------|------------|
| Squad A | `squad-a-lite` | SWE-bench **Lite** | HIGH priority, high SLO | **MAY run over quota** |
| Squad B | `squad-b-cpp` | SWE-bench **C/C++** | standard | standard borrowing |
| Squad C | `squad-c-csharp` | SWE-bench **C#** | standard | standard borrowing |

Every object the project creates carries the labels
`app.kubernetes.io/part-of: swebench-live-vllm`, `squad: a|b|c`, and
`split: lite|cpp|csharp`, so a single label selector can scope status, metrics, and
teardown to one squad or to the whole project.

## Shared GPU pool and quotas

All GPUs sit in one Kueue **cohort**, `swebench-gpu-pool` (**8x A10G** total on the NVIDIA
baseline — two vLLM endpoints' worth, since each endpoint needs 4 A10G at tensor-parallel 4).
Each squad gets a nominal quota and a borrowing ceiling (ceiling = nominal + borrow) so that
an idle squad's share is *lent* to a busy neighbour and *reclaimed* by preemption when the
owner comes back:

| Squad | ClusterQueue | Nominal GPUs | Borrowing limit | Rationale |
|-------|--------------|--------------|-----------------|-----------|
| A | `cq-squad-a` | 4 | up to 4 (ceiling 8) | High-priority; its whole 4-GPU endpoint is SLO-guaranteed and it can reclaim the whole pool |
| B | `cq-squad-b` | 2 | up to 2 (ceiling 4) | Borrows 2 to stand up its 4-GPU endpoint; yields via preemption when A bursts |
| C | `cq-squad-c` | 2 | up to 2 (ceiling 4) | Borrows 2 to stand up its 4-GPU endpoint; yields via preemption when A bursts |

Each squad namespace has one LocalQueue named `default` pointing at its ClusterQueue.
Priority is expressed with two classes: `squad-high-priority` (Squad A, higher value) and
`squad-standard` (Squad B and C). These values are illustrative and are tuned to the real
cluster before a verified run; they are defined once in `config/env.sh`.

## The model

Every squad's endpoint serves **`Qwen/Qwen3-32B`** through vLLM:

- OpenAI-compatible API on port `8000` under `/v1`, Service name `qwen-inference`.
- Served model name `Qwen/Qwen3-32B`, bearer token `swebench-token`.
- Sharded across **4x A10G** (`--tensor-parallel-size 4`, `dtype bfloat16`,
  `--gpu-memory-utilization 0.90`) with `--max-model-len 32768` (32K) so the KV cache fits
  on the A10G pool. Keeps `--enable-auto-tool-choice`, `--tool-call-parser qwen3_xml`,
  `--enable-prefix-caching`, and the thinking/reasoning chat-template kwargs.
- RHOAI-supported runtime image `quay.io/modh/vllm:rhoai-2.16` on the NVIDIA baseline; the
  AMD overlay serves the same model on **1x MI300X** (`--tensor-parallel-size 1`, since one
  MI300X's 192 GB holds the 32B model on a single GPU).
- The model string must resolve on the target cluster/registry (pullable from Hugging Face
  or mirrored into the model cache), or the vLLM pod will not start.

The AMI agent points at the in-cluster endpoint
(`http://qwen-inference.<squad-namespace>.svc.cluster.local:8000/v1`), exactly as the
proven engine in `benchmark/run-instance-k8s.sh` expects.

## Objective

Stand up a baseline on OpenShift AI that demonstrates, on real multi-tenant agent
workloads, that RHOAI's native stack can:

1. **Admit** each squad's workloads against its own quota and priority.
2. **Borrow** idle GPU capacity across the cohort.
3. **Reclaim / preempt** borrowed capacity when the owner (or a higher-priority squad)
   bursts.
4. **Share** GPUs between inference and the many short CPU/GPU agent and eval jobs.
5. **Coordinate** the multi-pod agent run (endpoint + coordinator + per-instance jobs) so
   work starts as a unit, with full **observability** throughout.

Then re-run the *same* workloads under Run:ai and compare — see
[EVALUATION.md](./EVALUATION.md) and [RHOAI-VS-RUNAI.md](./RHOAI-VS-RUNAI.md).

## The five key scenarios

Each scenario has a runnable driver under `scripts/scenarios/` and a detailed write-up in
[SCENARIOS.md](./SCENARIOS.md).

1. **Admission control & nominal quota** — `scripts/scenarios/scenario-1-multiteam-allocation.sh`.
   Each squad is admitted up to its nominal GPU quota (A=4, B=2, C=2); excess work is
   queued, not rejected.
2. **Quota borrowing from an idle cohort** — `scripts/scenarios/scenario-2-dynamic-utilization.sh`.
   With neighbours idle, one squad bursts and borrows beyond its nominal quota up to its
   borrowing limit.
3. **Reclamation & preemption under a high-priority burst** —
   `scripts/scenarios/scenario-3-reclamation.sh`. Squad A (high priority) submits a burst and
   reclaims GPUs that B/C had borrowed; lower-priority workloads are preempted and
   re-queued.
4. **GPU sharing between inference and eval** — `scripts/scenarios/scenario-4-gpu-sharing.sh`.
   The long-lived vLLM endpoint and the short agent/eval jobs share GPU capacity under
   the shared cohort and the `single-gpu` DRA claim.
5. **Coordinated (gang) scheduling of an agent run** —
   `scripts/scenarios/scenario-5-coordinated-observability.sh`. The endpoint, coordinator, and the
   first wave of per-instance jobs are admitted together so a run does not start
   half-provisioned.

Observability is cross-cutting: `scripts/06-status.sh` summarizes Kueue admission and GPU
allocation per squad, and `benchmark/telemetry_parse.py` scrapes vLLM `/metrics`
throughout a run.

## Evaluation approach

The project is evaluated in two phases on identical work:

- **Phase 1 — RHOAI baseline.** Kueue (cohort, ClusterQueues, LocalQueues,
  WorkloadPriorityClasses), DRA (DeviceClass + ResourceClaimTemplate), and an RHOAI
  hardware profile schedule the squads onto the shared pool. KServe serves Qwen through
  vLLM. The five scenarios are run and measured.
- **Phase 2 — Run:ai.** The same namespaces, manifests, and over-quota intent are
  re-targeted to the Run:ai scheduler with Run:ai projects/departments and annotations.
  The same five scenarios are run again.

For every scenario we capture workload admission, GPU allocation and utilization,
scheduling delay, preemption/reclamation behavior, and end-to-end issue-completion time,
then fill the comparison tables in [EVALUATION.md](./EVALUATION.md). The capability/gap
analysis — what RHOAI covers today and where (if anywhere) Run:ai adds incremental value
without duplicating it — lives in [RHOAI-VS-RUNAI.md](./RHOAI-VS-RUNAI.md).

> This document describes the scenario and the plan. It does **not** report run results;
> those are filled in after a verified run on the target cluster, following the tone of
> the NVIDIA-1537 post-training baseline.

## References

- [RHOAI: Managing distributed workloads (Kueue)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [RHOAI: Working with accelerators and hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [RHOAI: Serving models (KServe)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [Kubernetes: Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [Kueue documentation](https://kueue.sigs.k8s.io/docs/)
- [NVIDIA Run:ai documentation](https://docs.nvidia.com/run-ai/)
- [SWE-bench Live](https://www.swebench.com/)
