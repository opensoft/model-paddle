#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_FILE="${PADDLE_BUILD_MANIFEST:-$ROOT_DIR/build-manifest.env}"
LOCAL_ENV_FILE="${PADDLE_LOCAL_ENV:-$ROOT_DIR/local.env}"

if [[ -f "$LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
fi
if [[ -f "$MANIFEST_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$MANIFEST_FILE"
fi

BUILD_ROOT="${PADDLE_BUILD_ROOT:-$HOME/.cache/model-paddle/paddle-rocm}"
SRC_DIR="${PADDLE_SRC_DIR:-$BUILD_ROOT/Paddle}"
WHEELHOUSE="${PADDLE_WHEELHOUSE:-$BUILD_ROOT/wheelhouse}"
ROCM_PATH_VALUE="${ROCM_PATH:-/opt/rocm-7.2.0}"
PYTHON_BIN_VALUE="${PYTHON_BIN:-python3.12}"
OUT_DIR="${1:-$WHEELHOUSE/release-artifacts}"
VERIFY_OUTPUT_PATH="${VERIFY_OUTPUT_PATH:-$OUT_DIR/verify-output.json}"

mkdir -p "$OUT_DIR"

WHEEL_PATH="${WHEEL_PATH:-}"
if [[ -z "$WHEEL_PATH" ]]; then
  WHEEL_PATH="$(find "$WHEELHOUSE" -maxdepth 1 -type f -name 'paddlepaddle_dcu-*.whl' | sort | tail -n 1)"
fi

if [[ -z "$WHEEL_PATH" || ! -f "$WHEEL_PATH" ]]; then
  printf 'wheel not found\n' >&2
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  printf 'missing required command: sha256sum\n' >&2
  exit 1
fi

WHEEL_SHA256="$(sha256sum "$WHEEL_PATH" | awk '{print $1}')"
WHEEL_BASENAME="$(basename "$WHEEL_PATH")"
REPO_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
PADDLE_SOURCE_COMMIT=""
if [[ -d "$SRC_DIR/.git" ]]; then
  PADDLE_SOURCE_COMMIT="$(git -C "$SRC_DIR" rev-parse HEAD)"
fi

ROCMINFO_GFX_LINE=""
if [[ -x "$ROCM_PATH_VALUE/bin/rocminfo" ]]; then
  ROCMINFO_GFX_LINE="$("$ROCM_PATH_VALUE/bin/rocminfo" 2>/dev/null | grep -m1 -oE 'gfx[0-9a-z]+' || true)"
fi

MANIFEST_JSON="$OUT_DIR/release-manifest.json"
SHA_FILE="$OUT_DIR/SHA256SUMS"

export VERIFY_OUTPUT_PATH REPO_COMMIT PADDLE_SOURCE_COMMIT ROCM_PATH_VALUE PYTHON_BIN_VALUE
export WHEEL_PATH WHEEL_BASENAME WHEEL_SHA256 BUILD_ROOT WHEELHOUSE ROCMINFO_GFX_LINE

"$PYTHON_BIN_VALUE" - "$MANIFEST_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

out_path = Path(sys.argv[1])
verify_path = Path(os.environ["VERIFY_OUTPUT_PATH"])
verify_data = None
if verify_path.is_file():
    try:
        verify_data = json.loads(verify_path.read_text())
    except json.JSONDecodeError:
        verify_data = {"raw_text_path": str(verify_path)}

data = {
    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    "repo_commit": os.environ["REPO_COMMIT"],
    "paddle_tag": os.environ.get("PADDLE_TAG", "v3.3.1"),
    "paddle_source_commit": os.environ.get("PADDLE_SOURCE_COMMIT") or None,
    "rocm_path": os.environ["ROCM_PATH_VALUE"],
    "amdgpu_targets": os.environ.get("AMDGPU_TARGETS", "gfx1151"),
    "python_bin": os.environ["PYTHON_BIN_VALUE"],
    "wheel": {
        "filename": os.environ["WHEEL_BASENAME"],
        "path": os.environ["WHEEL_PATH"],
        "sha256": os.environ["WHEEL_SHA256"],
    },
    "build_root": os.environ["BUILD_ROOT"],
    "wheelhouse": os.environ["WHEELHOUSE"],
    "host": {
        "device_node": "/dev/kfd" if Path("/dev/kfd").exists() else ("/dev/dxg" if Path("/dev/dxg").exists() else None),
        "rocminfo_gfx": os.environ.get("ROCMINFO_GFX_LINE") or None,
    },
    "verify_output_path": str(verify_path) if verify_path.exists() else None,
    "verify_output": verify_data,
}
out_path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
PY

(
  cd "$OUT_DIR"
  printf '%s  %s\n' "$WHEEL_SHA256" "$WHEEL_BASENAME"
  manifest_basename="$(basename "$MANIFEST_JSON")"
  verify_basename="$(basename "$VERIFY_OUTPUT_PATH")"
  [[ -f "$manifest_basename" ]] && sha256sum "$manifest_basename"
  [[ -f "$verify_basename" ]] && sha256sum "$verify_basename"
) >"$SHA_FILE"

printf 'wrote %s\n' "$MANIFEST_JSON"
printf 'wrote %s\n' "$SHA_FILE"
