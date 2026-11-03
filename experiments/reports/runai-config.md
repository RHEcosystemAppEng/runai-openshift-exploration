# Run:ai configuration reference — cluster ai-dev06

_Generated 2026-11-03 14:45 UTC from the live cluster (`experiments/_common/dump-runai-config.sh`)._
NVIDIA Run:ai (KAI scheduler) v3.0.20 on OpenShift. Shows how the demo's priority /
quota / preemption behaviour is actually wired.

## 1. Projects (`projects.kai.resources`) — namespace, scheduler, GPU quota
```
nvidia-1563-test-tfigenbl    ns=None                   parent=default  gpu.deserved=1 gpu.limit=-1 kaiScheduler=True
team-a                       ns=None                   parent=default  gpu.deserved=4 gpu.limit=-1 kaiScheduler=True
team-b-lora                  ns=team-b-lora            parent=default  gpu.deserved=0 gpu.limit=-1 kaiScheduler=True
```
Team A has guaranteed GPUs (`deserved: 4`); Team B `deserved: 0` → everything it runs
on a GPU is over-quota and therefore reclaimable.

## 2. Scheduling queues (`queues.scheduling.run.ai`) — the quota hierarchy
```
nvidia-1563-test-tfigenbl  parent=q-4500000  priority=100 gpu[quota/limit/overQuotaWeight]=1/-1/1
q-4500000                  parent=None       priority=100 gpu[quota/limit/overQuotaWeight]=-1/-1/-1
team-a                     parent=q-4500000  priority=100 gpu[quota/limit/overQuotaWeight]=4/-1/2
team-b-lora                parent=q-4500000  priority=100 gpu[quota/limit/overQuotaWeight]=0/-1/0.01
```
Project queues → department queue `q-4500000` ("default"). An under-quota queue may
reclaim from an over-quota sibling.

## 3. Priority classes (category → priority → preemption)
```
NAME                      VALUE        GLOBAL-DEFAULT   AGE   PREEMPTIONPOLICY
build                     100          false            19d   PreemptLowerPriority
inference                 125          false            19d   PreemptLowerPriority
runai-critical            1000000000   false            19d   PreemptLowerPriority
train                     50           false            19d   PreemptLowerPriority
train-critical            60           false            19d   PreemptLowerPriority
train-high                55           false            19d   PreemptLowerPriority
```
| Category | priorityClass | preemptible |
|---|---|---|
| Deploy (Inference) | inference / very-high | No |
| Build (Workspace/Notebook) | build / high | No |
| Train (Training/Job) | train / low | Yes |

## 4. Over-quota feature flag (control-plane setting)
```
project.quota.manual_over_quota = True
```
Must be `true` for `deserved:0` projects to borrow GPUs (and thus be reclaimed).

## 5. Labels & annotations on a live workload (Team A inference pod)
_(no Team A inference pod running right now)_

What they do:
- `project=<name>` + the project namespace → maps the pod to its **Queue** (quota).
- `run.ai/workload-id`, `run.ai/top-owner-uid` → group a workload's pods together.
- `pod-group-name` annotation → the **PodGroup** (gang-scheduling unit).
- `runai-allocated-gpus` / `-gpu-memory` → what the scheduler allocated.
- `schedulerName: runai-scheduler` → KAI schedules it (not default-scheduler).

## 6. PodGroup — the scheduling unit (queue + priority + gang)
_(no Team A PodGroup right now)_

## 7. Team A inference — RHOAI `LLMInferenceService` (Deploy)
```
(no data)
```

## 8. Team B workload — real LoRA fine-tuning (Train), see `experiments/team-b/post-training/`
Team B's reclaimable GPU workload is the real RHOAI Training Hub LoRA SFT job
(`experiments/team-b/post-training/deploy/batch-training-job.yaml`, model `Qwen/Qwen2.5-1.5B-Instruct`,
1 GPU, image `registry.redhat.io/rhoai/odh-workbench-...pytorch-cuda`). Launch with
`post-training/scripts/submit-batch-job.sh`.

---
_Regenerate: `cd experiments && ./dump-runai-config.sh`_
