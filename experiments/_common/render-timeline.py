#!/usr/bin/env python3
"""Render reports/timeline-data.jsonl as a self-contained Gantt timeline (HTML/SVG).

One lane per GPU node; colored blocks show which team held that GPU over time
(blue=Team A, orange=Team B, gray=other project). A dashed marker shows the moment
Team A submits and reclaims. A strip at the bottom shows Team B's pending (preempted)
GPU jobs piling up. Usage:
    python3 _common/render-timeline.py [IN=reports/timeline-cycle-data.jsonl] [OUT=reports/timeline-cycle.html]
    (run from the experiments/ directory)
"""
import html
import json
import sys

IN = sys.argv[1] if len(sys.argv) > 1 else "reports/timeline-cycle-data.jsonl"
OUT = sys.argv[2] if len(sys.argv) > 2 else "reports/timeline-cycle.html"

COL = {"A": "#2a78d6", "B": "#eb6834", "O": "#7a7975"}
GPU_TYPE = {"31-120": "A10G", "36-157": "A10G", "63-107": "A10G", "63-222": "A10G", "43-119": "L40S"}

samples = []
with open(IN) as f:
    for line in f:
        line = line.strip()
        if line:
            samples.append(json.loads(line))
if not samples:
    sys.exit("no samples in " + IN)

interval = (samples[1]["t"] - samples[0]["t"]) if len(samples) > 1 else 2
maxT = samples[-1]["t"] + interval


def short_node(n):
    if not n:
        return "?"
    tail = n.split(".")[0].split("-")[-2:]
    return "-".join(tail)


def short_wl(w):
    w = w.lower()
    if "triton" in w:
        return "triton"
    if "qwen-kserve" in w or "kserve" in w:
        return "team-a-qwen"
    if "workbench" in w:
        return "workbench"
    for key in ("burst-1", "burst-2", "burst-3", "victim-1", "victim-2", "victim-3"):
        if key in w:
            return key
    return w[:16]


# collect nodes in a stable order: A10G first, then L40S, by octet
nodes = []
for s in samples:
    for h in s["holders"]:
        sn = short_node(h.get("node"))
        if sn not in nodes:
            nodes.append(sn)
nodes.sort(key=lambda sn: (GPU_TYPE.get(sn, "zzz"), sn))

# per node: ordered list of (t, team, wl) ; build runs
runs = {sn: [] for sn in nodes}
for sn in nodes:
    cur = None
    for s in samples:
        h = next((x for x in s["holders"] if short_node(x.get("node")) == sn), None)
        key = (h["team"], short_wl(h["wl"])) if h else None
        if key and (cur is None or cur["key"] != key):
            cur = {"key": key, "t0": s["t"], "t1": s["t"] + interval}
            runs[sn].append(cur)
        elif key:
            cur["t1"] = s["t"] + interval
        else:
            cur = None

# Team B pending count per sample
pend_series = [(s["t"], sum(1 for p in s["pending"] if p["team"] == "B")) for s in samples]

# reclaim = first node transition Team B -> Team A ; return = first A -> B after that
reclaim_t = None
for sn in nodes:
    prev = None
    for r in runs[sn]:
        cur = r["key"][0]
        if prev == "B" and cur == "A":
            reclaim_t = r["t0"] if reclaim_t is None else min(reclaim_t, r["t0"])
        prev = cur
return_t = None
if reclaim_t is not None:
    for sn in nodes:
        prev = None
        for r in runs[sn]:
            cur = r["key"][0]
            if prev == "A" and cur == "B" and r["t0"] > reclaim_t:
                return_t = r["t0"] if return_t is None else min(return_t, r["t0"])
            prev = cur

# ---- layout ----
W = 1280
LPAD, RPAD, TOP = 200, 36, 128
ROW_H, ROW_GAP = 40, 10
plotW = W - LPAD - RPAD
sx = lambda t: LPAD + plotW * t / maxT
lanes_h = len(nodes) * (ROW_H + ROW_GAP)
pend_top = TOP + lanes_h + 46
pend_h = 54
H = pend_top + pend_h + 70

svg = []
svg.append(f'<svg viewBox="0 0 {W} {H}" width="{W}" height="{H}" font-family="Inter,Segoe UI,Roboto,Arial,sans-serif">')
svg.append(f'<rect width="{W}" height="{H}" fill="#fcfcfb"/>')
# title
svg.append(f'<text x="{LPAD}" y="42" font-size="30" font-weight="800" fill="#0b0b0b">Team A takes precedence — GPU ownership over time</text>')
svg.append(f'<text x="{LPAD}" y="66" font-size="14" fill="#52514e">cluster ai-dev06 · NVIDIA Run:ai (KAI) · each lane = one GPU; color = owning team</text>')
# phase bands (whole e2e narrative): borrow → reclaim/use → return
if reclaim_t is not None:
    end2 = return_t if return_t is not None else maxT
    bands = [(0, reclaim_t, "#eb6834", "1 · Team B borrowing"),
             (reclaim_t, end2, "#2a78d6", "2 · Team A reclaims & uses")]
    if return_t is not None:
        bands.append((return_t, maxT, "#eb6834", "3 · Team B returns"))
    for (ba, bb, bc, lab) in bands:
        x0 = sx(ba); x1 = sx(bb)
        svg.append(f'<rect x="{x0:.1f}" y="{TOP-6}" width="{x1-x0:.1f}" height="{lanes_h+10}" fill="{bc}" opacity="0.06"/>')
        svg.append(f'<text x="{(x0+x1)/2:.1f}" y="88" font-size="12.5" font-weight="800" fill="{bc}" text-anchor="middle">{lab}</text>')
