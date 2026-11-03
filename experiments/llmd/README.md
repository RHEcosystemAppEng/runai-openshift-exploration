# llmd — LLM-D on RHOAI, shown correctly in Run:ai

Deploy a KServe **llm-d** (`LLMInferenceService`) on `ai-dev06`, link the project to Run:ai,
and have Run:ai display the **real** service as **one unified inference workload**.

This folder contains only what is used and working. End state (verified live):

| Plane | Shows |
|---|---|
| OpenShift AI (KServe) | `LLMInferenceService` `llmd-qwen-pd` — `Ready`, serving (prefill + decode + router/scheduler) |
| Run:ai | one workload `llmd-qwen-pd`, type **`LLMInferenceService`**, `Running` |

## Prerequisites
```bash
oc login --token=... --server=https://api.ai-dev06.kni.syseng.devcluster.openshift.com:6443
# Run:ai REST
export RUNAI_CP=https://runai.apps.ai-dev06.kni.syseng.devcluster.openshift.com
export RUNAI_CLUSTER_ID=37a972d6-b3f3-42c7-b60c-04c351e0ca18
# a dept-admin token works for project/workload calls; the workload-type step needs a
# system-admin token (see step 4).
```

## 1. Project + Run:ai link
```bash
oc new-project llmd
oc label   namespace llmd opendatahub.io/dashboard=true --overwrite
oc label   namespace llmd runai/queue=llmd --overwrite
oc annotate namespace llmd runai/enforce-scheduler-name=true --overwrite
# Run:ai project (deserved=2 so prefill+decode, both non-preemptible, both fit)
render llmd-project.json | api POST /api/v1/org-unit/projects --data-binary @-   # see experiments/_common/lib.sh
```
Files: `llmd-project.json`.

## 2. Deploy llm-d
```bash
# disaggregated prefill/decode (what we run):
oc apply -f llm-inference-service-disaggregated.yaml
# or the simple single-node variant:
oc apply -f llm-inference-service.yaml
```
Files: `llm-inference-service-disaggregated.yaml`, `llm-inference-service.yaml`. They compose
the RHOAI KServe llm-d presets saved in `templates/` (decode / prefill / router-route /
scheduler / single-node / multi-node-pd) so the deploy is reproducible.

## 3. Provide the llm-d gateway (so it serves) + cluster-sync RBAC
KServe is configured with `kserveIngressGateway: openshift-ingress/openshift-ai-inference`,
but that Gateway isn't provisioned by default → the router stays `RouterReady=False`. And
Run:ai's `cluster-sync` can't read `llminferenceservices`.
```bash
oc apply -f gateway.yaml            # the openshift-ai-inference Gateway (allowedRoutes: All)
oc apply -f cluster-sync-rbac.yaml  # lets cluster-sync read llminferenceservices
```
After this the `LLMInferenceService` reaches `Ready=True` (InferencePool + HTTPRoute + EPP
created) and serves (gateway is auth-gated by Kuadrant).
Files: `gateway.yaml`, `cluster-sync-rbac.yaml`.

## 4. Make Run:ai show it as one inference workload
Run:ai's Karta map set has no `LLMInferenceService` entry, so by default the service shows as
3 separate `Deployment` rows. A bare `kartas.run.ai` CR does **not** survive — `cluster-sync`
reconciles the control-plane map set and prunes custom CRs in ~24s. The durable fix is to
**register the workload type** (which carries the Karta map) in the control plane; cluster-sync
then syncs it down as a managed, un-prunable map.
```bash
# needs a SYSTEM-ADMIN token. On dev-06 that is test@run.ai; reset its password via the
# Keycloak master admin (secrets runai-backend-keycloakx / runai-backend-gen-keycloakx in
# ns runai-backend; realm policy = length>=8 + upper/lower/digit/special), then:
export RUNAI_SYSADMIN_TOKEN=<token for test@run.ai>
python3 -I register-workload-type.py
```
cluster-sync then creates a managed `krt-v1alpha2-serving-kserve-io-llminferenceservice` map,
and `llmd-qwen-pd` appears in Run:ai as one `LLMInferenceService` workload.
File: `register-workload-type.py` (the map + all create-payload gotchas are in its header).

## Verify
```bash
oc get llminferenceservice llmd-qwen-pd -n llmd                 # Ready=True
curl -sk -H "Authorization: Bearer $TOKEN" \
  "$RUNAI_CP/api/v1/workloads?clusterId=$RUNAI_CLUSTER_ID&limit=200" \
  | python3 -c "import sys,json;print([ (w['name'],w['type']) for w in json.load(sys.stdin)['workloads'] if w['name']=='llmd-qwen-pd'])"
# -> [('llmd-qwen-pd', 'LLMInferenceService')]
```
Screenshot: Run:ai UI → Workloads → project `llmd` → the `llmd-qwen-pd` row (type `LLMInferenceService`).

## Upstream recommendation
Ship the `LLMInferenceService` Karta map in Run:ai/KAI's **default managed set** (so steps 3–4
are unnecessary), and have RHOAI provision the `openshift-ai-inference` gateway out of the box.
