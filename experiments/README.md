# experiments — Team A / Team B GPU reclamation on Run:ai (dev-06)

The live `ai-dev06` demo of the core fairness promise: **a high-SLO team (Team A) with a
guaranteed GPU quota reclaims GPUs from a lower-priority team (Team B) by preempting Team
B's over-quota workloads** — then releases them back when it is done. Everything runs
through the **Run:ai REST API** (UI-visible, `runai-scheduler`-scheduled, preemptible by
category) on the real cluster.

Two teams share **5 single-GPU nodes** (4× A10G 24 GB + 1× L40S 48 GB):

| | Team A — [`team-a/`](team-a/) | Team B — [`team-b/`](team-b/) |
|---|---|---|
| Role | high-SLO **inference** + SWE-bench agents | **model customization** (LoRA) + notebook |
| Long-running (`deploy`) | vLLM `LLMInferenceService` — **Deploy**, non-preemptible | Jupyter workspace — **Build**, non-preemptible |
| Batch (`submit`) | SWE-bench agents — **Train** (CPU) | real LoRA fine-tuning — **Train** (GPU) |
| GPU `deserved` | **4** (reclaims on demand) | **0** (borrows → reclaimable) |
| Queue / namespace | `team-a` / `runai-team-a` | `team-b-lora` / `team-b-lora` |

Precedence is **Deploy > Build > Train**, and only `Train` is preemptible — so Team A's
inference reclaims Team B's over-quota LoRA, while both notebooks and the other project's
inference stay protected.

## Layout

| Path | What it is |
|---|---|
| [`team-a/`](team-a/) | Team A's verbs (`setup`, `deploy`, `submit`, `status`, `stop`) + its manifests, and [`team-a/swebench/`](team-a/swebench/) — the minimal vLLM-inference + representative-agent example. Use-case / run / results in its README. |
| [`team-b/`](team-b/) | Team B's verbs (`deploy`, `submit`, `status`, `stop`) + its manifests, and [`team-b/post-training/`](team-b/post-training/) — the verified RHOAI LoRA baseline (source of Team B's workload). Use-case / run / results in its README. |
| [`_common/`](_common/) | Shared `env.sh` (all config), `lib.sh` (token + REST helpers), `_common.sh` (per-team base), `_runai_fmt.py`, and the live views `show-by-category.sh` / `dump-runai-config.sh` / `render-timeline.py`. |
| [`orchestration/`](orchestration/) | Cross-team drivers: `run-cycle.sh` (full B→A→B cycle + timeline), `cleanup.sh`, and `kyverno-runai-enroll.yaml` (namespace → Run:ai enrollment policy). |
| [`deployment/`](deployment/) | Placeholder (`.gitkeep`). |

## Prerequisites

```bash
oc login --token=<your-token> --server=https://api.<your-cluster>:6443
export RUNAI_CLUSTER_ID='<the Run:ai cluster UUID>'
export RUNAI_PASSWORD='<test@run.ai password>'
```

`RUNAI_PASSWORD` is the system-administrator (`test@run.ai`) password. It is a **shared
account** whose password was changed to obtain a token — coordinate with teammates. The
Keycloak master-admin creds used to (re)set it live in secrets
`runai-backend-keycloakx` / `runai-backend-gen-keycloakx` (namespace `runai-backend`).
Never hard-code it; `env.sh` guards it with `:?`.

## Run it

```bash
cd experiments

# 0. one-time: Team A project + cluster over-quota
./team-a/setup.sh

# 1. Team B borrows idle GPUs for LoRA (Train)
./team-b/submit.sh 2

# 2. Team A inference reclaims a GPU (preempts a LoRA) and runs its agents
./team-a/deploy.sh up
./team-a/submit.sh 3

# 3. inspect
./team-a/status.sh ; ./team-b/status.sh

# 4. Team A releases → Team B's preempted LoRA resumes
./team-a/deploy.sh down

# teardown (optionally --project / --revert-setting)
./orchestration/cleanup.sh
```

## How to show results

```bash
# whole-cluster workloads grouped by category, auto-refreshing
watch -c -n2 ./_common/show-by-category.sh

# the scheduler's own reclaim record
oc get events -A | grep -i preempt

# recorded reclaim TIMELINE (Gantt) -> reports/
./orchestration/run-cycle.sh
python3 ./_common/render-timeline.py \
  reports/timeline-cycle-data.jsonl reports/timeline-cycle.html
# screenshot the .html to a .png for slides

# a full snapshot of how Run:ai is configured (projects, queues, quotas, priorities)
./_common/dump-runai-config.sh          # -> reports/runai-config.md
```

All artifacts land in [`reports/`](reports/) (committed) — see its README for what each
one shows. Per-team result details (agent output, LoRA metrics) are in each team's README.
