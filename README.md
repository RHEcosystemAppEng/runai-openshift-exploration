# runai-openshift-exploration

**Run:ai OSS (v3.0.20) on OpenShift with RHOAI workloads** — the hands-on Team A / Team B
GPU-sharing and RHOAI↔Run:ai integration slice of the **NVIDIA DSX OS PaaS — Phase-02
investigation** (Epic `NVIDIA-1237`, Red Hat Internal).

It demonstrates, live on cluster **`ai-dev06`**, two OpenShift AI projects mapped to Run:ai
(KAI-scheduled) queues under a single department that contend for the same GPUs through Run:ai
**quota, over-quota weight, and workload-category priority**.

> The broader Phase-02 investigation also covers NVIDIA Dynamo and Karta in **sibling repos** —
> those are referenced here, not documented. Organization abstractions (departments, projects,
> node pools, queues) are tracked upstream in the separate OSS project *KAI Resource Management*;
> in this repo a department and a project are Run:ai Kubernetes CRDs (`projects.kai.resources`
> + `scheduling.run.ai` queues).
>
> Run:ai OSS V3 under test is from the `dsx-ai-factory/run-ai` mono repo (released to open
> source 2026-10-13). GPU-fractioning work tracks `kai-scheduler/gpu-fractioning`.

---

## Versions tested (live-confirmed on `ai-dev06`, 2026-10-27/28)

| Component | Version |
| --- | --- |
| OpenShift | 4.22.13 (Kubernetes v1.35.6) |
| Container runtime (NRI enabled) | cri-o 1.35.6 |
| OpenShift AI / RHOAI (self-managed) | 3.5.2 |
| NVIDIA Run:ai control plane (OSS V3) | **3.0.20** |
| KAI Scheduler (scheduler + binder) | v0.18.3 |
| NVIDIA GPU Operator | 26.7.0 |
| NVIDIA GPU-Fractioning operator | TBD (not yet pinned in this repo) |
| Kyverno | 1.19.2 |

Additional components confirmed from the live stack: OpenShift Serverless (Knative, for KServe)
1.36.1 · Keycloak 26.6 · Valkey/Redis 9.0.4 · KServe `LLMInferenceService` v1alpha2 (runtime
`0.24.0+rhaiv.13`) · Training Hub 0.9.2 · vLLM runtime image `quay.io/modh/vllm:rhoai-2.16-cuda`.

