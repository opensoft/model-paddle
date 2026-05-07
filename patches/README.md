# Patch Bundle

This directory holds an exported snapshot of the Paddle source patches
that the build script applies. It is the **reviewable artifact layer**
for the ROCm-enabled Paddle source build.

## ⚠️ Authority and drift

> **This patch file is informational, not authoritative.**
>
> The actual patches that the build applies live as inline `sed` /
> heredoc / Python rewrites inside
> [`scripts/build-paddle-rocm-wheel.sh`](../scripts/build-paddle-rocm-wheel.sh).
> The exported `0001-...patch` is a **snapshot** produced by
> [`scripts/export-paddle-patches.sh`](../scripts/export-paddle-patches.sh),
> regenerated manually after edits to the build script.
>
> **The two will drift if someone forgets to re-run the export script.**
> CI runs a freshness check (see `.github/workflows/ci.yml`) that compares
> the exported patch against a freshly-prepared source tree and fails
> the PR if they differ.

If you are reading the patch file and want to be certain of what the
build does, also read the inline patch logic in `build-paddle-rocm-wheel.sh`.
The long-term goal is to flip authority — drive the build from this
patch directory and remove the inline rewrites — but until then, the
script wins.

## Files

- `series` — patch ordering (currently a single file)
- `0001-paddle-<tag>-rocm.patch` — exported patch bundle
- `README.md` — this file

## Regenerating the patch bundle

After changing patch logic in `scripts/build-paddle-rocm-wheel.sh`:

```bash
# 1. Apply the inline patches into a prepared source tree.
scripts/build-paddle-rocm-wheel.sh prepare

# 2. Diff the patched tree against its upstream tag and overwrite the bundle.
scripts/export-paddle-patches.sh
```

If `export-paddle-patches.sh` complains that no diff was found, you
either skipped step 1 or the patches were reset — re-run `prepare`.

## Reviewing patches

The single-file bundle is a logical group of patches. The
[patch inventory](../docs/patch-inventory.md) describes what each group
fixes and why. When the patch surface stabilizes, the bundle will be
split into per-group files matching the inventory.

In the meantime, when reading the patch file, look for chunks that
touch:

- `cmake/external/warpctc.cmake`, `cmake/external/warprnnt.cmake`,
  `cmake/hip.cmake` → group 1 (ROCm 7.x layout)
- `paddle/phi/common/complex.h`, `paddle/phi/core/enforce.h`,
  `paddle/fluid/platform/enforce.h` → group 2 (host-only Thrust guards)
- `*hipblas*`, `*rocblas*`, `*hiprand*`, `*rocrand*` → group 3 (ROCm
  component include-path updates)
- `pointer_attribute*`, `dynload/*hip*`, `*allocator*` → group 4 (HIP 7
  API glue)
- `top_k*`, `argsort*`, complex scalar construction → group 5 (math /
  library integration)
- `setup.py`, `python_package` packaging → group 6 (wheel build glue)
