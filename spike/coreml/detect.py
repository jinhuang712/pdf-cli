"""What the layout model finds: per-page regions (score >= 0.5) and overlay PNGs.

Runs the converted Core ML model (fp32, CPU_AND_GPU) and post-processes in
Python (sigmoid + top-300 over query x class, as RTDetrImageProcessor does).
No Docling-style overlap resolution is applied.

usage: python detect.py heron|egret
Writes OUT/<kind>-detections.json and OUT/overlay-<kind>-<page>.png.
"""
import collections
import json
import sys

import coremltools as ct
from PIL import Image, ImageDraw, ImageFont

import common
from common import OUT, PAGES, load, postprocess, preprocess

kind = sys.argv[1]
THR = 0.5
load(kind)  # fills common.LABELS from the cached config's id2label
ml = ct.models.MLModel(str(OUT / f"{kind}-fp32.mlpackage"), compute_units=ct.ComputeUnit.CPU_AND_GPU)

COLORS = {
    "text": (120, 120, 120), "title": (200, 0, 0), "section_header": (230, 90, 0),
    "caption": (0, 140, 0), "footnote": (140, 0, 140), "page_header": (0, 120, 200),
    "page_footer": (0, 120, 200), "picture": (220, 0, 120), "table": (0, 60, 220),
    "formula": (150, 110, 0), "list_item": (0, 160, 160), "code": (90, 0, 200),
}
font = ImageFont.load_default(size=22)
result = {}
for page in PAGES:
    x, wh = preprocess(page)
    o = ml.predict({"pixel_values": x.numpy()})
    dets = postprocess(o["logits"], o["pred_boxes"], wh, thr=THR, topk=300)
    img = Image.open(page).convert("RGB")
    dr = ImageDraw.Draw(img)
    for label, score, (x0, y0, x1, y1) in dets:
        c = COLORS.get(label, (0, 0, 0))
        dr.rectangle([x0, y0, x1, y1], outline=c, width=3)
        dr.text((x0 + 3, max(0, y0 - 24)), f"{label} {score:.2f}", fill=c, font=font)
    img.save(OUT / f"overlay-{kind}-{page.stem}.png")
    counts = collections.Counter(d[0] for d in dets)
    result[page.stem] = {"counts": dict(counts.most_common()),
                         "regions": [{"label": l, "score": round(s, 3), "box": b} for l, s, b in dets]}
    print(page.stem, dict(counts.most_common()))

(OUT / f"{kind}-detections.json").write_text(json.dumps(result, indent=1))
