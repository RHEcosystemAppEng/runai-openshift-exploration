#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Capture a clean reclaim timeline (monolithic: one sampling loop, no nested bg).
#   - samples GPU ownership + Team B pending every INTERVAL s
#   - at SUBMIT_AT s, Team A submits BURST training jobs -> scheduler preempts
#     Team B's over-quota GPUs so Team A reaches its guaranteed share
# Output: reports/timeline-data.jsonl  (render with render-timeline.py)
#
#   export RUNAI_PASSWORD=...
#   ./showcase-timeline.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

BURST="${TEAM_A_BURST:-2}"
INTERVAL="${INTERVAL:-2}"
DURATION="${DURATION:-90}"
SUBMIT_AT="${SUBMIT_AT:-14}"
OUT="${OUT:-../reports/timeline-data.jsonl}"

echo ">> reset: delete Team A burst jobs so Team B reclaims the free A10Gs"
api GET "/api/v1/workloads?clusterId=${RUNAI_CLUSTER_ID}&limit=200" \
 | python3 -I -c "import sys,json
for w in json.load(sys.stdin)['workloads']:
    if w['name'].startswith('team-a-burst') and w.get('phase') not in ('Deleted','Deleting'): print(w['id'])" \
 | while read -r id; do [ -n "$id" ] && api DELETE "/api/v1/workloads/trainings/$id" -o /dev/null -w ""; done

echo ">> ensure Team B has 3 victims filling the free A10Gs"
./03-launch-team-b-victims.sh 3 >/dev/null 2>&1 || true

echo ">> capturing ${DURATION}s @ ${INTERVAL}s; Team A bursts ${BURST} at t=${SUBMIT_AT}s"
: > "$OUT"
start=$(date +%s); submitted=0
while :; do
  t=$(( $(date +%s) - start ))
  [ "$t" -ge "$DURATION" ] && break
  oc get pods -A -o json 2>/dev/null | T="$t" python3 -I -c '
import sys,json,os
t=int(os.environ["T"])
def team(ns): return "A" if ns=="runai-team-a" else ("B" if ns=="team-b-lora" else "O")
def cat(n):
  n=n.lower()
  if "kserve" in n or "triton" in n or "inference" in n: return "Deploy"
  if "workbench" in n or "notebook" in n: return "Build"
  return "Train"
try: d=json.load(sys.stdin)
except Exception: d={"items":[]}
hold=[]; pend=[]
for p in d.get("items",[]):
  ns=p["metadata"]["namespace"]; nm=p["metadata"]["name"]; ph=p.get("status",{}).get("phase")
  if ns not in ("runai-team-a","team-b-lora","runai-nvidia-1563-test-tfigenbl"): continue
  if not any((c.get("resources",{}).get("requests",{}) or {}).get("nvidia.com/gpu") for c in p["spec"]["containers"]): continue
  r={"team":team(ns),"wl":nm,"cat":cat(nm)}
  if ph=="Running": r["node"]=p["spec"].get("nodeName"); hold.append(r)
  elif ph=="Pending": pend.append(r)
print(json.dumps({"t":t,"holders":hold,"pending":pend}))' >> "$OUT"

  if [ "$submitted" -eq 0 ] && [ "$t" -ge "$SUBMIT_AT" ]; then
    echo "   t=${t}s: Team A submits ${BURST} burst job(s)"
    for n in $(seq 1 "$BURST"); do
      VICTIM_NAME="team-a-burst-$n" TEAM_B_PROJECT_ID="$TEAM_A_PROJECT_ID" render team-b-victim.json \
        | api POST /api/v1/workloads/trainings --data-binary @- >/dev/null
    done
    submitted=1
  fi
  sleep "$INTERVAL"
done
echo ">> done: $(wc -l < "$OUT") samples -> $OUT"
