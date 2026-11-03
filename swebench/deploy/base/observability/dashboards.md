# Shared-GPU-pool dashboard — what to show and where it comes from

This document specifies the dashboard for NVIDIA-1535 — *Multi-Tenant Autonomous
Coding Agents on a Shared GPU Cluster*. The purpose is to make the shared pool's
behaviour legible: is the pool busy, is each squad getting its fair (and
borrowed) share, how deep are the queues, how long do agents wait, how often is
work preempted, and how fast do real GitHub issues get resolved.

The use case: three data-science squads share one RHOAI **8x A10G** pool
(cohort `swebench-gpu-pool`), two vLLM endpoints' worth since each endpoint runs
across 4 A10G (tensor-parallel 4). Squad A (SWE-bench Lite) is high-SLO and may run
over quota; Squads B (C/C++) and C (C#) are standard priority and lend/reclaim
their GPUs. The dashboard must let an operator see all three at once and answer
"is the sharing policy working?".

## Three data sources feed this dashboard

1. **vLLM `/metrics`** (`vllm:*` series) — serving-side latency/throughput/cache.
   Collected two ways, both from the same endpoint on Service `qwen-inference:8000`:
   - live into Prometheus via `servicemonitor-vllm.yaml` (for Grafana/RHOAI);
   - into JSONL on the workspace PVC via
     `benchmark/telemetry_parse.py` (every 30 s) for offline analysis and the
     per-run report. The metric names below are exactly the ones that parser
     captures, so the two sources line up.
2. **Kueue metrics** (`kueue_*` series) — admission, per-squad quota/usage,
   queue depth, scheduling delay, preemption. See `kueue-observability.md` for
   the full list and PromQL.
3. **GPU device metrics** — temperature, power, utilization, VRAM. Cluster-wide
   source is the **NVIDIA DCGM exporter** (`DCGM_FI_DEV_*`) from the GPU Operator
   (or the AMD device-metrics-exporter on the AMD overlay). The proven
   `telemetry_parse.py` also derives the same fields per-pod via `nvidia-smi` /
   `rocm-smi` (needs the `pods/exec` RBAC in `telemetry-rbac.yaml`) as a fallback
   where DCGM is not deployed.

---

## Panels

### Row 1 — Pool utilization (is the shared GPU busy?)
- **GPU utilization %, pool-wide and per GPU.**
  DCGM `DCGM_FI_DEV_GPU_UTIL`; fallback telemetry `gpu.gpu_util_pct`.
- **VRAM used / total.**
  DCGM `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE`; fallback
  `gpu.vram_used_gb`, `gpu.vram_used_pct`, `gpu.vram_total_gb`.
- **Power draw (W) and temperature (°C) per GPU.**
  DCGM `DCGM_FI_DEV_POWER_USAGE`, `DCGM_FI_DEV_GPU_TEMP`; fallback
  `gpu.gpu_power_w`, `gpu.gpu_temp_c`. (Clocks: `gpu.gpu_clock_mhz`,
  `gpu.mem_clock_mhz`.)

### Row 2 — Per-squad GPU usage vs quota (is sharing fair? who is borrowing?)
- **Stacked GPUs-in-use by squad** against the 8x A10G pool line.
  `kueue_cluster_queue_resource_usage{resource="nvidia.com/gpu"}` by
  `cluster_queue` (cq-squad-a/-b/-c).
- **Usage vs nominal quota** per squad — the amount above nominal is *borrowed*.
  `usage - kueue_cluster_queue_nominal_quota` (see PromQL in
  `kueue-observability.md`). Highlight when Squad A exceeds its nominal 4 (its
  sanctioned over-quota, up to the whole 8-GPU pool) and when B/C exceed their nominal 2
  by borrowing the 2 extra GPUs each needs to run its 4-GPU endpoint.

### Row 3 — Queue depth & scheduling delay (is anyone starved?)
- **Pending workloads per squad** (queue depth).
  `kueue_pending_workloads{cluster_queue=...}`.
- **Admission / scheduling delay** — time from submit to quota reserved and to
  admitted, p50/p95 per squad.
  `kueue_quota_reserved_wait_time_seconds`, `kueue_admission_wait_time_seconds`.

### Row 4 — Preemption & reclamation (is the policy doing its job?)
- **Preemption count over time, split by reason** (reclaim-within-cohort vs
  priority). `increase(kueue_preempted_workloads_total{reason=...}[window])`.
- **Evictions** `kueue_evicted_workloads_total`. Correlate spikes with Squad B/C
  bursts and with Squad A high-priority admissions.

### Row 5 — Serving performance (is the LLM endpoint keeping up?)
- **TTFT and TPOT** (time-to-first-token, time-per-output-token).
  vLLM histograms `vllm:time_to_first_token_seconds`,
  `vllm:time_per_output_token_seconds`; file fields `vllm.ttft_avg_s`,
  `vllm.tpot_avg_ms` (also `vllm.itl_avg_ms`, `vllm.e2e_latency_avg_s`).
- **Throughput** — prompt + generation tokens/s.
  rate of `vllm:prompt_tokens_total` + `vllm:generation_tokens_total`; file field
  `vllm.total_tokens_served`.
- **KV-cache usage % and prefix-cache hit rate.**
  `vllm:kv_cache_usage_perc` (a.k.a. `gpu_cache_usage_perc`); file fields
  `vllm.kv_cache_usage_perc`, `vllm.cache_hit_rate`.
- **Concurrent / queued requests and vLLM-internal preemptions.**
  `vllm:num_requests_running`, `vllm:num_requests_waiting`,
  `vllm:num_preemptions_total`.

### Row 6 — Agent / issue progress (the actual business outcome)
- **Running vs complete agent Jobs per squad.**
  From the engine: `oc get jobs -l app=swebench-instance` counts, captured in the
  telemetry `jobs.running` / `jobs.complete` fields.
- **Issue-completion time** — wall-clock per resolved SWE-bench instance (and
  resolved-rate per round). Derived from the engine's per-instance
  `eval-results/<instance>/report.json` (`resolved`, F2P/P2P) plus Job
  start/finish timestamps; summarised by `benchmark/collect-results.sh` /
  `eval_grade.py`. Plot per squad to compare splits (Lite vs C/C++ vs C#).

---

## How the panels answer the use-case questions

- *Is the pool well utilized?* — Row 1 + Row 5 throughput/KV-cache.
- *Is each squad getting its share, and is borrowing happening?* — Row 2.
- *Is Squad A's SLO protected while B/C still make progress?* — Row 2 (A over
  quota) + Row 3 (B/C queue depth stays bounded) + Row 6 (completion time).
- *Does reclamation/preemption fire correctly when an idle squad bursts?* —
  Row 4 correlated with Row 2.
- *Phase-2 comparison (Run:AI):* rebuild Rows 2–4 from Run:AI project
  deserved/allocated-GPU and preemption signals and overlay against this Kueue
  baseline to judge whether Run:AI reproduces the sharing policy.

## Where to build it

- **RHOAI / OpenShift**: enable user-workload monitoring, then build a Grafana
  (or console Observe → Dashboards) board on the Prometheus `kueue_*`, `vllm:*`
  and `DCGM_FI_DEV_*` series above.
- **Offline / per-run**: the JSONL from `telemetry_parse.py` on the workspace PVC
  feeds the same panels without a live Prometheus — one record per 30 s with the
  `gpu`, `vllm` and `jobs` fields referenced above. Pull it with
  `oc cp <coordinator-pod>:/workspace/telemetry/ ./telemetry/`.

> Do not hard-code "verified" numbers here. Populate thresholds and SLO lines
> from a real run on the target cluster and record them in the top-level README's
> verified-run section, matching the post-training reference style.

## References

- [vLLM — production metrics](https://docs.vllm.ai/en/latest/serving/metrics.html)
- [Kueue — metrics reference](https://kueue.sigs.k8s.io/docs/reference/metrics/)
- [NVIDIA DCGM exporter metrics](https://docs.nvidia.com/datacenter/cloud-native/gpu-telemetry/latest/dcgm-exporter.html)
- [OpenShift — monitoring for user-defined projects](https://docs.openshift.com/container-platform/latest/observability/monitoring/enabling-monitoring-for-user-defined-projects.html)
- [RHOAI — monitoring data science / distributed workloads](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
