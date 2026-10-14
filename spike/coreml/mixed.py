"""Mixed precision experiment: fp16 backbone+encoder, fp32 decoder (and heads).

usage: python mixed.py heron|egret
Writes OUT/<kind>-mixed.mlpackage and prints correctness (detections >= 0.5 vs
PyTorch) and median latency per compute unit.
"""
import statistics
import sys
import time

import coremltools as ct
import numpy as np
import torch

from common import OUT, PAGES, SIZE, Net, iou, load, postprocess, preprocess

kind = sys.argv[1]
net = Net(load(kind)).eval()
inputs = [preprocess(p) for p in PAGES]
with torch.no_grad():
    refs = [[t.numpy() for t in net(x)] for x, _ in inputs]
    traced = torch.jit.trace(net, inputs[0][0], strict=False, check_trace=False)


def keep_fp32(op):
    scopes = " ".join(str(s) for s in getattr(op, "scopes", {}).values()) if hasattr(op, "scopes") else ""
    return "decoder" in op.name or "decoder" in scopes


n_total = n_fp32 = 0


def selector(op):
    global n_total, n_fp32
    n_total += 1
    if keep_fp32(op):
        n_fp32 += 1
        return False
    return True


ml = ct.convert(
    traced,
    inputs=[ct.TensorType(name="pixel_values", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
    outputs=[ct.TensorType(name="logits"), ct.TensorType(name="pred_boxes")],
    convert_to="mlprogram",
    compute_precision=ct.transform.FP16ComputePrecision(op_selector=selector),
    minimum_deployment_target=ct.target.macOS14,
)
print(f"ops seen by selector {n_total}, kept fp32 {n_fp32}")
path = OUT / f"{kind}-mixed.mlpackage"
ml.save(str(path))

for cu in ("ALL", "CPU_AND_NE", "CPU_AND_GPU", "CPU_ONLY"):
    m = ct.models.MLModel(str(path), compute_units=getattr(ct.ComputeUnit, cu))
    res = []
    for (x, wh), (rl, rb) in zip(inputs, refs):
        o = m.predict({"pixel_values": x.numpy()})
        r5 = postprocess(rl, rb, wh, thr=0.5, topk=300)
        g5 = postprocess(o["logits"], o["pred_boxes"], wh, thr=0.5, topk=300)
        res.append(f"{sum(any(a[0] == b[0] and iou(a[2], b[2]) > 0.9 for b in g5) for a in r5)}/{len(r5)} (got {len(g5)})")
    d = {"pixel_values": inputs[0][0].numpy()}
    for _ in range(3):
        m.predict(d)
    ts = []
    for _ in range(20):
        t = time.perf_counter()
        m.predict(d)
        ts.append((time.perf_counter() - t) * 1000)
    print(cu, "det05", res, "median_ms", round(statistics.median(ts), 1))
