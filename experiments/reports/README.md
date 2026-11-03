# experiments/reports — evidence of the Run:ai behavior

Where the demo's output lands. These artifacts are how we **show** the Run:ai
priority/quota/reclaim behavior on `dev-06`. Everything here except this README is
**generated and git-ignored** (it can carry cluster node names) — regenerate it with the
commands below.

| Artifact | Shows | Produced by |
|---|---|---|
| `timeline-cycle.html` | **Gantt timeline** — which team holds each GPU over a full borrow→reclaim→return cycle (blue=Team A, orange=Team B, grey=other), with the reclaim marker and Team B's pending/preempted strip. | `render-timeline.py` from the `.jsonl` |
| `timeline-cycle-data.jsonl` | Raw per-interval GPU-ownership samples (holders + pending). | `orchestration/run-cycle.sh` |
| `timeline-cycle.png` | Screenshot of the HTML for slides. | manual (screenshot the HTML) |
| `runai-config.md` | Snapshot of how Run:ai is configured: projects, queues, GPU quotas, over-quota weights, priority classes, the cluster over-quota flag, and live pod labels / PodGroup / scheduler. | `_common/dump-runai-config.sh` |
| `run-cycle*.log` | Phase-by-phase run log (borrow → reclaim → release) with the captured preemption events. | `orchestration/run-cycle.sh` |

## Regenerate

```bash
cd experiments
export RUNAI_CP=... RUNAI_CLUSTER_ID=... RUNAI_USER=... RUNAI_PASSWORD=...

# Config snapshot
./_common/dump-runai-config.sh                 # -> reports/runai-config.md

# Full cycle + timeline figure
./orchestration/run-cycle.sh                    # -> reports/timeline-cycle-data.jsonl (+ run log)
python3 ./_common/render-timeline.py \
  reports/timeline-cycle-data.jsonl reports/timeline-cycle.html
# then screenshot timeline-cycle.html -> timeline-cycle.png for slides
```

## Live views (no file output)

```bash
watch -c -n2 ./_common/show-by-category.sh      # workloads by Deploy/Build/Train, live
oc get events -A | grep -i preempt              # the scheduler's own reclaim record
```
