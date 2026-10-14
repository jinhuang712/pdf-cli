"""Correctness and speed: PyTorch (CPU, MPS) vs Core ML (fp32/fp16 x compute units) vs ONNX Runtime.

usage: python bench.py heron|egret [runs]
Writes OUT/<kind>-bench.json.
"""
import json
import statistics
import sys
import time
import traceback

import coremltools as ct
import numpy as np
import torch

from common import OUT, PAGES, SIZE, Net, iou, load, postprocess, preprocess, size_of

kind = sys.argv[1]
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 20
WARM = 3
res = {"kind": kind, "runs": RUNS, "pages": [p.name for p in PAGES], "torch": {}, "coreml": {}, "onnx": {}}

net = Net(load(kind)).eval()
inputs = [preprocess(p) for p in PAGES]
print("params", sum(p.numel() for p in net.parameters()) / 1e6, "M")
res["params_M"] = sum(p.numel() for p in net.parameters()) / 1e6


def bench(fn, x):
    for _ in range(WARM):
        fn(x)
    ts = []
    for _ in range(RUNS):
        t = time.perf_counter()
        fn(x)
        ts.append((time.perf_counter() - t) * 1000)
    return round(statistics.median(ts), 1), round(min(ts), 1)


def compare(ref, got, wh, k=10):
    """max abs diffs + how many of the reference top-k (query, class) detections
    reappear in got's top-k with the same label and box IoU > 0.9."""
    rl, rb = ref
    gl, gb = got
    d = {"logits_maxabs": float(np.abs(rl - gl).max()),
         "boxes_maxabs": float(np.abs(rb - gb).max()),
         "scores_maxabs": float(np.abs(1 / (1 + np.exp(-rl)) - 1 / (1 + np.exp(-gl))).max())}
    d["boxes_meanabs"] = float(np.abs(rb - gb).mean())
    d["query_label_agree"] = float((rl[0].argmax(-1) == gl[0].argmax(-1)).mean())
    r = postprocess(rl, rb, wh, topk=k)
    g = postprocess(gl, gb, wh, topk=k)
    d["topk_match"] = sum(any(a[0] == b[0] and iou(a[2], b[2]) > 0.9 for b in g) for a in r)
    d["k"] = k
    # detections with score >= 0.5: reference ones found in got (label + IoU > 0.9), and counts
    r5 = postprocess(rl, rb, wh, thr=0.5, topk=300)
    g5 = postprocess(gl, gb, wh, thr=0.5, topk=300)
    m5 = sum(any(a[0] == b[0] and iou(a[2], b[2]) > 0.9 for b in g5) for a in r5)
    d["det05"] = f"{m5}/{len(r5)} (got {len(g5)})"
    return d


# ---- PyTorch CPU (reference) ----
ref = []
with torch.no_grad():
    for (x, wh), p in zip(inputs, PAGES):
        lo, bo = net(x)
        ref.append((lo.numpy(), bo.numpy()))
        res["torch"].setdefault("top5", {})[p.name] = postprocess(lo.numpy(), bo.numpy(), wh, topk=5)
    res["torch"]["cpu_ms"] = bench(lambda x: net(x), inputs[0][0])
print("torch cpu", res["torch"]["cpu_ms"])

# ---- PyTorch MPS ----
try:
    netm = Net(load(kind)).eval().to("mps")
    with torch.no_grad():
        xm = inputs[0][0].to("mps")
        lo, bo = netm(xm)
        res["torch"]["mps_vs_cpu"] = compare(ref[0], (lo.cpu().numpy(), bo.cpu().numpy()), inputs[0][1])

        def run_mps(x):
            lo, bo = netm(x)
            torch.mps.synchronize()
            return lo

        res["torch"]["mps_ms"] = bench(run_mps, xm)
    print("torch mps", res["torch"]["mps_ms"], res["torch"]["mps_vs_cpu"])
except Exception as e:
    res["torch"]["mps_error"] = repr(e)[:500]
    traceback.print_exc()

