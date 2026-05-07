# Release Wheel

This is the checklist for cutting a wheel release from this repository.

## Inputs

- a built wheel in `$PADDLE_WHEELHOUSE`
- a passing `verify-paddle-rocm-runtime.sh` run captured to JSON
- the verified matrix (or a documented override) in `build-manifest.env`
- the git commit of `model-paddle` that produced the build

## Release Artifact Set

Each release should include:

1. `paddlepaddle_dcu-<...>.whl` — the wheel
2. `verify-output.json` — JSON output of `scripts/verify-paddle-rocm-runtime.sh`
3. `release-manifest.json` — machine-readable build/release metadata
4. `SHA256SUMS` — checksums for the artifacts above
5. Release notes summarizing:
   - Paddle tag
   - ROCm version
   - `AMDGPU_TARGETS`
   - Python ABI
   - `rocminfo` summary line
   - `model-paddle` git commit hash
   - any deviations from the verified matrix

## Tag Format

```text
paddle-<paddle-tag>-rocm<rocm-version>-<gfx-target>-py<abi>
```

Example:

```text
paddle-v3.3.1-rocm7.2-gfx1151-py312
```

If you publish wheels for multiple gfx targets against the same Paddle
+ ROCm + Python combination, append the gfx target to the wheel
filename and bundle them under a single release. Don't cut N parallel
releases for the same matrix.

## Procedure

```bash
# 1. Run the canonical rebuild + verify (sources build-manifest.env,
#    runs detect-host, builds, installs in throwaway venv, verifies).
scripts/rebuild-and-verify-rocm-wheel.sh

# 2. Capture verifier output to a known path. The wrapper prints it to
#    stdout but doesn't persist it; do that explicitly here.
mkdir -p /tmp/model-paddle-release
scripts/verify-paddle-rocm-runtime.sh /tmp/paddle-rocm-verify/bin/python \
  > /tmp/model-paddle-release/verify-output.json

# 3. Generate release-manifest.json + SHA256SUMS next to the wheel.
VERIFY_OUTPUT_PATH=/tmp/model-paddle-release/verify-output.json \
  scripts/write-release-manifest.sh /tmp/model-paddle-release

# 4. Locate the wheel.
WHEEL_PATH="$(find "$HOME/.cache/ledgerlinc/paddle-rocm/wheelhouse" \
  -maxdepth 1 -type f -name 'paddlepaddle_dcu-*.whl' | sort | tail -1)"

# 5. Cut the GitHub Release.
TAG="paddle-v3.3.1-rocm7.2-gfx1151-py312"
gh release create "$TAG" \
  --target main \
  --title "Paddle v3.3.1 ROCm wheel — gfx1151 / ROCm 7.2 / py3.12" \
  --notes-file - <<'EOF' \
  "$WHEEL_PATH" \
  /tmp/model-paddle-release/verify-output.json \
  /tmp/model-paddle-release/release-manifest.json \
  /tmp/model-paddle-release/SHA256SUMS
ROCm-enabled PaddlePaddle wheel built from upstream Paddle v3.3.1.

Verified matrix:
- Paddle: v3.3.1
- ROCm: 7.2.0
- AMDGPU_TARGETS: gfx1151
- Python ABI: 3.12
- Host: AMD Radeon 8060S (Strix Halo APU), WSL2 Ubuntu 24.04

Install:
    pip install <release-asset-url-of-the-wheel>

Smoke check:
    python -c "import paddle; print(paddle.is_compiled_with_rocm())"
EOF
```

## release-manifest.json schema

The release manifest is emitted by
[`scripts/write-release-manifest.sh`](../scripts/write-release-manifest.sh).
Sample shape (consumers can parse this to confirm a wheel is right for
their host without re-running the verifier):

```json
{
  "generated_at_utc": "2026-05-07T01:50:00.123456+00:00",
  "repo_commit": "a3edbfd...",
  "paddle_tag": "v3.3.1",
  "paddle_source_commit": "abc1234...",
  "rocm_path": "/opt/rocm-7.2.0",
  "amdgpu_targets": "gfx1151",
  "python_bin": "python3.12",
  "wheel": {
    "filename": "paddlepaddle_dcu-3.3.0.dev20260319-cp312-cp312-linux_x86_64.whl",
    "path": "/home/.../wheelhouse/paddlepaddle_dcu-...whl",
    "sha256": "fedcba9876..."
  },
  "build_root": "/home/.../paddle-rocm",
  "wheelhouse": "/home/.../paddle-rocm/wheelhouse",
  "host": {
    "device_node": "/dev/dxg",
    "rocminfo_gfx": "gfx1151"
  },
  "verify_output_path": "/tmp/.../verify-output.json",
  "verify_output": { "...": "full JSON from verify-paddle-rocm-runtime.sh" }
}
```

Field stability: `paddle_tag`, `paddle_source_commit`, `rocm_path`,
`amdgpu_targets`, `python_bin`, `wheel.filename`, `wheel.sha256` are
the load-bearing fields. Consumers should pin against `wheel.sha256`
plus the asset URL to detect corruption or accidental re-uploads.

## Consumer Contract

Downstream consumers install via the GitHub Release asset URL:

```bash
pip install https://github.com/opensoft/model-paddle/releases/download/<tag>/paddlepaddle_dcu-<...>.whl
```

For private-repo access the consumer needs `gh auth` (interactive) or
a deploy key / `GH_TOKEN` (CI). One-line CI workflow snippet:

```yaml
- name: Install Paddle ROCm wheel
  env:
    GH_TOKEN: ${{ secrets.MODEL_PADDLE_DEPLOY_TOKEN }}
  run: |
    gh release download paddle-v3.3.1-rocm7.2-gfx1151-py312 \
      --repo opensoft/model-paddle \
      --pattern 'paddlepaddle_dcu-*.whl' \
      --output /tmp/wheel.whl
    pip install /tmp/wheel.whl
```

If a release changes any of:

- Paddle tag
- ROCm version
- gfx target
- Python ABI

…downstream consumers should treat that as a runtime upgrade and
re-validate the new wheel in their own pre-flight / smoke-test before
rolling it into production.
