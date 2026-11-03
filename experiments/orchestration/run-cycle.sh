#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Full fairness cycle with REAL workloads, driven through the aligned per-team
# interface (../team-a, ../team-b), while recording a GPU-ownership timeline.
#
#   Phase 1  Team B runs real LoRA fine-tuning (Train) → borrows the free GPUs.
#   Phase 2  Team A needs resources → deploy.sh up (vLLM inference, Deploy) reclaims a
#            GPU (preempts a Team B LoRA) + submit.sh runs SWE-bench agents.
#   Phase 3  Team A's work finishes → deploy.sh down frees the GPU → Team B LoRA resumes.
#
# Output: reports/timeline-cycle-data.jsonl
#   render it with:  python3 ../_common/render-timeline.py \
#                      reports/timeline-cycle-data.jsonl reports/timeline-cycle.html
#   usage:  export RUNAI_PASSWORD=... ; ./run-cycle.sh
# ─────────────────────────────────────────────────────────────────────────────
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../_common/_common.sh"
TA="$HERE/../team-a"; TB="$HERE/../team-b"
B_JOBS="${B_JOBS:-3}"; A_AGENTS="${A_AGENTS:-2}"
INTERVAL="${INTERVAL:-2}"; DURATION="${DURATION:-175}"
ACT_RECLAIM="${ACT_RECLAIM:-28}"; ACT_RELEASE="${ACT_RELEASE:-112}"
mkdir -p "$REPORTS_DIR"
OUT="${OUT:-$REPORTS_DIR/timeline-cycle-data.jsonl}"

if [ "${SKIP_SETUP:-0}" != "1" ]; then
  echo ">> reset: Team A idle (inference down), clear old LoRA/bursts"
  "$TA"/stop.sh >/dev/null 2>&1 || true
  "$TB"/stop.sh >/dev/null 2>&1 || true
  echo ">> wait for a clean slate (Team A holds 0 GPUs)"
  waited=0
  while [ "$waited" -lt 90 ]; do
    a=$(oc get pods -n runai-team-a -o json 2>/dev/null | python3 -I -c "import sys,json;print(sum(1 for p in json.load(sys.stdin).get('items',[]) if p['spec'].get('nodeName') and p.get('status',{}).get('phase') not in ('Succeeded','Failed') and any((c.get('resources',{}).get('requests',{}) or {}).get('nvidia.com/gpu') for c in p['spec']['containers'])))" 2>/dev/null || echo 0)
    echo "   team-a GPU pods=${a:-0}"
    [ "${a:-0}" -eq 0 ] && break
    waited=$((waited+6)); sleep 6
  done
  echo ">> Phase 1: Team B submits $B_JOBS real LoRA fine-tuning jobs"
  "$TB"/submit.sh "$B_JOBS" 2>&1 | sed 's/^/   /'
  echo ">> wait for Team B LoRA to occupy GPUs"
  waited=0
  while [ "$waited" -lt 150 ]; do
    r=$(oc get pods -n team-b-lora 2>/dev/null | grep lora-ft | grep -c Running || true)
    echo "   LoRA running=${r:-0}"
    [ "${r:-0}" -ge 2 ] && break
    waited=$((waited+6)); sleep 6
  done
else
  echo ">> SKIP_SETUP=1: using existing Team B LoRA as Phase 1"
fi

echo ">> capture ${DURATION}s @ ${INTERVAL}s; reclaim@${ACT_RECLAIM}s release@${ACT_RELEASE}s"
: > "$OUT"; start=$(date +%s); did_reclaim=0; did_release=0
while :; do
  t=$(( $(date +%s) - start )); [ "$t" -ge "$DURATION" ] && break
  oc get pods -A -o json 2>/dev/null | T2="$t" python3 -I -c '
import sys,json,os
t=int(os.environ["T2"])
def team(ns): return "A" if ns=="runai-team-a" else ("B" if ns=="team-b-lora" else "O")
def cat(n):
  n=n.lower()
  if "kserve" in n or "triton" in n or "inference" in n: return "Deploy"
  if "workbench" in n or "notebook" in n or "ws" in n: return "Build"
  return "Train"
try: d=json.load(sys.stdin)
except Exception: d={"items":[]}
hold=[]; pend=[]
for p in d.get("items",[]):
  ns=p["metadata"]["namespace"]; nm=p["metadata"]["name"]; ph=p.get("status",{}).get("phase")
  if ns not in ("runai-team-a","team-b-lora","runai-nvidia-1563-test-tfigenbl"): continue
  if not any((c.get("resources",{}).get("requests",{}) or {}).get("nvidia.com/gpu") for c in p["spec"]["containers"]): continue
  r={"team":team(ns),"wl":nm,"cat":cat(nm)}
  node=p["spec"].get("nodeName")
  # a pod holds its GPU once it is bound to a node (ContainerCreating/Init/Running),
  # not only when phase==Running (vLLM takes minutes to go Running).
  if node and ph not in ("Succeeded","Failed"): r["node"]=node; hold.append(r)
  elif ph=="Pending": pend.append(r)
print(json.dumps({"t":t,"holders":hold,"pending":pend}))' >> "$OUT"

  if [ "$did_reclaim" -eq 0 ] && [ "$t" -ge "$ACT_RECLAIM" ]; then
    echo "   t=${t}s: Phase 2 — Team A deploy up (reclaim) + submit $A_AGENTS agents"
    "$TA"/deploy.sh up >/dev/null 2>&1 || true
    "$TA"/submit.sh "$A_AGENTS" >/dev/null 2>&1 || true
    did_reclaim=1
  fi
  if [ "$did_release" -eq 0 ] && [ "$t" -ge "$ACT_RELEASE" ]; then
    echo "   t=${t}s: Phase 3 — Team A deploy down (free GPU → Team B returns)"
    "$TA"/deploy.sh down >/dev/null 2>&1 || true
    did_release=1
  fi
  sleep "$INTERVAL"
done
echo ">> done: $(wc -l < "$OUT") samples -> $OUT"
