#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Register an `LLMInferenceService` workload type (with its Karta map) in the Run:ai
control plane so the real llm-d service is shown as ONE unified inference workload.

WHY: Run:ai's Karta map set is control-plane-managed — cluster-sync prunes any custom
`kartas.run.ai` CR within ~24s. The only durable way to add a map is to register a
*workload type* via the control-plane API; cluster-sync then syncs it down as a managed
(un-prunable) Karta CR and maps the real LLMInferenceService as one workload.

PROVEN on ai-dev06 (2026-11-03): POST returns 201; `llmd-qwen-pd` then appears as
type=LLMInferenceService / phase=Running in GET /api/v1/workloads.

GOTCHAS (each cost a 400 until fixed):
  - Requires a SYSTEM-ADMIN token (dept-admin gets 403). On this cluster the built-in
    system admin is test@run.ai; its password is reset via the Keycloak master admin
    (see README). Pass the token in RUNAI_SYSADMIN_TOKEN.
  - Each element of `kartas` must BE the Karta object itself ({apiVersion,kind,metadata,
    spec}) — the server does json.Unmarshal(element -> models.Karta). Do NOT wrap it as
    {version, karta} (that yields "root component ... empty").
  - `childComponents` must be a sibling of `rootComponent` under structureDefinition
    (not nested inside rootComponent), or gang members are "not defined".
  - workload-type Name must equal the CRD Kind; group must equal the CRD group.

Usage:
  export RUNAI_CP=https://runai.apps.<cluster>
  export RUNAI_SYSADMIN_TOKEN=<bearer token for a system-administrator>
  # category/priority IDs from GET /api/v1/workload-categories and /api/v1/workload-priorities
  python3 -I register-workload-type.py
"""
import json, os, ssl, urllib.request

CP = os.environ["RUNAI_CP"].rstrip("/")
TOKEN = os.environ["RUNAI_SYSADMIN_TOKEN"]
CATEGORY_ID = os.environ.get("CATEGORY_ID", "b8ab8e57-abbe-42d0-8ccb-df242d2fd0c5")  # Deploy
PRIORITY_ID = os.environ.get("PRIORITY_ID", "51b8807f-73ad-4233-847a-de9309b9375e")  # very-high
CTX = ssl._create_unverified_context()

COMP = 'app.kubernetes.io/component'   # distinguishes decode / prefill / scheduler
NAME = 'app.kubernetes.io/name'        # gang grouping key (== the LLMISVC name)

root = {
    "kind": {"group": "serving.kserve.io", "version": "v1alpha2", "kind": "LLMInferenceService"},
    "name": "llminferenceservice",
    "statusDefinition": {
        "conditionsDefinition": {"messageFieldName": "message", "path": ".status.conditions",
                                  "reasonFieldName": "reason", "statusFieldName": "status", "typeFieldName": "type"},
        "statusMappings": {
            "running": [{"byConditions": [{"status": "True", "type": "Ready"}]}],
            "failed":  [{"byConditions": [{"status": "False", "type": "WorkloadsReady"},
                                           {"status": "False", "type": "RouterReady"}]}],
        },
    },
}
def child(name, comp):
    return {"kind": {"group": "apps", "version": "v1", "kind": "Deployment"}, "name": name,
            "ownerRef": "llminferenceservice",
            "podSelector": {"componentTypeSelector": {"keyPath": '.metadata.labels["%s"]' % COMP, "value": comp}},
            "scaleDefinition": {"replicasPath": ".spec.replicas // 1"}}
children = [child("decode", "llminferenceservice-workload"),
            child("prefill", "llminferenceservice-workload-prefill"),
            child("scheduler", "llminferenceservice-router-scheduler")]
spec = {
    "optimizationInstructions": {"gangScheduling": {"podGroups": [{"name": "service", "members": [
        {"componentName": "decode",  "groupByKeyPaths": ['.metadata.labels["%s"]' % NAME]},
        {"componentName": "prefill", "groupByKeyPaths": ['.metadata.labels["%s"]' % NAME]}]}]}},
    "structureDefinition": {"rootComponent": root, "childComponents": children},
}
karta = {"apiVersion": "run.ai/v1alpha1", "kind": "Karta", "metadata": {}, "spec": spec}
payload = {"name": "LLMInferenceService", "group": "serving.kserve.io",
           "categoryId": CATEGORY_ID, "priorityId": PRIORITY_ID,
           "preemptibility": "non-preemptible", "kartas": [karta]}

req = urllib.request.Request(CP + "/api/v1/workload-types", data=json.dumps(payload).encode(), method="POST")
req.add_header("Content-Type", "application/json"); req.add_header("Authorization", "Bearer " + TOKEN)
try:
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        print("201 created:", json.loads(r.read())["id"])
except urllib.error.HTTPError as e:
    print("ERROR", e.code, e.read().decode())
