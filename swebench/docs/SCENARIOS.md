# Scenarios — swebench-live-vllm

Five scenarios exercise the shared GPU cluster under real multi-tenant agent load. Each
has a runnable driver under [`scripts/scenarios/`](../scripts/scenarios) that sources
[`config/env.sh`](../config/env.sh), guards on the expected `$CLUSTER_SERVER`, submits
work through the proven engine in [`benchmark/`](../benchmark), and prints what to watch.
Observe each run with [`scripts/06-status.sh`](../scripts/06-status.sh) (Kueue admission +
GPU allocation per squad) and [`benchmark/telemetry_parse.py`](../benchmark/telemetry_parse.py)
(vLLM `/metrics`).

The same five scripts run in both phases. In Phase 1 they are scheduled by Kueue + DRA; in
Phase 2 the workloads carry `schedulerName: runai-scheduler` and a Run:ai project
annotation and are scheduled by Run:ai. The "RHOAI mechanism" and "Run:ai analogue"
columns name what does the work in each phase.

> These write-ups state what each scenario *demonstrates* and what to observe. They do not
> assert measured outcomes; record those in [EVALUATION.md](./EVALUATION.md) after a run.

---

## Scenario 1 — Admission control & nominal quota

- **Script:** `scripts/scenarios/scenario-1-multiteam-allocation.sh`
- **Demonstrates:** Each squad is admitted up to its *nominal* GPU quota and no further;
  work beyond quota is **queued (Suspended), not rejected**, and starts as capacity frees.
- **Setup:** Submit, in each squad, an agent run whose first wave needs exactly the
  nominal quota (A=4, B=2, C=2 GPUs) plus one extra instance.
- **What to observe:**
  - `scripts/06-status.sh` shows each LocalQueue/ClusterQueue with admitted workloads equal
    to its nominal quota and the extra instance `Pending`/`Suspended`.
  - `oc get workloads -n <squad-ns>` shows `QuotaReserved` / `Admitted` conditions; the
    queued one has no reservation yet.
  - As an admitted job finishes, the queued workload is admitted automatically.
- **RHOAI mechanism:** Kueue `ClusterQueue` nominal quota + `LocalQueue` admission; the
  workload is gated until its GPU request fits. (`kueue.x-k8s.io/v1beta1`)
- **Run:ai analogue:** Run:ai project **deserved quota**; the scheduler holds workloads
  above the project's guaranteed share in its queue.

---

## Scenario 2 — Quota borrowing from an idle cohort

- **Script:** `scripts/scenarios/scenario-2-dynamic-utilization.sh`
- **Demonstrates:** With neighbours idle, one squad **borrows GPUs beyond its nominal
  quota**, up to its borrowing limit, using the cohort's unused capacity.
- **Setup:** Ensure Squads A and C are idle, then have Squad B submit its agent run, which
  needs its full 4-GPU endpoint — more than its nominal 2 GPUs, so it borrows 2 more from
  the cohort (up to its ceiling of 4).
- **What to observe:**
  - `scripts/06-status.sh` shows `cq-squad-b` admitting more GPUs than its nominal quota;
    the surplus is drawn from the shared cohort `swebench-gpu-pool`.
  - Kueue's `ClusterQueue` status reports borrowed resources; admitted GPU count for B
    exceeds 2 but never exceeds 4.
  - Cohort-wide GPU usage approaches the pool total while A and C stay idle.
- **RHOAI mechanism:** Kueue cohort + `borrowingLimit` on the ClusterQueue; idle quota is
  lent across the cohort.
- **Run:ai analogue:** Run:ai **over-quota / fair-share** — idle project capacity is
  loaned to projects that need it.

---

## Scenario 3 — Reclamation & preemption under a high-priority burst

- **Script:** `scripts/scenarios/scenario-3-reclamation.sh`
- **Demonstrates:** When Squad A (high priority, high SLO) bursts, GPUs that B/C borrowed
  are **reclaimed by preempting** lower-priority workloads, which are re-queued and resume
  later — the core multi-tenant SLO guarantee.
- **Setup:** Start from the borrowed state of Scenario 2 (B/C occupying borrowed GPUs),
  then submit a Squad A burst that needs its nominal share back and beyond.
- **What to observe:**
  - `oc get workloads -A` shows B/C workloads transitioning to `Preempted`/`Evicted` with
    a reason referencing reclamation; Squad A workloads become `Admitted`.
  - `scripts/06-status.sh` shows GPUs shifting from B/C to A; A can climb to the whole
    8-GPU pool because its borrow limit is 4 (ceiling 8) and it holds `squad-high-priority`.
  - Preempted instances re-appear as `Suspended` and resume once A releases capacity; the
    issue-completion time for those instances lengthens (captured in EVALUATION.md).
  - `telemetry_parse.py` records `num_preemptions_total` from vLLM where applicable.
