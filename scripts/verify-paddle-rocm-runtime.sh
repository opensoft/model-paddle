#!/usr/bin/env bash
set -Eeuo pipefail

# Verify that a Python environment contains a ROCm-enabled Paddle build and
# can bind to gpu:0 on the current workstation.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-${1:-$ROOT_DIR/.venv-paddle-rocm/bin/python}}"
ROCM_PATH_VALUE="${ROCM_PATH:-/opt/rocm-7.2.0}"

if [[ ! -x "$PYTHON_BIN" ]]; then
  printf 'python interpreter not executable: %s\n' "$PYTHON_BIN" >&2
  exit 2
fi

export ROCM_PATH="$ROCM_PATH_VALUE"
export HIP_PATH="$ROCM_PATH_VALUE"
export HSA_ENABLE_DXG_DETECTION="${HSA_ENABLE_DXG_DETECTION:-1}"
export HSA_ENABLE_SDMA="${HSA_ENABLE_SDMA:-0}"
export MIOPEN_FIND_MODE="${MIOPEN_FIND_MODE:-2}"
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib/llvm/lib:${LD_LIBRARY_PATH:-}"
if [[ -f "$ROCM_PATH/lib/libhsa-runtime64.so.1" ]]; then
  export LD_PRELOAD="$ROCM_PATH/lib/libhsa-runtime64.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
fi

"$PYTHON_BIN" - <<'PY'
import json
import sys
from importlib import metadata

out = {
    "python": sys.executable,
    "python_version": sys.version.split()[0],
}

try:
    import paddle
except Exception as exc:
    out.update({"state": "paddle_import_failed", "error": repr(exc)})
    print(json.dumps(out, indent=2, sort_keys=True))
    raise SystemExit(10)

def paddle_distribution_version():
    for name in ("paddlepaddle", "paddlepaddle-gpu", "paddlepaddle-dcu"):
        try:
            return metadata.version(name)
        except metadata.PackageNotFoundError:
            continue
    return getattr(paddle, "__version__", None)


out.update(
    {
        "paddle_version": getattr(paddle, "__version__", None),
        "paddle_distribution_version": paddle_distribution_version(),
        "compiled_with_cuda": bool(paddle.is_compiled_with_cuda()),
        "compiled_with_rocm": bool(paddle.is_compiled_with_rocm()),
    }
)

try:
    out["device_count"] = int(paddle.device.cuda.device_count())
except Exception as exc:
    out["device_count_error"] = repr(exc)
    out["device_count"] = 0

if not out["compiled_with_rocm"]:
    out["state"] = "paddle_not_rocm_enabled"
    print(json.dumps(out, indent=2, sort_keys=True))
    raise SystemExit(11)

if out["device_count"] < 1:
    out["state"] = "gpu_not_visible_to_paddle"
    print(json.dumps(out, indent=2, sort_keys=True))
    raise SystemExit(12)

try:
    paddle.device.set_device("gpu:0")
    x = paddle.to_tensor([1.0, 2.0, 3.0])
    y = (x * 2).numpy().tolist()
    out["tensor_probe"] = y
except Exception as exc:
    out.update({"state": "gpu_bind_failed", "error": repr(exc)})
    print(json.dumps(out, indent=2, sort_keys=True))
    raise SystemExit(13)

out["state"] = "paddle_rocm_bind_succeeded"
print(json.dumps(out, indent=2, sort_keys=True))
PY
