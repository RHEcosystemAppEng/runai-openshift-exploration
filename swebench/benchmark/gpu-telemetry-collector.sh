#!/usr/bin/env bash
# GPU telemetry collector for SWE-bench benchmarks.
# Runs as a background process on the coordinator, periodically scraping:
# 1. rocm-smi metrics from vLLM pod (GPU utilization, VRAM, temp, power, clocks)
# 2. vLLM /metrics endpoint (KV cache, throughput, latency, tokens, TTFT, TPOT)
# 3. K8s job status (concurrency, queue depth)
#
# Output: /workspace/telemetry/<timestamp>.jsonl (one JSON object per sample)
#
# Usage: nohup bash gpu-telemetry-collector.sh > /workspace/logs/telemetry.log 2>&1 &
#
# Interval: every 30 seconds (configurable via INTERVAL env var)

set -o pipefail

WORKSPACE="${WORKSPACE:-/workspace}"
NAMESPACE="${NAMESPACE:-ccamacho-test-bench}"
INTERVAL="${INTERVAL:-30}"
VLLM_URL="http://qwen-inference.${NAMESPACE}.svc.cluster.local:8000"
TELEMETRY_DIR="$WORKSPACE/telemetry"
mkdir -p "$TELEMETRY_DIR"

OUTFILE="$TELEMETRY_DIR/metrics-$(date +%Y%m%d).jsonl"

echo "[$(date)] GPU telemetry collector started (interval=${INTERVAL}s, output=$OUTFILE)"

