#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_FILE="${PADDLE_BUILD_MANIFEST:-$ROOT_DIR/build-manifest.env}"
LOCAL_ENV_FILE="${PADDLE_LOCAL_ENV:-$ROOT_DIR/local.env}"
VERIFY_VENV="${PADDLE_VERIFY_VENV:-/tmp/paddle-rocm-verify}"

# Load order (highest precedence first):
#   1. existing shell env  — already set, respected by all `${VAR:-...}` defaults
#   2. local.env           — per-host overrides (gitignored)
#   3. build-manifest.env  — verified-matrix defaults
if [[ -f "$LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
fi
if [[ -f "$MANIFEST_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$MANIFEST_FILE"
fi

log() {
  printf '[paddle-rocm-rebuild] %s\n' "$*"
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

need_cmd bash
need_cmd python3
need_cmd git

log "using manifest: $MANIFEST_FILE"
[[ -f "$LOCAL_ENV_FILE" ]] && log "loaded local overrides: $LOCAL_ENV_FILE"
log "running host self-check"
detect_rc=0
"$ROOT_DIR/scripts/detect-host.sh" || detect_rc=$?
case "$detect_rc" in
  0) log "host self-check: ready" ;;
  2) log "host self-check: ready with warnings — continuing" ;;
  *)
    printf '\n[paddle-rocm-rebuild] host self-check failed (exit %s).\n' "$detect_rc" >&2
    printf '[paddle-rocm-rebuild] Fix the [fail] items above before building.\n' >&2
    exit 4
    ;;
esac

log "running configure"
"$ROOT_DIR/scripts/build-paddle-rocm-wheel.sh" configure

log "running build"
"$ROOT_DIR/scripts/build-paddle-rocm-wheel.sh" build

WHEELHOUSE="${PADDLE_WHEELHOUSE:-$HOME/.cache/model-paddle/paddle-rocm/wheelhouse}"
WHEEL_PATH="$(find "$WHEELHOUSE" -maxdepth 1 -type f -name 'paddlepaddle_dcu-*.whl' | sort | tail -n 1)"
if [[ -z "$WHEEL_PATH" ]]; then
  printf 'no wheel found in %s\n' "$WHEELHOUSE" >&2
  exit 2
fi

PYTHON_BIN="${PYTHON_BIN:-python3.12}"
need_cmd "$PYTHON_BIN"

log "creating verify venv at $VERIFY_VENV"
rm -rf "$VERIFY_VENV"
"$PYTHON_BIN" -m venv "$VERIFY_VENV"
"$VERIFY_VENV/bin/pip" install -U pip
"$VERIFY_VENV/bin/pip" install "$WHEEL_PATH"

log "running runtime verifier"
"$ROOT_DIR/scripts/verify-paddle-rocm-runtime.sh" "$VERIFY_VENV/bin/python"

log "rebuild-and-verify completed"