**GPU pool:** 5 single-GPU nodes — **4× NVIDIA A10G 24 GB** (used for contention) + **1× NVIDIA
L40S 48 GB** (hosts Team B's workbench). Neither queue has a hard GPU cap (`gpu.limit = -1`).

> The Phase-02 deck title reads "Run:ai OSS (3.0.2)"; that is a typo — every live artifact and
> this repo record **3.0.20**.

---

## Team A / Team B configuration

Exact values from `experiments/env.sh`, `experiments/team-a-project.json`, and
`experiments/01-setup-projects.sh` (queue priority / over-quota weight come from the live cluster
dump, not the JSON).

| | **Team A — Inference** | **Team B — Model customization** |
| --- | --- | --- |
| Workloads | vLLM inference supporting agents | LoRA fine-tuning + interactive notebook |
| Run:ai queue | `team-a` | `team-b-lora` |
| Guaranteed (deserved) GPUs | **4** | **0** (borrows capacity) |
| GPU limit | `-1` (uncapped) | `-1` (uncapped) |
| Queue priority | 100 | 100 |
| Over-quota (surplus) weight | **4** | **0.01** |
| Served model | `Qwen/Qwen2.5-3B-Instruct` (fits one A10G) | `Qwen/Qwen2.5-1.5B-Instruct` (LoRA) |

**Reclaim precedence is *not* queue priority** (both queues are equal at 100). Team A wins
contention through: (a) deserved quota **4 vs 0**, (b) over-quota weight **4 vs 0.01**, and
(c) workload-category priority classes **inference (125) > build (100) > train (50)** — only
`train` is preemptible, so Team B's over-quota LoRA training yields first while its notebook
(`build`, on the L40S) is never preempted.

---

## Contention scenario & observed findings

**Scenario:** Team A (high-SLO vLLM inference supporting agents) and Team B (checkpoint-sensitive
LoRA training + an interactive notebook) share the 4× A10G pool; the L40S hosts Team B's
workbench.

**Observed:**

1. **GPU borrowing** — Team B's `deserved=0` LoRA job borrows idle A10Gs while Team A is light.
2. **Dynamic reclaim** — when Team A's inference/burst needs capacity, KAI preempts Team B's
   over-quota `train` pods (captured `oc` events, e.g.
   `team-b-victim-2 preempted by runai-team-a/pg-team-a-burst-1`), typically within ~8 s on a
   warm run, with no oscillation.
3. **Capacity return** — after Team A releases, the preempted Team B jobs go `Pending` and then
   reclaim their GPU lanes.
4. **Graceful preemption** — preemption honours `terminationGracePeriodSeconds` (SIGTERM), so
   checkpoint-capable jobs can save and resume; save/resume was validated in separate controlled
   tests.

**Investigating** *(deck-stated; not yet reproduced/recorded in this repo)* — two Team B
workloads appeared to hold a GPU after training reported completion; root-cause analysis is
ongoing.

**Next** — validate full end-to-end recovery in one pass: checkpoint save → preempt/reschedule →
restore → successful completion.

---

## KServe status mismatch (RawDeployment vs Serverless)

*Deck-stated finding; flagged here as **not yet reproduced on `ai-dev06`**.* A KServe workload can
show **Ready** in the RHOAI dashboard but **Creating…** in the Run:ai control-plane UI. Stated
root cause: RHOAI deploys KServe in **RawDeployment** mode while Run:ai's built-in KServe status
mapping expects **Serverless** readiness conditions. Temporary workaround: manually patch the
workload condition status. Long-term: upstream Run:ai to natively evaluate RawDeployment
conditions.

> Caveat for this repo: OpenShift Serverless (Knative) 1.36.1 **is** installed and the live Team A
> endpoint is an `LLMInferenceService` with `router: {}` (Serverless-backed), so the actual KServe
> `DeploymentMode` on `ai-dev06` must be confirmed before presenting RawDeployment as the cause.

---

## RHOAI ↔ Run:ai integration flow

No custom code, and not a product integration — project-to-project linking only:

1. Create the RHOAI Data Science Project + namespace (`opendatahub.io/dashboard="true"`).
2. A Kyverno `ClusterPolicy` (`experiments/kyverno-runai-enroll.yaml`) injects the label
   `runai/queue=<namespace>` and annotation `runai/enforce-scheduler-name="true"`.
3. Register the matching Run:ai team via REST `POST /api/v1/org-unit/projects`
   (`parentId` = department, with GPU quota) — this creates the `kai.resources` Project, the
   `scheduling.run.ai` Queue, and RoleBindings.
4. Mirror RBAC via `POST /api/v1/authorization/access-rules`.
5. Any workload deployed in the namespace (e.g. a KServe `LLMInferenceService`) is auto-detected,
   attributed to the project, scheduled by `runai-scheduler`, and GPU-accounted — verified with a
   bare `oc create deployment` that came back with `schedulerName=runai-scheduler` and the project
   labels.

Known gaps: the KServe status mismatch above, and an RBAC asymmetry (a Run:ai-first project had no
RHOAI admin binding) — bind one IdP/OpenShift group as both an RHOAI admin and a Run:ai
access-rule subject.

---

## Repository layout

| Path | What it is |
| --- | --- |
| `experiments/` | The **live `ai-dev06` Run:ai/KAI reclamation demo** — the only subtree exercised live. Numbered scripts `01`–`05`, `demo-live.sh`, `run-cycle.sh`, per-team interface under `teams/`, `team-*.json` REST payloads, `env.sh`/`lib.sh`, `kyverno-runai-enroll.yaml`, `dump-runai-config.sh`. |
| `swebench/` | RHOAI/Kueue-first multi-tenant SWE-bench coding-agent baseline (`NVIDIA-1535`). **Design targets only** — its 8× A10G / `Qwen3-32B` TP4 shape and `deploy/runai/` mapping are unverified and do not match the live 5-single-GPU cluster. |
| `post-training/` | RHOAI-only Team B LoRA SFT baseline (`NVIDIA-1537`); one verified `ai-dev06` run with `Qwen2.5-1.5B-Instruct`. |
| `runai-deployment/` | Placeholder (`.gitkeep` only). |
| `reports/` | **Local-only, git-ignored** — live config dumps, demo/cycle/integration reports, and timeline figures are kept here and are *not* committed. |

---

## How to run

All live work is under `experiments/` (see `experiments/README.md`). Prerequisites: `oc login` to
`https://api.ai-dev06.kni.syseng.devcluster.openshift.com:6443` and `export RUNAI_PASSWORD`.

```bash
cd experiments

# One-shot reclaim demo
./05-run-reclaim-demo.sh

# …or step by step
./01-setup-projects.sh          # create team-a (deserved=4) + enable cluster-wide manual over-quota
./03-launch-team-b-victims.sh 3 # Team B borrows idle A10Gs
./02-deploy-inference.sh        # Team A vLLM endpoint preempts a Team B victim
./04-launch-team-a-batch.sh 3   # Team A burst reclaims more capacity

# Narrated walkthrough
NONINTERACTIVE=1 TEAM_A_BURST=2 ./demo-live.sh

# Full symmetric cycle (per-team interface)
cd teams
./team-b/submit.sh 2 ; ./team-a/deploy.sh up ; ./team-a/submit.sh 3 ; ./team-a/deploy.sh down

# Recorded timeline figure
cd .. && ./run-cycle.sh && python3 render-timeline.py

# Cleanup
./99-cleanup.sh [--project] [--revert-setting]
```

---

## Authentication & secrets

Run:ai REST calls need a **system-administrator** user. On `ai-dev06` that is the built-in
`test@run.ai` in Keycloak realm `runai` (ROPC via the public `runai` OIDC client).

- **Never hard-code `RUNAI_PASSWORD`.** `env.sh` guards it with `:?` and requires it exported in
  your shell. It is a **shared account** whose password was changed to obtain a token, so
  coordinate with teammates before running — the demo also mutates the cluster-wide
  `project.quota.manual_over_quota` setting.
- Keycloak master-admin credentials live in cluster secrets `runai-backend-keycloakx` /
  `runai-backend-gen-keycloakx` (namespace `runai-backend`).
- For the `swebench/` and `post-training/` baselines use the OpenShift console **Copy login
  command** flow; do not commit any token.

---

## References & roster

- **Investigation:** NVIDIA DSX OS PaaS — Phase-02, Red Hat Internal · Epic `NVIDIA-1237`.
- **Local work items:** `NVIDIA-1563` (live Team A/B integration, `experiments/`),
  `NVIDIA-1535` (`swebench/` baseline), `NVIDIA-1537` (`post-training/` baseline).
- **Roster:** Architect — Sharon Dashet · Engineering manager — Swati Kale ·
  Engineers — Prudhvi Vuda, Tomer Figenblat, Carlos Camacho Gonzalez.
- **Group repo:** `RHEcosystemAppEng/runai-openshift-exploration`.
- **Run:ai OSS source:** `github.com/dsx-ai-factory/run-ai` (mono repo, OSS 2026-10-13).
- **GPU-fractioning operator:** `github.com/kai-scheduler/gpu-fractioning`.
- **Sibling DSX repos (reference only):** NVIDIA Dynamo, Karta.
