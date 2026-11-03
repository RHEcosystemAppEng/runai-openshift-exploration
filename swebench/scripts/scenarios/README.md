# Key-scenario drivers — NVIDIA-1535

These five scripts exercise the multi-tenant GPU-sharing use case for
*Multi-Tenant Autonomous Coding Agents on a Shared GPU Cluster*. Three squads
share one RHOAI GPU cluster (`swebench-gpu-pool`, 8 GPUs):

| Squad | Namespace | SWE-bench split | Priority | Quota (nominal / borrow) |
|-------|-----------|-----------------|----------|--------------------------|
| A | `squad-a-lite` | Lite | `squad-high-priority` (may over-quota) | 2 / 6 |
| B | `squad-b-cpp` | C/C++ | `squad-standard` | 3 / 5 |
| C | `squad-c-csharp` | C# | `squad-standard` | 3 / 5 |

Every driver runs on **both** stacks via `--scheduler rhoai|runai`, so the same
behaviour can be compared between the OpenShift AI / Kueue baseline and Run:AI.
Each run writes a timestamped Markdown summary under `reports/`.

## How the drivers work

Each scenario submits **real, apply-ready GPU Jobs** that carry the exact naming
contract labels (`app.kubernetes.io/part-of: swebench-live-vllm`, `squad`,
`split`) and bind to the right scheduler:

- `--scheduler rhoai` → Job is created **suspended** with the Kueue LocalQueue
  label `kueue.x-k8s.io/queue-name: default` and the WorkloadPriorityClass label,
  so the squad's ClusterQueue performs admission, borrowing and preemption.
- `--scheduler runai` → Job is scheduled by `runai-scheduler` and tagged with the
  Run:AI project (`runai/queue` = squad namespace).

The Jobs hold their GPU(s) for `--hold` seconds (default 900) as controllable
stand-ins for a squad's vLLM endpoint / agent GPU workload. That is what lets the
scheduler actually demonstrate admission, quota borrowing and preemption in a
bounded demo window. To drive the *full* SWE-bench engine instead, use the
benchmark coordinator (see `benchmark/` and the Phase-1 run scripts); the
scheduling behaviour these drivers expose is identical because the agent/eval
Jobs carry the same labels and queue bindings.

Common flags (all scripts): `--scheduler rhoai|runai`, `--hold SECONDS`,
`--dry-run` (render manifests, change nothing), `--cleanup` (delete this
scenario's jobs across all squads, then exit).

## Use-case scenario → driver map

| # | Use-case scenario | Driver | What it does |
|---|-------------------|--------|--------------|
| 1 | **Multi-team allocation** | `scenario-1-multiteam-allocation.sh` | All 3 squads submit concurrently; demand (12 GPUs) exceeds the 8-GPU pool; shows admission arbitration and nominal guarantees. |
| 2 | **Dynamic utilization** | `scenario-2-dynamic-utilization.sh` | Squad C idle; A and B burst past quota and borrow C's share to fill the pool. |
| 3 | **Reclamation / preemption** | `scenario-3-reclamation.sh` | A and B hold borrowed GPUs, then C bursts and reclaims its nominal quota via preemption. |
| 4 | **GPU sharing** | `scenario-4-gpu-sharing.sh` | Heterogeneous GPU workloads (2-GPU profiled vLLM, 1-GPU replicas, single-GPU job) compete for one flavor; shows profile vs no-profile packing. |
| 5 | **Coordinated scheduling + observability** | `scenario-5-coordinated-observability.sh` | Gang (multi-pod, all-or-nothing) workload; applies `deploy/base/observability`; collects admission/placement/preemption evidence and the status overview. |

## Metrics to compare (rhoai vs runai)

Run each scenario once per `--scheduler` and diff the two `reports/` files.

| Dimension | RHOAI / Kueue source | Run:AI source | What it shows |
|-----------|----------------------|---------------|---------------|
| Admission | `oc get clusterqueues -o wide`; Workload `Admitted`/`QuotaReserved` conditions | `runai list projects`; pod scheduling events | Who is admitted vs pending under contention (scenario 1). |
| Quota borrowing | ClusterQueue `BORROWING` columns; GPUs-in-use per squad | project over-quota allocation | Idle share lent out, pool utilization (scenario 2). |
| Reclamation / preemption | Workload `Preempted` conditions; Warning events `preempt/evict/reclaim` | reclaim/preempt events | Borrowed GPUs returned on demand; which squad's pods are evicted (scenario 3). |
| GPU sharing / packing | Workload flavor assignment; pod `NODE` column | Run:AI bin-packing / fractioning | Mixed GPU shapes co-scheduled; fragmentation (scenario 4). |
| Coordinated scheduling | Single Workload, all-or-nothing admission | pod-group / gang admission | Multi-pod workloads start together or wait together (scenario 5). |
| Time-to-admission | Job `creation → pod Running` | same | Scheduling latency under load (all scenarios). |
| Priority honoured | Squad A (`squad-high-priority`) preferred; B/C preempted first | project priority | High-SLO squad protected (scenarios 1, 3). |
| Utilization | sum of `nvidia.com/gpu` requests per squad (GPU accounting table in each report) | same | Pool saturation vs the 8-GPU total. |

## Prerequisites

- Phase-1 baseline applied: squad namespaces, Kueue cohort/ClusterQueues/
  LocalQueues, `ResourceFlavor` `nvidia-a10g`, PriorityClasses
  `squad-high-priority` / `squad-standard`, DRA, and the `swebench-gpu-profile`
  hardware profile (`deploy/base` + `deploy/overlays/<vendor>`).
- For Run:AI runs: `scripts/runai/10-enable-runai.sh` then
  `scripts/runai/11-apply-runai-policies.sh`.
- Logged in to the cluster in `config/env.sh` `CLUSTER_SERVER` (the drivers
  refuse to run otherwise).

## Typical sequence

```bash
# RHOAI baseline
bash scripts/scenarios/scenario-1-multiteam-allocation.sh --scheduler rhoai
bash scripts/scenarios/scenario-2-dynamic-utilization.sh  --scheduler rhoai
bash scripts/scenarios/scenario-3-reclamation.sh          --scheduler rhoai
bash scripts/scenarios/scenario-4-gpu-sharing.sh          --scheduler rhoai
bash scripts/scenarios/scenario-5-coordinated-observability.sh --scheduler rhoai

# Switch the SAME workloads to Run:AI, then re-run each with --scheduler runai
bash scripts/runai/10-enable-runai.sh
bash scripts/runai/11-apply-runai-policies.sh
bash scripts/scenarios/scenario-1-multiteam-allocation.sh --scheduler runai
# ... scenarios 2-5 with --scheduler runai ...

# Clean up a scenario's jobs when done
bash scripts/scenarios/scenario-3-reclamation.sh --cleanup
```

See RHOAI docs: Kueue quota management, Dynamic Resource Allocation (DRA),
hardware profiles, and the Run:AI on OpenShift AI integration.
