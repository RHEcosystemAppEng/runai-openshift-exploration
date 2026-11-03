# Team A — inference (high-SLO) + SWE-bench agents

Team A is the **high-SLO inference tenant**. It serves a model and runs coding agents
against it, and it holds a **guaranteed GPU quota** so it can **reclaim** GPUs that
Team B borrowed while Team A was idle.

## Use case

| | |
|---|---|
| **Long-running workload** (`deploy`) | vLLM endpoint via RHOAI KServe `LLMInferenceService` (`team-a-qwen`), 1× A10G. Run:ai category **Deploy** → **non-preemptible**. Model `Qwen/Qwen2.5-3B-Instruct` (fits one A10G 24 GB). |
| **Batch workload** (`submit`) | N SWE-bench agent jobs (category **Train**, CPU). Each makes a **real** OpenAI-compatible completion call to the Team A endpoint and prints the model's patch/diff. |
| **Quota** | GPU `deserved = 4`, over-quota weight `4`, queue `team-a`, namespace `runai-team-a`. Because it is under its deserved share when idle, Team A can **reclaim up to 4 GPUs on demand** by preempting Team B's over-quota `Train` pods. |

This is the "production inference that must get its GPUs back" side of the shared-cluster
story. The vLLM serving manifest and the representative agent live in
[`swebench/`](swebench/) (a minimal, standalone "serve a model + call it" example);
`submit.sh` runs `swebench/agent/swebench_agent.py` against the endpoint.

## Files

| File | What it is |
|---|---|
| `setup.sh` | **One-time**: enable cluster over-quota + create the `team-a` project (`deserved=4`). |
| `deploy.sh [up\|down]` | Apply / delete the vLLM `LLMInferenceService` (Deploy). |
| `submit.sh [N=3]` | Submit N SWE-bench agent jobs (Train) that call the endpoint. |
| `status.sh` | Team A workloads grouped by Run:ai category. |
| `stop.sh` | Delete the inference endpoint + all swebench/burst jobs. |
| `team-a-project.json` | Project/quota REST payload (used by `setup.sh`). |
| `team-a-llminferenceservice.yaml` | KServe `LLMInferenceService`, `runai-scheduler`, A10G tolerations. |
| `team-a-swebench-batch.json` | The Train job payload (base64-injects and runs the agent). |
| `swebench/` | Minimal standalone vLLM-inference (`deploy/serving-vllm.yaml`) + representative agent (`agent/swebench_agent.py`, which `submit.sh` runs). |

## How to run

```bash
# Prereqs (see ../README.md): oc login, export RUNAI_CLUSTER_ID and RUNAI_PASSWORD
cd experiments/team-a

./setup.sh              # one-time: over-quota + team-a project (deserved=4)
./deploy.sh up          # start the vLLM inference endpoint (Deploy)
./status.sh             # watch it become Ready (image + model pull takes minutes)
./submit.sh 3           # 3 SWE-bench agents (Train) call the endpoint
...
./stop.sh               # tear down Team A workloads
```

## How to show results

- **`./status.sh`** — the Team A workloads grouped **Deploy / Build / Train**, showing
  category, priority and preemptibility live. Pair with
  `watch -c -n2 ../_common/show-by-category.sh` for the whole-cluster category view.
- **Agent output** — the real model response/diff is in each Train job's logs:
  ```bash
  oc logs -n runai-team-a job/team-a-swebench-lite-001
  ```
- **Reclaim evidence** — when `deploy up` runs while Team B holds the GPUs, the scheduler
  preempts a Team B `Train` pod:
  ```bash
  oc get events -A | grep -i preempt
  ```
- **Run:ai UI → Workloads** (project `team-a`): the `Inference` row goes Running while
  Team B's `team-b-lora-ft-*` rows flip to Pending.
- For the end-to-end reclaim **timeline figure**, run [`../orchestration/run-cycle.sh`](../orchestration/)
  (see that folder's usage).
