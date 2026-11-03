# Aligned per-team interface

`teams/team-a/` and `teams/team-b/` expose the **same four verbs**, so both teams are
driven identically — everything goes through the Run:ai REST API (UI-visible,
runai-scheduled, preemptible by category).

| verb | Team A | Team B |
|------|--------|--------|
| `./deploy.sh [up\|down]` | vLLM inference — `LLMInferenceService` (**Deploy**, GPU) | Jupyter workspace (**Build**) |
| `./submit.sh [N]` | N SWE-bench agent jobs (**Train**, CPU → call the endpoint) | N LoRA fine-tuning jobs (**Train**, GPU) |
| `./status.sh` | Team A workloads by category | Team B workloads by category |
| `./stop.sh` | delete inference + swebench (+bursts) | delete LoRA (+workspace, +victims) |

Shared config/helpers: `experiments/env.sh` (export `RUNAI_PASSWORD` first), `lib.sh`,
`teams/_common.sh`.

## These are the real workloads
- **Team A** — real vLLM serving (`Qwen/Qwen2.5-3B-Instruct`) + SWE-bench agents that
  make real completion calls to it.
- **Team B** — the real RHOAI Training Hub **LoRA SFT** (`Qwen/Qwen2.5-1.5B-Instruct`,
  `training-hub[lora]`), submitted via the API but mounting the same
  `team-b-lora-batch-source` + `odh-trusted-ca-bundle` configmaps the `post-training/`
  Job uses — so it's Prudvi's exact workload, now Run:ai-native and preemptible.

## Full priority cycle (Team B → Team A → Team B)
```bash
cd experiments/teams
export RUNAI_PASSWORD=...

./team-b/submit.sh 2      # Team B borrows the free GPUs for LoRA fine-tuning (Train)
./team-a/deploy.sh up     # Team A inference (Deploy) reclaims a GPU — preempts a LoRA
./team-a/submit.sh 3      # Team A SWE-bench agents run against the endpoint and finish
./team-a/status.sh ; ./team-b/status.sh

./team-a/deploy.sh down   # Team A frees its GPU → Team B's preempted LoRA resumes
```
Category precedence: **Deploy > Build > Train** (see `reports/runai-config.md`). Team A's
inference preempts Team B's over-quota LoRA; Team B's workspace/notebook (Build) and the
other project's inference (Deploy) stay protected.
