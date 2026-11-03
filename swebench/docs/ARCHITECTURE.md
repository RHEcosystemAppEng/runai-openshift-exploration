# Architecture — swebench-live-vllm

This document shows how the shared GPU pool is carved up by Kueue + DRA + an RHOAI
hardware profile, how each squad's vLLM endpoint and agent/eval jobs sit inside that
quota, and how a single GitHub issue flows through the AMI agent. It closes with the
Phase-2 Run:ai variant. Every box maps to a real file under
[`deploy/`](../deploy) or [`benchmark/`](../benchmark); names come from
[`config/env.sh`](../config/env.sh).

## Phase 1 — RHOAI baseline

```
                         Shared GPU pool — 8x A10G, ResourceFlavor: nvidia-a10g
                         (node label nvidia.com/gpu.product=NVIDIA-A10G, taint g5-gpu)
                         deploy/base/scheduling/resourceflavor.yaml
                                             │
                        Kueue cohort: swebench-gpu-pool   deploy/base/scheduling/clusterqueue-squad-{a,b,c}.yaml
        ┌────────────────────────────┬──────┴──────────────────┬────────────────────────────┐
        │                            │                          │                            │
 ClusterQueue cq-squad-a      ClusterQueue cq-squad-b    ClusterQueue cq-squad-c       WorkloadPriorityClass
 nominal 4 / borrow ≤4        nominal 2 / borrow ≤2      nominal 2 / borrow ≤2         squad-high-priority (A)
 ceiling 8 (whole pool)       ceiling 4 (one endpoint)   ceiling 4 (one endpoint)
 (squad-high-priority)        (squad-standard)           (squad-standard)              squad-standard  (B,C)
        │                            │                          │                deploy/base/scheduling/priorityclasses.yaml
 LocalQueue "default"         LocalQueue "default"       LocalQueue "default"
   ns squad-a-lite             ns squad-b-cpp             ns squad-c-csharp
        │                            │                          │
        ▼                            ▼                          ▼
┌────────────────────┐     ┌────────────────────┐     ┌────────────────────┐
│ ns squad-a-lite    │     │ ns squad-b-cpp     │     │ ns squad-c-csharp  │   deploy/squads/*/namespace.yaml
│ labels: squad=a,   │     │ squad=b,           │     │ squad=c,           │
│ split=lite         │     │ split=cpp          │     │ split=csharp       │
│                    │     │                    │     │                    │
│  vLLM endpoint     │     │  vLLM endpoint     │     │  vLLM endpoint     │
│  qwen-inference    │     │  qwen-inference    │     │  qwen-inference    │   KServe InferenceService
│  :8000/v1 · 4xA10G │     │  :8000/v1 · 4xA10G │     │  :8000/v1 · 4xA10G │   + ServingRuntime (vLLM)
│  Qwen/Qwen3-32B    │     │  Qwen/Qwen3-32B    │     │  Qwen/Qwen3-32B    │   deploy/base/serving/servingruntime.yaml
│        ▲           │     │        ▲           │     │        ▲           │   deploy/base/serving/inferenceservice.yaml
│        │ /v1       │     │        │           │     │        │           │
│  coordinator (CPU) │     │  coordinator       │     │  coordinator       │   deploy/base/agents/coordinator-deployment.yaml
│  creates Jobs ─────┼──┐  │  creates Jobs      │     │  creates Jobs      │   + deploy/base/agents/rbac.yaml
│        │           │  │  │        │           │     │        │           │
│   ┌────┴─────┐     │  │  │   ┌────┴─────┐     │     │   ┌────┴─────┐     │
│   │ agent Job│ ... │  │  │   │ agent Job│ ... │     │   │ agent Job│ ... │   benchmark/run-instance-k8s.sh
│   │ eval Job │     │  │  │   │ eval Job │     │     │   │ eval Job │     │   benchmark/eval-instance-k8s.sh
│   └────┬─────┘     │  │  │   └────┬─────┘     │     │   └────┬─────┘     │   (each claims single-gpu via DRA)
│        │           │  │  │        │           │     │        │           │
│  workspace PVC     │  │  │  workspace PVC     │     │  workspace PVC     │   deploy/base/agents/workspace-pvc.yaml
│  /data /staging    │  │  │                    │     │                    │   (RWX: ocs-storagecluster-cephfs)
│  /results /eval..  │  │  │                    │     │                    │
└────────────────────┘  │  └────────────────────┘     └────────────────────┘
                        │
         DRA: DeviceClass gpu.nvidia.com + ResourceClaimTemplate single-gpu
         deploy/base/scheduling/dra.yaml + deploy/squads/*/resourceclaimtemplate.yaml
         RHOAI HardwareProfile swebench-gpu-profile  deploy/base/serving/hardwareprofile.yaml
```

