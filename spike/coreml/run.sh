#!/bin/sh
# Run a spike script with the pinned Python environment.
# usage: ./run.sh convert.py heron | ./run.sh bench.py heron 30 | ./run.sh diag.py heron
cd "$(dirname "$0")" || exit 1
exec uv run --python 3.12 \
  --with torch==2.7.0 --with transformers==5.19.0 --with coremltools==9.0 \
  --with onnxruntime==1.23.2 --with onnx==1.19.1 --with pillow==12.3.0 --with 'numpy==2.3.5' \
  python "$@"
