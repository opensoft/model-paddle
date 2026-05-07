# Contributing

Thanks for taking a look. This repo packages the source-build path for
the ROCm-enabled PaddlePaddle wheel; contributions usually fall into
one of:

1. **Reporting a build on a new host** (verified or failed) — opens a
   path to a new compatibility-matrix row or release.
2. **Fixing or adding a patch** in the build script when Paddle, ROCm,
   or `AMDGPU_TARGETS` changes break the existing patches.
3. **Bumping the verified Paddle tag** when upstream releases.
4. **Tightening docs** when the README or runbook misses a real-world
   failure mode.

## Before you start

- Run `scripts/detect-host.sh` and capture its output. Half of build
  failures turn out to be missing prerequisites or wrong env vars.
- Read [`docs/patch-inventory.md`](./docs/patch-inventory.md). If
  Paddle or ROCm has changed in a way that interacts with a patch
  group, your fix probably belongs in that group.

## Reporting a host build

Open an issue using the
[Build Report template](./.github/ISSUE_TEMPLATE/build-report.md).
Include the items in the checklist; the most useful single attachment
is the JSON output of `scripts/verify-paddle-rocm-runtime.sh` from a
freshly-built wheel.

If the build was **successful**, the matrix gets a new row and you can
ask for a release for your hardware. If it was **failed**, the
maintainers will help triage; in many cases the fix is one new patch
in the build script.

## Adding or modifying a patch

The build script (`scripts/build-paddle-rocm-wheel.sh`) is the source
of truth for what patches get applied. Workflow:

1. Edit the inline patch logic in `scripts/build-paddle-rocm-wheel.sh`.
2. Test by running `scripts/build-paddle-rocm-wheel.sh prepare`, then
   inspecting the patched source under `$PADDLE_BUILD_ROOT/Paddle/`.
3. Run a full `scripts/rebuild-and-verify-rocm-wheel.sh` to confirm the
   wheel still passes.
4. Re-export the patch bundle:
   ```bash
   scripts/build-paddle-rocm-wheel.sh prepare
   scripts/export-paddle-patches.sh
   ```
5. Update [`docs/patch-inventory.md`](./docs/patch-inventory.md) if
   you added or removed a patch group.
6. Commit `scripts/build-paddle-rocm-wheel.sh`,
   `patches/0001-...patch`, `patches/series`, and
   `docs/patch-inventory.md` together.

CI runs `git apply --check` against a fresh Paddle clone to confirm
the exported patch still applies; if your PR changes the script but
forgets to re-export, CI fails.

## Bumping the verified Paddle tag

Cadence policy:

- Patch releases (e.g. v3.3.1 → v3.3.2): rebuild and verify on the
  reference host. If verify passes with no patch changes, update
  `build-manifest.env`'s `PADDLE_TAG` and re-export the patch bundle
  (the file name embeds the tag).
- Minor releases (v3.3 → v3.4): expect at least one patch group to
  need rework. Open an issue first to track the bump; don't merge a
  blind bump.
- We aim to evaluate new Paddle releases within ~4 weeks of the
  upstream tag. Faster turnarounds welcome via PR.

## Updating the compatibility matrix

When a build is successfully verified on a new host:

1. Add a row to [`docs/compatibility-matrix.md`](./docs/compatibility-matrix.md)
   in the right bucket (`verified`, `expected with overrides`,
   `unverified`).
2. If a release is cut for that host, fill the **Release tag** column.
3. Cross-link to the issue / build report that produced the row.

## Docs

If you read the docs and got confused, that's a bug — please open an
issue describing what you expected vs. what was unclear, ideally with
a suggested wording. Doc PRs are welcome and don't need a build report.

## Code of conduct

Be kind, be specific, be brief.
