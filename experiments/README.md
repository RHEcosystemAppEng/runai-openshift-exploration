# ai-dev06 overlay — Team A priority / GPU reclamation demo

This folder is a **live-cluster adaptation** of the `swebench-live-vllm` demo for the
OpenShift cluster **`ai-dev06`**, which runs **NVIDIA Run:ai (KAI scheduler) v3.0.20**.

It demonstrates the core fairness promise: **a higher-priority team (Team A) with a
guaranteed GPU quota reclaims GPUs from a lower-priority team (Team B) by preempting
Team B's over-quota workloads** — here, Team A's workload is a real **vLLM inference
endpoint** plus **SWE-bench batch jobs** that call it.

## Why this overlay differs from `deploy/base` and `deploy/runai`

The repo's base templates target an 8-GPU cluster with 4-GPU nodes, Kueue or
`run.ai/v2alpha1` CRDs, and Qwen3-32B (tensor-parallel 4). `ai-dev06` is different,
so applying the base templates verbatim does **not** work here:

| Base template assumes | ai-dev06 reality | Consequence |
|---|---|---|
| 8 GPUs on 4-GPU nodes | **5 GPUs on 5 single-GPU nodes** (4× A10G 24 GB + 1× L40S 48 GB) | No pod can get 4 GPUs → **tensor-parallel 4 is impossible**; we serve a model that fits ONE A10G. |
| Qwen3-32B | needs the 4-GPU node above | Overlay defaults to `Qwen/Qwen2.5-3B-Instruct` (fits one A10G); swap `spec.model.uri` in the LLMISVC. |
| Kueue / `run.ai/v2alpha1` CRDs | **Run:ai / KAI**; projects are `kai.resources` CRs **synced from the control plane** | Projects are created via the **REST API**, not `oc apply`. Kueue labels are ignored. |
| `InferenceService` (RawDeployment) | RHOAI serving stack is **KServe LLM (`LLMInferenceService` v1alpha2)** with well-known vLLM presets | Team A inference is a standard `LLMInferenceService` that merges `…single-node-template-nvidia-cuda`. |
| no special node taints | GPU nodes tainted `g5-gpu` (A10G) / `g6e-gpu` (L40S) | Every workload must carry matching **tolerations** (baked into the JSON payloads). |
| `quay.io/modh/vllm:rhoai-2.16` | that tag is a **404** | Overlay uses `quay.io/modh/vllm:rhoai-2.16-cuda`. |

Because of the above, this overlay uses two reproducible paths, applied by the
numbered scripts:
- **`oc apply`** of the standard **`LLMInferenceService`** CR for Team A inference.
- the **Run:ai REST API** with versioned JSON payloads (`team-*.json`) for things
  that are not cluster CRDs here: the **project/quota** (control-plane synced) and
  the **batch/training** workloads (so they appear in the Run:ai Workloads UI).

## Layout

| File | Purpose |
|---|---|
| `env.sh` | All config (cluster IDs, model, taints). **No secrets** — export `RUNAI_PASSWORD`. |
| `lib.sh` | `runai_token`, `api`, `render`, `workload_id`, `gpu_holders` helpers. |
| `team-a-project.json` | Team A project: GPU `deserved: 4`, over-quota ceiling unlimited. |
| `team-a-llminferenceservice.yaml` | Team A vLLM endpoint — **RHOAI-standard KServe `LLMInferenceService`**, 1 GPU, `runai-scheduler`. |
| `team-a-swebench-batch.json` + `swebench_agent.py` | CPU batch job that makes a real completion call to the endpoint. |
| `team-b-victim.json` | Team B preemptible training job (deserved 0 → over-quota → reclaimable). |
| `01`..`05`, `99` scripts | setup → inference → victims → batch → full demo → cleanup. |

## Prerequisites

```bash
oc login --token=<your-token> --server=https://api.<your-cluster>:6443
export RUNAI_PASSWORD='<test@run.ai password>'      # see "Getting an admin token"
```

### Getting an admin token
The Run:ai REST API (project/workload management) needs a user with the
`system-administrator` role. The built-in one is `test@run.ai`. Its password can be
set via the Keycloak master admin, whose creds live in cluster secrets:

```bash
# master admin creds
oc get secret runai-backend-keycloakx     -n runai-backend -o jsonpath='{.data.KEYCLOAK_ADMIN}'          | base64 -d   # username
oc get secret runai-backend-gen-keycloakx -n runai-backend -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d   # password
# then (one time) set a password on test@run.ai via the Keycloak admin REST API, and
export RUNAI_PASSWORD='<that password>'
```
`lib.sh` exchanges `RUNAI_USER`/`RUNAI_PASSWORD` for a bearer token via the `runai`
OIDC client (ROPC) in the `runai` realm.

## Run it

```bash
# one-shot end-to-end demo
./05-run-reclaim-demo.sh

# or step by step
./01-setup-projects.sh            # create team-a (deserved 4) + enable over-quota
./03-launch-team-b-victims.sh 3   # Team B fills the 3 free A10Gs (BEFORE)
./02-deploy-inference.sh          # Team A vLLM -> preempts a Team B victim (reclaim)
./04-launch-team-a-batch.sh 3     # Team A SWE-bench batch jobs call the endpoint
```

Watch it in the Run:ai UI → **Workloads** (project `team-a` vs `team-b-lora`): Team A
`Inference` + `Training` rows go Running while Team B `team-b-victim-*` rows flip to
Pending (preempted). `oc get events -A | grep -i preempt` shows the scheduler's record.

## Showcase views

```bash
./show-by-category.sh                 # workloads grouped by Deploy / Build / Train (live)
watch -c -n2 ./show-by-category.sh    # same, auto-refreshing (good on screen)
NONINTERACTIVE=1 TEAM_A_BURST=2 ./demo-live.sh   # live before→reclaim→after narration

# Timeline (Gantt): capture GPU ownership over a reclaim, then render to ../reports/
./showcase-timeline.sh               # writes ../reports/timeline-data.jsonl
python3 render-timeline.py           # -> ../reports/timeline.html (screenshot to .png)
```

## Cleanup

```bash
./99-cleanup.sh                    # delete demo workloads
./99-cleanup.sh --project          # also delete the team-a project
./99-cleanup.sh --revert-setting   # also set manual_over_quota back to false
```

## Notes / caveats
- The batch jobs are a **representative** SWE-bench agent (real inference call, no
  per-instance repo image / AMI agent). For the full pipeline see `deploy/base/agents`.
- `test@run.ai`'s password was changed to obtain an API token — coordinate with
  teammates who use that shared account.
- The demo changes a **cluster-wide** setting (`manual_over_quota`); revert with the
  flag above if you need the original state.
