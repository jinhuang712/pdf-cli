"""Shared helpers for the M0.4 Core ML spike.

Loads the real Docling layout models from the local Hugging Face cache only
(HF_HUB_OFFLINE=1). (A first run used random weights because huggingface.co
was unreachable from the agent's network.)
"""
import os

os.environ["HF_HUB_OFFLINE"] = "1"  # read only from ~/.cache/huggingface/hub

import pathlib

import numpy as np
import torch
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / "out" / "coreml"
PAGES = sorted((OUT / "pages-real").glob("*.png"))
SIZE = 640

REPOS = {
    "heron": "docling-project/docling-layout-heron",
    "egret": "docling-project/docling-layout-egret-medium",
}
# Filled from the loaded config's id2label.
LABELS: list = []


def load(kind: str):
    from transformers import AutoConfig, AutoModelForObjectDetection
    cfg = AutoConfig.from_pretrained(REPOS[kind])
    # Precompute anchors as a buffer (same values as the runtime path for a
    # 640x640 input); the runtime path does an in-place copy coremltools rejects.
    cfg.anchor_image_size = [SIZE, SIZE]
    m = AutoModelForObjectDetection.from_pretrained(REPOS[kind], config=cfg).eval()
    LABELS[:] = [cfg.id2label[i] for i in range(len(cfg.id2label))]
    return m


def preprocess(path):
    """RTDetrImageProcessor defaults: resize to 640x640 bilinear, /255, no normalisation."""
    img = Image.open(path).convert("RGB")
    w, h = img.size
    x = np.asarray(img.resize((SIZE, SIZE), Image.BILINEAR), dtype=np.float32) / 255.0
    return torch.from_numpy(x.transpose(2, 0, 1)[None].copy()), (w, h)


class Net(torch.nn.Module):
    """pixel_values -> (logits, pred_boxes); no post-processing."""

    def __init__(self, m):
        super().__init__()
        self.m = m
        if os.environ.get("NOPATCH"):
            return
        # Fixed 640x640 input: make transformers' torch_int() return Python ints so
        # feature-map sizes become trace-time constants (otherwise coremltools fails
        # on an `int` cast of a 1-element tensor in the AIFI position embedding).
        import importlib
        for mod in ("transformers.models.rt_detr_v2.modeling_rt_detr_v2",
                    "transformers.models.d_fine.modeling_d_fine"):
            mm = importlib.import_module(mod)
            mm.torch_int = int
            # Precompute the 2D sine position embedding (an int/fp `outer` that
            # coremltools rejects) so the trace sees a constant tensor.
            for cls_name in ("RTDetrV2SinePositionEmbedding", "DFineSinePositionEmbedding"):
                cls = getattr(mm, cls_name, None)
                if cls is None or getattr(cls, "_patched", False):
                    continue
                orig = cls.forward
                cache = {}

                def fwd(self, width, height, device, dtype, _orig=orig, _cache=cache):
                    key = (int(width), int(height), id(self))
                    if key not in _cache:
                        # filled by an eager warm-up call before tracing
                        _cache[key] = _orig(self, int(width), int(height), device, dtype).detach().clone()
                    return _cache[key]

                cls.forward = fwd
                cls._patched = True
            # D-FINE: F.linear with a 1-D weight (the bin-weighting vector) hits
            # an assert in coremltools' linear op; use an equivalent mul+sum.
            integ = getattr(mm, "DFineIntegral", None)
            if integ is not None and not getattr(integ, "_patched", False):
                def integ_fwd(self, pred_corners, project):
                    b, q, _ = pred_corners.shape
                    p = torch.softmax(pred_corners.reshape(-1, self.max_num_bins + 1), dim=1)
                    return (p * project.to(p.device)).sum(-1).reshape(b, q, -1)

                integ.forward = integ_fwd
                integ._patched = True
            # Deformable attention takes spatial shapes as traced 0-d tensors;
            # turn them into Python ints so split sizes/reshapes are constants.
            for fn_name in ("multi_scale_deformable_attention_v2",):
                fn = getattr(mm, fn_name, None)
                if fn is None or getattr(fn, "_patched", False):
                    continue

                # int() on a traced tensor still emits aten::Int, so use the
                # constant sizes implied by the fixed input and the strides.
                shapes = [(SIZE // s, SIZE // s) for s in m.config.feat_strides]

                def wrapped(value, value_spatial_shapes, *a, _fn=fn, _shapes=shapes, **k):
                    assert len(value_spatial_shapes) == len(_shapes)
                    return _fn(value, _shapes, *a, **k)

                wrapped._patched = True
                setattr(mm, fn_name, wrapped)

    def forward(self, pixel_values):
        o = self.m(pixel_values=pixel_values)
        lg = o.intermediate_logits
        if not os.environ.get("NO_SELECT_FIX") and lg is not None and lg.shape[1] == 1:
            # D-FINE in eval stacks only the last decoder layer's logits, then
            # takes [:, -1] of a size-1 axis. Core ML's CPU backend returns
            # wrong values for that select (probe_egret_cpu.py), so reshape.
            return lg.reshape(lg.shape[0], lg.shape[2], lg.shape[3]), o.pred_boxes
        return o.logits, o.pred_boxes


def postprocess(logits, boxes, wh, thr=0.0, topk=20):
    """Sigmoid focal-style scoring as in RTDetrImageProcessor.post_process_object_detection."""
    logits = np.asarray(logits, dtype=np.float32)[0]
    boxes = np.asarray(boxes, dtype=np.float32)[0]
    scores = 1 / (1 + np.exp(-logits))
    flat = scores.reshape(-1)
    idx = np.argsort(-flat)[:topk]
    q, c = np.unravel_index(idx, scores.shape)
    w, h = wh
    cx, cy, bw, bh = boxes[q].T
    xyxy = np.stack([(cx - bw / 2) * w, (cy - bh / 2) * h, (cx + bw / 2) * w, (cy + bh / 2) * h], 1)
    return [(LABELS[ci], float(flat[i]), xyxy[k].round(1).tolist())
            for k, (i, ci) in enumerate(zip(idx, c)) if flat[i] >= thr]


def iou(a, b):
    ix = max(0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    ua = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter
    return inter / ua if ua > 0 else 0.0


def size_of(p):
    p = pathlib.Path(p)
    if p.is_file():
        return p.stat().st_size
    return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
