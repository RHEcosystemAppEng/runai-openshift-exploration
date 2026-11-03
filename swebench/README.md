# Multi-tenant autonomous coding agents on a shared GPU cluster

This project is the RHOAI-first baseline for Jira **NVIDIA-1535**. Three data-science
squads share one Red Hat OpenShift AI (RHOAI) GPU cluster. Each squad runs
autonomous coding agents (the **AMI** agent) that solve real GitHub issues from a
different **SWE-bench Live** split, calling a self-hosted **vLLM** endpoint for LLM
inference (GPU) and running each project's test suite (CPU) to validate the patch.

| Squad | Namespace        | SWE-bench split | Priority / SLO                         |
|-------|------------------|-----------------|----------------------------------------|
| A     | `squad-a-lite`   | Lite            | **high** (high SLO, may run over quota)|
| B     | `squad-b-cpp`    | C / C++         | standard                               |
| C     | `squad-c-csharp` | C#              | standard                               |

The goal is a **working OpenShift AI baseline** using **Kueue + DRA + RHOAI hardware
profiles**, and then a **Run:AI phase** that re-targets the *same* workloads (same
projects, annotations, over-quota policies) at the Run:AI scheduler — so the two
schedulers can be compared on admission, quota borrowing, reclamation/preemption,
GPU sharing, coordinated scheduling, and observability.

The project is designed to run against the `dev-06` RHOAI cluster (the same target as
the post-training reference / sibling ticket NVIDIA-1537). Every script refuses to
run unless your `oc` context points at `$CLUSTER_SERVER` (see `config/env.sh`). From
the repo root you can also drive it through the aligned wrapper `scripts/swebench.sh`
(see `scripts/README.md`), which gives the same verbs as the other subprojects.

## Workflow

1. **Preflight** the cluster — verify RHOAI, Kueue, DRA, KServe/ServingRuntime, the
   RHOAI HardwareProfile, and the NVIDIA/AMD GPU operator are present.
2. **Create** the three squad projects/namespaces and apply the OpenShift AI
   dashboard label.
3. **Deploy scheduling** — the Kueue cohort ClusterQueues, Workload/core
   PriorityClasses, the DRA DeviceClass, and a per-squad LocalQueue.
4. **Deploy serving** — a self-hosted vLLM endpoint per squad (KServe
   ServingRuntime + InferenceService + RHOAI HardwareProfile + model-cache PVC).
5. **Deploy agents** — the AMI coordinator, RBAC, and a shared workspace PVC per
   squad.
6. **Launch** the autonomous SWE-bench Live run per squad and watch it with
   `status` (queues, workloads, GPU allocation, progress).

Then the **Run:AI phase** re-points the same projects, annotations, and over-quota
policies at the Run:AI scheduler for a like-for-like comparison with the Kueue
baseline. It is a workflow and scheduling demo, not a SWE-bench quality benchmark.

## RHOAI target

The default model is `Qwen/Qwen3-32B` (`MODEL_ID` / `SERVED_MODEL_NAME` in
`config/env.sh`), served by **vLLM** through a **KServe** ServingRuntime +
InferenceService with an **RHOAI HardwareProfile**; each endpoint fans out over
**4× A10G** (tensor-parallel 4). `config/env.sh` is the single source of truth for
names, quotas, the GPU vendor values, and the model. Check the installed RHOAI
version, enabled components, Kueue/DRA, GPU operator, and the model's availability on
`dev-06` before deploying.

> **Model availability.** The model string `Qwen/Qwen3-32B` must exist on the target
> cluster or its registry — either pullable from Hugging Face by the vLLM runtime or
> mirrored into the cluster's model registry/cache. If the string does not resolve,
> the vLLM pod will fail to start; override `MODEL_ID` to a model the cluster can
> actually serve.

## Shared GPU pool and quotas

All three squads share one Kueue **cohort** (`swebench-gpu-pool`) over an **8x A10G**
pool — two vLLM endpoints' worth, since each endpoint needs **4 A10G** (tensor-parallel 4).
Each squad has a nominal quota plus a `borrowingLimit` (**additional** capacity on top of
the nominal quota, so ceiling = nominal + borrow), so an idle squad's GPUs are lent out and
reclaimed by preemption when the owner bursts:

