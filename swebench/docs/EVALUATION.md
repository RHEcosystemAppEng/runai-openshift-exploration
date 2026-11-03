# Evaluation — RHOAI baseline vs Run:ai

This is the measurement plan for NVIDIA-1535. The same five scenarios
([SCENARIOS.md](./SCENARIOS.md)) run in **Phase 1 (RHOAI: Kueue + DRA + hardware
profiles)** and **Phase 2 (Run:ai)** against the same model, same splits, and same
agent/eval engine, so the only variable is the scheduling platform. For each metric below
we give what it means, how to capture it, and a table to fill after a verified run.

> The tables ship **empty on purpose**. Do not populate them with estimates. Fill them only
> from a real run on the target cluster, and record the cluster/RHOAI/Run:ai versions
> alongside, in the tone of the NVIDIA-1537 post-training "Verified run" section.

## Metrics and how to capture each

| # | Metric | What it measures | How to capture |
|---|--------|------------------|----------------|
| 1 | **Workload admission** | Were each squad's workloads admitted within quota, and was excess queued (not rejected)? | `scripts/06-status.sh`; `oc get workloads -A` (Kueue conditions `QuotaReserved`/`Admitted`). Phase 2: `runai list jobs` / Run:ai dashboard. |
| 2 | **GPU allocation** | GPUs allocated per squad vs nominal quota; borrowed and reclaimed counts | `scripts/06-status.sh`; `oc describe clusterqueue cq-squad-*` (flavorsUsage, borrowed). Phase 2: Run:ai project allocation view. |
| 3 | **GPU utilization** | Are allocated GPUs actually busy (not just reserved)? | `benchmark/telemetry_parse.py` (KV-cache %, running/waiting requests, gen tokens/s) + `benchmark/gpu-telemetry-collector.sh` (util %, power, VRAM). |
| 4 | **Scheduling delay** | Time from submit to admission/first-GPU, per squad and priority | Workload creation vs admission timestamp (`oc get workload -o jsonpath` on `.metadata.creationTimestamp` and the `Admitted` condition `lastTransitionTime`). Phase 2: Run:ai job events. |
| 5 | **Preemption / reclamation** | How fast and how fairly borrowed GPUs are reclaimed for a high-priority burst; how many workloads preempted and re-queued | Scenario 3; count `Preempted`/`Evicted` workload transitions; `telemetry_parse.py` `num_preemptions_total`; time from Squad A submit to reclaimed GPUs. |
| 6 | **Issue-completion time** | End-to-end wall-clock to resolve a SWE-bench instance (retrieve → reason → patch → test → `report.json`), incl. any preemption delay | Per-instance `report.json` timestamps rolled up by `benchmark/collect-results.sh`; `resolved` counts per split. |

Capture the same six metrics in both phases from the same scripts (Phase 2 swaps Kueue
reads for Run:ai reads where noted).

## Results table template — per scenario

Fill one block per scenario, once for RHOAI and once for Run:ai.

### Scenario 1 — Admission control & nominal quota

| Squad | Nominal GPU quota | Admitted GPUs | Queued (suspended) workloads | Rejected (should be 0) | Scheduling delay p50 / p90 |
|-------|-------------------|---------------|------------------------------|------------------------|----------------------------|
| A (lite) | 4 | | | | |
| B (cpp) | 2 | | | | |
| C (csharp) | 2 | | | | |

### Scenario 2 — Quota borrowing

| Squad | Nominal | Borrow limit | Peak admitted GPUs | GPUs borrowed from cohort | Cohort peak utilization |
|-------|---------|--------------|--------------------|---------------------------|-------------------------|
| B (bursting) | 2 | 2 (ceiling 4) | | | |

### Scenario 3 — Reclamation & preemption

| Metric | Value |
|--------|-------|
| GPUs reclaimed for Squad A | |
| Workloads preempted (B/C) | |
| Time: A submit → GPUs reclaimed | |
| Time: preempted instance → resumed | |
| Added issue-completion time on preempted instances | |

### Scenario 4 — GPU sharing (inference + eval)

| Metric | Value |
|--------|-------|
| Endpoint GPU held continuously? (Y/N) | |
| Agent/eval `single-gpu` claims cycled | |
| Endpoint KV-cache usage % (avg / peak) | |
| Generation tokens/s during job bursts | |
| Any endpoint starvation events? | |

### Scenario 5 — Coordinated (gang) scheduling

| Metric | Value |
|--------|-------|
| Group admitted all-or-nothing? (Y/N) | |
| Partial starts observed (should be 0) | |
| Time: capacity free → full group admitted | |

## Head-to-head summary — RHOAI vs Run:ai

Fill after both phases complete.

| Metric | RHOAI (Kueue + DRA + HW profiles) | Run:ai | Notes / winner |
|--------|-----------------------------------|--------|----------------|
| Admission correctness (no false rejects) | | | |
| GPU allocation accuracy vs quota | | | |
| GPU utilization (busy vs reserved) | | | |
| Scheduling delay p50 / p90 | | | |
| Preemption/reclamation latency | | | |
| Fairness under contention | | | |
| Issue-completion time (per split) | | | |
| SWE-bench resolved count (per split) | | | |
| Operational effort to configure | | | |

## Run metadata to record (both phases)

Mirror the NVIDIA-1537 "Verified run" discipline:

- OpenShift version, RHOAI version, Kueue/DRA feature gates; Run:ai version (Phase 2).
- GPU model and count actually scheduled; `ResourceFlavor` / Run:ai node pool used.
- vLLM runtime image digest, model, `--max-model-len`, tool-call parser.
- `PARALLEL`, `MAX_TURNS`, `MAX_RETRIES` from `config/env.sh` at run time.
- Scheduler in effect (`kueue`/`default-scheduler` vs `runai-scheduler`).
- Any quota, admission, or preemption errors observed.
- Where artifacts landed: `report.json` paths, `telemetry/` directory, `scripts/06-status.sh`
  captures.

## References

- [`scripts/06-status.sh`](../scripts/06-status.sh) · [`benchmark/telemetry_parse.py`](../benchmark/telemetry_parse.py) · [`benchmark/collect-results.sh`](../benchmark/collect-results.sh)
- [Kueue metrics](https://kueue.sigs.k8s.io/docs/reference/metrics/) · [Kueue preemption](https://kueue.sigs.k8s.io/docs/concepts/preemption/)
- [RHOAI: Monitoring and observability](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [NVIDIA Run:ai analytics & scheduling](https://docs.nvidia.com/run-ai/)
