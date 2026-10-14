"""Per-page region counts from OUT/<kind>-detections.json, after a simple
same-label NMS (IoU > 0.5) and a cross-label pass (IoU > 0.8 keeps the higher score).
usage: python3 summarize.py heron"""
import json
import pathlib
import sys

OUT = pathlib.Path(__file__).resolve().parents[1] / "out" / "coreml"


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    i = ix * iy
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 0


COLS = ["text", "section_header", "title", "list_item", "formula", "picture", "table", "caption",
        "footnote", "page_header", "page_footer", "other"]
d = json.loads((OUT / f"{sys.argv[1]}-detections.json").read_text())
print("| page | " + " | ".join(COLS) + " | raw |")
print("|" + "---|" * (len(COLS) + 2))
for page, v in d.items():
    regs = sorted(v["regions"], key=lambda r: -r["score"])
    kept = []
    for r in regs:
        if any((k["label"] == r["label"] and iou(k["box"], r["box"]) > 0.5) or iou(k["box"], r["box"]) > 0.8 for k in kept):
            continue
        kept.append(r)
    c = {}
    for r in kept:
        lab = r["label"] if r["label"] in COLS else "other"
        if lab == "other":
            c.setdefault("_other", []).append(r["label"])
        c[lab] = c.get(lab, 0) + 1
    other = c.get("other", 0)
    cells = [str(c.get(k, 0)) for k in COLS[:-1]] + [f"{other} ({', '.join(sorted(set(c.get('_other', []))))})" if other else "0"]
    print(f"| {page} | " + " | ".join(cells) + f" | {len(regs)} |")
