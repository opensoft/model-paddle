# Patch Inventory

This inventory explains why the local source-build wrapper patches Paddle and
its vendored dependencies before every configure/build run.

The detailed mechanics live in `scripts/build-paddle-rocm-wheel.sh`; this file
is the human-readable map for future upgrades.

## Current Patch Groups

### 1. ROCm 7.x layout compatibility

Touches:

- Paddle ROCm CMake
- vendored `warpctc`
- vendored `warprnnt`

Why:

- Paddle `v3.3.1` assumes older ROCm directory layout and older hard-coded
  offload targets.
- The verified host uses ROCm `7.2.0` and `gfx1151`.

What it fixes:

- flat include/library/cmake layout
- offload target derivation from `AMDGPU_TARGETS`
- runtime library lookup for the current ROCm install

### 2. Host-only C++ protection from ROCm Thrust / rocPRIM internals

Touches:

- `paddle/phi/common/complex.h`
- `paddle/phi/core/enforce.h`
- `paddle/fluid/platform/enforce.h`
- values/vector helpers
- bundled Thrust shuffle shims

Why:

- ROCm 7.x device-side headers can leak into ordinary host translation units
  and fail compilation.

What it fixes:

- keeps device-only ROCm/Thrust code out of normal host C++ files

### 3. ROCm component include-path updates

Touches code that includes:

- `hipblas`
- `hiprand`
- `rocblas`
- `rocsparse`
- `rocrand`
- `rocsolver`
- `hipsolver`

Why:

- Paddle source and vendored code assume older nested include paths.

What it fixes:

- aligns includes with ROCm 7.x flat-header packaging

### 4. HIP 7 API / runtime glue fixes

Touches:

- pointer attribute handling
- ROCm driver dynamic loading wrappers
- allocator facade paths

Why:

- runtime-facing APIs moved enough that upstream v3.3.1 assumptions do not
  cleanly hold on the verified host.

What it fixes:

- current pointer-attribute field usage
- runtime symbol loading for HIP virtual memory / graph functions
- ROCm allocator include path correctness

### 5. Math / library integration fixes

Touches:

- hipBLAS complex scalar construction
- rocPRIM traits for Paddle `float16` and `bfloat16`
- top-k wave64 shared-memory sizing
- argsort/top-k/mode kernel compatibility

Why:

- verified host path exposes mismatches between Paddle types and ROCm 7.x
  library expectations

What it fixes:

- host-side scalar types
- missing type traits
- invalid zero-length shared-memory path on wave64

### 6. Packaging / wheel build glue

Touches:

- Python packaging deps
- LLVM runtime library path
- generated/copy build artifacts used by wheel packaging
- stub generation control

Why:

- a successful compile is not enough; the wheel packaging step also needs the
  right runtime/search-path and generated-file setup

What it fixes:

- wheel build completion
- runtime probe viability for the produced wheel

## Upgrade Guidance

When bumping Paddle, ROCm, Python, or `AMDGPU_TARGETS`, review each patch group
and ask:

1. Is this still required?
2. Is it required but needs a different implementation?
3. Can it be dropped because upstream absorbed it?

Do not treat the current patch list as timeless. The point of this file is to
make each patch removable once the underlying incompatibility disappears.

When the patch logic changes, regenerate the exported patch bundle under
[`../patches/`](../patches/) so the checked-in artifact stays aligned with the
builder behavior.
