# Rebuild ROCm Wheel

This document is the shortest reliable path for rebuilding the
ROCm-enabled Paddle wheel, with prerequisites, success criteria, and
troubleshooting for the failures you're most likely to actually hit.

For the deeper runbook (patch rationale, build variables, packaging
details), see [`source-build.md`](./source-build.md).

## Supported Matrix

Source of truth: [`../build-manifest.env`](../build-manifest.env)

- Paddle tag: `v3.3.1`
- ROCm path: `/opt/rocm-7.2.0` (override per-host via `ROCM_PATH`)
- AMD GPU target: `gfx1151` (override per-host via `AMDGPU_TARGETS`)
- Python ABI: `3.12`
- Host model: Linux or WSL2 with a visible ROCm-capable device

If your host doesn't match exactly, `scripts/detect-host.sh` will tell
you what env vars to set. The verified matrix is reproduced when you
run `rebuild-and-verify-rocm-wheel.sh` with no overrides; any other
host is a documented experiment until the verifier passes there.

## Host Prerequisites

Required commands:

- `git`
- `python3.12`
- `cmake`
- `pip` (ships with the Python interpreter)
- `bash`
- ROCm LLVM toolchain at `$ROCM_PATH/llvm/bin/amdclang` and
  `$ROCM_PATH/llvm/bin/amdclang++`

Required host signals (use `$ROCM_PATH` from your manifest, not the
literal `/opt/rocm-7.2.0` — that path is just the verified default):

- `test -d "$ROCM_PATH"`
- `test -e /dev/kfd` (native Linux) **or** `test -e /dev/dxg` (WSL2)
- `python3.12 --version` succeeds
- `"$ROCM_PATH/bin/rocminfo"` succeeds and reports a `gfx*` line

Use the host self-check (recommended over running these manually):

```bash
scripts/detect-host.sh
```

Exit code: `0` ready, `2` ready with warnings, `1`/other = critical
fail. The rebuild wrapper aborts if detect-host returns critical fail.

## Unsupported / Not Yet Supported

- Docker Desktop container builds (no native ROCm device-stack
  exposure on Windows-side WSL2).
- Building from inside `py-bench` or any container without a mapped
  ROCm device.
- Hosts with no visible ROCm device stack (`/dev/kfd` and `/dev/dxg`
  both missing).
- ROCm versions outside the verified `7.x` band — may work, expect to
  do additional patch work; see the patch inventory.

## Canonical Rebuild Flow

One command (recommended). Sources `build-manifest.env`, sources
`local.env` if present, runs detect-host (aborts on fail), then
configure → build → throwaway-venv install → verifier:

```bash
scripts/rebuild-and-verify-rocm-wheel.sh
```

Manual phase split (if you want to inspect each step):

```bash
# Sourcing the manifest is optional — the build script reads the same
# env vars directly. Useful if you want to print the active matrix:
source build-manifest.env

# Phase 1: clone Paddle outside the repo, apply the inline patches.
# Useful on its own when you want to inspect the patched source without
# committing to a full configure.
scripts/build-paddle-rocm-wheel.sh prepare

# Phase 2: CMake configure (re-runs prepare if needed).
scripts/build-paddle-rocm-wheel.sh configure

# Phase 3: full build + wheel packaging (re-runs configure if needed).
# CMAKE_BUILD_PARALLEL_LEVEL defaults to nproc/2 (min 2). Lower it to
# CMAKE_BUILD_PARALLEL_LEVEL=4 (or even 2) on hosts with ≤16 GB RAM —
# the libpaddle.so link step alone needs 12–16 GB.
scripts/build-paddle-rocm-wheel.sh build

# Verify against any Python venv that has the wheel installed.
python3.12 -m venv /tmp/paddle-rocm-test
/tmp/paddle-rocm-test/bin/pip install -U pip
/tmp/paddle-rocm-test/bin/pip install \
  "$HOME/.cache/ledgerlinc/paddle-rocm/wheelhouse"/paddlepaddle_dcu-*.whl
scripts/verify-paddle-rocm-runtime.sh /tmp/paddle-rocm-test/bin/python
```

