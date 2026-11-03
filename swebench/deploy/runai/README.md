# Phase 2 — Run:AI re-targeting (NVIDIA-1535)

This directory re-targets the **same** multi-tenant SWE-bench Live workloads that the
Phase-1 RHOAI baseline runs — the three squads, their namespaces, the shared vLLM
endpoint, and the per-instance agent Jobs — from **Kueue + DRA + hardware profiles**
onto the **Run:AI scheduler**. Nothing about what the squads *do* changes: Squad A
still solves SWE-bench Lite at high priority, Squad B/C still solve C/C++ and C#.
Only the admission/quota/preemption control plane changes.

The goal is to evaluate, object-for-object, how the proven Kueue design maps onto
Run:AI: admission, quota borrowing, reclamation/preemption, GPU sharing, coordinated
scheduling, and observability — so the two phases can be compared on the same cluster
with the same engine (`benchmark/`).

## Kueue ⇄ Run:AI object mapping

| Concern | Phase 1 (RHOAI / Kueue) | Phase 2 (Run:AI) | File |
|---|---|---|---|
| Shared GPU pool (8 GPUs) | Kueue **cohort** `swebench-gpu-pool` | **Department** `swebench` (`deserved: 8`) | `department.yaml` |
| Per-squad quota | **ClusterQueue** `cq-squad-a/-b/-c` + `nominalQuota[gpu]` (A=2,B=3,C=3) | **Project** `squad-a-lite/-b-cpp/-c-csharp` + `resources.gpu.deserved` | `projects.yaml` |
| Queue binding in namespace | **LocalQueue** `default` in each squad ns | Project ↔ namespace binding (`spec.namespace` / `runai=<project>` label) | `projects.yaml` |
| Quota borrowing | `ClusterQueue.borrowingLimit[gpu]` (A→6, B/C→2) | over-quota: `resources.gpu.overQuota` + `maxAllowed` ceiling (A→8, B/C→5) | `projects.yaml`, `policies/overquota-policy.yaml` |
| Reclaim borrowed on burst | `preemption.reclaimWithinCohort: Any` | intrinsic Run:AI over-quota preemption (evicts borrowed before deserved) | `policies/priority-policy.yaml` |
| Priority | **WorkloadPriorityClass** `squad-high-priority` / `squad-standard` | project `defaultPriorityClassName` + policy-pinned `priorityClassName` | `projects.yaml`, `policies/priority-policy.yaml` |
| High-tenant preempts borrowers | `preemption.borrowWithinCohort: priority` | high-priority Squad A preempts B/C over-quota pods | `policies/priority-policy.yaml` |
| Accelerator flavor / node pool | **ResourceFlavor** `nvidia-a10g` (labels + tolerations) | policy default `nodePools: [nvidia-a10g]` + tolerations | `policies/admission-policy.yaml` |
| Default GPU shape | **HardwareProfile** `swebench-gpu-profile` | policy `defaults.gpu` | `policies/admission-policy.yaml`, `policies/overquota-policy.yaml` |
| GPU sharing / fractions | **DRA** `DeviceClass gpu.nvidia.com` + `ResourceClaimTemplate single-gpu` | Run:AI GPU fractions / MIG (`gpu: <fraction>` in workload/policy) | `policies/admission-policy.yaml` *(fraction = TODO per use case)* |
| Scheduler selection | LocalQueue admission (default-scheduler + Kueue) | `schedulerName: runai-scheduler` on every pod | `scheduler-patch.yaml`, `policies/admission-policy.yaml` |
| Charge workload to tenant | `kueue.x-k8s.io/queue-name: default` label | `runai/project: <squad>` annotation/label | `scheduler-patch.yaml` |

## Files

| File | Purpose |
|---|---|
| `department.yaml` | `swebench` Department holding the shared 8-GPU pool quota (cohort analogue). |
| `projects.yaml` | Three Projects with deserved GPU quota (A=2, B=3, C=3), over-quota enabled, borrow ceilings (A=8, B/C=5), and priority mapping (A high). |
| `scheduler-patch.yaml` | Example strategic-merge patch adding `schedulerName: runai-scheduler` + project annotation to the vLLM workload and the agent Jobs (applied by `scripts/10-enable-runai.sh`). |
| `policies/overquota-policy.yaml` | Over-quota limits — Squad A may exceed, B/C hard-capped (borrowingLimit analogue). |
| `policies/priority-policy.yaml` | Priority & preemption — high-priority Squad A preempts, deserved quota reclaimed. |
| `policies/admission-policy.yaml` | Workload admission guard-rails + defaults (scheduler, node pool, tolerations, floors). |
| `kustomization.yaml` | Bundles Department + Projects + policies (not the scheduler patch). |

