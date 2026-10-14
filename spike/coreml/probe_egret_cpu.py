"""Probe: shape of egret's Core ML CPU logit error (per-query constant => LQE quality term).
usage: python probe_egret_cpu.py"""
import coremltools as ct
import numpy as np
import torch

from common import OUT, PAGES, Net, load, preprocess

net = Net(load("egret")).eval()
x, _ = preprocess(PAGES[0])
with torch.no_grad():
    ref = net(x)[0].numpy()[0]
for cu in ("CPU_ONLY", "CPU_AND_GPU"):
    ml = ct.models.MLModel(str(OUT / "egret-fp32.mlpackage"), compute_units=getattr(ct.ComputeUnit, cu))
    got = ml.predict({"pixel_values": x.numpy()})["logits"][0]
    d = got - ref
    print(cu, "mean |d|", float(np.abs(d).mean()),
          "| per-query spread of d across classes (max-min), median:", float(np.median(d.max(1) - d.min(1))),
          "| median per-query mean d:", float(np.median(d.mean(1))))


# Expose decoder internals and compare on CPU.
class Inner(Net):
    def forward(self, pixel_values):
        o = self.m(pixel_values=pixel_values)
        return o.last_hidden_state, o.intermediate_logits, o.logits


inner = Inner(net.m).eval()
with torch.no_grad():
    refs = [t.numpy() for t in inner(x)]
    tr = torch.jit.trace(inner, x, strict=False, check_trace=False)
ml = ct.convert(tr, inputs=[ct.TensorType(name="pixel_values", shape=x.shape)],
                outputs=[ct.TensorType(name="hidden"), ct.TensorType(name="inter"), ct.TensorType(name="logits")],
                convert_to="mlprogram", compute_precision=ct.precision.FLOAT32,
                minimum_deployment_target=ct.target.macOS14)
ml.save(str(OUT / "tmp" / "egret-inner.mlpackage"))
m2 = ct.models.MLModel(str(OUT / "tmp" / "egret-inner.mlpackage"), compute_units=ct.ComputeUnit.CPU_ONLY)
o = m2.predict({"pixel_values": x.numpy()})
for name, r in zip(("hidden", "inter", "logits"), refs):
    g = o[name]
    if name == "inter":
        for i in range(r.shape[1]):
            print("inner", name, "layer", i, "mean|d|", float(np.abs(g[:, i] - r[:, i]).mean()))
    else:
        print("inner", name, r.shape, "mean|d|", float(np.abs(g - r).mean()))
c = net.m.class_embed[-1] if hasattr(net.m, "class_embed") else net.m.model.decoder.class_embed[-1]
with torch.no_grad():
    lin = c(torch.from_numpy(o["hidden"])).numpy()
print("inner class_embed(coreml hidden) vs coreml logits mean|d|", float(np.abs(lin - o["logits"]).mean()),
      "vs torch logits", float(np.abs(lin - refs[2]).mean()))