- **RHOAI mechanism:** Kueue `WorkloadPriorityClass` (`squad-high-priority` vs
  `squad-standard`) + ClusterQueue preemption policy (reclaim within cohort /
  priority-based preemption). (`scheduling.k8s.io/v1` PriorityClass +
  `kueue.x-k8s.io/v1beta1` WorkloadPriorityClass)
- **Run:ai analogue:** Run:ai **priority + preemption of over-quota (borrowed) pods**; a
  higher-priority project reclaims its deserved GPUs by evicting borrowed workloads.

---

## Scenario 4 — GPU sharing between inference and eval

- **Script:** `scripts/scenarios/scenario-4-gpu-sharing.sh`
- **Demonstrates:** The long-lived vLLM endpoint and the many short agent/eval jobs
  **share the pool's GPU capacity** cleanly through one cohort and the `single-gpu` DRA
  claim — inference stays up while bursts of jobs cycle through GPUs.
- **Setup:** With a squad's `qwen-inference` endpoint serving, run a wave of agent + eval
  jobs that each take a `single-gpu` claim, at `PARALLEL` concurrency.
- **What to observe:**
  - The endpoint keeps its GPU for the whole run while agent/eval jobs acquire and release
    `single-gpu` claims around it; `oc get resourceclaims -n <squad-ns>` shows claims
    cycling.
  - `telemetry_parse.py` shows KV-cache usage, running/waiting requests, and
    generation-tokens/s on the shared endpoint while jobs come and go.
  - No agent job starves the endpoint; total concurrent GPU use stays within quota +
    borrow.
- **RHOAI mechanism:** DRA `DeviceClass gpu.nvidia.com` + `ResourceClaimTemplate single-gpu`
  (`resource.k8s.io/v1beta1`) under one Kueue cohort, with the `swebench-gpu-profile`
  hardware profile defining the accelerator shape. (On clusters with GPU partitioning /
  time-slicing enabled, the same claim template targets a sliced device.)
- **Run:ai analogue:** Run:ai **GPU fractions / time-slicing** and the Run:ai scheduler
  packing inference and jobs onto shared GPUs.

---

## Scenario 5 — Coordinated (gang) scheduling of an agent run

- **Script:** `scripts/scenarios/scenario-5-coordinated-observability.sh`
- **Demonstrates:** An agent run only starts when its pieces can start **together** — the
  vLLM endpoint, the coordinator, and the first wave of per-instance jobs are admitted as
  a unit, so a run never sits half-provisioned (agents up but no endpoint, or vice versa).
- **Setup:** Submit a squad's full run (endpoint + coordinator + first `PARALLEL` jobs) as
  one group into a near-full cohort, then free capacity and confirm the group admits
  atomically.
- **What to observe:**
  - While the cohort is full, the whole group stays `Suspended`; no partial start.
  - When enough GPUs free up for the group's combined request, all members admit together
    and the run begins; `scripts/06-status.sh` shows the group flip from pending to
    admitted in one step.
- **RHOAI mechanism:** Kueue **all-or-nothing admission** of a workload / Kueue's
  gang-style admission for grouped Jobs; the coordinator's RBAC
  (`deploy/base/agents/rbac.yaml`) lets it create the per-instance Jobs once admitted.
- **Run:ai analogue:** Run:ai **gang scheduling** (train/distributed workloads scheduled
  all-or-nothing) applied to the endpoint + coordinator + first job wave.

---

## Cross-cutting: observability

Observability is not a separate scenario; it is captured in every run:

- `scripts/06-status.sh` — per-squad Kueue admission, borrowed/reclaimed GPUs, pending
  workloads, and endpoint readiness in one view (label selector
  `app.kubernetes.io/part-of=swebench-live-vllm`).
- `benchmark/telemetry_parse.py` + `benchmark/gpu-telemetry-collector.sh` — vLLM `/metrics`
  (TTFT, TPOT, KV-cache %, running/waiting requests, preemptions) and GPU
  temperature/power/VRAM, written to `/workspace/telemetry/` on a schedule.
- `benchmark/collect-results.sh` — rolls up `report.json` across instances so
  issue-completion counts and per-squad throughput can be tabulated.

What this proves, per scenario and overall, and the Run:ai comparison are summarized in
[EVALUATION.md](./EVALUATION.md) and [RHOAI-VS-RUNAI.md](./RHOAI-VS-RUNAI.md).

## References

- [`config/env.sh`](../config/env.sh) — quotas and priority values the scenarios assume
- [Kueue: preemption](https://kueue.sigs.k8s.io/docs/concepts/preemption/) · [cohorts & borrowing](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- [Kubernetes DRA](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [NVIDIA Run:ai scheduling (fair-share, over-quota, gang, GPU fractions)](https://docs.nvidia.com/run-ai/)