# ---- Core ML ----
CUS = {"ALL": ct.ComputeUnit.ALL, "CPU_AND_NE": ct.ComputeUnit.CPU_AND_NE,
       "CPU_AND_GPU": ct.ComputeUnit.CPU_AND_GPU, "CPU_ONLY": ct.ComputeUnit.CPU_ONLY}
for prec in ("fp32", "fp16"):
    pkg = OUT / f"{kind}-{prec}.mlpackage"
    if not pkg.exists():
        res["coreml"][prec] = {"error": "no mlpackage"}
        continue
    res["coreml"][prec] = {"mlpackage_MB": round(size_of(pkg) / 1e6, 1)}
    for cu_name, cu in CUS.items():
        r = {}
        try:
            t = time.perf_counter()
            ml = ct.models.MLModel(str(pkg), compute_units=cu)
            r["load_s"] = round(time.perf_counter() - t, 2)
            outs = []
            for (x, wh), rr in zip(inputs, ref):
                o = ml.predict({"pixel_values": x.numpy()})
                outs.append(compare(rr, (o["logits"], o["pred_boxes"]), wh))
            r["vs_torch"] = {
                "logits_maxabs": max(o["logits_maxabs"] for o in outs),
                "boxes_maxabs": max(o["boxes_maxabs"] for o in outs),
                "scores_maxabs": max(o["scores_maxabs"] for o in outs),
                "boxes_meanabs": max(o["boxes_meanabs"] for o in outs),
                "query_label_agree_min": min(o["query_label_agree"] for o in outs),
                "top10_match_per_page": [o["topk_match"] for o in outs],
                "det05_per_page": [o["det05"] for o in outs],
            }
            xin = {"pixel_values": inputs[0][0].numpy()}
            r["ms"] = bench(lambda d: ml.predict(d), xin)
        except Exception as e:
            r["error"] = repr(e)[:500]
            traceback.print_exc()
        res["coreml"][prec][cu_name] = r
        print("coreml", prec, cu_name, r)

# ---- ONNX Runtime (our own export; the official heron-onnx could not be downloaded) ----
try:
    import onnxruntime as ort
    onnx_path = OUT / f"{kind}.onnx"
    if not onnx_path.exists():
        with torch.no_grad():
            net(inputs[0][0])
            torch.onnx.export(net, (inputs[0][0],), str(onnx_path), input_names=["pixel_values"],
                              output_names=["logits", "pred_boxes"], opset_version=17, dynamo=False)
    res["onnx"]["file_MB"] = round(size_of(onnx_path) / 1e6, 1)
    for prov in (["CPUExecutionProvider"], ["CoreMLExecutionProvider", "CPUExecutionProvider"]):
        name = prov[0]
        r = {}
        try:
            t = time.perf_counter()
            s = ort.InferenceSession(str(onnx_path), providers=prov)
            r["load_s"] = round(time.perf_counter() - t, 2)
            r["providers"] = s.get_providers()
            outs = []
            for (x, wh), rr in zip(inputs, ref):
                lo, bo = s.run(None, {"pixel_values": x.numpy()})
                outs.append(compare(rr, (lo, bo), wh))
            r["vs_torch"] = {"logits_maxabs": max(o["logits_maxabs"] for o in outs),
                             "boxes_maxabs": max(o["boxes_maxabs"] for o in outs),
                             "boxes_meanabs": max(o["boxes_meanabs"] for o in outs),
                             "query_label_agree_min": min(o["query_label_agree"] for o in outs),
                             "top10_match_per_page": [o["topk_match"] for o in outs],
                             "det05_per_page": [o["det05"] for o in outs]}
            r["ms"] = bench(lambda x: s.run(None, {"pixel_values": x}), inputs[0][0].numpy())
        except Exception as e:
            r["error"] = repr(e)[:500]
            traceback.print_exc()
        res["onnx"][name] = r
        print("onnx", name, r)
except Exception as e:
    res["onnx"]["error"] = repr(e)[:500]
    traceback.print_exc()

(OUT / f"{kind}-bench.json").write_text(json.dumps(res, indent=1))
print(json.dumps(res, indent=1))
