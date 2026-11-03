#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Workloads grouped by Run:ai CATEGORY — the precedence model at a glance.
#
#   DEPLOY  (Inference)           highest priority, NON-preemptible  -> production
#   BUILD   (Workspace/Notebook)  medium,            non-preemptible -> interactive
#   TRAIN   (Training/Job)        lowest,            PREEMPTIBLE     -> evicted first
#
# Precedence = project quota (deserved vs over-quota)  +  category priority  +
# preemptibility. This view shows all three per workload, live.
#
# Usage:  ./show-by-category.sh          # once
#         watch -c -n2 ./show-by-category.sh   # live refresh (recommended on screen)
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

api GET "/api/v1/workloads?clusterId=${RUNAI_CLUSTER_ID}&limit=200" | python3 -I -c "
import sys,json
C={'\033[0m':'\033[0m'}
RESET='\033[0m'; BOLD='\033[1m'
col={'Deploy':'\033[1;35m','Build':'\033[1;36m','Train':'\033[1;33m'}
order=['Deploy','Build','Train']
meta={
 'Deploy':('Inference','NON-preemptible','production serving — always protected'),
 'Build' :('Workspace/Notebook','non-preemptible*','interactive / dev'),
 'Train' :('Training/Job','PREEMPTIBLE','batch — evicted first to free GPUs'),
}
ws=json.load(sys.stdin)['workloads']
groups={k:[] for k in order}
for w in ws:
    if w.get('phase') in ('Completed','Failed','Deleted','Stopped'): continue
    cat=w.get('category') or '?'
    groups.setdefault(cat,[]).append(w)
print(f\"{BOLD}GPU workloads by category — precedence: Deploy > Build > Train{RESET}\")
for cat in order:
    rows=groups.get(cat,[])
    typ,pre,desc=meta[cat]
    c=col.get(cat,'')
    print(f\"\n{c}{'█'} {cat.upper():7}{RESET}  ({typ}; {pre}) — {desc}\")
    if not rows:
        print('     (none active)'); continue
    for w in sorted(rows,key=lambda x:(x['projectName'],x['name'])):
        gpu=((w.get('workloadRequestedResources') or {}).get('gpu') or {}).get('request')
        gpu=f\"{gpu} GPU\" if gpu else '  -  '
        ph=w.get('phase','?')
        mark='🟢' if ph=='Running' else ('⏳' if ph in ('Pending','Initializing','Creating') else '•')
        team='TEAM-A' if w['projectName']=='team-a' else ('TEAM-B' if w['projectName']=='team-b-lora' else w['projectName'])
        print(f\"     {mark} {team:7} {w['name']:28} prio={w.get('priority'):<4} {gpu:6} {ph}\")
print(f\"\n{BOLD}Why:{RESET} when Team A (deserved GPUs) needs capacity, the scheduler preempts the\")
print(f\"     lowest-priority PREEMPTIBLE workloads first — Team B's TRAIN jobs — while\")
print(f\"     DEPLOY (inference) and BUILD (notebooks) stay protected.\")
"
