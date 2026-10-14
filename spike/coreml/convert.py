"""Trace the network and convert it to Core ML (mlprogram, fp32 and fp16).

usage: python convert.py heron|egret
"""
import sys
import time
import traceback

import coremltools as ct
import numpy as np
import torch

from common import OUT, SIZE, Net, load, size_of

kind = sys.argv[1]
net = Net(load(kind)).eval()
x = torch.rand(1, 3, SIZE, SIZE)

t = time.perf_counter()
with torch.no_grad():
    net(x)  # eager warm-up fills the position-embedding cache (see common.Net)
    if "--export" in sys.argv:
        traced = torch.export.export(net, (x,), strict=False).run_decompositions({})
    else:
        traced = torch.jit.trace(net, x, strict=False, check_trace=False)
print(f"{'export' if '--export' in sys.argv else 'trace'} ok {time.perf_counter() - t:.1f}s")

for prec in ("fp32", "fp16"):
    dst = OUT / f"{kind}-{prec}.mlpackage"
    t = time.perf_counter()
    try:
        ml = ct.convert(
            traced,
            inputs=None if "--export" in sys.argv else [ct.TensorType(name="pixel_values", shape=(1, 3, SIZE, SIZE), dtype=np.float32)],
            outputs=[ct.TensorType(name="logits"), ct.TensorType(name="pred_boxes")],
            convert_to="mlprogram",
            compute_precision=ct.precision.FLOAT32 if prec == "fp32" else ct.precision.FLOAT16,
            minimum_deployment_target=ct.target.macOS14,
        )
        ml.save(str(dst))
        print(f"{prec} convert ok {time.perf_counter() - t:.1f}s size={size_of(dst) / 1e6:.1f}MB")
    except Exception:
        print(f"{prec} convert FAILED after {time.perf_counter() - t:.1f}s")
        traceback.print_exc()