Key points:

- **One cohort, three ClusterQueues.** All GPU quota is pooled in `swebench-gpu-pool`;
  each squad draws from its own ClusterQueue with a nominal guarantee and a borrowing
  ceiling. Unused capacity flows to whoever needs it and is reclaimed by preemption.
- **DRA for GPUs.** GPUs are requested through a `ResourceClaimTemplate` (`single-gpu`)
  against `DeviceClass gpu.nvidia.com` rather than only a raw `nvidia.com/gpu` count, so
  the same manifests re-target cleanly to other accelerators via overlays.
- **RHOAI hardware profile.** `swebench-gpu-profile` carries the node tolerations
  (taint key `g5-gpu`), accelerator identity (4x A10G), and resource shape the RHOAI
  dashboard and admission expect — the same convention as the NVIDIA-1537 workbench manifest.
- **Serving via KServe.** Each squad's `qwen-inference` endpoint is a KServe
  `InferenceService` backed by a vLLM `ServingRuntime`, pinned to
  `quay.io/modh/vllm:rhoai-2.16`, serving `Qwen/Qwen3-32B` across **4x A10G**
  (`--tensor-parallel-size 4`, `--max-model-len 32768` so the KV cache fits), exposing
  the OpenAI-compatible `/v1` API the agent uses.
- **CPU vs GPU split.** The vLLM endpoint and the per-instance agent jobs consume GPU; the
  coordinator and the test-execution/eval jobs are primarily CPU. CPU/memory quota per
  squad is set in `config/env.sh` (`SQUAD_CPU_NOMINAL`, `SQUAD_MEM_NOMINAL`).

## Data flow of one SWE-bench issue

The engine under `benchmark/` is unchanged from the proven `ocp_cluster` run; the
scheduling stack above decides *when and where* each of these steps gets a GPU.

```
 (1) retrieve issue        coordinator reads one record from the split JSONL on the
                           workspace PVC (/data/swebench-multilang-<split>.jsonl):
                           repo, problem_statement, test_patch, FAIL_TO_PASS, docker_image
                                   │   benchmark/run-instance-k8s.sh builds the prompt
                                   ▼
 (2) reason via vLLM       agent Job runs the AMI binary against
                           http://qwen-inference.<ns>.svc:8000/v1 (Qwen/Qwen3-32B).
                           The Job holds a single-gpu DRA claim while it reasons.
                                   │
                                   ▼
 (3) patch                 AMI edits the repo cloned in the instance image (/testbed),
                           commits, and emits agent.patch → ami-<slug>-diff.patch on the PVC
                                   │
                                   ▼
 (4) test / eval           eval Job (benchmark/eval-instance-k8s.sh) resets the repo,
                           applies agent.patch + the test_patch, runs test_cmds, and parses
                           FAIL_TO_PASS / PASS_TO_PASS with the instance log_parser
                                   │
                                   ▼
 (5) report.json           {resolved, FAIL_TO_PASS, PASS_TO_PASS} written to
                           /workspace/eval-results/<split>/<model-slug>/<instance>/report.json
                           telemetry_parse.py records vLLM/GPU metrics alongside it
```

The autonomous driver `benchmark/autonomous-k8s-monitor.sh` loops steps 1–5 across the
whole split with `PARALLEL` concurrent Jobs, retries close misses, and archives per-round
backups — see [`benchmark/`](../benchmark) and the file-structure section of the proven
`ocp_cluster/README.md`.

