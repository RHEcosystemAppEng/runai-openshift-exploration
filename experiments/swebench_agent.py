#!/usr/bin/env python3
"""Representative SWE-bench agent instance (ai-dev06 overlay).

A real SWE-bench run clones a repo at a commit, applies the failing-test patch,
and drives the AMI agent against the squad's vLLM endpoint (see
deploy/base/agents/instance-job.template.yaml). This lightweight stand-in keeps
the part that matters for the Run:ai priority/preemption demo: it makes a REAL
OpenAI-compatible inference call to Team A's in-cluster vLLM endpoint and prints
the model's proposed patch. It is CPU-only, so it is admitted against Team A's
CPU quota while the GPU is held by the vLLM InferenceService.

Env: AI_BASE_URL, AI_MODEL, AI_API_KEY, INSTANCE_ID.
"""
import json
import os
import ssl
import time
import urllib.request

# The KServe LLMInferenceService workload service terminates TLS with a
# self-signed cert; skip verification for this in-cluster demo call.
SSL_CTX = ssl._create_unverified_context()

BASE = os.environ["AI_BASE_URL"].rstrip("/")
MODEL = os.environ["AI_MODEL"]
KEY = os.environ.get("AI_API_KEY", "swebench-token")
INST = os.environ.get("INSTANCE_ID", "demo-instance")

PROMPT = (
    f"SWE-bench instance {INST}: Calculator.divide(a, b) throws an unhandled "
    "exception when b == 0. Propose a minimal unified diff that returns a clear "
    "error instead. Reply with just the diff."
)
body = json.dumps(
    {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": "You are a SWE-bench coding agent."},
            {"role": "user", "content": PROMPT},
        ],
        "max_tokens": 256,
        "temperature": 0.2,
    }
).encode()

req = urllib.request.Request(
    f"{BASE}/chat/completions",
    data=body,
    headers={"Content-Type": "application/json", "Authorization": f"Bearer {KEY}"},
)

# The endpoint may still be pulling the model when this Job starts; retry.
for attempt in range(60):
    try:
        with urllib.request.urlopen(req, timeout=180, context=SSL_CTX) as r:
            out = json.load(r)
        reply = out["choices"][0]["message"]["content"]
        print(f"[{INST}] vLLM reply:\n{reply[:800]}")
        print(f"[{INST}] DONE")
        break
    except Exception as e:  # noqa: BLE001 - demo resilience
        print(f"[{INST}] endpoint not ready yet ({e}); retry {attempt}", flush=True)
        time.sleep(10)
else:
    raise SystemExit(f"[{INST}] endpoint unreachable after retries")
