# Squads — multi-tenant GPU cluster (NVIDIA-1535)

Three data-science squads share one RHOAI GPU cluster. Each squad runs its own
autonomous coding agents (the AMI agent) against a different SWE-bench Live split,
backed by its own self-hosted vLLM endpoint (`qwen-inference`, serving
`Qwen/Qwen3-32B` across 4x A10G at tensor-parallel 4 on port 8000 over the
OpenAI-compatible `/v1` API). Every squad is one OpenShift namespace with an identical
internal shape, so the same workloads re-target cleanly in the Run:AI phase.

## Squad → namespace → split → priority → quota

| Squad | Namespace        | SWE-bench split | ClusterQueue | WorkloadPriorityClass | Nominal GPUs | Borrow up to |
|-------|------------------|-----------------|--------------|-----------------------|--------------|--------------|
| A     | `squad-a-lite`   | Lite            | `cq-squad-a` | `squad-high-priority` | 4            | 4            |
| B     | `squad-b-cpp`    | C/C++           | `cq-squad-b` | `squad-standard`      | 2            | 2            |
| C     | `squad-c-csharp` | C#              | `cq-squad-c` | `squad-standard`      | 2            | 2            |

All three ClusterQueues share one Kueue cohort, `swebench-gpu-pool`, backed by the
`nvidia-a10g` ResourceFlavor. The pool totals **8x A10G** — two vLLM endpoints' worth,
since each endpoint runs across 4 A10G (tensor-parallel 4). Nominal quotas sum to 8, so the
cluster is fully subscribed and borrowing is always at another squad's expense. Squad A is
the high-SLO tenant: its nominal 4 guarantees its whole endpoint, and `squad-high-priority`
lets it borrow the rest of the pool (ceiling 8) and preempt the standard squads. Squads B
and C get a nominal 2 each and must borrow 2 more (ceiling 4) to stand up their own 4-GPU
endpoints; those borrowed GPUs are reclaimed through preemption when Squad A bursts.

## What each squad directory contains

Each `squad-<x>/` directory holds only the squad-local objects and a kustomization
that pins the shared bases into the squad's namespace:

- `namespace.yaml` — the namespace, labelled `squad`, `split`,
  `app.kubernetes.io/part-of: swebench-live-vllm`, the RHOAI dashboard opt-in
  (`opendatahub.io/dashboard: "true"`), and the default LocalQueue label.
- `localqueue.yaml` — the LocalQueue named `default` (same in every squad, so
  workloads are portable) pointing at the squad's ClusterQueue.
- `resourceclaimtemplate.yaml` — the `single-gpu` DRA `ResourceClaimTemplate`
  instantiated in the namespace, selecting one device from the `gpu.nvidia.com`
  DeviceClass.
- `kustomization.yaml` — sets the namespace, pulls `../../base/serving`
  (the vLLM endpoint) and `../../base/agents` (the coordinator + RWX workspace),
  adds the local queue and claim template, and stamps the squad identity labels
  plus the squad's Kueue priority onto the workloads.

## How to deploy

The ClusterQueues these LocalQueues reference, the `swebench-gpu-pool` cohort, the
WorkloadPriorityClasses, the `nvidia-a10g` ResourceFlavor, and the DRA DeviceClass
are cluster-scoped and live under `deploy/base/scheduling`. Apply them first:

```bash
# cluster-scoped scheduling prerequisites
kustomize build deploy/base/scheduling | oc apply -f -

# all three squads (NVIDIA baseline)
kustomize build deploy/squads | oc apply -f -

# or one squad at a time
kustomize build deploy/squads/squad-a-lite | oc apply -f -
```

For the AMD variant, render through `deploy/overlays/amd` (which patches the GPU
resource name to `amd.com/gpu: "1"`, drops `--tensor-parallel-size` to 1 — one MI300X's
192 GB fits the 32B model on a single GPU — the storage class, the ResourceFlavor
(`amd-mi300x`, renamed from `nvidia-a10g`), the vLLM image, and adds the FIPS
init-container) rather than applying these directories directly.

## What this proves

This is the per-tenant layer of the shared-cluster baseline: three isolated
namespaces, each with its own vLLM endpoint and agents, all admitted through one
Kueue cohort with per-squad quota, borrowing limits, and priority. It sets up the
admission, quota-borrowing, and reclamation/preemption behaviour evaluated against
the cluster, and gives the Run:AI phase the same namespaces, queues, priorities,
and over-quota policy to re-target.

References:

- [Kueue — cohorts, borrowing and preemption](https://kueue.sigs.k8s.io/docs/concepts/)
- [RHOAI — Dynamic Accelerator Slicing / DRA and hardware profiles](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [Kubernetes — Dynamic Resource Allocation](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
