#!/usr/bin/env python3
"""Formatting helpers for dump-runai-config.sh. Reads JSON on stdin; mode = argv[1].
Kept as a file (not inline) to avoid shell-quoting issues."""
import json
import sys

mode = sys.argv[1] if len(sys.argv) > 1 else ""
try:
    data = json.load(sys.stdin)
except Exception:
    print("(no data)")
    sys.exit(0)


def kv(d, keys):
    return {k: d.get(k) for k in keys}


if mode == "projects":
    for p in data["items"]:
        s = p["spec"]
        q = (s.get("queues") or [{}])[0]
        g = (q.get("resources") or {}).get("gpu", {})
        print(f"{p['metadata']['name']:<28} ns={str(s.get('namespace')):<22} "
              f"parent={str(s.get('parent')):<8} gpu.deserved={g.get('deserved')} "
              f"gpu.limit={g.get('limit')} kaiScheduler={s.get('enforceKaiScheduler')}")

elif mode == "queues":
    for q in data["items"]:
        s = q["spec"]
        g = s.get("resources", {}).get("gpu", {})
        print(f"{q['metadata']['name']:<26} parent={str(s.get('parentQueue')):<10} "
              f"priority={s.get('priority')} "
              f"gpu[quota/limit/overQuotaWeight]={g.get('quota')}/{g.get('limit')}/{g.get('overQuotaWeight')}")

elif mode == "setting":
    for s in data:
        if s.get("key") == "project.quota.manual_over_quota":
            print(s["key"], "=", s.get("value"))

elif mode == "pod":
    p = data
    m, sp = p["metadata"], p["spec"]
    print("schedulerName   :", sp.get("schedulerName"))
    print("priorityClass   :", sp.get("priorityClassName"))
    print("labels:")
    for k, v in sorted(m.get("labels", {}).items()):
        if any(x in k.lower() for x in ["run.ai", "kai", "project", "workload", "queue"]):
            print("  ", k, "=", v)
    print("annotations:")
    for k, v in sorted(m.get("annotations", {}).items()):
        if any(x in k.lower() for x in ["run.ai", "kai", "pod-group", "runai", "project"]):
            print("  ", k, "=", v)

elif mode == "podgroup":
    print(json.dumps(kv(data, ["queue", "priorityClassName", "minMember", "markUnschedulable"]), indent=2))

elif mode == "team":
    team = sys.argv[2] if len(sys.argv) > 2 else ""
    rows = [w for w in data.get("workloads", [])
            if w.get("projectName") == team and w.get("phase") not in ("Deleted",)]
    if not rows:
        print("  (no active workloads)")
    for w in sorted(rows, key=lambda x: (str(x.get("category")), x["name"])):
        g = ((w.get("workloadRequestedResources") or {}).get("gpu") or {}).get("request")
        mark = "RUN " if w.get("phase") == "Running" else ("WAIT" if w.get("phase") in ("Pending", "Initializing", "Creating") else "    ")
        print(f"  [{mark}] {str(w.get('category')):7} {w['name']:30} {str(w.get('phase')):10} gpu={g}")

elif mode == "llmisvc":
    s = data.get("spec", {})
    t = s.get("template", {})
    c = (t.get("containers") or [{}])[0]
    print("model.uri      :", s.get("model", {}).get("uri"))
    print("replicas       :", s.get("replicas"))
    print("schedulerName  :", t.get("schedulerName"))
    print("tolerations    :", [tt.get("key") for tt in t.get("tolerations", [])])
    print("gpu request    :", (c.get("resources", {}).get("requests", {}) or {}).get("nvidia.com/gpu"))