## Success Criteria

The rebuild is considered successful only if all of these hold:

1. The build script exits `0`.
2. A `paddlepaddle_dcu-*.whl` is present in
   `$PADDLE_WHEELHOUSE` (default `~/.cache/ledgerlinc/paddle-rocm/wheelhouse/`).
3. `verify-paddle-rocm-runtime.sh` emits:
   - `"state": "paddle_rocm_bind_succeeded"`
   - `"compiled_with_rocm": true`
   - `"device_count": 1` or higher
4. The verify probe executes a tensor on `gpu:0` (the JSON includes
   the `tensor_probe` array).

## Output Locations

Default external build root (override via `PADDLE_BUILD_ROOT` in
`local.env`):

```text
~/.cache/ledgerlinc/paddle-rocm/
```

Default wheelhouse:

```text
~/.cache/ledgerlinc/paddle-rocm/wheelhouse/
```

This repo intentionally does not build into the repository tree and
does not modify any consumer's `.venv`.

## Clean Rebuild

To invalidate everything:

```bash
rm -rf ~/.cache/ledgerlinc/paddle-rocm
scripts/rebuild-and-verify-rocm-wheel.sh
```

Use a clean rebuild when you change:

- `PADDLE_TAG`
- `ROCM_PATH` (different ROCm version)
- `AMDGPU_TARGETS` (different gfx target)
- `PYTHON_BIN`
- patch logic in the build script

## Troubleshooting

### `scripts/detect-host.sh` reports `[fail] No ROCm install found`

ROCm is not installed at any `/opt/rocm-*` path. Install it from
[AMD's official guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-overview.html).
On Ubuntu 22.04/24.04, the supported install adds AMD's apt repo and
runs `apt install rocm-dev`. After install, re-run `detect-host.sh`.

### `rocminfo` runs but reports no `gfx*` line

The kernel driver is not seeing the GPU.

- **Native Linux**: `lsmod | grep amdgpu` should show the module loaded.
  Run `dmesg | grep -i amdgpu` for the device init log.
- **WSL2**: confirm you're on WSL2 (`uname -r` should contain
  `WSL2`) and that the Windows-side AMD Adrenalin driver is recent
  enough to expose the GPU to WSL via `/dev/dxg`.

### CMake says `ROCm not found` even though `/opt/rocm-X.Y/` exists

Set both `ROCM_PATH` and `HIP_PATH`:

```bash
export ROCM_PATH=/opt/rocm-7.2.0
export HIP_PATH=/opt/rocm-7.2.0
scripts/build-paddle-rocm-wheel.sh configure
```

Some Paddle CMake stubs check `HIP_PATH` independently; the patch in
this repo handles the common case but explicit env helps on
non-standard layouts.

### Configure succeeds, build fails compiling ROCm headers

Symptoms: errors in `paddle/phi/...` or `paddle/fluid/...` mentioning
`rocprim`, `thrust`, `__device__`, or `unsupported AMD GPU builtin`.

The build is using `gcc` instead of `amdclang` for host C++. Plain GCC
fails when ROCm device-side headers leak into host translation units.
Set the host compilers explicitly:

```bash
export PADDLE_HOST_CC=$ROCM_PATH/llvm/bin/amdclang
export PADDLE_HOST_CXX=$ROCM_PATH/llvm/bin/amdclang++
```

`build-manifest.env` sets these by default. Verify they made it through
with `echo $PADDLE_HOST_CC`.

### `fatal error: 'rocprim/...' file not found` (or similar)