| Squad | Nominal GPUs | Borrow limit (additional) | Max (ceiling) | Notes                                |
|-------|--------------|---------------------------|---------------|--------------------------------------|
| A     | 4            | 4                         | 8             | high priority — whole 4-GPU endpoint SLO-guaranteed; reclaims B/C's borrowed GPUs to take the pool |
| B     | 2            | 2                         | 4             | borrows 2 to run its 4-GPU endpoint; yields on reclaim |
| C     | 2            | 2                         | 4             | borrows 2 to run its 4-GPU endpoint; yields on reclaim |
| total | 8            | —                         | 8 (pool)      | nominal sum == pool size             |

Squad A's nominal 4 guarantees its whole endpoint; Squads B and C get a nominal 2 each and
must borrow 2 more from the cohort to stand up their own 4-GPU endpoints. Squad A's
workloads carry the `squad-high-priority` WorkloadPriorityClass, so when A submits a burst
it preempts the lower-priority borrowers, reclaims the GPUs B/C borrowed, and can take the
whole 8-GPU pool.

## Repository layout

```
config/env.sh            Single source of truth: names, quotas, vendor values, model.
deploy/
  base/scheduling/       Cluster-scoped: ResourceFlavor, cohort ClusterQueues,
                         Workload+core PriorityClasses, DRA DeviceClass.
  base/serving/          KServe ServingRuntime + InferenceService + RHOAI
                         HardwareProfile + model-cache PVC + Service + Route.
  base/serving-plain/    Same, minus the HardwareProfile (the --no-profile mode).
  base/serving-raw/      Raw vLLM Deployment path (the --raw mode).
  base/agents/           Coordinator Deployment + shared workspace PVC + RBAC.
  overlays/nvidia/**     Passthrough default overlay (base is already NVIDIA).
  overlays/amd/**        Kustomize PATCHES: amd.com/gpu, managed-csi, amd-mi300x,
                         ROCm image, + the FIPS init-container for raw serving.
  squads/<ns>/           Per-squad Namespace + LocalQueue + ResourceClaimTemplate.
scripts/                 Runnable bash (see below). lib/common.sh sources env.sh.
benchmark/               The PROVEN engine (autonomous monitor, per-instance agent +
                         eval Jobs, telemetry). Referenced, not rewritten.
../post-training/        The sibling RHOAI project this one imitates in style, and
                         the root scripts/ wrappers that give both the same verbs.
```

### Vendor parameterization (`nvidia` | `amd`)

`deploy/base/**` carries **concrete NVIDIA values** (`nvidia.com/gpu`, `gp3-csi`,
flavor `nvidia-a10g`, taint `g5-gpu`, RHOAI image `quay.io/modh/vllm:rhoai-2.16`) —
this is the RHOAI-first default, where each endpoint fans out over **4x A10G**
(tensor-parallel 4). `deploy/overlays/amd/` holds kustomize patches that swap to
`amd.com/gpu`, `managed-csi`, flavor `amd-mi300x` (renamed from the base `nvidia-a10g`),
image `vllm/vllm-openai-rocm:latest`, patch `--tensor-parallel-size` down to 1 (one
MI300X's 192 GB fits the 32B model on a single GPU), and add the FIPS libcrypto
init-container (adapted
from the proven `ocp_cluster` ROCm deployment). kustomize cannot read shell `${VARS}`,
so bases stay concrete and overlays patch; the **shell scripts** (which source
`config/env.sh`) use `${VARS}` and select the overlay via `GPU_VENDOR` → `KSERVE_OVERLAY`.
Select the vendor with, e.g. `GPU_VENDOR=amd bash scripts/00-preflight.sh`.

## Deploy to `dev-06`

Log in to `dev-06` with the OpenShift console's **Copy login command** flow (do not
save the token in this repo), then run the numbered scripts in order. Each is
idempotent, prints a usage header with `-h`, and guards the target cluster.

