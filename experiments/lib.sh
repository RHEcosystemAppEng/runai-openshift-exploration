#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Shared helpers: get a Run:ai admin bearer token and call the REST API.
# Source env.sh before this file.
# ─────────────────────────────────────────────────────────────────────────────

# Resource-Owner-Password-Credentials grant against the 'runai' Keycloak realm.
# Returns a bearer token for RUNAI_USER (default test@run.ai, a system-administrator).
runai_token() {
  curl -sk -m 15 "${RUNAI_CP}/auth/realms/runai/protocol/openid-connect/token" \
    -d "client_id=${RUNAI_OIDC_CLIENT}" \
    -d "username=${RUNAI_USER}" \
    -d "password=${RUNAI_PASSWORD}" \
    -d "grant_type=password" -d "scope=openid" \
  | python3 -I -c "import sys,json; print(json.load(sys.stdin)['access_token'])"
}

# api METHOD PATH [curl args...]
api() {
  local method="$1"; shift
  local path="$1"; shift
  curl -sk -m 60 -X "$method" "${RUNAI_CP}${path}" \
    -H "Authorization: Bearer $(runai_token)" \
    -H "Content-Type: application/json" "$@"
}

# Render a JSON template: substitute ${VARS} from the environment with envsubst-like
# behaviour using python (so no envsubst dependency and proper JSON escaping).
render() {
  python3 -I -c "import os,sys,string; sys.stdout.write(string.Template(sys.stdin.read()).safe_substitute(os.environ))" < "$1"
}

# Look up a workload id by exact name (first match).
workload_id() {
  local name="$1"
  api GET "/api/v1/workloads?clusterId=${RUNAI_CLUSTER_ID}&limit=200" \
  | python3 -I -c "import sys,json;print(next((w['id'] for w in json.load(sys.stdin)['workloads'] if w['name']=='$name'),''))"
}

# Show the current GPU holders across the cluster (who has which node).
gpu_holders() {
  oc get pods -A -o json 2>/dev/null | python3 -I -c "
import sys,json
for p in json.load(sys.stdin)['items']:
    if p.get('status',{}).get('phase')!='Running': continue
    for c in p['spec']['containers']:
        if c.get('resources',{}).get('requests',{}).get('nvidia.com/gpu'):
            print(f\"  {p['spec'].get('nodeName','?'):30} {p['metadata']['namespace']:22} {p['metadata']['name']}\")
" | sort
}
