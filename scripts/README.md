# Root run scripts

Thin entrypoints that give every subproject the **same verb interface**, so the
way you run things is aligned regardless of each subproject's internal layout.
Each wrapper just delegates to the scripts the subproject already ships — it does
not reimplement or modify them.

| Verb | `scripts/post-training.sh` | `scripts/swebench.sh` |
| --- | --- | --- |
| `setup` | create/reuse the `team-b-lora` RHOAI project | `make preflight projects` (readiness + squad projects) |
| `deploy` | apply the RHOAI Workbench (`deploy/workbench.yaml`) | `make scheduling serving agents` |
| `run` | submit the repeatable LoRA batch Job | `make launch` (autonomous SWE-bench run) |
| `status` | show the batch Job + pods | `make status` (queues, workloads, GPU, progress) |
| `teardown` | print manual cleanup commands | `make teardown` (keeps PVCs by default) |
| `help` | usage | usage |

Extra args after the verb are forwarded, e.g.:

```bash
scripts/swebench.sh run --squad a
scripts/swebench.sh teardown --squad all --delete-pvc
scripts/swebench.sh make runai-enable      # passthrough to any Makefile target
scripts/post-training.sh run               # submit the batch Job
```

Run them from anywhere — each wrapper resolves the repo root from its own path
and `cd`s into the right subproject first.

## Prerequisites

Both expect you to be logged in to the target cluster (`oc login …`) first; each
underlying script guards the cluster it is allowed to touch and refuses to run
against the wrong server.

## Notes

- **post-training/** is owned elsewhere and is never modified by these wrappers —
  `post-training.sh` only *invokes* its scripts (and `teardown` just prints the
  manual commands, since that folder ships no teardown script).
- **experiments/** (the live Run:ai/KAI reclamation demo) keeps its own aligned
  interface under `experiments/teams/<team>/{deploy,submit,status,stop}.sh` plus
  the numbered `experiments/0*.sh` scripts; see `experiments/README.md`.
