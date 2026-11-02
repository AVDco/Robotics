#!/usr/bin/env bash
# Build the Astro_dog vision environment on a WSL2 Ubuntu 22.04 host.
#
# Installs the Python stack the vision tools need into
#   Astro_dog/vision/.venv
# and downloads the YOLO weights next to the scripts (both gitignored).
#
#   bash scripts/setup-vision.sh          # idempotent; safe to re-run
#
# Notes
#  * torch comes from the cu128 index because the RTX 5060 Laptop is Blackwell
#    (compute capability sm_120); the default PyPI wheel does not include it.
#  * insightface has no wheel and is compiled here, hence build-essential and
#    python3-dev.
#  * pyrealsense2 comes from PyPI, NOT the Intel apt repo: that repo's GPG key
#    is broken here and jammy has no librealsense2 package.
#  * onnxruntime-gpu is installed LAST and with --no-deps, because insightface
#    declares a dependency on the CPU `onnxruntime` and pip lets that wheel
#    overwrite the GPU one. Both installs succeed and the CPU module silently
#    wins -- see step 5.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VISION="$ROOT/Astro_dog/vision"
VENV="$VISION/.venv"
PY="$VENV/bin/python"

echo "=== [1/6] system build deps ==="
# apt lists go stale on a long-lived image, and a missing package here is a
# confusing pip error two steps later, so refresh them.
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq || exit 1
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
  python3-venv python3-dev build-essential cmake || exit 1

echo "=== [2/6] venv ==="
if [ ! -x "$PY" ]; then
  python3 -m venv "$VENV" || exit 1
fi
"$PY" -V

echo "=== [3/6] pip bootstrap ==="
"$PY" -m pip install -q --upgrade pip wheel setuptools || exit 1

echo "=== [4/6] torch (cu128) + vision packages ==="
"$PY" -m pip install --index-url https://download.pytorch.org/whl/cu128 \
  torch torchvision || exit 1
"$PY" -m pip install ultralytics insightface pyrealsense2 || exit 1

echo "=== [5/6] onnxruntime-gpu (must win over insightface's onnxruntime) ==="
# `pip install insightface onnxruntime-gpu` looks like it works -- both report
# success -- and leaves the CPU `onnxruntime` package installed, which shadows
# the GPU one on import. Every CUDA session then either falls back to the CPU
# or dies. Removing the CPU module first and reinstalling the GPU wheel with
# --no-deps (its dependencies, incl. the nvidia-* CUDA wheels, are already
# satisfied by torch) is what actually makes CUDAExecutionProvider usable.
"$PY" -m pip uninstall -y -q onnxruntime >/dev/null 2>&1
"$PY" -m pip install --no-deps --force-reinstall onnxruntime-gpu || exit 1

echo "=== [6/6] YOLO weights + verify ==="
if [ ! -f "$VISION/yolo11n.pt" ]; then
  ( cd "$VISION" && "$PY" -c \
      "from ultralytics import YOLO; YOLO('yolo11n.pt')" ) || echo "WARN: weight download failed"
fi

cd "$VISION" || exit 1
"$PY" - <<'PY'
import cv2, numpy, torch
print("torch      ", torch.__version__,
      "| cuda:", torch.cuda.is_available(),
      torch.cuda.get_device_name(0) if torch.cuda.is_available() else "-")
print("numpy      ", numpy.__version__)
print("cv2        ", cv2.__version__)
for mod in ("ultralytics", "insightface", "onnxruntime", "pyrealsense2"):
    try:
        m = __import__(mod)
        print(f"{mod:12s}", getattr(m, "__version__", "ok"))
    except Exception as exc:
        print(f"{mod:12s} FAIL: {exc}")
PY

# The listing above is NOT proof the GPU works: get_available_providers() shows
# CUDAExecutionProvider even when its CUDA libraries cannot be resolved, and
# the failure only appears when a session is created. Build a two-node model
# and actually run it. gpu_env.preload() is the same call identity_live makes.
"$PY" - <<'PY'
import numpy as np
import gpu_env, onnx
from onnx import helper, TensorProto

cuda = gpu_env.preload()
print(f"cuda libs   {len(cuda['loaded'])} loaded, {len(cuda['failed'])} failed")
if cuda["failed"]:
    print("            ", cuda["failed"][:3])

import onnxruntime as ort

x = helper.make_tensor_value_info("x", TensorProto.FLOAT, [1, 3])
y = helper.make_tensor_value_info("y", TensorProto.FLOAT, [1, 3])
graph = helper.make_graph([helper.make_node("Relu", ["x"], ["y"])], "g", [x], [y])
model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
# onnx writes IR 14 by default; onnxruntime 1.23 only accepts up to 11.
model.ir_version = 10
onnx.save(model, "/tmp/_vision_gpu_probe.onnx")

sess = ort.InferenceSession("/tmp/_vision_gpu_probe.onnx",
                            providers=["CUDAExecutionProvider", "CPUExecutionProvider"])
active = sess.get_providers()
out = sess.run(None, {"x": np.array([[-1.0, 2.0, -3.0]], dtype=np.float32)})[0]
ok = active[0] == "CUDAExecutionProvider" and out.tolist() == [[0.0, 2.0, 0.0]]
print("ort CUDA    ", "OK" if ok else f"NOT USED (active: {active[0]})")
# Fail the script, not just the log: a CPU-only install looks identical until
# the face stage runs 10x slower than it should.
raise SystemExit(0 if ok else 1)
PY
[ $? -eq 0 ] || exit 1

echo
echo "done. try:"
echo "  $PY $VISION/cam_record.py realsense --probe"
echo "  $PY $VISION/identity_live.py"
