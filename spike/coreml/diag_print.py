"""Print a compact summary of OUT/<kind>-diag.json. usage: python3 diag_print.py heron"""
import json
import pathlib
import sys

d = json.loads((pathlib.Path(__file__).resolve().parents[1] / "out" / "coreml" / f"{sys.argv[1]}-diag.json").read_text())
f = lambda s: f"{s['maxabs']:.3g}/{s['meanabs']:.2g}/nf{s['nonfinite']}"
print("row: enc max/mean, top300 overlap, logits max/mean, boxes max/mean")
for r in d["noise"]:
    print("noise1e-4", f(r["enc"]), round(r["top300_overlap"], 3), f(r["logits"]), f(r["boxes"]))
for k, rows in d["coreml"].items():
    for r in rows:
        print(k, f(r["enc"]), round(r["top300_overlap"], 3), f(r["logits"]), f(r["boxes"]))
