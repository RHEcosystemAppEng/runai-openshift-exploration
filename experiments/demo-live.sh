#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# LIVE showcase: watch Team A take precedence over Team B.
#
# Team A has GPU deserved=4 (guaranteed); Team B has deserved=0 (its GPUs are all
# over-quota, i.e. BORROWED and reclaimable). When Team A submits work while under
# its guarantee, the Run:ai/KAI scheduler PREEMPTS Team B's borrowed GPUs so Team A
# is admitted. This script shows that transition in real time.
#
#   1. Top up Team B so it is holding the free A10G GPUs   (BEFORE)
#   2. (optional pause so you can start screen-recording / open the Run:ai UI)
#   3. Submit N Team A "burst" jobs                         (THE MOMENT)
#   4. Live-watch: print each Team B eviction + Team A placement as it happens
#   5. AFTER snapshot + the scheduler's preemption events
#
# Usage:
#   export RUNAI_PASSWORD=...           # see README "Getting an admin token"
#   ./demo-live.sh                      # default: Team A bursts 2 jobs, interactive pause
#   TEAM_A_BURST=3 ./demo-live.sh       # reclaim more
#   NONINTERACTIVE=1 ./demo-live.sh     # no pause (for recordings / CI)
#
# Tip: open the Run:ai UI -> Workloads next to this terminal; refresh at step 3 to
# watch team-b-victim-* flip Running -> Pending while team-a-* go Running.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh && source ./lib.sh

BURST="${TEAM_A_BURST:-2}"       # how many extra GPUs Team A reclaims
WATCH_SECS="${WATCH_SECS:-60}"

c_a=$'\033[1;32m'; c_b=$'\033[1;31m'; c_h=$'\033[1;36m'; c0=$'\033[0m'
hr() { printf '%s\n' "────────────────────────────────────────────────────────"; }

snapshot() {   # prints one line per GPU, coloured by owning team
  oc get pods -A -o json 2>/dev/null | python3 -I -c "
import sys,json
rows=[]
for p in json.load(sys.stdin)['items']:
    if p.get('status',{}).get('phase')!='Running': continue
    for c in p['spec']['containers']:
        if c.get('resources',{}).get('requests',{}).get('nvidia.com/gpu'):
            rows.append((p['spec'].get('nodeName','?'),p['metadata']['namespace'],p['metadata']['name']))
for node,ns,name in sorted(rows):
    tag='TEAM-A' if ns=='runai-team-a' else ('TEAM-B' if ns=='team-b-lora' else 'other ')
    print(f'{tag}|{node}|{name}')
"
}
show() { snapshot | while IFS='|' read -r tag node name; do
  col=$c0; [ "$tag" = "TEAM-A" ] && col=$c_a; [ "$tag" = "TEAM-B" ] && col=$c_b
  printf '   %s%-7s%s %-30s %s\n' "$col" "$tag" "$c0" "$node" "$name"
done; }

echo "${c_h}STEP 1 — make sure Team B is holding the borrowable GPUs${c0}"
./03-launch-team-b-victims.sh 3 >/dev/null 2>&1 || true
sleep 8
echo "BEFORE — GPU ownership:"; show
a_before=$(snapshot | grep -c '^TEAM-A'); b_before=$(snapshot | grep -c '^TEAM-B')
echo "   => Team A holds ${a_before} GPU(s), Team B holds ${b_before} GPU(s)"
hr

if [ "${NONINTERACTIVE:-0}" != "1" ]; then
  read -r -p "${c_h}STEP 2 — press ENTER to submit Team A's burst (${BURST} GPUs) and watch Team B get evicted...${c0} "
fi

echo "${c_h}STEP 3 — Team A submits ${BURST} burst job(s)${c0}"
export AGENT_B64="x"   # unused by burst jobs
for n in $(seq 1 "$BURST"); do
  export VICTIM_NAME=""   # not used
  name="team-a-burst-$n"
  body=$(VICTIM_NAME="$name" TEAM_B_PROJECT_ID="$TEAM_A_PROJECT_ID" render team-b-victim.json)
  echo "$body" | api POST /api/v1/workloads/trainings --data-binary @- \
    | python3 -I -c "import sys,json;d=json.load(sys.stdin);print('   submitted '+'$name'+' ->',d.get('workloadId','ERR')[:12])" 2>/dev/null
done
hr

echo "${c_h}STEP 4 — LIVE (watching for evictions & placements, ${WATCH_SECS}s)${c0}"
prev=""
for i in $(seq 1 "$WATCH_SECS"); do
  cur=$(snapshot)
  if [ "$cur" != "$prev" ]; then
    printf '%s[t+%02ds]%s\n' "$c_h" "$i" "$c0"
    echo "$cur" | while IFS='|' read -r tag node name; do
      col=$c0; [ "$tag" = "TEAM-A" ] && col=$c_a; [ "$tag" = "TEAM-B" ] && col=$c_b
      printf '   %s%-7s%s %-30s %s\n' "$col" "$tag" "$c0" "$node" "$name"
    done
    prev="$cur"
  fi
  a_now=$(echo "$cur" | grep -c '^TEAM-A')
  [ "$a_now" -ge "$((a_before + BURST))" ] && { echo "   ${c_a}>> Team A reached its target GPU count.${c0}"; break; }
  sleep 1
done
hr

echo "${c_h}STEP 5 — AFTER + scheduler preemption record${c0}"
echo "AFTER — GPU ownership:"; show
echo "Preemption events (Team A preempting Team B):"
oc get events -A 2>/dev/null | grep -iE 'preempt' | grep -i team-a | tail -6 | sed 's/^/   /'
echo
echo "Team B victims now (evicted ones are Pending):"
oc get pods -n team-b-lora 2>/dev/null | grep -E 'victim' | sed 's/^/   /'
