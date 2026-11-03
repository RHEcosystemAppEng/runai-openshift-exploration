# swebench — basic vLLM inference + representative agent

The minimal, working SWE-bench-style inference example for `ai-dev06`: serve a model
with vLLM and call it with a representative coding agent. This is the part that is
actually exercised on this cluster.

> The full multi-squad SWE-bench harness (Kueue/Run:ai scheduling, AMI agent, repo
> checkout + test grading, Qwen3-32B/TP4) was removed — it was never run live here and
> doesn't fit this 5× single-GPU cluster. Recover it from git history / Jira NVIDIA-1535
> if needed.

## Contents
| Path | What it is |
|---|---|
| `deploy/serving-vllm.yaml` | Basic KServe `LLMInferenceService` — vLLM on 1× A10G, `Qwen/Qwen2.5-3B-Instruct`. |
| `agent/swebench_agent.py` | Representative agent: one **real** OpenAI-compatible call to the endpoint, prints the model's diff. CPU-only. |

## Run it

```bash
oc new-project swebench-vllm
oc apply -f deploy/serving-vllm.yaml
# wait for the endpoint to go Ready (image + model pull takes minutes)
oc get llminferenceservice -n swebench-vllm

# call it with the representative agent
AI_BASE_URL="https://$(oc get route -n swebench-vllm -l app.kubernetes.io/part-of=swebench-live-vllm -o jsonpath='{.items[0].spec.host}')/v1" \
AI_MODEL=Qwen/Qwen2.5-3B-Instruct AI_API_KEY=swebench-token INSTANCE_ID=lite-001 \
python3 agent/swebench_agent.py
```

## Relationship to the live demo
This is Team A's workload. In the Run:ai priority/reclaim demo it runs with
`schedulerName: runai-scheduler` in the `runai-team-a` namespace so it counts against
Team A's GPU quota — driven by the sibling `../` interface (`deploy.sh` / `submit.sh`).
