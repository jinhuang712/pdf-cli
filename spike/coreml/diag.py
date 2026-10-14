"""Separate conversion error from query-selection instability.

The decoder works on the top-300 encoder anchors (torch.topk). With random
weights the encoder scores are nearly flat, so tiny numeric differences pick
different queries and the final logits/boxes stop lining up. This script:
  1. measures how much PyTorch itself moves when the input gets 1e-4 noise;
  2. converts a variant that also outputs the dense, pre-selection encoder class
     logits (enc_outputs_class, 8400 anchors) and compares those, plus the
     overlap of the selected top-300 anchor sets.

usage: python diag.py heron|egret
"""
import json
import sys

import coremltools as ct
import numpy as np
import torch

from common import OUT, PAGES, SIZE, Net, load, preprocess

kind = sys.argv[1]


class Dense(Net):
    def forward(self, pixel_values):
        o = self.m(pixel_values=pixel_values)
        return o.enc_outputs_class, o.logits, o.pred_boxes


net = Dense(load(kind)).eval()
xs = [preprocess(p)[0] for p in PAGES]
out = {"noise": [], "coreml": {}}


def top_set(enc, k=300):
    return set(np.argsort(-enc[0].max(-1))[:k].tolist())


def stats(a, b):
    finite = np.isfinite(a) & np.isfinite(b)
    d = np.abs(a - b)[finite]
    return {"maxabs": float(d.max()), "meanabs": float(d.mean()),
            "rel_maxabs": float(d.max() / (np.abs(a[finite]).max() + 1e-9)),
            "nonfinite": int((~finite).sum())}


with torch.no_grad():
    refs = [[t.numpy() for t in net(x)] for x in xs]
    g = torch.Generator().manual_seed(1)
    for x, r in zip(xs, refs):
        n = [t.numpy() for t in net(x + 1e-4 * torch.rand(x.shape, generator=g))]
        out["noise"].append({"enc": stats(r[0], n[0]), "logits": stats(r[1], n[1]),
                             "boxes": stats(r[2], n[2]),
                             "top300_overlap": len(top_set(r[0]) & top_set(n[0])) / 300})
    net(xs[0])
    traced = torch.jit.trace(net, xs[0], strict=False, check_trace=False)

for prec in ("fp32", "fp16"):
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name="pixel_values", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
        outputs=[ct.TensorType(name="enc_class"), ct.TensorType(name="logits"), ct.TensorType(name="pred_boxes")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT32 if prec == "fp32" else ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    for cu_name in ("CPU_ONLY", "CPU_AND_NE", "CPU_AND_GPU"):
        path = OUT / f"{kind}-dense-{prec}.mlpackage"
        ml.save(str(path))
        m = ct.models.MLModel(str(path), compute_units=getattr(ct.ComputeUnit, cu_name))
        rows = []
        for x, r in zip(xs, refs):
            o = m.predict({"pixel_values": x.numpy()})
            rows.append({"enc": stats(r[0], o["enc_class"]),
                         "top300_overlap": len(top_set(r[0]) & top_set(o["enc_class"])) / 300,
                         "logits": stats(r[1], o["logits"]), "boxes": stats(r[2], o["pred_boxes"])})
        out["coreml"][f"{prec}/{cu_name}"] = rows
        print(prec, cu_name, json.dumps(rows))

print("noise", json.dumps(out["noise"]))
(OUT / f"{kind}-diag.json").write_text(json.dumps(out, indent=1))