## How to apply this phase

All names/quotas come from `config/env.sh` (the single source of truth). Scripts
source it and guard on `$CLUSTER_SERVER`; the manifests here carry the mirrored
concrete values because kustomize cannot expand shell variables.

1. **Prerequisite:** the Phase-1 baseline is deployed and the Run:AI operator is
   installed on the cluster, with the `run.ai` CRDs present:

   ```bash
   oc api-resources | grep -i run.ai      # confirm Department/Project/*Policy kinds + apiVersion
   oc whoami --show-server                 # must equal $CLUSTER_SERVER from config/env.sh
   ```

2. **Create the Run:AI control objects** (Department, Projects, policies):

   ```bash
   oc apply -k deploy/runai/
   ```

3. **Re-target the running workloads** onto the Run:AI scheduler. This is what
   `scripts/10-enable-runai.sh` does: it sources `config/env.sh` and applies
   `scheduler-patch.yaml` to the vLLM Deployment and injects the same two fields
   (`schedulerName: runai-scheduler` + `runai/project`) into each agent Job the
   coordinator generates:

   ```bash
   bash scripts/10-enable-runai.sh
   ```

4. **Verify** admission, borrowing, and preemption:

   ```bash
   oc get project.run.ai                                  # deserved vs. allocated GPUs
   oc get pods -A -l app.kubernetes.io/part-of=swebench-live-vllm \
     -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,SCHED:.spec.schedulerName
   ```

   Burst Squad A while B/C hold borrowed GPUs and confirm Run:AI reclaims the
   over-quota pods (the Kueue `reclaimWithinCohort` behaviour).

## ⚠️ Version-confirmation TODOs

Every manifest here uses the `run.ai/v2alpha1` group/version and the documented
field names the task specified, but **Run:AI CRD schemas differ across versions**.
Before applying on a real cluster, confirm and adjust:

- `apiVersion`/`kind` for Department, Project, and the `*Policy` objects
  (`oc api-resources | grep run.ai`, `oc explain <kind>.run.ai --recursive`).
- The over-quota field (`resources.gpu.overQuota` vs. an over-quota *weight*).
- The project↔namespace binding (`spec.namespace` vs. the `runai=<project>` ns label).
- The project annotation key on pods (`runai/project` vs. `project` label vs.
  namespace-label-only).
- Policy scope namespaces (`runai-<project>` vs. a department/tenant scope).

Each file carries inline `TODO(confirm)` markers at the exact fields in question.
These are intentionally the documented names, **not** invented APIs; resolve them
against the installed Run:AI version rather than guessing.

## What this proves

Applying this phase demonstrates that the Phase-1 multi-tenant design — one shared
GPU pool, three squads with nominal quotas, an over-quota high-SLO tenant, and
reclaim-by-preemption — maps cleanly onto Run:AI's Department/Project/over-quota
model **without changing the workloads or the benchmark engine**. It sets up the
side-by-side evaluation of the two schedulers (admission latency, borrowing
behaviour, reclamation fairness, GPU sharing, observability) called for by
NVIDIA-1535. It does **not** by itself prove numeric scheduler behaviour on the
cluster — run Phase 1 and Phase 2 with the same `benchmark/` engine and record the
results before drawing conclusions.

## References

- [Red Hat OpenShift AI — distributed workloads & Kueue](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/)
- [Kueue — cohorts, borrowing, preemption](https://kueue.sigs.k8s.io/docs/concepts/)
- [Kubernetes DRA (Dynamic Resource Allocation)](https://kubernetes.io/docs/concepts/scheduling-eviction/dynamic-resource-allocation/)
- [NVIDIA Run:AI — projects, departments, quotas & over-quota](https://docs.nvidia.com/run-ai/)
- [NVIDIA Run:AI — scheduling, fairness & preemption](https://docs.nvidia.com/run-ai/)
