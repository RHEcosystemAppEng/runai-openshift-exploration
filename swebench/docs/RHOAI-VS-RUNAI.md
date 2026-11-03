# RHOAI vs Run:ai — capability / gap matrix

NVIDIA-1535 asks a specific question: for multi-tenant autonomous coding agents on a
shared GPU cluster, **how much does RHOAI's native stack (Kueue + DRA + hardware
profiles) already cover, where are the gaps, and does Run:ai add incremental value without
duplicating what RHOAI does?**

This document lays out the matrix requirement-by-requirement. The "RHOAI covers today"
column is a design-level assessment of the baseline in this repo; it is **not** a measured
result. The "evidence" and "recommendation" sections are placeholders to fill from the
runs captured in [EVALUATION.md](./EVALUATION.md). Do not assert outcomes not yet measured.

## Requirement → platform matrix

| # | Requirement (from the use case) | RHOAI today (Kueue + DRA + HW profiles) | Gap / caveat to verify | Run:ai analogue | Incremental value of Run:ai? (fill after runs) |
|---|---------------------------------|------------------------------------------|------------------------|-----------------|------------------------------------------------|
| 1 | **Multi-tenant isolation** (3 squads, own quota/priority) | Namespaces + `ClusterQueue` per squad + `LocalQueue`; labels scope everything | Confirm RBAC/quota isolation holds under contention | Run:ai projects/departments | |
| 2 | **Admission control** (queue excess, don't reject) | Kueue admission: workloads suspended until they fit | Confirm no false rejects; queue ordering by priority | Run:ai scheduler queue per project | |
| 3 | **Quota borrowing** (lend idle capacity) | Kueue cohort + `borrowingLimit` | Confirm borrow limits (A≤4, B/C≤2; ceilings 8/4/4) enforced | Run:ai over-quota / fair-share | |
| 4 | **Reclamation / preemption** (high-priority burst wins) | `WorkloadPriorityClass` + ClusterQueue preemption/reclaim-within-cohort | Confirm reclaim latency and that only borrowed/low-prio pods are evicted | Run:ai priority + preemption of over-quota pods | |
| 5 | **GPU sharing** (inference + many short jobs) | DRA `DeviceClass` + `ResourceClaimTemplate single-gpu`; HW profile shape | Fractional/time-sliced sharing depends on cluster GPU-partitioning setup | Run:ai GPU fractions / time-slicing | |
| 6 | **Coordinated / gang scheduling** (run starts as a unit) | Kueue all-or-nothing admission of grouped workloads | Confirm endpoint+coordinator+first wave admit atomically | Run:ai gang scheduling | |
| 7 | **Accelerator abstraction** (NVIDIA + AMD) | DRA DeviceClass + kustomize overlays (`nvidia`/`amd`) | Verify overlay parity incl. FIPS init-container on AMD | Run:ai node pools / accelerators | |
| 8 | **Model serving** (self-hosted vLLM, OpenAI API) | KServe `InferenceService` + vLLM `ServingRuntime`, per squad | Kueue governs the **batch** agent/eval Jobs natively; the vLLM endpoints are **long-running Deployments** — they carry the queue-name label, but Kueue only accounts for them if its **Deployment/Pod integration is enabled**, otherwise a plain `ResourceQuota` governs the serving GPUs | Run:ai governs long-running inference (and GPU fractions / over-quota for serving) natively | |
| 9 | **Hardware profile / node targeting** | RHOAI `HardwareProfile` (`swebench-gpu-profile`) + tolerations | Confirm profile drives the dashboard + admission as expected | Run:ai node pools + tolerations | |
| 10 | **Observability** (admission, allocation, utilization) | Kueue metrics + `scripts/06-status.sh` + `telemetry_parse.py` | Confirm per-squad allocation + preemption are visible end-to-end | Run:ai dashboard & analytics | |
| 11 | **Over-quota policy for a privileged tenant** (Squad A) | High-priority class + large borrow limit (up to whole pool) | Confirm A can take the pool without starving B/C guarantees | Run:ai project over-quota flag (`RUNAI_OVERQUOTA`) | |

## Where RHOAI is expected to be sufficient

Based on the baseline design (to be confirmed by the runs):

- Per-tenant quota, borrowing, and priority-based preemption are **native Kueue** features;
  the cohort model maps directly onto "pooled GPUs with per-squad guarantees."
- GPU requests via **DRA** plus an **RHOAI hardware profile** cover accelerator shape and
  node targeting, and the kustomize overlays carry this to AMD without touching the bases.
- **KServe + vLLM** serving is independent of the scheduler, so it is reused unchanged in
  both phases.

## Where gaps or open questions may remain (verify with runs)

- **Fractional GPU sharing granularity.** Kueue+DRA share *whole* devices well; fine-grained
  fractional sharing/time-slicing depends on the cluster's GPU-partitioning configuration.
  Compare against Run:ai GPU fractions.
- **Long-running inference governance (the clearest Run:ai value-add).** Kueue's model is
  built for **batch** workloads that start, run, and complete — it governs the agent/eval
  Jobs cleanly. The vLLM endpoints, however, are **long-running Deployments** that hold a
  GPU indefinitely. Kueue only accounts for them if its **Deployment/Pod integration is
  explicitly enabled** (otherwise the serving GPUs fall to a plain `ResourceQuota` and sit
  outside the cohort's borrowing/preemption math), and even then it cannot sub-divide a
  device. Run:ai, by contrast, governs long-running inference, **GPU fractions**, and
  **over-quota for serving** natively — this is exactly where Run:ai adds value beyond
  Kueue's batch model, and the gap to verify on the target cluster.
- **Gang-scheduling ergonomics.** Confirm Kueue's all-or-nothing admission covers the
  endpoint + coordinator + first job wave as cleanly as Run:ai's gang scheduling.
- **Reclamation latency and fairness.** Measure how quickly borrowed GPUs are returned to
  a high-priority burst, and whether guarantees for B/C hold.
- **Operator ergonomics / dashboards.** Qualitative: effort to configure and observe each
  platform for this workload.

## Evidence (fill after runs)

For each requirement above, link the scenario, the `scripts/06-status.sh` capture, the
`telemetry/` record, and the EVALUATION.md table cell that supports the assessment.

- Requirement 2 (admission): _evidence placeholder_
- Requirement 3 (borrowing): _evidence placeholder_
- Requirement 4 (preemption): _evidence placeholder_
- Requirement 5 (GPU sharing): _evidence placeholder_
- Requirement 6 (gang scheduling): _evidence placeholder_
- Requirement 11 (over-quota Squad A): _evidence placeholder_

## Recommendation (placeholders — do not fill until measured)

> The following are decision slots to complete only after both phases run. State each as a
> conclusion backed by a specific EVALUATION.md metric, not an expectation.

- **Does RHOAI's native stack meet the NVIDIA-1535 requirements on its own?** _TBD after runs._
- **For which specific requirement(s), if any, did Run:ai add measurable value beyond RHOAI?**
  _TBD after runs._
- **For which requirement(s) would Run:ai duplicate RHOAI with no measured gain?**
  _TBD after runs._
- **Recommended configuration for the three squads going forward.** _TBD after runs._

## References

- [EVALUATION.md](./EVALUATION.md) — the metrics these conclusions must cite
- [SCENARIOS.md](./SCENARIOS.md) — the runs that produce the evidence
- [Kueue concepts](https://kueue.sigs.k8s.io/docs/concepts/) · [Kubernetes DRA](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [RHOAI distributed workloads & hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [NVIDIA Run:ai documentation](https://docs.nvidia.com/run-ai/)