# time axis gridlines + ticks
for tt in range(0, maxT + 1, 10):
    x = sx(tt)
    svg.append(f'<line x1="{x:.1f}" y1="{TOP-8}" x2="{x:.1f}" y2="{pend_top+pend_h}" stroke="#e7e6e2"/>')
    svg.append(f'<text x="{x:.1f}" y="{TOP-14}" font-size="11" fill="#8a8a85" text-anchor="middle">{tt}s</text>')
# node lanes
for i, sn in enumerate(nodes):
    y = TOP + i * (ROW_H + ROW_GAP)
    gt = GPU_TYPE.get(sn, "GPU")
    svg.append(f'<text x="{LPAD-12}" y="{y+ROW_H/2+5:.0f}" font-size="13" font-weight="600" fill="#0b0b0b" text-anchor="end">{sn} <tspan fill="#8a8a85" font-weight="400">{gt}</tspan></text>')
    svg.append(f'<rect x="{LPAD}" y="{y}" width="{plotW}" height="{ROW_H}" fill="#f2f1ee" rx="6"/>')
    for r in runs[sn]:
        team, wl = r["key"]
        x0 = sx(r["t0"]); w = sx(r["t1"]) - x0
        svg.append(f'<rect x="{x0:.1f}" y="{y}" width="{max(w-2,2):.1f}" height="{ROW_H}" rx="6" fill="{COL[team]}"/>')
        if w > 54:
            svg.append(f'<text x="{x0+8:.1f}" y="{y+ROW_H/2+5:.0f}" font-size="12" font-weight="600" fill="#fff">{html.escape(wl)}</text>')
# cycle markers: reclaim (Team A takes over) and return (Team B gets GPUs back)
if reclaim_t is not None:
    x = sx(reclaim_t)
    svg.append(f'<line x1="{x:.1f}" y1="{TOP-8}" x2="{x:.1f}" y2="{pend_top+pend_h}" stroke="#2a78d6" stroke-width="2" stroke-dasharray="5 4"/>')
    svg.append(f'<text x="{x+6:.1f}" y="{TOP-26}" font-size="12" font-weight="700" fill="#2a78d6">Team A needs GPUs → reclaim ({reclaim_t}s)</text>')
if return_t is not None:
    x = sx(return_t)
    # drop the label a line when the two markers are close, to avoid overlap
    ly = TOP - 44 if (reclaim_t is not None and (return_t - reclaim_t) * (plotW / maxT) < 220) else TOP - 26
    svg.append(f'<line x1="{x:.1f}" y1="{TOP-8}" x2="{x:.1f}" y2="{pend_top+pend_h}" stroke="#eb6834" stroke-width="2" stroke-dasharray="5 4"/>')
    svg.append(f'<text x="{x+6:.1f}" y="{ly}" font-size="12" font-weight="700" fill="#eb6834">Team A done → Team B returns ({return_t}s)</text>')
# pending strip (Team B queued/preempted)
svg.append(f'<text x="{LPAD-12}" y="{pend_top+pend_h/2+5:.0f}" font-size="12" font-weight="600" fill="#eb6834" text-anchor="end">Team B pending</text>')
svg.append(f'<rect x="{LPAD}" y="{pend_top}" width="{plotW}" height="{pend_h}" fill="#fdf0ea" rx="6"/>')
maxp = max((c for _, c in pend_series), default=1) or 1
for (tt, c) in pend_series:
    if c <= 0:
        continue
    x = sx(tt); bw = max(sx(tt + interval) - x - 1, 2)
    bh = pend_h * c / maxp
    svg.append(f'<rect x="{x:.1f}" y="{pend_top+pend_h-bh:.1f}" width="{bw:.1f}" height="{bh:.1f}" fill="#eb6834" opacity="0.85"/>')
svg.append(f'<text x="{LPAD+plotW}" y="{pend_top+pend_h+16:.0f}" font-size="11" fill="#8a8a85" text-anchor="end">bar height = # Team B GPU jobs waiting (preempted)</text>')
# legend
ly = H - 24
items = [("Team A (deserved 4)", COL["A"]), ("Team B (deserved 0)", COL["B"]), ("Other project", COL["O"])]
lx = LPAD
for label, c in items:
    svg.append(f'<rect x="{lx}" y="{ly-11}" width="13" height="13" rx="3" fill="{c}"/>')
    svg.append(f'<text x="{lx+19}" y="{ly}" font-size="12" fill="#52514e">{label}</text>')
    lx += 20 + 9 * len(label) + 24
svg.append('</svg>')

doc = "<!doctype html><html><head><meta charset='utf-8'><style>body{margin:0;background:#fcfcfb}</style></head><body>" + "".join(svg) + "</body></html>"
with open(OUT, "w") as f:
    f.write(doc)
print("wrote", OUT, "| nodes:", nodes, "| maxT:", maxT, "| reclaim_t:", reclaim_t)
