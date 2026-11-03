# Team B — model customization (LoRA fine-tuning) + notebook

Team B is the **model-customization tenant**. It has **no guaranteed GPUs**
(`deserved = 0`), so it **borrows** idle GPUs for training — and those borrowed GPUs are
**reclaimable** by Team A. Its interactive notebook, however, is protected.

## Use case

| | |
|---|---|
| **Long-running workload** (`deploy`) | Interactive Jupyter workspace (category **Build** → **non-preemptible**). This is the data-scientist's notebook; it is never a reclaim victim. |
| **Batch workload** (`submit`) | N **real** LoRA fine-tuning jobs (category **Train**, GPU → **preemptible**). Red Hat Training Hub `lora_sft` on `Qwen/Qwen2.5-1.5B-Instruct`, text-to-SQL dataset. |
| **Quota** | GPU `deserved = 0`, over-quota weight `0.01`, queue `team-b-lora`, namespace `team-b-lora`. Every GPU it holds is over-quota → a reclaim source for Team A. |

This is the "borrow idle capacity for training, yield it gracefully" side of the story.
The LoRA job here is **the same workload** as the standalone RHOAI baseline in
[`./post-training/`](./post-training/) — that deep-dive runs it on `default-scheduler`
(interactive notebook **and** a batch Job) and is the **verified** reference with captured
metrics. The scripts here make that exact workload **Run:ai-native and preemptible**.

> **Precondition:** `submit.sh` mounts the config maps `team-b-lora-batch-source` and
> `odh-trusted-ca-bundle` in namespace `team-b-lora`. The source config map is created by
> the post-training batch path — run it once first:
> ```bash
> ./post-training/scripts/create-project.sh
> ./post-training/scripts/submit-batch-job.sh   # creates team-b-lora-batch-source
> ```

## Files

| File | What it is |
|---|---|
| `deploy.sh [up\|down]` | Create / delete the Jupyter workspace (Build). `TEAM_B_WS_GPU=0` by default. |
| `submit.sh [N=2]` | Submit N real LoRA fine-tuning jobs (Train, GPU). |
| `status.sh` | Team B workloads grouped by Run:ai category. |
| `stop.sh` | Delete the LoRA jobs + workspace. |
| `team-b-workspace.json` | Workspace (Build) REST payload. |
| `team-b-lora.json` | LoRA fine-tuning (Train) REST payload. |

## How to run

```bash
# Prereqs (see ../README.md): oc login, export RUNAI_CLUSTER_ID and RUNAI_PASSWORD
# plus the one-time post-training config map (see Precondition above)
cd experiments/team-b

./deploy.sh up          # start the interactive Jupyter workspace (Build)
./submit.sh 2           # 2 real LoRA fine-tuning jobs (Train) borrow idle GPUs
./status.sh             # Team B workloads by category
...
./stop.sh               # tear down Team B workloads
```

## How to show results

- **`./status.sh`** — Team B workloads grouped **Deploy / Build / Train**; watch the LoRA
  `Train` rows go Running (borrowing), then Pending if Team A reclaims, then Running again
  when Team A releases.
- **LoRA metrics** — each job writes a `metrics.json` (base vs LoRA exact-match on 6
  held-out prompts). The reference run improved **1/6 → 3/6** exact match; sample reports
  live in [`./post-training/reports/`](./post-training/reports/). From a job:
  ```bash
  oc logs -n team-b-lora job/<team-b-lora-batch-...>   # tails the newest metrics.json
  ```
- **Preemption / resume evidence** — when Team A reclaims:
  ```bash
  oc get events -A | grep -i preempt     # e.g. team-b-lora-ft-2 preempted by runai-team-a/...
  ```
  The preempted LoRA pod goes Pending and reschedules once Team A frees its GPU.
- **Run:ai UI → Workloads** (project `team-b-lora`): the `Workspace` (Build) stays
  protected while `Training` (LoRA) rows flip Pending ↔ Running under contention.
