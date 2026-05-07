# Paddle ROCm Source Build

This document is the source-build path for producing the ROCm-enabled
PaddlePaddle wheel that the LedgerLinc OCR pipeline consumes for
`ppstructurev3@gpu` preprocessing on AMD ROCm WSL hosts (currently
`gfx1151` on ROCm 7.x).

End-to-end pipeline validation (running PPStructureV3 against an invoice
and checking the lane stamp on the resulting artifact) lives in the
LedgerLinc OCR pipeline repo. This repo only owns the wheel build and a
standalone Paddle/ROCm runtime probe.

## Current Status

Status as of 2026-05-06:

- A ROCm-enabled Paddle wheel has been built from Paddle `v3.3.1` source.
- `scripts/verify-paddle-rocm-runtime.sh <python-bin>` succeeds with
  `state: paddle_rocm_bind_succeeded`, `compiled_with_rocm: true`,
  `device_count: 1`, and a tensor probe on `gpu:0`.
- The LedgerLinc OCR pipeline repo's preflight succeeds with
  `state: ppstructurev3_init_succeeded` and selected device `gpu:0` when
  pointed at a venv that has the wheel installed.
- A temp one-document GPU preprocess run on the pipeline side wrote a
  schema-valid `preprocess_output.json` with `pipeline_version` ending in
  `.gpu0` (full numbers and the ongoing optimization roadmap live in the
  pipeline repo's stage 1 PRD).

MIOpen emits workspace warnings during inference on this host. They do not
block output, but they are a performance signal: the current path is usable
for proof and development, not yet optimized for benchmark speed.

The workstation ROCm runtime itself is visible:

- ROCm path: `/opt/rocm-7.2.0`
- WSL GPU device: `/dev/dxg`
- GPU architecture: `gfx1151`
- GPU marketing name: `AMD Radeon(TM) 8060S Graphics`

The package issue is not CUDA versus ROCm naming. Paddle's Python GPU API
uses strings like `gpu:0`, but the build must be compiled with ROCm/HIP for
this AMD device. Installing a CUDA `paddlepaddle-gpu` wheel will not fix this
host.

## Why Source Build

For Paddle 3.3.x, the public Linux wheel table currently publishes CPU and
CUDA wheels. A public Linux x86_64 Python 3.12 ROCm/HIP wheel matching
PaddleOCR/PaddleX was not found.

The Paddle v3.3.1 source does contain a ROCm build switch:

- `WITH_ROCM=ON`
- `WITH_GPU=OFF`

`WITH_GPU` is the CUDA path and Paddle rejects enabling CUDA and ROCm together.
With `WITH_ROCM=ON`, Paddle names the Python wheel `paddlepaddle-dcu`.

The v3.3.1 ROCm CMake also assumes an older ROCm layout and hard-codes older
offload targets (`gfx906`, `gfx926`, `gfx928`, `gfx936`). The local build
wrapper patches those source-build assumptions for ROCm 7.x and `gfx1151`.

## Local Source Patches

The wrapper applies the workstation patches every time `prepare`, `configure`,
or `build` runs, so the external Paddle checkout can be refreshed without
losing the fixes.

Current patch set:

- Paddle ROCm CMake: supports ROCm 7.x flat include/library layout and derives
  HIP offload targets from `AMDGPU_TARGETS` instead of hard-coded Hygon/Instinct
  targets.
- Vendored `warpctc` and `warprnnt`: applies the same ROCm 7.x layout and
  `gfx1151` offload target handling to the external projects.
- Host-only Thrust guards: keeps ROCm Thrust system headers out of ordinary
  host C++ translation units in `paddle/phi/common/complex.h`,
  `paddle/phi/core/enforce.h`, and `paddle/fluid/platform/enforce.h`.
- ROCm component includes: rewrites older nested include paths for `hipblas`,
  `hiprand`, `rocblas`, `rocsparse`, `rocrand`, `rocsolver`, and `hipsolver`
  to the ROCm 7 flat headers.
- HIP 7 pointer attributes: uses the current `hipPointerAttribute_t.type`
  field.
- ROCm driver dynload: instantiates Paddle's declared HIP virtual-memory and
  graph dynamic-loader wrappers, including `hipMemCreate` and `hipMemRelease`.
- ROCm allocator headers: avoids CUDA driver allocator headers in the ROCm
  allocator facade path.
- hipBLAS complex scalars: uses `rocblas_float_complex` and
  `rocblas_double_complex` for host-side scalar construction.
- `values_vectors_functor.h`: keeps the Thrust device-vector implementation
  inside HIP translation units.
- Bundled Thrust shuffle shims: removes stale ROCm-internal includes/macros
  that no longer exist in ROCm 7.x.
- rocPRIM traits: defines traits for Paddle `float16` and `bfloat16` before
  argsort, top-k, and mode kernels use ROCm 7 `rocprim` primitives.
- Top-k wave64 fix: sizes the shared-memory `shared_max` array by rounded-up
  warp count so HIP wave64 builds do not instantiate a zero-length array when
  Paddle uses `BlockSize=32`.
- Build/runtime packaging fixes: include ROCm's LLVM runtime library path,
  set `SKIP_STUB_GEN=ON`, install the Python packaging dependencies needed by
  Paddle's wheel builder, and generate/copy
  `paddle.incubate.autograd.phi_ops_map` before packaging.

## Build Wheel

Run from the repository root on the WSL host, not from `py-bench`:

```bash
scripts/build-paddle-rocm-wheel.sh configure
```

If configure succeeds, build the wheel:

```bash
CMAKE_BUILD_PARALLEL_LEVEL=4 scripts/build-paddle-rocm-wheel.sh build
```

The build runs outside the repository by default:

```text
~/.cache/ledgerlinc/paddle-rocm/
```

The resulting wheel is copied to:

```text
~/.cache/ledgerlinc/paddle-rocm/wheelhouse/
```

The script intentionally does not modify the project `.venv`.

The successful local wheel currently lands at:

```text
~/.cache/ledgerlinc/paddle-rocm/wheelhouse/paddlepaddle_dcu-3.3.0.dev20260319-cp312-cp312-linux_x86_64.whl
```

## Build Variables

Common overrides:

| Variable | Default | Meaning |
|----------|---------|---------|
| `PADDLE_TAG` | `v3.3.1` | Paddle source tag to build. |
| `ROCM_PATH` | `/opt/rocm-7.2.0` | ROCm install root. |
| `AMDGPU_TARGETS` | `gfx1151` | HIP offload architecture list. |
| `PYTHON_BIN` | `python3.12` | Python ABI used for the wheel. |
| `PADDLE_HOST_CC` | `$ROCM_PATH/llvm/bin/amdclang` | Host C compiler. Required because ROCm headers can enter normal Paddle C++ translation units. |
| `PADDLE_HOST_CXX` | `$ROCM_PATH/llvm/bin/amdclang++` | Host C++ compiler. |
| `CMAKE_BUILD_PARALLEL_LEVEL` | half of `nproc`, minimum 2 | Build parallelism. |

Do not use the system GCC build directory for ROCm. GCC can configure the
top-level project, but normal Paddle C++ files may include ROCm `rocprim`
headers and fail on AMD GPU builtins. The wrapper defaults to a clean
`build-v3.3.1-rocm-amdclang` directory for this reason.

## Install Into An Isolated Test Venv

After a wheel exists, install it into a separate test venv. The pipeline's
project `.venv` should never be replaced until the isolated environment
passes the verifier below.

```bash
python3.12 -m venv .venv-paddle-rocm
.venv-paddle-rocm/bin/pip install -U pip
.venv-paddle-rocm/bin/pip install paddleocr==3.5.0 "paddlex[ocr]==3.5.1"
.venv-paddle-rocm/bin/pip uninstall -y paddlepaddle
.venv-paddle-rocm/bin/pip install ~/.cache/ledgerlinc/paddle-rocm/wheelhouse/paddlepaddle-dcu*.whl
.venv-paddle-rocm/bin/pip install "numpy>=1.24,<2.4" "Pillow>=10.4,<11" "pypdfium2>=4.30,<5"
```

(Pipeline consumers additionally install the `ledgerlinc-ocr` editable
package into the same venv; that step lives in the pipeline repo's
quickstart.)

## Verify Runtime Bind

```bash
scripts/verify-paddle-rocm-runtime.sh .venv-paddle-rocm/bin/python
```

Expected successful state:

```text
paddle_rocm_bind_succeeded
```

The verifier is intentionally pipeline-agnostic: it confirms only that
Paddle is ROCm-compiled, sees a GPU device, and can run a tensor on
`gpu:0`. End-to-end PPStructureV3 / pipeline validation is the pipeline
repo's responsibility.

## Container Boundary

Build and first validation happen on the WSL host, not from a Docker
Desktop container. The current WSL Docker Desktop path does not expose a
native ROCm device stack to the container.

After the host can bind Paddle to `gpu:0`, the next decision (out of scope
for this repo) is whether to publish a native Linux ROCm container image
that bundles the wheel. That belongs in this repo as a follow-on, since
the GitHub repo is described as "OCR model… run in our azure cloud."