## Vendor parameterization (NVIDIA default, AMD overlay)

Kustomize cannot expand shell `${VARS}`, so the **bases carry concrete NVIDIA values** and
**overlays patch** them. Shell scripts, which *do* source `config/env.sh`, use `${VARS}`.

```
deploy/
├── base/                 concrete NVIDIA baseline (nvidia.com/gpu, gp3-csi,
│   ├── ...                flavor nvidia-a10g, taint g5-gpu, vllm:rhoai-2.16)
│   └── kustomization.yaml
└── overlays/
    ├── nvidia/           passthrough default overlay → base unchanged
    │   └── kustomization.yaml
    └── amd/              patches: amd.com/gpu "1" + --tensor-parallel-size 1 (one
        ├── kustomization.yaml          MI300X = 192GB fits 32B on ONE GPU), managed-csi,
        ├── patch-*.yaml                flavor amd-mi300x (renamed from nvidia-a10g),
        └── patch-fips-initcontainer.yaml  image vllm/vllm-openai-rocm:latest, and
                                            ADDS the FIPS init-container (binary-patches
                                            opencv's bundled OpenSSL 1.1.1k, mirroring
                                            ocp_cluster/deploy/03-deployment-vllm.yaml)
```

`GPU_VENDOR=nvidia|amd` in `config/env.sh` selects the overlay (`KSERVE_OVERLAY`) and all
the matching resource names, so `oc apply -k deploy/overlays/$KSERVE_OVERLAY` deploys the
right variant.

## Phase 2 — Run:ai variant

Phase 2 re-targets the *same* namespaces, PVCs, vLLM endpoints, coordinator, and
agent/eval Jobs; only the scheduling layer changes.

```
        Shared GPU pool — 8x A10G (same nodes, same flavor)
                          │
            Run:ai scheduler: runai-scheduler
                          │
        Run:ai department: swebench   (replaces the Kueue cohort)
        ┌─────────────────┼──────────────────┐
  Run:ai project A   Run:ai project B   Run:ai project C   (replace the ClusterQueues;
  deserved 4 / max 8   deserved 2 / max 4  deserved 2 / max 4  over-quota ON for A)
        │                 │                  │
   ns squad-a-lite   ns squad-b-cpp    ns squad-c-csharp    (UNCHANGED namespaces + labels)
        │                 │                  │
   vLLM endpoint     vLLM endpoint      vLLM endpoint        (UNCHANGED InferenceService)
   coordinator       coordinator        coordinator          (UNCHANGED)
   agent/eval Jobs   agent/eval Jobs    agent/eval Jobs      (schedulerName + Run:ai
        │                 │                  │                 project annotation added)
   workspace PVC     workspace PVC      workspace PVC         (UNCHANGED)
```

In Phase 2 the Kueue objects are replaced by Run:ai projects/departments, workloads carry
`schedulerName: runai-scheduler` and the Run:ai project annotation, and over-quota is a
project policy instead of a Kueue borrowing limit (`RUNAI_*` knobs in `config/env.sh`).
Everything below the scheduler — serving, coordinator, agent/eval engine, workspace,
labels — is identical, which is exactly what makes the RHOAI-vs-Run:ai comparison in
[EVALUATION.md](./EVALUATION.md) apples-to-apples.

## References

- [`config/env.sh`](../config/env.sh) — all names, quotas, and vendor values
- [`deploy/base/`](../deploy/base) · [`deploy/overlays/nvidia/`](../deploy/overlays/nvidia) · [`deploy/overlays/amd/`](../deploy/overlays/amd)
- [`benchmark/run-instance-k8s.sh`](../benchmark/run-instance-k8s.sh) · [`benchmark/eval-instance-k8s.sh`](../benchmark/eval-instance-k8s.sh) · [`benchmark/autonomous-k8s-monitor.sh`](../benchmark/autonomous-k8s-monitor.sh)
- [Kueue cohorts and borrowing](https://kueue.sigs.k8s.io/docs/concepts/cluster_queue/)
- [Kubernetes Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [RHOAI model serving (KServe)](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
