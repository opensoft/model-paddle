#!/usr/bin/env bash
# Cut a GitHub Release for a built wheel. Run on the host where the wheel
# was built. Captures verifier JSON, generates release-manifest.json +
# SHA256SUMS, then `gh release create`s with the four artifacts.
#
# Usage:
#   scripts/cut-release.sh                  # uses build-manifest.env defaults
#   scripts/cut-release.sh --dry-run        # generate artifacts, skip the GH upload
#
# Required tools on PATH: gh, sha256sum, the python interpreter from
# build-manifest.env (default python3.12).

set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCAL_ENV_FILE="${PADDLE_LOCAL_ENV:-$ROOT_DIR/local.env}"
MANIFEST_FILE="${PADDLE_BUILD_MANIFEST:-$ROOT_DIR/build-manifest.env}"
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/cut-release.sh [--dry-run]

Reads:
  - $PADDLE_WHEELHOUSE/paddlepaddle_dcu-*.whl  (the built wheel)
  - build-manifest.env / local.env             (matrix + paths)

Writes (under /tmp/model-paddle-release/):
  - verify-output.json        (capture from verify-paddle-rocm-runtime.sh)
  - release-manifest.json     (build/release metadata)
  - SHA256SUMS                (checksums)
  - release-notes.md          (auto-generated, edit before final upload if you want)

Then (unless --dry-run):
  - gh release create $TAG with the wheel + the three sidecars + release-notes
EOF
      exit 0
      ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ -f "$LOCAL_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV_FILE"
