# Observing Kueue admission, quota, borrowing and preemption

This runbook is for NVIDIA-1535 — *Multi-Tenant Autonomous Coding Agents on a
Shared GPU Cluster*. Three squads share one RHOAI GPU pool (8 GPUs) through a
single Kueue cohort, `swebench-gpu-pool`. Each squad's autonomous AMI agent Jobs
are admitted by Kueue against a per-squad `ClusterQueue`:

| Squad | Namespace | ClusterQueue | LocalQueue | Nominal GPUs | Borrow up to | Priority |
|-------|-----------|--------------|------------|--------------|--------------|----------|
| A (SWE-bench Lite)   | `squad-a-lite`   | `cq-squad-a` | `default` | 2 | 6 | `squad-high-priority` |
| B (SWE-bench C/C++)  | `squad-b-cpp`    | `cq-squad-b` | `default` | 3 | 5 | `squad-standard` |
| C (SWE-bench C#)     | `squad-c-csharp` | `cq-squad-c` | `default` | 3 | 5 | `squad-standard` |

All three ClusterQueues belong to cohort `swebench-gpu-pool`, so idle GPUs are
lent across squads and reclaimed by preemption when the owning squad bursts.
Squad A is high-priority and may run over quota up to the whole pool.

This document answers the operational question the use case asks:
**"why was this workload admitted, placed, or preempted?"**

> Everything below uses real `kueue.x-k8s.io/v1beta1` objects. `oc` and `kubectl`
> are interchangeable; `oc` is used to match the rest of the repo.

---

## 1. The objects to watch

Each AMI agent batch Job is wrapped by Kueue as a **Workload** object in the
squad namespace. Admission decisions live on the Workload; capacity accounting
lives on the ClusterQueue.

```bash
# Per-squad queued/admitted workloads (run against one squad namespace)
oc get workloads -n squad-a-lite
oc get workloads -n squad-a-lite \
  -o custom-columns=\
NAME:.metadata.name,\
QUEUE:.spec.queueName,\
ADMITTED:.status.admission.clusterQueue,\
PRIORITY:.spec.priority,\
RECLAIMABLE:.status.reclaimablePods

# Pool-wide capacity: nominal quota, how much is borrowed, what is pending
oc get clusterqueues -o custom-columns=\
NAME:.metadata.name,\
COHORT:.spec.cohort,\
PENDING:.status.pendingWorkloads,\
ADMITTED:.status.admittedWorkloads,\
RESERVING:.status.reservingWorkloads

# Full flavor-by-flavor usage incl. borrowed amount vs nominalQuota/borrowingLimit
oc describe clusterqueue cq-squad-a
```

`oc describe clusterqueue` prints a `Flavors Usage` block per ResourceFlavor
(`nvidia-a10g`) showing `Total` used against the configured `nominalQuota` and
`borrowingLimit` for `nvidia.com/gpu`. When `Total` exceeds `nominalQuota`, the
difference is being **borrowed** from idle siblings in the cohort.

---

## 2. Why was a workload ADMITTED (or left PENDING)?

A Workload is admitted when its ClusterQueue has, in some ResourceFlavor, enough
unused quota — its own nominal quota plus any borrowable idle capacity in the
cohort, capped by its `borrowingLimit`.

```bash
# The authoritative explanation is on the Workload's conditions/events:
oc describe workload <workload-name> -n squad-b-cpp

# Watch admission decisions and preemptions as they happen:
oc get events -n squad-b-cpp --field-selector reason=QuotaReserved,reason=Admitted
oc get events -n squad-b-cpp \
  --field-selector involvedObject.kind=Workload --sort-by=.lastTimestamp
```

Read the Workload `.status.conditions`:

- `QuotaReserved=True` — Kueue found room (own quota and/or borrowed) and
  reserved it; the Pods are being created.
- `Admitted=True` — fully admitted and running.
- `QuotaReserved=False` with a message like *"couldn't assign flavors …
  insufficient quota for nvidia.com/gpu in flavor nvidia-a10g"* — **pending**:
  the cohort has no free GPU to give right now. It stays pending (FIFO within
  priority) until capacity frees up or a lower-priority workload is preempted.

**Squad A running over quota** looks like: `cq-squad-a` admitting Workloads whose
summed `nvidia.com/gpu` is above its nominal `2` (up to `6`), with the
ClusterQueue's `Flavors Usage.Total` showing the borrowed amount. That is the
intended HIGH-SLO behaviour, not an error.

---

## 3. Why was a workload PREEMPTED (reclamation)?

When an owning squad (say B) submits a burst while its GPUs are being borrowed by
another squad (say C, over quota), Kueue reclaims by preempting the borrowing
workloads. Squad A's `squad-high-priority` also lets A preempt standard-priority
work across the cohort.

```bash
# Preemption events in the victim's namespace:
oc get events -n squad-c-csharp --field-selector reason=Preempted \
  --sort-by=.lastTimestamp

# The victim Workload records who/what evicted it and why:
oc describe workload <victim-workload> -n squad-c-csharp
#   look for conditions: Evicted=True, reason=Preempted
#   message e.g. "preempted to reclaim quota for cq-squad-b" (reclaim within
#   cohort) or "preempted due to prioritization in the cohort" (priority-based)
```

Kueue distinguishes two preemption reasons, both relevant here:

- **Reclaim within cohort** — squad B takes back GPUs that were lent out while it
  was idle. Driven by `preemption.reclaimWithinCohort` on `cq-squad-b`.
- **Priority-based** — squad A (`squad-high-priority`) displaces standard-priority
  workloads. Driven by `preemption.withinClusterQueue` /
  `reclaimWithinCohort: Any` plus the `WorkloadPriorityClass` values.

The preempted agent Job is re-queued by Kueue; the AMI engine is idempotent
per instance (the autonomous monitor retries), so a reclaimed instance is picked
up again on the next round rather than lost.

---

## 4. Metrics to watch (Kueue → Prometheus)

Kueue exports Prometheus metrics; on RHOAI they are scraped by the monitoring
stack (enable user-workload monitoring — see `servicemonitor-vllm.yaml`). The
series that answer the use-case questions:

| Metric | What it tells you |
|--------|-------------------|
| `kueue_pending_workloads{cluster_queue=...}` | queue depth per squad (admission backlog) |
| `kueue_admitted_workloads_total{cluster_queue=...}` | throughput of admissions |
| `kueue_cluster_queue_resource_usage{cluster_queue,flavor,resource}` | live GPU usage per squad vs quota |
| `kueue_cluster_queue_nominal_quota{cluster_queue,flavor,resource}` | configured nominal quota |
| `kueue_cluster_queue_borrowing_limit` / `kueue_cluster_queue_resource_reservation` | borrowable headroom and what is reserved |
| `kueue_quota_reserved_wait_time_seconds` | scheduling delay: time from submit to quota reserved |
| `kueue_admission_wait_time_seconds` | time from submit to fully admitted |
| `kueue_preempted_workloads_total{reason=...}` | reclamation vs priority preemption counts |
| `kueue_evicted_workloads_total{reason=...}` | evictions (incl. preemption) |

### Example PromQL

```promql
# Per-squad GPU usage vs its nominal quota (over-quota == borrowing)
sum by (cluster_queue) (
  kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"}
)
/ on (cluster_queue)
sum by (cluster_queue) (
  kueue_cluster_queue_nominal_quota{resource="nvidia.com/gpu"}
)

# Is anyone borrowing right now? (usage above nominal)
sum by (cluster_queue) (kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"})
  - sum by (cluster_queue) (kueue_cluster_queue_nominal_quota{resource="nvidia.com/gpu"})

# Queue depth (admission backlog) per squad
kueue_pending_workloads

# Preemptions in the last hour, split reclaim vs priority
sum by (reason) (increase(kueue_preempted_workloads_total[1h]))

# p95 scheduling delay (submit -> quota reserved) per squad
histogram_quantile(0.95,
  sum by (le, cluster_queue) (rate(kueue_quota_reserved_wait_time_seconds_bucket[5m]))
)
```

---

## 5. Run:AI phase (Phase 2) — the same questions, different plane

When the SAME workloads are re-targeted to the Run:AI scheduler
(`runai-scheduler`, department `swebench`, over-quota enabled for Squad A), the
admission/borrow/preempt questions move off Kueue onto Run:AI:

```bash
# Run:AI projects/quotas (CLI)
runai list projects
runai describe project squad-a-lite
# Workloads and their allocation/preemption status
runai list jobs -p squad-a-lite
runai describe job <job> -p squad-a-lite   # shows requested vs allocated GPU, over-quota, preempted
```

Watch the equivalent signals: Run:AI project **deserved** vs **allocated** GPUs
(nominal vs borrowed), over-quota allocation for Squad A, and preemption events
when a project reclaims its deserved share. The evaluation compares these to the
Kueue baseline above: does Run:AI admit, borrow, reclaim and preempt the shared
pool the same way, and is Squad A's SLO still protected?

---

## References

- [Kueue — ClusterQueue, cohorts, borrowing](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- [Kueue — preemption](https://kueue.sigs.k8s.io/docs/concepts/preemption/)
- [Kueue — metrics reference](https://kueue.sigs.k8s.io/docs/reference/metrics/)
- [Kueue — troubleshooting / why pending](https://kueue.sigs.k8s.io/docs/tasks/troubleshooting/)
- [RHOAI — distributed workloads with Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [OpenShift — enabling monitoring for user-defined projects](https://docs.openshift.com/container-platform/latest/observability/monitoring/enabling-monitoring-for-user-defined-projects.html)
