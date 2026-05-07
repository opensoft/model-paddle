# model-paddle

Canonical home for the ROCm-enabled PaddlePaddle wheel that the
[LedgerLinc OCR pipeline](https://github.com/opensoft/ledgerlinc-model-ocr-pipeline)
consumes for `ppstructurev3@gpu` preprocessing.

## What this repo owns

- **The build of Paddle from source** for AMD ROCm targets that have no
  matching public wheel (currently `gfx1151` on ROCm 7.x, Python 3.12).
- **The patches** the source build applies to Paddle and its vendored
  third-party projects (`warpctc`, `warprnnt`, ROCm CMake, hipBLAS
  scalars, rocPRIM traits, MIOpen offload targets, etc.) so the v3.3.1
  ROCm switch produces a usable wheel on this hardware.
- **A pipeline-agnostic runtime probe** that verifies a built wheel can
  actually bind to `gpu:0` and execute a tensor.
- **Distribution of built wheels** as
  [GitHub Release assets](https://github.com/opensoft/model-paddle/releases)
  on this repo.

## What this repo does NOT own

- The OCR pipeline itself, PPStructureV3 invocation, lane stamping,
  schema-validated preprocess output, or end-to-end timing — all in
  `ledgerlinc-model-ocr-pipeline`.
- The pipeline's `paddlepaddle-dcu` distribution-name detection (lives
  in the pipeline's preflight module).
- Cloud-workstation orchestration (will live here as a follow-on if/when
  the repo also ships a native Linux ROCm container image, per the repo
  description "OCR model… run in our azure cloud").

## Why a separate repo

Stage 1's runtime-boundary rule keeps the model runtime out of the
pipeline. The build of that runtime is a parallel concern: a 1k-line bash
build wrapper, a long list of ROCm/CMake patches, and the gfx-target
matrix don't belong in the pipeline repo's source tree. Decoupling lets
the wheel version, ROCm version, and gfx target list move on their own
cadence; the pipeline pins a wheel asset URL and bumps it in a one-line
PR when this repo cuts a new release.

## Layout

```
model-paddle/
├── README.md                 — this file
├── scripts/
│   ├── build-paddle-rocm-wheel.sh    — clone, patch, configure, build
│   └── verify-paddle-rocm-runtime.sh — pipeline-agnostic Paddle/ROCm probe
└── docs/
    └── source-build.md       — full source-build runbook + patch inventory
```

## Quick start

Build a wheel for the current workstation defaults (ROCm 7.2.0,
`gfx1151`, Python 3.12):

```bash
scripts/build-paddle-rocm-wheel.sh configure
CMAKE_BUILD_PARALLEL_LEVEL=4 scripts/build-paddle-rocm-wheel.sh build
```

The wheel lands in `~/.cache/ledgerlinc/paddle-rocm/wheelhouse/`. Verify
it on a fresh venv:

```bash
python3.12 -m venv /tmp/paddle-rocm-test
/tmp/paddle-rocm-test/bin/pip install -U pip
/tmp/paddle-rocm-test/bin/pip install \
  ~/.cache/ledgerlinc/paddle-rocm/wheelhouse/paddlepaddle_dcu-*.whl
scripts/verify-paddle-rocm-runtime.sh /tmp/paddle-rocm-test/bin/python
```

Expected terminal state: `paddle_rocm_bind_succeeded`.

Full procedure, environment matrix, and the patch inventory live in
[`docs/source-build.md`](./docs/source-build.md).

## Wheel distribution

Built wheels are published as **GitHub Release assets** on this repo.
Tag scheme: `paddle-<paddle-tag>-rocm<rocm-version>-<gfx-target>-py<abi>`,
for example `paddle-v3.3.1-rocm7.2-gfx1151-py312`. Each release includes:

- `paddlepaddle_dcu-<...>.whl` — the wheel
- `verify-output.json` — output of `verify-paddle-rocm-runtime.sh`
  against the wheel as built, captured at release time
- A short release note pinning the host ROCm/HIP version, host
  `rocminfo` summary, and the `build-paddle-rocm-wheel.sh` git commit
  hash

Pipeline consumers install via:

```bash
pip install https://github.com/opensoft/model-paddle/releases/download/<tag>/paddlepaddle_dcu-<...>.whl
```

(Replace `<tag>` and `<...>` with the values from the release; private
repo access requires `gh auth` or a deploy key.)

## Status

- v3.3.1 source build for ROCm 7.2 / `gfx1151` / Python 3.12 has been
  verified locally (tensor bind + pipeline-side PPStructureV3 init).
- No release has been cut yet. First release will publish the verified
  workstation wheel produced by `build-paddle-rocm-wheel.sh`.
