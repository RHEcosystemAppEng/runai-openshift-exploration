# runai-openshift-exploration

Run:ai OSS (v3.0.20) on OpenShift with RHOAI workloads.

This repo demonstrates, live on cluster `dev-06`, two OpenShift AI projects mapped to
Run:ai (KAI-scheduled) queues under a single department that contend for the same GPUs
through Run:ai quota, over-quota weight, and workload-category priority. In this repo a
department and a project are Run:ai Kubernetes CRDs (`projects.kai.resources` and
`scheduling.run.ai` queues).

## Versions tested

Live-confirmed on `dev-06`.

| Component | Version |
| --- | --- |
| OpenShift | 4.22.13 (Kubernetes v1.35.6) |
| Container runtime (NRI enabled) | cri-o 1.35.6 |
| OpenShift AI / RHOAI (self-managed) | 3.5.2 |
| NVIDIA Run:ai control plane (OSS V3) | 3.0.20 |
| KAI Scheduler (scheduler + binder) | v0.18.3 |
| NVIDIA GPU Operator | 26.7.0 |
| Kyverno | 1.19.2 |

Also confirmed from the live stack: OpenShift Serverless (Knative, for KServe) 1.36.1,
Keycloak 26.6, Valkey/Redis 9.0.4, KServe `LLMInferenceService` v1alpha2 (runtime
`0.24.0+rhaiv.13`), Training Hub 0.9.2, vLLM runtime image
`quay.io/modh/vllm:rhoai-2.16-cuda`.

