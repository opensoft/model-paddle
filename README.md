# model-paddle

**Build a working PaddlePaddle wheel for AMD ROCm GPUs that the upstream
Paddle project doesn't ship pre-built wheels for.**

## What is this for?

[PaddlePaddle](https://www.paddlepaddle.org.cn/) is the deep-learning
framework that underpins
[PaddleOCR](https://www.paddleocr.ai/main/),
[PPStructure](https://paddlepaddle.github.io/PaddleX/3.2/en/pipeline_usage/tutorials/ocr_pipelines/PP-StructureV3.html),
and many other Baidu open-source vision/NLP projects. To use it on an
AMD GPU, you need a ROCm-compiled `.whl` (Python wheel package). Out of
the box, `pip install paddlepaddle` only ships **CPU** and **NVIDIA
CUDA** wheels — there are no public ROCm wheels for current AMD desktop,
mobile, or workstation parts. This repo fills that gap.

What you get from this repo:

- a reproducible source build of Paddle with `WITH_ROCM=ON`
- the patches needed to compile Paddle 3.x against ROCm 7.x and modern
  AMD targets (`gfx1151`, RDNA3, CDNA2/3) — see
  [`docs/patch-inventory.md`](./docs/patch-inventory.md)
- a host self-check that tells you what GPU you have and how to override
  the build for it
- a pipeline-agnostic runtime probe that confirms the built wheel binds
  to `gpu:0` and runs a tensor
- GitHub Release distribution of pre-built wheels for verified hosts

The output wheel is a normal Paddle build — you `pip install` it and
`import paddle` like any other PaddlePaddle install. With `WITH_ROCM=ON`
the wheel is named `paddlepaddle-dcu` (Paddle's name for ROCm-flavored
builds), but the Python API surface is identical.

## Hardware / OS support

| Status | Hosts | What you should do |
|---|---|---|
| **Verified** | `gfx1151` (AMD Radeon 8060S / Strix Halo APUs) on ROCm 7.2.0, Python 3.12, Linux or WSL2 | Use the prebuilt wheel — see **[Install (verified hosts)](#install-verified-hosts)** below. No source build needed. |
| **Expected to work with overrides** | other RDNA3 (`gfx110x` — RX 7900 XT/XTX, W7900) and CDNA2/CDNA3 (`gfx90a` MI200, `gfx940`/`gfx942` MI300) on ROCm 7.x | Run `scripts/detect-host.sh`, then run `scripts/rebuild-and-verify-rocm-wheel.sh` with the env vars detect-host suggests. If the build fails, [open an issue](https://github.com/opensoft/model-paddle/issues/new) with the build log + verifier JSON. If it succeeds, please [report it](./docs/compatibility-matrix.md#reporting-a-successful-build) so we can add a row. |
| **Likely needs additional patches** | pre-RDNA3 RDNA2 (`gfx103x`) and Vega/MI100 (`gfx9xx`) on ROCm 6.x | Read [`docs/patch-inventory.md`](./docs/patch-inventory.md) first. The v3.3.1 ROCm CMake assumes the older directory layout that this patch set replaces; some patch groups will need version-specific reverts. Expect to write new patches and contribute them back. |

**Don't have ROCm yet?** Install it from
[AMD's official guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-overview.html)
before continuing. On Ubuntu 22.04 / 24.04, the supported install adds
AMD's apt repo and runs `apt install rocm-dev`. After install, run
`scripts/detect-host.sh` to verify.

**Tested distros**: Ubuntu 22.04, Ubuntu 24.04, and WSL2 Ubuntu. Other
Linux distributions should work if ROCm packages are available; please
[open an issue](https://github.com/opensoft/model-paddle/issues/new)
with your results so we can update the matrix.

If you're not sure what GPU you have, run:

```bash
scripts/detect-host.sh
```

It prints your gfx target, ROCm version, the device files visible to
this host, the exact override flags to use for the build, a Y/N readout
for every prerequisite, and a recommended `CMAKE_BUILD_PARALLEL_LEVEL`
based on your CPU count and RAM.

## Install (verified hosts)

If your hardware matches the **Verified** row above (`gfx1151` / ROCm
7.2.0 / Python 3.12 / Linux or WSL2), use the prebuilt wheel — no
source build needed. The four steps below take a couple of minutes
total. For other GPU/ROCm/Python combos, skip to
[Quick start (build from source)](#quick-start-build-from-source).

**Step 1 — authenticate to GitHub.** This repo is private, so a direct
`pip install https://github.com/...` URL will not work without auth.
Use the GitHub CLI:

```bash
gh auth status   # if not logged in: `gh auth login`
```

**Step 2 — download the wheel from the release.**

```bash
gh release download paddle-v3.3.1-rocm7.2-gfx1151-py312 \
  --repo opensoft/model-paddle \
  --pattern 'paddlepaddle_dcu-*.whl' \
  --dir /tmp
```

The full release (with `release-manifest.json`, `verify-output.json`,
and `SHA256SUMS`) is at
[releases/tag/paddle-v3.3.1-rocm7.2-gfx1151-py312](https://github.com/opensoft/model-paddle/releases/tag/paddle-v3.3.1-rocm7.2-gfx1151-py312).
To round-trip the checksums:

```bash
gh release download paddle-v3.3.1-rocm7.2-gfx1151-py312 \
  --repo opensoft/model-paddle --dir /tmp/paddle-rocm-release
( cd /tmp/paddle-rocm-release && sha256sum -c SHA256SUMS )
```

**Step 3 — install into a Python 3.12 venv.**

```bash
python3.12 -m venv .venv && source .venv/bin/activate
pip install /tmp/paddlepaddle_dcu-*.whl
```

> The wheel is **cp312-only** (Python 3.12 ABI). It will not install
> into a 3.10 / 3.11 venv. If you need a different ABI, rebuild from
> source: `PYTHON_BIN=python3.11 scripts/rebuild-and-verify-rocm-wheel.sh`.

**Step 4 — set the runtime env vars.** ROCm + Paddle needs these
exports before `import paddle`, otherwise the import may segfault on
WSL2 or report no GPU. The bundled
[`scripts/verify-paddle-rocm-runtime.sh`](./scripts/verify-paddle-rocm-runtime.sh)
exports them automatically; in your own project, add the equivalent to
your venv activation or `.envrc`:

```bash
export ROCM_PATH=/opt/rocm-7.2.0
export HIP_PATH="$ROCM_PATH"
export PATH="$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib/llvm/lib:${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="$ROCM_PATH/lib/libhsa-runtime64.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
# WSL2 only:
export HSA_ENABLE_DXG_DETECTION=1
export HSA_ENABLE_SDMA=0
# Perf knob (recommended):
export MIOPEN_FIND_MODE=2
```

**Step 5 — smoke check.** Either run the inline one-liners:

```bash
python -c "import paddle; print('rocm:', paddle.is_compiled_with_rocm())"   # → rocm: True
python -c "import paddle; print('devices:', paddle.device.cuda.device_count())"  # → devices: 1+
python -c "import paddle; paddle.utils.run_check()"   # full Paddle self-test on the GPU
```

…or run the end-to-end probe (it sets the env vars from Step 4 itself
and prints structured JSON ending in `state: paddle_rocm_bind_succeeded`
on success):

```bash
scripts/verify-paddle-rocm-runtime.sh "$(which python)"
```

If the probe fails, see
[`docs/rebuild-rocm-wheel.md` § Troubleshooting](./docs/rebuild-rocm-wheel.md#troubleshooting).

## Resource budget

The build is a full from-source compilation of Paddle. Plan for it.

| Resource | Reference (gfx1151 / ROCm 7.2 / Py3.12 / 16-core / 32 GB) | Notes |
|---|---|---|
| Wall-clock time | ~1.5–2 hours | First-time configure + full build + wheel packaging. |
| RAM (peak) | ~14–18 GB at the link step | `libpaddle.so` link is the largest single moment; multi-job link will OOM on low-RAM hosts. |
| Disk (cache) | ~12 GB | Paddle source clone + CMake build dir + wheelhouse — all under `~/.cache/model-paddle/paddle-rocm/`. |
| Network | ~3 GB | Paddle clone + vendored deps + Python build wheels on the first run. |

Cap `CMAKE_BUILD_PARALLEL_LEVEL` at roughly `RAM_GB / 2` (or use what
detect-host.sh suggests) — over-parallel link is the usual OOM cause.
The build script already defaults to `nproc / 2` (min 2). Lower that on
≤16 GB hosts.

## What this repo owns

- The build of Paddle from source for AMD ROCm targets.
- The patches the source build applies to Paddle and its vendored
  third-party projects.
- A reviewable exported patch artifact under [`patches/`](./patches/)
  (a snapshot — see the patches/README.md note about authority).
- A pipeline-agnostic runtime probe.
- Distribution of built wheels as
  [GitHub Release assets](https://github.com/opensoft/model-paddle/releases).

## What this repo does NOT own

- Any OCR / vision / training pipeline that consumes Paddle.
- Cloud-workstation orchestration (will live here as a follow-on if/when
  the repo also ships a native Linux ROCm container image, per the repo
  description "OCR model… run in our azure cloud").

## Layout

```
model-paddle/
├── README.md                 — this file
├── LICENSE                   — Apache-2.0 (matches Paddle upstream)
├── NOTICE                    — Paddle source attribution
├── CONTRIBUTING.md           — version-bump policy, how to add a verified host
├── build-manifest.env        — verified-matrix defaults (sourceable)
├── local.env.sample          — template for per-host overrides (copy → local.env)
├── patches/
│   ├── 0001-...patch         — exported Paddle source patch bundle (snapshot)
│   ├── README.md             — how the patch bundle relates to the build script
│   └── series                — patch ordering
├── scripts/
│   ├── detect-host.sh        — host self-check; gfx target, ROCm version, prereq Y/N, recommended overrides
│   ├── build-paddle-rocm-wheel.sh        — clone, patch, configure, build (phases: prepare/configure/build)
│   ├── export-paddle-patches.sh          — regenerate patch bundle from prepared source tree
│   ├── rebuild-and-verify-rocm-wheel.sh  — one-command happy path: detect → build → verify
│   ├── verify-paddle-rocm-runtime.sh     — pipeline-agnostic Paddle/ROCm probe
│   ├── write-release-manifest.sh         — emit release-manifest.json + SHA256SUMS
│   └── cut-release.sh                    — capture verify JSON, build manifest, and gh release create
└── docs/
    ├── compatibility-matrix.md  — verified / expected / unverified matrix
    ├── patch-inventory.md       — why each local source patch exists
    ├── rebuild-rocm-wheel.md    — rebuild contract + prerequisites + happy path + troubleshooting
    ├── release-wheel.md         — release asset checklist + consumer contract + gh release commands
    └── source-build.md          — full source-build runbook
```

## Verified default build matrix

The verified defaults are pinned in
[`build-manifest.env`](./build-manifest.env):

- Paddle tag: `v3.3.1`
- ROCm: `7.2.0`
- AMD GPU target: `gfx1151`
- Python ABI: `3.12`
- Host OS: Linux or WSL2 with a visible ROCm-capable device

Every variable in the manifest respects pre-set values, so you can
override per-host without editing the file:

```bash
AMDGPU_TARGETS=gfx1100 ROCM_PATH=/opt/rocm-7.0.0 \
  scripts/rebuild-and-verify-rocm-wheel.sh
```

For persistent per-host overrides, copy `local.env.sample` to
`local.env` (gitignored) and edit. The build/verify wrappers source it
automatically.

## Quick start (build from source)

This path produces a wheel from source. Use it if your GPU/ROCm/Python
combination doesn't have a prebuilt release yet (see
[compatibility matrix](./docs/compatibility-matrix.md)). If your host
matches the **Verified** row, use the [Install (verified hosts)](#install-verified-hosts)
path instead — the from-source build takes 1.5–2 hours.

**Step 1 — Run the host self-check.** It exits 0 (ready), 2 (ready with
warnings), or non-zero (critical fails like missing ROCm). The rebuild
wrapper aborts on critical fail.

```bash
scripts/detect-host.sh
```

**Step 2 — Run the one-command rebuild.** It re-runs detect-host, then
configures, builds, installs the wheel into a throwaway venv, and runs
the runtime probe.

```bash
scripts/rebuild-and-verify-rocm-wheel.sh
```

Expected terminal state: `paddle_rocm_bind_succeeded`. The wheel lands
in `~/.cache/model-paddle/paddle-rocm/wheelhouse/`.

**Manual phase split** (if you want to inspect each step):

```bash
# Phase 1: clone Paddle outside the repo, apply the inline patches.
scripts/build-paddle-rocm-wheel.sh prepare

# Phase 2: CMake configure (after prepare, can be re-run independently).
scripts/build-paddle-rocm-wheel.sh configure

# Phase 3: full build + wheel packaging.
# CMAKE_BUILD_PARALLEL_LEVEL defaults to nproc/2; override on tight-RAM hosts.
scripts/build-paddle-rocm-wheel.sh build
```

Then verify against any Python venv that has the wheel installed:

```bash
python3.12 -m venv /tmp/paddle-rocm-test
/tmp/paddle-rocm-test/bin/pip install -U pip
/tmp/paddle-rocm-test/bin/pip install \
  ~/.cache/model-paddle/paddle-rocm/wheelhouse/paddlepaddle_dcu-*.whl
scripts/verify-paddle-rocm-runtime.sh /tmp/paddle-rocm-test/bin/python
```

Full procedure and rebuild contract:

- [`docs/compatibility-matrix.md`](./docs/compatibility-matrix.md)
- [`docs/rebuild-rocm-wheel.md`](./docs/rebuild-rocm-wheel.md)
- [`docs/source-build.md`](./docs/source-build.md)
- [`docs/patch-inventory.md`](./docs/patch-inventory.md)
- [`docs/release-wheel.md`](./docs/release-wheel.md)

## Using a locally-built wheel

Once the verifier reports `paddle_rocm_bind_succeeded`, install the
wheel into your project's venv from the local cache:

```bash
pip install ~/.cache/model-paddle/paddle-rocm/wheelhouse/paddlepaddle_dcu-*.whl
```

Set the runtime env vars and run the smoke check exactly as in
[Install (verified hosts)](#install-verified-hosts) Steps 4–5.

If you're using the wheel for OCR (PaddleOCR, PPStructure), the
companion versions verified together with this build are
`paddleocr==3.5.0` and `paddlex[ocr]==3.5.1`. Pinning is recommended;
unpinned upgrades have introduced ROCm-incompatible code paths in the
past.

## Wheel distribution

Built wheels are published as **GitHub Release assets** on this repo.
Tag scheme: `paddle-<paddle-tag>-rocm<rocm-version>-<gfx-target>-py<abi>`,
for example `paddle-v3.3.1-rocm7.2-gfx1151-py312`. Each release includes:

- `paddlepaddle_dcu-<...>.whl` — the wheel
- `verify-output.json` — output of `verify-paddle-rocm-runtime.sh`
  captured at release time
- `release-manifest.json` — machine-readable build/release metadata
  (Paddle source commit, ROCm version, gfx target, repo commit, etc.)
- `SHA256SUMS` — checksums for release artifacts
- Release notes pinning the host ROCm/HIP version, `rocminfo` summary,
  and the build-script git commit hash

See [`docs/release-wheel.md`](./docs/release-wheel.md) for the cut-a-release SOP
and the schema of `release-manifest.json`.

## Status

- v3.3.1 source build for ROCm 7.2 / `gfx1151` / Python 3.12 has been
  verified locally (tensor bind + downstream PPStructureV3 init).
- First release published:
  [`paddle-v3.3.1-rocm7.2-gfx1151-py312`](https://github.com/opensoft/model-paddle/releases/tag/paddle-v3.3.1-rocm7.2-gfx1151-py312)
  — wheel + `verify-output.json` + `release-manifest.json` + `SHA256SUMS`.

## Contributing

If you successfully build on a host that's not yet in the
[compatibility matrix](./docs/compatibility-matrix.md),
please [open an issue](https://github.com/opensoft/model-paddle/issues/new)
using the **Build Report** template — that's how the matrix grows.
See [CONTRIBUTING.md](./CONTRIBUTING.md) for the version-bump policy
and the patch-update workflow.

## Origin

This repo was extracted from the Paddle source-build infrastructure
needed by the
[LedgerLinc OCR pipeline](https://github.com/opensoft/ledgerlinc-model-ocr-pipeline)
to run PPStructureV3 on AMD ROCm GPUs. It is not coupled to that
pipeline — the wheel is plain `paddlepaddle-dcu` and works for any
PaddlePaddle workload.

## License

Apache-2.0; see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).
The wheel is built from upstream Paddle source (Apache-2.0); all
local modifications in this repo are also Apache-2.0.
