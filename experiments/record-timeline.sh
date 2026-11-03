#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Sample GPU ownership + pending GPU workloads over time -> JSONL (one line/sample).
# Used by showcase-timeline.sh to produce reports/timeline-data.jsonl, which
# render-timeline.py turns into a Gantt timeline.
#   ./record-timeline.sh [DURATION_S=120] [INTERVAL_S=2] [OUT=../reports/timeline-data.jsonl]
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
DURATION="${1:-120}"; INTERVAL="${2:-2}"; OUT="${3:-../reports/timeline-data.jsonl}"
: > "$OUT"
start=$(date +%s); end=$((start+DURATION))
while [ "$(date +%s)" -lt "$end" ]; do
  T=$(( $(date +%s) - start )) oc get pods -A -o json 2>/dev/null | T=$(( $(date +%s) - start )) python3 -I -c '
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
  rec={"team":team(ns),"wl":nm,"cat":cat(nm)}
  if ph=="Running": rec["node"]=p["spec"].get("nodeName"); hold.append(rec)
  elif ph=="Pending": pend.append(rec)
print(json.dumps({"t":t,"holders":hold,"pending":pend}))
' >> "$OUT"
  sleep "$INTERVAL"
done
echo "recorded $(wc -l < "$OUT") samples -> $OUT"