fi
if [[ -f "$MANIFEST_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$MANIFEST_FILE"
fi

WHEELHOUSE="${PADDLE_WHEELHOUSE:-$HOME/.cache/model-paddle/paddle-rocm/wheelhouse}"
PYTHON_BIN="${PYTHON_BIN:-python3.12}"
ROCM_PATH_VALUE="${ROCM_PATH:-/opt/rocm-7.2.0}"
PADDLE_TAG_VALUE="${PADDLE_TAG:-v3.3.1}"
GFX_TARGET="${AMDGPU_TARGETS:-gfx1151}"

OUT_DIR="${RELEASE_OUT_DIR:-/tmp/model-paddle-release}"
VERIFY_VENV="${RELEASE_VERIFY_VENV:-/tmp/paddle-rocm-release}"

log() { printf '[cut-release] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || { printf 'missing required command: %s\n' "$1" >&2; exit 1; }; }

need "$PYTHON_BIN"
need sha256sum
if (( DRY_RUN == 0 )); then
  need gh
  if ! gh auth status >/dev/null 2>&1; then
    printf 'gh CLI not authenticated. Run: gh auth login\n' >&2
    exit 1
  fi
fi

WHEEL_PATH="$(find "$WHEELHOUSE" -maxdepth 1 -type f -name 'paddlepaddle_dcu-*.whl' | sort | tail -n 1)"
if [[ -z "$WHEEL_PATH" || ! -f "$WHEEL_PATH" ]]; then
  printf 'no paddlepaddle_dcu-*.whl in %s\n' "$WHEELHOUSE" >&2
  printf 'run scripts/rebuild-and-verify-rocm-wheel.sh first.\n' >&2
  exit 1
fi
WHEEL_BASENAME="$(basename "$WHEEL_PATH")"
log "wheel: $WHEEL_PATH"

mkdir -p "$OUT_DIR"

log "creating release verify venv at $VERIFY_VENV"
rm -rf "$VERIFY_VENV"
"$PYTHON_BIN" -m venv "$VERIFY_VENV"
"$VERIFY_VENV/bin/pip" install -U -q pip
"$VERIFY_VENV/bin/pip" install -q "$WHEEL_PATH"

VERIFY_OUTPUT_PATH="$OUT_DIR/verify-output.json"
log "running verifier, capturing to $VERIFY_OUTPUT_PATH"
"$ROOT_DIR/scripts/verify-paddle-rocm-runtime.sh" "$VERIFY_VENV/bin/python" \
  > "$VERIFY_OUTPUT_PATH"

# Sanity-check the verifier output before continuing.
if ! grep -q '"state": "paddle_rocm_bind_succeeded"' "$VERIFY_OUTPUT_PATH"; then
  printf 'verifier did NOT report paddle_rocm_bind_succeeded; refusing to release.\n' >&2
  cat "$VERIFY_OUTPUT_PATH" >&2
  exit 3
fi
log "verifier: paddle_rocm_bind_succeeded"

log "writing release-manifest.json + SHA256SUMS"
VERIFY_OUTPUT_PATH="$VERIFY_OUTPUT_PATH" \
  "$ROOT_DIR/scripts/write-release-manifest.sh" "$OUT_DIR"

# Compute the release tag from the matrix + a normalized ROCm version.
ROCM_VERSION_SHORT="$(printf '%s' "${ROCM_PATH_VALUE##*/rocm-}" | awk -F. '{print $1"."$2}')"
PYABI="$("$PYTHON_BIN" -c 'import sys; print(f"py{sys.version_info[0]}{sys.version_info[1]}")')"
TAG="paddle-${PADDLE_TAG_VALUE}-rocm${ROCM_VERSION_SHORT}-${GFX_TARGET}-${PYABI}"
log "release tag: $TAG"

ROCMINFO_GFX_LINE=""
if [[ -x "$ROCM_PATH_VALUE/bin/rocminfo" ]]; then
  ROCMINFO_GFX_LINE="$("$ROCM_PATH_VALUE/bin/rocminfo" 2>/dev/null | grep -m1 -oE 'gfx[0-9a-z]+' || true)"
fi
REPO_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

NOTES_FILE="$OUT_DIR/release-notes.md"
cat >"$NOTES_FILE" <<EOF
ROCm-enabled PaddlePaddle wheel built from upstream Paddle ${PADDLE_TAG_VALUE}.

## Verified matrix

- Paddle: ${PADDLE_TAG_VALUE}
- ROCm: ${ROCM_PATH_VALUE} (${ROCM_VERSION_SHORT}.x)
- AMDGPU_TARGETS: ${GFX_TARGET}
- Python ABI: ${PYABI}
- rocminfo gfx: ${ROCMINFO_GFX_LINE:-unknown}
- model-paddle commit: ${REPO_COMMIT}

## Install

\`\`\`bash
pip install https://github.com/opensoft/model-paddle/releases/download/${TAG}/${WHEEL_BASENAME}
\`\`\`

## Smoke check

\`\`\`bash
python -c "import paddle; print('rocm:', paddle.is_compiled_with_rocm())"
python -c "import paddle; print('devices:', paddle.device.cuda.device_count())"
python -c "import paddle; paddle.utils.run_check()"
\`\`\`

## Artifacts

- \`${WHEEL_BASENAME}\` — the wheel
- \`verify-output.json\` — verifier JSON captured at release time
- \`release-manifest.json\` — machine-readable build metadata
- \`SHA256SUMS\` — checksums for all three above

See [docs/release-wheel.md](https://github.com/opensoft/model-paddle/blob/main/docs/release-wheel.md)
for the manifest schema. Pin downstream consumers to this asset URL.
EOF

log "release notes drafted at $NOTES_FILE"

if (( DRY_RUN == 1 )); then
  log "dry-run: skipping gh release create"
  log "to publish:"
  log "  gh release create $TAG --target main \\"
  log "    --title \"Paddle ${PADDLE_TAG_VALUE} ROCm wheel — ${GFX_TARGET} / ROCm ${ROCM_VERSION_SHORT} / ${PYABI}\" \\"
  log "    --notes-file $NOTES_FILE \\"
  log "    \"$WHEEL_PATH\" \\"
  log "    \"$OUT_DIR/verify-output.json\" \\"
  log "    \"$OUT_DIR/release-manifest.json\" \\"
  log "    \"$OUT_DIR/SHA256SUMS\""
  exit 0
fi

log "creating GitHub release $TAG"
gh release create "$TAG" \
  --target main \
  --title "Paddle ${PADDLE_TAG_VALUE} ROCm wheel — ${GFX_TARGET} / ROCm ${ROCM_VERSION_SHORT} / ${PYABI}" \
  --notes-file "$NOTES_FILE" \
  --repo opensoft/model-paddle \
  "$WHEEL_PATH" \
  "$OUT_DIR/verify-output.json" \
  "$OUT_DIR/release-manifest.json" \
  "$OUT_DIR/SHA256SUMS"

log "release created. URL:"
gh release view "$TAG" --repo opensoft/model-paddle --json url --jq '.url'
