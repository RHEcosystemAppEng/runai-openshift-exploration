#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Clean, well-spaced END-TO-END timeline (controlled durations for legibility).
#
# Shows the whole fairness cycle with crisp phases:
#   1  Team B fills all free GPUs (holds)                      [team-b-victim.json]
#   2  Team A bursts in → preempts Team B → USES the GPUs      [team-a-burst.json, finite]
#   3  Team A's burst FINISHES on its own → GPUs free
#   4  Team B automatically RECLAIMS the GPUs
#
# This is the legible walkthrough of the mechanism. The REAL-workload proof (LoRA
# fine-tuning <-> vLLM inference, with a real preemption event) is in cycle-report.md /
# timeline-cycle.png, produced by run-cycle.sh.
#
#   export RUNAI_PASSWORD=... ; ./run-cycle-schematic.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh
T=teams
B_JOBS="${B_JOBS:-3}"; A_BURST="${A_BURST:-2}"; export BURST_SECONDS="${BURST_SECONDS:-55}"
INTERVAL="${INTERVAL:-2}"; DURATION="${DURATION:-150}"; ACT_RECLAIM="${ACT_RECLAIM:-26}"
OUT="${OUT:-../reports/timeline-e2e-data.jsonl}"

echo ">> reset + wait for clean slate"
"$T"/team-a/stop.sh >/dev/null 2>&1 || true
"$T"/team-b/stop.sh >/dev/null 2>&1 || true
w=0; while [ "$w" -lt 90 ]; do
  a=$(oc get pods -A 2>/dev/null | grep -E "runai-team-a|team-b-lora" | grep -cE "burst|victim|lora-ft|qwen" || true)
  [ "${a:-0}" -eq 0 ] && break; w=$((w+6)); sleep 6
done

echo ">> Phase 1: Team B fills the free GPUs ($B_JOBS jobs)"
for n in $(seq 1 "$B_JOBS"); do
  VICTIM_NAME="team-b-victim-$n" render team-b-victim.json | api POST /api/v1/workloads/trainings --data-binary @- >/dev/null
done
w=0; while [ "$w" -lt 90 ]; do
  r=$(oc get pods -n team-b-lora 2>/dev/null | grep victim | grep -c Running || true)
  echo "   Team B running=${r:-0}"; [ "${r:-0}" -ge "$B_JOBS" ] && break; w=$((w+5)); sleep 5
done

echo ">> capture ${DURATION}s; Team A bursts $A_BURST @ ${ACT_RECLAIM}s (each runs ${BURST_SECONDS}s then finishes)"
: > "$OUT"; start=$(date +%s); fired=0
while :; do
  t=$(( $(date +%s) - start )); [ "$t" -ge "$DURATION" ] && break
  oc get pods -A -o json 2>/dev/null | T2="$t" python3 -I -c '
import sys,json,os
t=int(os.environ["T2"])
def team(ns): return "A" if ns=="runai-team-a" else ("B" if ns=="team-b-lora" else "O")
def cat(n):
  n=n.lower()
  if "kserve" in n or "triton" in n or "inference" in n: return "Deploy"
  if "workbench" in n or "notebook" in n or "-ws" in n: return "Build"
  return "Train"
try: d=json.load(sys.stdin)
except Exception: d={"items":[]}
hold=[]; pend=[]
for p in d.get("items",[]):
  ns=p["metadata"]["namespace"]; nm=p["metadata"]["name"]; ph=p.get("status",{}).get("phase")
  if ns not in ("runai-team-a","team-b-lora","runai-nvidia-1563-test-tfigenbl"): continue
  if not any((c.get("resources",{}).get("requests",{}) or {}).get("nvidia.com/gpu") for c in p["spec"]["containers"]): continue
  r={"team":team(ns),"wl":nm,"cat":cat(nm)}; node=p["spec"].get("nodeName")
  if node and ph not in ("Succeeded","Failed"): r["node"]=node; hold.append(r)
  elif ph=="Pending": pend.append(r)
print(json.dumps({"t":t,"holders":hold,"pending":pend}))' >> "$OUT"
  if [ "$fired" -eq 0 ] && [ "$t" -ge "$ACT_RECLAIM" ]; then
    echo "   t=${t}s: Team A bursts in (preempt → use → auto-finish)"
    for n in $(seq 1 "$A_BURST"); do
      BURST_NAME="team-a-burst-$n" render team-a-burst.json | api POST /api/v1/workloads/trainings --data-binary @- >/dev/null
    done
    fired=1
  fi
  sleep "$INTERVAL"
done
echo ">> done: $(wc -l < "$OUT") samples -> $OUT"
