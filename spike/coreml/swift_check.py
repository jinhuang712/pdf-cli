"""Check Swift (swift_load.swift) outputs against PyTorch on a real page.

usage: python swift_check.py prep              -> writes OUT/tmp/page0.bin (preprocessed page 0)
       python swift_check.py check heron|egret -> compares OUT/tmp/page0.bin.swiftout with PyTorch
"""
import sys

import numpy as np
import torch

from common import OUT, PAGES, Net, iou, load, postprocess, preprocess

x, wh = preprocess(PAGES[0])
src = OUT / "tmp" / "page0.bin"
if sys.argv[1] == "prep":
    src.parent.mkdir(exist_ok=True)
    x.numpy().astype("<f4").tofile(src)
    print("wrote", src, PAGES[0].name)
else:
    net = Net(load(sys.argv[2])).eval()
    with torch.no_grad():
        rl, rb = [t.numpy() for t in net(x)]
    raw = np.fromfile(str(src) + ".swiftout", dtype="<f4")
    gl = raw[: rl.size].reshape(rl.shape)
    gb = raw[rl.size:].reshape(rb.shape)
    r5 = postprocess(rl, rb, wh, thr=0.5, topk=300)
    g5 = postprocess(gl, gb, wh, thr=0.5, topk=300)
    m = sum(any(a[0] == b[0] and iou(a[2], b[2]) > 0.9 for b in g5) for a in r5)
    print(f"swift vs torch: logits maxabs {np.abs(gl - rl).max():.4g}, boxes maxabs {np.abs(gb - rb).max():.4g}, "
          f"det>=0.5 matched {m}/{len(r5)} (swift {len(g5)})")
