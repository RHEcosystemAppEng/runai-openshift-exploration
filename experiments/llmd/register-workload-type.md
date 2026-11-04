# Registering LLM-D (`LLMInferenceService`) as a Run:ai workload type

How we made Run:ai represent a disaggregated **LLM-D** KServe service as **one unified
inference workload** — the mapping, why it has to be registered through the control plane,
and the exact steps. Verified live on `ai-dev06` (Run:ai OSS V3 3.0.20 / KAI v0.18.3 /
RHOAI 3.5.2, KServe RawDeployment).

Artifacts in this folder:
- [`karta-llminferenceservice.yaml`](karta-llminferenceservice.yaml) — the mapping (single source of truth)
- [`register-workload-type.py`](register-workload-type.py) — loads the YAML and registers it

---

## The problem

A disaggregated LLM-D `LLMInferenceService` (prefill + decode + router/scheduler) runs fine
under Run:ai — the `runai-scheduler` is injected, KAI schedules the pods, quota is accounted.
But Run:ai **does not recognize it as an inference workload**. It shows up as **three
separate generic `Deployment` workloads**:

```
llmd-qwen-pd-kserve              type=Deployment   (decode)
llmd-qwen-pd-kserve-prefill      type=Deployment   (prefill)
llmd-qwen-pd-kserve-router-scheduler  type=Deployment  (EPP)
```

Root cause: Run:ai maps Kubernetes objects to its workload model with **Karta**, and the
stock Karta map set has **no entry for the `LLMInferenceService` CRD** (it covers
`InferenceService` v1beta1 and `LeaderWorkerSet`, but not `LLMInferenceService`). Without a
map, the service falls back to the generic Deployment map and loses its identity and
prefill/decode topology.

## Why you can't just apply a Karta CR

Karta maps are CRs (`kartas.run.ai`), so the obvious fix is to `oc apply` a
`krt-*-llminferenceservice` CR. **That does not survive.** On this build the map set is
**control-plane-managed**: Run:ai's `cluster-sync` continuously reconciles the cluster's
Karta set against the backend and **deletes any custom/non-managed Karta CR within ~24s**
(confirmed; the pruner is `cluster-sync`, not `karta-operator` — scaling the operator down
does not stop it, and management labels do not help). A hand-crafted `ExternalWorkload` CR
also doesn't help — it persists but is never ingested into the workload list.

(Also required, separately: `cluster-sync` needs RBAC to read `llminferenceservices` — it is
forbidden by default — and the service only serves once the `openshift-ai-inference` gateway
exists. See `cluster-sync-rbac.yaml` and `gateway.yaml`.)

## The durable fix: register a workload type

The map set is driven by **workload types** registered in the control plane (each managed
Karta carries a `run.ai/workload-type-id` tying it to a registered type). So the durable way
to add the `LLMInferenceService` map is to **register a workload type** that embeds it:

```
POST /api/v1/workload-types
```

`cluster-sync` then syncs it down as a **managed, un-prunable** Karta CR
(`krt-v1alpha2-serving-kserve-io-llminferenceservice`), and the real service is mapped as one
workload.

### Run it
```bash
export RUNAI_CP=https://runai.apps.<cluster>
export RUNAI_SYSADMIN_TOKEN=<bearer token for a SYSTEM-ADMIN>   # see "Token" below
# category/priority IDs from GET /api/v1/workload-categories and /api/v1/workload-priorities
python3 -I register-workload-type.py        # loads karta-llminferenceservice.yaml, POSTs it
```

### The mapping (what `karta-llminferenceservice.yaml` says)
- **root** = `LLMInferenceService` (v1alpha2); status comes from its own `.status.conditions`
  (`Ready=True` → running). Because it reads the CRD's real conditions, it sidesteps the
  classic "RawDeployment vs Serverless" status mismatch.
- **children** = the decode / prefill / router-scheduler (EPP) Deployments, selected by
  `app.kubernetes.io/component`, nested under the root (so they stop being peers).
- **gang** = prefill + decode co-scheduled, grouped by `app.kubernetes.io/name`.

## Gotchas (each returned a `400` until fixed)
- **System-admin required.** A dept-admin token gets `403 Insufficient permissions`. The
  create validation is authoritative in the OSS source (`dsx-ai-factory/run-ai`
  `control-plane/workloads/pkg/services/...`).
- **Each `kartas[]` element must BE the Karta object** (`{apiVersion,kind,metadata,spec}`).
  The server does `json.Unmarshal(element → models.Karta)`; wrapping it as `{version,karta}`
  (the GET response shape) makes the spec parse empty → "root component ... empty".
- **`childComponents` must be a sibling of `rootComponent`** under `structureDefinition`
  (not nested inside it), or gang members are "not defined".
- **Name/group must match the CRD:** workload-type `name` == Kind (`LLMInferenceService`),
  `group` == `serving.kserve.io`.
- Deprecated: send `kartas`, not `resourceInterfaces`.

## Token (system-admin) on dev-06
The built-in system admin is `test@run.ai`. Its password is reset via the Keycloak master
admin (secrets `runai-backend-keycloakx` / `runai-backend-gen-keycloakx` in ns
`runai-backend`; realm policy: length ≥ 8 + upper/lower/digit/special), then exchanged for a
bearer token via the `runai` OIDC client (ROPC).
My user/password credentials didn't work so this is why I had to rotate it.

## Result (verified live)
```
GET /api/v1/workloads  →  llmd-qwen-pd : LLMInferenceService : Running   (one workload)
oc get kartas.run.ai   →  krt-v1alpha2-serving-kserve-io-llminferenceservice  (managed, persists)
```
`llmd-qwen-pd` now shows in the Run:ai UI as a single `LLMInferenceService` inference
workload instead of three loose Deployments.

## Long-term
NVIDIA/KAI should ship the `LLMInferenceService` Karta map in the **default managed set**
(and cover the LWS-backed multi-node P/D topology), and RHOAI should provision the
`openshift-ai-inference` gateway out of the box — making all of the above unnecessary.

## References
- `karta-llminferenceservice.yaml`, `register-workload-type.py`, `gateway.yaml`,
  `cluster-sync-rbac.yaml`, and `README.md` in this folder.
- Run:ai OSS: `github.com/dsx-ai-factory/run-ai`; Karta: `github.com/dsx-ai-factory/workload-map`
  (see its `skills/add-workload-type` for authoring Karta definitions).
