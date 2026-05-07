# Compatibility Matrix

This table tracks what this repository has actually validated or
expects to work for AMD ROCm Paddle source builds. New rows come from
[Build Report issues](../.github/ISSUE_TEMPLATE/build-report.md) — see
[Reporting a successful build](#reporting-a-successful-build) below.

| Paddle | ROCm | Python | AMD GPU targets | Host model | Status | Release tag | Notes |
|---|---|---|---|---|---|---|---|
| `v3.3.1` | `7.2.0` | `3.12` | `gfx1151` | Linux / WSL2 | **verified** | not cut yet | current maintained path |
| `v3.3.1` | `7.x` | `3.12` | `gfx1100`, `gfx1101`, `gfx1102` | Linux | expected with overrides | none | not yet rebuilt in this repo |
| `v3.3.1` | `7.x` | `3.12` | `gfx90a`, `gfx940`, `gfx942` | Linux | expected with overrides | none | server-class cards not yet verified here |
| `v3.3.1` | `6.x` | `3.11` or `3.12` | mixed | Linux | unverified | none | likely needs version-specific patch changes |

## Status definitions

- **verified** — the build completed and `verify-paddle-rocm-runtime.sh`
  passed on the listed matrix. A maintainer or contributor produced
  build/verify evidence (release artifacts or a Build Report issue).
- **expected with overrides** — the current patch set is believed to
  be portable to that host, but this repo has not yet seen a passing
  build there. Try it; please report results.
- **unverified** — no compatibility claim should be inferred. The
  build is likely to need additional patch work.

## Reporting a successful build

If you successfully build on a host that's not yet in the matrix,
please:

1. [Open a Build Report issue](https://github.com/opensoft/model-paddle/issues/new?template=build-report.md).
   Attach the JSON outputs of `scripts/detect-host.sh` and
   `scripts/verify-paddle-rocm-runtime.sh`, plus the relevant section
   of your `release-manifest.json`.
2. Indicate whether you'd like a release cut for your host (so others
   can `pip install` your verified wheel without rebuilding).

Maintainers update this table from the issue. Direct PRs to this file
are welcome but the issue is the load-bearing record — it preserves
the build evidence.

## Reporting a failed build

The Build Report template covers failures too. Failures are how new
patches get added to the build script — see
[CONTRIBUTING.md](../CONTRIBUTING.md#adding-or-modifying-a-patch).