```bash
oc whoami --show-server                              # must equal $CLUSTER_SERVER

bash scripts/00-preflight.sh                         # RHOAI/Kueue/DRA/KServe/GPU readiness table
bash scripts/01-create-projects.sh                   # squad-a-lite, squad-b-cpp, squad-c-csharp
bash scripts/02-deploy-scheduling.sh                 # cohort ClusterQueues + priority + DRA + LocalQueues
bash scripts/03-deploy-serving.sh  --squad all       # vLLM endpoint per squad (KServe + HardwareProfile)
bash scripts/04-deploy-agents.sh   --squad all       # coordinator + workspace per squad
bash scripts/05-launch-benchmark.sh --squad a        # one-click autonomous run for Squad A
bash scripts/06-status.sh                            # serving + agents + Kueue quota across all squads
```

Or, from the repo root, the aligned wrapper: `scripts/swebench.sh setup`, `deploy`,
`run --squad a`, `status`.

### Serving modes (step 3)

```bash
bash scripts/03-deploy-serving.sh --squad a --profile      # KServe + RHOAI HardwareProfile (default)
bash scripts/03-deploy-serving.sh --squad b --no-profile   # plain KServe, no HardwareProfile
bash scripts/03-deploy-serving.sh --squad c --raw          # raw vLLM Deployment (no KServe)
```

### Stop or clean up

```bash
bash scripts/stop.sh --squad a                       # stop the run, keep infra
bash scripts/teardown.sh --squad all                 # remove workloads, keep PVCs
bash scripts/teardown.sh --squad all --delete-pvc --scheduling
```

The launcher needs the SWE-bench Live dataset for the split and a local `ami` binary:

```bash
AMI_BINARY=~/.local/bin/ami DATASET_DIR=~/datasets \
  bash scripts/05-launch-benchmark.sh --squad a --parallel 5
```

### What this proves

This is the repeatable **RHOAI baseline** for the shared-cluster use case: three
tenant projects, one Kueue cohort over a shared GPU pool, DRA single-GPU claims,
RHOAI hardware profiles, and a self-hosted vLLM endpoint per squad driving the proven
autonomous SWE-bench engine. It demonstrates the control surface for admission,
quota borrowing, and high-priority reclamation/preemption between squads.

It does **not** yet prove the **Run:AI phase**: re-targeting the same workloads at the
Run:AI scheduler (project mapping, department quota, over-quota policy injection,
Run:AI preemption/consolidation) and comparing it to the Kueue baseline. The naming
contract and annotations are kept scheduler-neutral so the same manifests and scripts
can be pointed at Run:AI (`RUNAI_SCHEDULER` / `RUNAI_DEPARTMENT` in `config/env.sh`)
once the cluster's Run:AI integration mechanism is settled.

## Verified `dev-06` run

No verified-run metrics are claimed yet — the numbers above (quotas, pool size) are the
design targets from `config/env.sh`; tune them to the real cluster. After the first
`dev-06` run, record here (following the post-training README's "Verified run" format):
OpenShift and RHOAI versions, GPU types, per-squad nominal-vs-allocated GPUs, the served
model, run durations, admission/borrowing/preemption events observed, and the SWE-bench
pass rates. Run outputs land under `reports/` (git-ignored except `.gitkeep`).

## Local development

The full run needs a GPU cluster, but dataset preparation is deterministic and can be run
anywhere with Python 3:

```bash
python -m pip install -r requirements.txt
python data/prepare_datasets.py
```

## References

- [RHOAI: distributed workloads & Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [Kueue — cohorts, borrowing, preemption](https://kueue.sigs.k8s.io/docs/concepts/)
- [Kubernetes Dynamic Resource Allocation (DRA)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [KServe ServingRuntime / InferenceService](https://kserve.github.io/website/)
- [vLLM OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html)
- Proven source engine: `superinference/challenges/ocp_cluster` (vLLM deploy, per-instance agent + eval Jobs).
- Style reference: `../post-training/` (sibling ticket NVIDIA-1537).