Either the wrong gfx target (the build is offloading to a target the
ROCm install doesn't have headers for), or `ROCM_PATH` is wrong.

```bash
scripts/detect-host.sh   # reports your detected gfx target + ROCm path
```

Then re-run with the printed override (e.g.
`AMDGPU_TARGETS=gfx1100 ROCM_PATH=/opt/rocm-7.0.0 scripts/rebuild-and-verify-rocm-wheel.sh`).

### Link-time OOM (kernel kills `ld.lld` or `clang++`)

Symptoms: build runs for ~1 hour and then dies during the final link
of `libpaddle.so` with `Killed` or `error: write to file failed: No
space left on device`.

The link of `libpaddle.so` alone needs 12–16 GB of RAM. Multi-job link
multiplies that.

```bash
CMAKE_BUILD_PARALLEL_LEVEL=2 scripts/build-paddle-rocm-wheel.sh build
# or, on very low RAM:
CMAKE_BUILD_PARALLEL_LEVEL=1 scripts/build-paddle-rocm-wheel.sh build
```

Alternative: add swap before building (`fallocate -l 16G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile`).

### Wheel builds, but `import paddle` segfaults

Common on WSL2 / `gfx1151` hosts: the patched binary needs the host
ROCm runtime preloaded ahead of bundled libraries. The same fix that
applies to Ollama's WSL ROCm path applies here:

```bash
export LD_LIBRARY_PATH=$ROCM_PATH/lib:$ROCM_PATH/lib/llvm/lib:${LD_LIBRARY_PATH:-}
export LD_PRELOAD=$ROCM_PATH/lib/libhsa-runtime64.so.1${LD_PRELOAD:+:$LD_PRELOAD}
export HSA_ENABLE_DXG_DETECTION=1
export HSA_ENABLE_SDMA=0
python -c "import paddle; print(paddle.is_compiled_with_rocm())"
```

If that fixes it, capture those env exports in a host-local startup
script. The verifier (`scripts/verify-paddle-rocm-runtime.sh`) sets
these automatically.

### Wheel builds and verifies, but PaddleX or PaddleOCR rejects it

Symptoms: `RuntimeError: paddle.fluid.core_avx not found`, or PaddleX
complains the Paddle install isn't GPU-capable.

Almost always a version skew between Paddle (this wheel) and the
PaddleOCR / PaddleX release on top. The verified-together versions:

```bash
pip install paddleocr==3.5.0 "paddlex[ocr]==3.5.1"
```

Newer PaddleOCR / PaddleX releases have introduced ROCm-incompatible
code paths in the past. Pin both before bumping anything.

### Both `paddlepaddle` and `paddlepaddle-dcu` get installed

Distinct distribution names that both expose the `paddle` Python
package. If pip ends up with both, `import paddle` may pick the wrong
one and lose ROCm. Uninstall the CPU build before installing the dcu
wheel:

```bash
pip uninstall -y paddlepaddle paddlepaddle-gpu
pip install ~/.cache/ledgerlinc/paddle-rocm/wheelhouse/paddlepaddle_dcu-*.whl
```

### Wheel filename has version `3.3.0.dev<datestamp>` even though we built `v3.3.1`

This is a Paddle source quirk: the v3.3.1 source tree still
self-identifies as `3.3.0.dev<datestamp>` until upstream bumps the
internal version string. The git tag (`v3.3.1`) is the canonical
version, not the wheel filename. Pin downstream consumers to the
GitHub Release asset URL, not a PEP-440 version specifier.

### MIOpen workspace warnings during inference

Expected on this host with the verified matrix. They are a performance
signal, not a correctness signal. The verifier reaches
`paddle_rocm_bind_succeeded` regardless. If you need to suppress:

```bash
export MIOPEN_LOG_LEVEL=2  # default is 3 (warnings + errors)
```

### Wrong Python ABI selected

The wheel filename embeds the ABI tag (`-cp312-cp312-linux_x86_64`).
A `cp312` wheel won't install into a `python3.11` venv. Confirm:

```bash
python3.12 --version
ls $PADDLE_WHEELHOUSE/*.whl
```

Set `PYTHON_BIN=python3.X` to build for a different ABI; the wheel
filename will reflect the new ABI tag.
