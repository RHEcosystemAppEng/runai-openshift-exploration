#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Register the LLM-D `LLMInferenceService` workload type in the Run:ai control plane so the
real llm-d service is shown as ONE unified inference workload.

It loads the Karta map from `karta-llminferenceservice.yaml` (the single source of truth,
human-readable) and registers it via POST /api/v1/workload-types. cluster-sync then syncs
it down as a managed (un-prunable) Karta CR and maps the real LLMInferenceService as one
workload.

WHY the API (not a CR): cluster-sync prunes custom `kartas.run.ai` CRs within ~24s; the
workload-type registration is the durable path.

PROVEN on ai-dev06 (2026-11-03): POST → 201; `llmd-qwen-pd` then appears as
type=LLMInferenceService / phase=Running in GET /api/v1/workloads.

PAYLOAD GOTCHAS baked in below (each cost a 400 until fixed):
  - Needs a SYSTEM-ADMIN token (dept-admin → 403). On dev-06 reset test@run.ai via the
    Keycloak master admin (realm policy: len>=8 + upper/lower/digit/special). Pass it in
    RUNAI_SYSADMIN_TOKEN.
  - Each `kartas[]` element must BE the Karta object ({apiVersion,kind,metadata,spec}) —
    the server does json.Unmarshal(element -> models.Karta). Do NOT wrap as {version,karta}.
  - `childComponents` must be a sibling of `rootComponent` (the YAML already is).
  - workload-type Name must equal the CRD Kind; group must equal the CRD group.

Usage:
  export RUNAI_CP=https://runai.apps.<cluster>
  export RUNAI_SYSADMIN_TOKEN=<bearer token for a system-administrator>
  # category/priority IDs from GET /api/v1/workload-categories and /api/v1/workload-priorities
  python3 -I register-workload-type.py
"""
import json, os, ssl, urllib.request
try:
    import yaml
except ImportError:
    raise SystemExit("PyYAML required: pip install pyyaml (map is in karta-llminferenceservice.yaml)")

CP = os.environ["RUNAI_CP"].rstrip("/")
TOKEN = os.environ["RUNAI_SYSADMIN_TOKEN"]
CATEGORY_ID = os.environ.get("CATEGORY_ID", "b8ab8e57-abbe-42d0-8ccb-df242d2fd0c5")  # Deploy
PRIORITY_ID = os.environ.get("PRIORITY_ID", "51b8807f-73ad-4233-847a-de9309b9375e")  # very-high
HERE = os.path.dirname(os.path.abspath(__file__))
CTX = ssl._create_unverified_context()

# The Karta object itself is each element of `kartas` (server unmarshals element -> Karta).
karta = yaml.safe_load(open(os.path.join(HERE, "karta-llminferenceservice.yaml")))
payload = {
    "name": "LLMInferenceService", "group": "serving.kserve.io",
    "categoryId": CATEGORY_ID, "priorityId": PRIORITY_ID,
    "preemptibility": "non-preemptible",
    "kartas": [karta],
}

req = urllib.request.Request(CP + "/api/v1/workload-types", data=json.dumps(payload).encode(), method="POST")
req.add_header("Content-Type", "application/json"); req.add_header("Authorization", "Bearer " + TOKEN)
try:
    with urllib.request.urlopen(req, timeout=30, context=CTX) as r:
        print("201 created workload-type id:", json.loads(r.read())["id"])
except urllib.error.HTTPError as e:
    print("ERROR", e.code, e.read().decode())