GPU pool: 5 single-GPU nodes, being 4x NVIDIA A10G 24 GB (used for contention) and
1x NVIDIA L40S 48 GB (hosts Team B's workbench). Neither queue has a hard GPU cap
(`gpu.limit = -1`).

## Team A and Team B configuration

Values come from `experiments/env.sh`, `experiments/team-a-project.json`, and
`experiments/01-setup-projects.sh`. Queue priority and over-quota weight come from the
live cluster, not the JSON.

| | Team A (inference) | Team B (model customization) |
| --- | --- | --- |
| Workloads | vLLM inference supporting agents | LoRA fine-tuning + interactive notebook |
| Run:ai queue | `team-a` | `team-b-lora` |
| Guaranteed (deserved) GPUs | 4 | 0 (borrows capacity) |
| GPU limit | `-1` (uncapped) | `-1` (uncapped) |
| Queue priority | 100 | 100 |
| Over-quota (surplus) weight | 4 | 0.01 |
| Served model | `Qwen/Qwen2.5-3B-Instruct` (fits one A10G) | `Qwen/Qwen2.5-1.5B-Instruct` (LoRA) |

Reclaim precedence is not queue priority (both queues are equal at 100). Team A wins
contention through: (a) deserved quota 4 vs 0, (b) over-quota weight 4 vs 0.01, and
(c) workload-category priority classes inference (125) > build (100) > train (50). Only
`train` is preemptible, so Team B's over-quota LoRA training yields first, while its
notebook (`build`, on the L40S) is never preempted.

## Contention scenario and observed findings

Scenario: Team A (vLLM inference supporting agents) and Team B (LoRA training plus an
interactive notebook) share the 4x A10G pool; the L40S hosts Team B's workbench.

Observed:

1. GPU borrowing. Team B's `deserved=0` LoRA job borrows idle A10Gs while Team A is light.
2. Dynamic reclaim. When Team A's inference or burst needs capacity, KAI preempts Team B's
   over-quota `train` pods (captured `oc` events, for example
   `team-b-victim-2 preempted by runai-team-a/pg-team-a-burst-1`), typically within about
   8 seconds on a warm run, with no oscillation.
3. Capacity return. After Team A releases, the preempted Team B jobs go `Pending` and then
   reclaim their GPU lanes.
4. Graceful preemption. Preemption honours `terminationGracePeriodSeconds` (SIGTERM), so
   checkpoint-capable jobs can save and resume; save/resume was validated in separate
   controlled tests.

Not yet validated: a full end-to-end recovery in one pass (checkpoint save, reschedule,
restore, completion).

## RHOAI and Run:ai integration

No custom code, and not a product integration; this is project-to-project linking only.

1. Create the RHOAI Data Science Project and namespace (`opendatahub.io/dashboard="true"`).
2. A Kyverno `ClusterPolicy` (`experiments/kyverno-runai-enroll.yaml`) injects the label
   `runai/queue=<namespace>` and annotation `runai/enforce-scheduler-name="true"`.
3. Register the matching Run:ai team via REST `POST /api/v1/org-unit/projects`
   (`parentId` is the department, with a GPU quota). This creates the `kai.resources`
   Project, the `scheduling.run.ai` Queue, and RoleBindings.
4. Mirror RBAC via `POST /api/v1/authorization/access-rules`.
5. Any workload deployed in the namespace (for example a KServe `LLMInferenceService`) is
   auto-detected, attributed to the project, scheduled by `runai-scheduler`, and
   GPU-accounted. This was verified with a bare `oc create deployment` that came back with
   `schedulerName=runai-scheduler` and the project labels.

Known gap: an RBAC asymmetry (a Run:ai-first project had no RHOAI admin binding). Bind one
IdP/OpenShift group as both an RHOAI admin and a Run:ai access-rule subject.

## Repository layout

| Path | What it is |
| --- | --- |
| `experiments/` | The live `dev-06` Run:ai/KAI reclamation demo, the only subtree exercised live. Numbered scripts `01` to `05`, `demo-live.sh`, `run-cycle.sh`, per-team interface under `teams/`, `team-*.json` REST payloads, `env.sh`/`lib.sh`, `kyverno-runai-enroll.yaml`, `dump-runai-config.sh`. |
| `swebench/` | RHOAI/Kueue-first multi-tenant SWE-bench coding-agent baseline. Design targets only; its 8x A10G and `Qwen3-32B` tensor-parallel-4 shape and `deploy/runai/` mapping are unverified and do not match the live 5-single-GPU cluster. |
| `post-training/` | RHOAI-only Team B LoRA fine-tuning baseline; one verified `dev-06` run with `Qwen2.5-1.5B-Instruct`. |
| `scripts/` | Root entrypoints giving each subproject the same verbs (`setup`, `deploy`, `run`, `status`, `teardown`). |
| `runai-deployment/` | Placeholder (`.gitkeep` only). |
| `reports/` | Local-only and git-ignored. Live config dumps, demo and cycle reports, and timeline figures are kept here and are not committed. |

## How to run

All live work is under `experiments/` (see `experiments/README.md`). Prerequisites:
`oc login` to `https://api.<your-cluster>:6443` and `export RUNAI_PASSWORD`.

```bash
cd experiments

# One-shot reclaim demo
./05-run-reclaim-demo.sh

# ...or step by step
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

## Authentication and secrets

Run:ai REST calls need a system-administrator user. On `dev-06` that is the built-in
`test@run.ai` in Keycloak realm `runai` (ROPC via the public `runai` OIDC client).

- Never hard-code `RUNAI_PASSWORD`. `env.sh` guards it with `:?` and requires it exported
  in your shell. It is a shared account whose password was changed to obtain a token, so
  coordinate with teammates before running; the demo also mutates the cluster-wide
  `project.quota.manual_over_quota` setting.
- Keycloak master-admin credentials live in cluster secrets `runai-backend-keycloakx` and
  `runai-backend-gen-keycloakx` (namespace `runai-backend`).
- For the `swebench/` and `post-training/` baselines use the OpenShift console Copy login
  command flow; do not commit any token.

## References

- Run:ai OSS source: `github.com/dsx-ai-factory/run-ai`
- GPU-fractioning operator: `github.com/kai-scheduler/gpu-fractioning`
- Group repo: `RHEcosystemAppEng/runai-openshift-exploration`
