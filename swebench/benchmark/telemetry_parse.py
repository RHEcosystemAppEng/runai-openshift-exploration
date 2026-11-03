#!/usr/bin/env python3
"""Parse vLLM /metrics and rocm-smi output into a single JSON record."""
import json, sys, re, os, subprocess, time

def parse_vllm_metrics(metrics_text):
    m = {}
    for l in metrics_text.split('\n'):
        if l.startswith('#') or not l.strip():
            continue
        parts = l.split()
        if len(parts) < 2:
            continue
        name = parts[0].split('{')[0].replace('vllm:', '').replace(':', '_')
        val = parts[-1]
        try:
            fval = float(val)
        except:
            continue

        if name in (
            'num_requests_running', 'num_requests_waiting',
            'kv_cache_usage_perc', 'prompt_tokens_total',
            'generation_tokens_total', 'num_preemptions_total',
            'prefix_cache_hits_total', 'prefix_cache_queries_total',
            'estimated_flops_per_gpu_total', 'estimated_read_bytes_per_gpu_total',
            'process_cpu_seconds_total', 'process_resident_memory_bytes',
        ):
            m[name] = fval

        # Histogram sums and counts for latency metrics
        if '_sum{' in l:
            if 'e2e_request_latency' in l: m['e2e_latency_sum'] = fval
            elif 'time_to_first_token' in l: m['ttft_sum'] = fval
            elif 'time_per_output_token' in l: m['tpot_sum'] = fval
            elif 'inter_token_latency' in l: m['itl_sum'] = fval
        if '_count{' in l:
            if 'e2e_request_latency' in l: m['e2e_latency_count'] = fval
            elif 'time_to_first_token' in l: m['ttft_count'] = fval
            elif 'time_per_output_token' in l: m['tpot_count'] = fval
            elif 'inter_token_latency' in l: m['itl_count'] = fval

    # Compute averages
    if m.get('e2e_latency_count', 0) > 0:
        m['e2e_latency_avg_s'] = round(m['e2e_latency_sum'] / m['e2e_latency_count'], 3)
    if m.get('ttft_count', 0) > 0:
        m['ttft_avg_s'] = round(m['ttft_sum'] / m['ttft_count'], 3)
    if m.get('tpot_count', 0) > 0:
        m['tpot_avg_ms'] = round(m['tpot_sum'] / m['tpot_count'] * 1000, 3)
    if m.get('itl_count', 0) > 0:
        m['itl_avg_ms'] = round(m['itl_sum'] / m['itl_count'] * 1000, 3)

    # Cache hit rate
    queries = m.get('prefix_cache_queries_total', 0)
    hits = m.get('prefix_cache_hits_total', 0)
    m['cache_hit_rate'] = round(hits / max(queries, 1), 4)

    # Total tokens served
    m['total_tokens_served'] = m.get('prompt_tokens_total', 0) + m.get('generation_tokens_total', 0)

    return m


def parse_rocm_smi(smi_text):
    m = {}
    t = re.search(r'Temperature.*?:\s*(\d+\.?\d*)', smi_text) or re.search(r'(\d+\.?\d*)°C', smi_text)
    if t: m['gpu_temp_c'] = float(t.group(1))
    p = re.search(r'(\d+\.?\d*)W\s', smi_text)
    if p: m['gpu_power_w'] = float(p.group(1))
    u = re.search(r'GPU[%\s]*(\d+)%', smi_text) or re.search(r'(\d+)%\s*$', smi_text, re.MULTILINE)
    if u: m['gpu_util_pct'] = int(u.group(1))
    vt = re.search(r'VRAM Total Memory.*?:\s*(\d+)', smi_text)
    vu = re.search(r'VRAM Total Used.*?:\s*(\d+)', smi_text)
    if vt: m['vram_total_gb'] = round(int(vt.group(1)) / 1073741824, 2)
    if vu: m['vram_used_gb'] = round(int(vu.group(1)) / 1073741824, 2)
    if vt and vu: m['vram_used_pct'] = round(int(vu.group(1)) / int(vt.group(1)) * 100, 1)
    sc = re.findall(r'(\d+)Mhz', smi_text)
    if len(sc) >= 1: m['gpu_clock_mhz'] = int(sc[0])
    if len(sc) >= 2: m['mem_clock_mhz'] = int(sc[1])
    return m


if __name__ == '__main__':
    namespace = os.environ.get('NAMESPACE', 'ccamacho-test-bench')
    vllm_url = os.environ.get('VLLM_URL', 'http://qwen-inference.%s.svc.cluster.local:8000' % namespace)
    outdir = os.environ.get('TELEMETRY_DIR', '/workspace/telemetry')
    interval = int(os.environ.get('INTERVAL', '30'))
    os.makedirs(outdir, exist_ok=True)

    outfile = os.path.join(outdir, 'metrics-%s.jsonl' % time.strftime('%Y%m%d'))
    print('Telemetry collector: interval=%ds output=%s' % (interval, outfile))

    while True:
        try:
            ts = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
            epoch = int(time.time())

            # vLLM metrics
            try:
                import urllib.request
                resp = urllib.request.urlopen(vllm_url + '/metrics', timeout=10)
                metrics_text = resp.read().decode('utf-8', errors='replace')
                vllm_data = parse_vllm_metrics(metrics_text)
            except:
                vllm_data = {}

            # rocm-smi via oc exec
            try:
                vllm_pod = subprocess.check_output(
                    ['oc', 'get', 'pods', '-l', 'app=vllm-qwen', '-n', namespace,
                     '-o', 'jsonpath={.items[0].metadata.name}'],
                    timeout=10).decode().strip()
                smi_output = subprocess.check_output(
                    ['oc', 'exec', vllm_pod, '-c', 'vllm', '-n', namespace,
                     '--', 'rocm-smi', '--showmeminfo', 'vram'],
                    timeout=15).decode()
                smi_concise = subprocess.check_output(
                    ['oc', 'exec', vllm_pod, '-c', 'vllm', '-n', namespace,
                     '--', 'rocm-smi'],
                    timeout=15).decode()
                gpu_data = parse_rocm_smi(smi_output + '\n' + smi_concise)
            except:
                gpu_data = {}

            # K8s job counts
            try:
                jobs_out = subprocess.check_output(
                    ['oc', 'get', 'jobs', '-l', 'app=swebench-instance', '-n', namespace,
                     '--no-headers'], timeout=10).decode()
                running = sum(1 for l in jobs_out.strip().split('\n') if 'Running' in l) if jobs_out.strip() else 0
                complete = sum(1 for l in jobs_out.strip().split('\n') if 'Complete' in l) if jobs_out.strip() else 0
            except:
                running = 0
                complete = 0

            record = {
                'timestamp': ts,
                'epoch': epoch,
                'gpu': gpu_data,
                'vllm': vllm_data,
                'jobs': {'running': running, 'complete': complete}
            }

            with open(outfile, 'a') as f:
                f.write(json.dumps(record) + '\n')

        except Exception as e:
            print('Error: %s' % e, file=sys.stderr)

        time.sleep(interval)
