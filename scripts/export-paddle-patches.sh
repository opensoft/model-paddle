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
PADDLE_TAG_VALUE="${PADDLE_TAG:-v3.3.1}"
PATCH_DIR="$ROOT_DIR/patches"
PATCH_BASENAME="${PADDLE_PATCH_BASENAME:-0001-paddle-${PADDLE_TAG_VALUE#v}-rocm.patch}"
PATCH_FILE="$PATCH_DIR/$PATCH_BASENAME"
SERIES_FILE="$PATCH_DIR/series"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  cat >&2 <<EOF
prepared Paddle source tree not found at: $SRC_DIR

The export script reads the diff between the patched Paddle checkout and its
upstream tag. You need to run prepare/configure/build first so the build
script applies its inline patches:

  scripts/build-paddle-rocm-wheel.sh prepare

Then re-run this script.
EOF
  exit 1
fi

mkdir -p "$PATCH_DIR"
git -C "$SRC_DIR" diff --binary --full-index --no-ext-diff >"$PATCH_FILE"

if [[ ! -s "$PATCH_FILE" ]]; then
  cat >&2 <<EOF
no source diff found in: $SRC_DIR

The Paddle source tree at that path matches its upstream tag exactly. That
means the build script has not patched it yet, or the patches were reset.
Run:

  scripts/build-paddle-rocm-wheel.sh prepare

(or 'configure' / 'build') to apply the inline patches, then re-run this
script.
EOF
  rm -f "$PATCH_FILE"
  exit 2
fi

printf '%s\n' "$PATCH_BASENAME" >"$SERIES_FILE"
printf 'wrote %s\n' "$PATCH_FILE"
printf 'updated %s\n' "$SERIES_FILE"
