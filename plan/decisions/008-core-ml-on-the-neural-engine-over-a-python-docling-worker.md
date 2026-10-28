# 008. Core ML on the Neural Engine over a Python Docling worker

Decided: 2026-10-14    Status: current

Layout models run as Core ML models on the Neural Engine. This keeps the tool one binary, with no Python.

| Option | For | Against |
|---|---|---|
| **Core ML** | Uses the Neural Engine, and ships inside the binary. | Some models fail to convert. Apple decides whether a model runs on the Neural Engine. |
| MLX | Apple's own machine-learning framework, with a Swift API. | Each model must be ported. It runs on the GPU. |
| ONNX Runtime | Runs almost any exported model. | One more runtime to bundle. |
| Python Docling worker | A proven pipeline, under MIT. | Brings back Python and PyTorch, a gigabyte-scale install and seconds of model loading. |

When a model fails to convert to Core ML, the fallback is MLX first, then ONNX Runtime. Model weights come only from licences that allow use in a public repo.

The M0 spike converted Docling's two layout models, heron and egret-medium, both under Apache-2.0 ([spike/M0.4-coreml.md](../../spike/M0.4-coreml.md)). Full precision matched PyTorch exactly. Mixed precision on all compute units ran in 15–29 ms per page and missed about 1 region in 100. Plain half precision gave wrong results on the CPU and the Neural Engine. Swift compiled and loaded the models without Xcode.
