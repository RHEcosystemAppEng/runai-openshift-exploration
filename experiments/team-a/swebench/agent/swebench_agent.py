#!/usr/bin/env python3
"""Representative SWE-bench agent (ai-dev06).

A full SWE-bench run clones a repo at a commit, applies the failing-test patch,
and drives a coding agent (e.g. AMI) against a vLLM endpoint over many turns. This
lightweight stand-in keeps the part that matters for a serving/scheduling demo: it
makes a REAL OpenAI-compatible inference call to the vLLM endpoint and prints the
model's proposed patch. CPU-only.

Usage:
    AI_BASE_URL=https://<endpoint>/v1 AI_MODEL=Qwen/Qwen2.5-3B-Instruct \\
    AI_API_KEY=swebench-token INSTANCE_ID=lite-001 python3 swebench_agent.py

(The live Run:ai reclaim demo runs this same agent as Team A's batch workload; see
experiments/team-a/.)
"""
import json
import os
import ssl
import time
import urllib.request

# The KServe endpoint terminates TLS with a self-signed cert; skip verification
# for this in-cluster demo call.
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

# The endpoint may still be pulling the model when this starts; retry.
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