while true; do
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  EPOCH=$(date +%s)

  # ── 1. vLLM Prometheus metrics ──
  METRICS=$(curl -s "$VLLM_URL/metrics" 2>/dev/null || echo "")

  # Parse key metrics
  VLLM_JSON=$(echo "$METRICS" | python3 -c "
import sys
lines = sys.stdin.read().split('\n')
m = {}
for l in lines:
    if l.startswith('#') or not l.strip(): continue
    parts = l.split()
    if len(parts) < 2: continue
    name = parts[0].split('{')[0]
    val = parts[-1]
    # Keep the most useful metrics
    if name in (
        'vllm:num_requests_running',
        'vllm:num_requests_waiting',
        'vllm:kv_cache_usage_perc',
        'vllm:prompt_tokens_total',
        'vllm:generation_tokens_total',
        'vllm:num_preemptions_total',
        'vllm:prefix_cache_hits_total',
        'vllm:prefix_cache_queries_total',
        'vllm:estimated_flops_per_gpu_total',
        'vllm:estimated_read_bytes_per_gpu_total',
        'process_cpu_seconds_total',
        'process_resident_memory_bytes',
    ):
        m[name.replace('vllm:','').replace(':','_')] = float(val)

# E2E latency, TTFT, TPOT from histogram summaries
for l in lines:
    if '_sum{' in l and not l.startswith('#'):
        name = l.split('{')[0]
        val = float(l.split()[-1])
        if 'e2e_request_latency' in name: m['e2e_latency_sum'] = val
        elif 'time_to_first_token' in name: m['ttft_sum'] = val
        elif 'time_per_output_token' in name: m['tpot_sum'] = val
        elif 'inter_token_latency' in name: m['itl_sum'] = val
    if '_count{' in l and not l.startswith('#'):
        name = l.split('{')[0]
        val = float(l.split()[-1])
        if 'e2e_request_latency' in name: m['e2e_latency_count'] = val
        elif 'time_to_first_token' in name: m['ttft_count'] = val
        elif 'time_per_output_token' in name: m['tpot_count'] = val
        elif 'inter_token_latency' in name: m['itl_count'] = val

# Compute averages
if m.get('e2e_latency_count',0) > 0:
    m['e2e_latency_avg_s'] = round(m['e2e_latency_sum'] / m['e2e_latency_count'], 3)
if m.get('ttft_count',0) > 0:
    m['ttft_avg_s'] = round(m['ttft_sum'] / m['ttft_count'], 3)
if m.get('tpot_count',0) > 0:
    m['tpot_avg_s'] = round(m['tpot_sum'] / m['tpot_count'], 6)
if m.get('itl_count',0) > 0:
    m['itl_avg_s'] = round(m['itl_sum'] / m['itl_count'], 6)

# Throughput: tokens per second (prompt + generation)
prompt_total = m.get('prompt_tokens_total', 0)
gen_total = m.get('generation_tokens_total', 0)
m['total_tokens_served'] = prompt_total + gen_total

# Cache hit rate
queries = m.get('prefix_cache_queries_total', 0)
hits = m.get('prefix_cache_hits_total', 0)
m['cache_hit_rate'] = round(hits / max(queries, 1), 4)

import json
print(json.dumps(m))
" 2>/dev/null || echo "{}")

  # ── 2. rocm-smi via vLLM pod ──
  VLLM_POD=$(oc get pods -l app=vllm-qwen -n "$NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  GPU_JSON="{}"
  if [ -n "$VLLM_POD" ]; then
    GPU_JSON=$(oc exec "$VLLM_POD" -c vllm -n "$NAMESPACE" -- rocm-smi --showtemp --showuse --showpower --showmeminfo vram --showclocks 2>/dev/null | python3 -c "
import sys, re
lines = sys.stdin.read()
m = {}
# Temperature
t = re.search(r'Temperature.*?:\s*(\d+\.?\d*)', lines)
if t: m['gpu_temp_c'] = float(t.group(1))
# Power
p = re.search(r'Power.*?:\s*(\d+\.?\d*)', lines)
if p: m['gpu_power_w'] = float(p.group(1))
# GPU utilization
u = re.search(r'GPU use.*?:\s*(\d+)', lines)
if u: m['gpu_util_pct'] = int(u.group(1))
# VRAM
vt = re.search(r'VRAM Total.*?:\s*(\d+)', lines)
vu = re.search(r'VRAM Total Used.*?:\s*(\d+)', lines)
if vt: m['vram_total_bytes'] = int(vt.group(1))
if vu: m['vram_used_bytes'] = int(vu.group(1))
if vt and vu:
    m['vram_used_pct'] = round(int(vu.group(1)) / int(vt.group(1)) * 100, 1)
    m['vram_used_gb'] = round(int(vu.group(1)) / 1073741824, 2)
    m['vram_total_gb'] = round(int(vt.group(1)) / 1073741824, 2)
# Clocks
sc = re.search(r'sclk.*?(\d+)Mhz', lines)
mc = re.search(r'mclk.*?(\d+)Mhz', lines)
if sc: m['gpu_clock_mhz'] = int(sc.group(1))
if mc: m['mem_clock_mhz'] = int(mc.group(1))
import json
print(json.dumps(m))
" 2>/dev/null || echo "{}")
  fi

  # ── 3. K8s job status ──
  RUNNING_JOBS=$(oc get jobs -l app=swebench-instance -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Running" || echo 0)
  COMPLETE_JOBS=$(oc get jobs -l app=swebench-instance -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c "Complete" || echo 0)
  TOTAL_PODS=$(oc get pods -l app=swebench-instance -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo 0)

  # ── Combine and write ──
  python3 -c "
import json
ts = '$TS'
epoch = $EPOCH
vllm = json.loads('$VLLM_JSON')
gpu = json.loads('$GPU_JSON')
record = {
    'timestamp': ts,
    'epoch': epoch,
    'gpu': gpu,
    'vllm': vllm,
    'jobs': {
        'running': $RUNNING_JOBS,
        'complete': $COMPLETE_JOBS,
        'total_pods': $TOTAL_PODS
    }
}
print(json.dumps(record))
" >> "$OUTFILE" 2>/dev/null

  sleep "$INTERVAL"
done
