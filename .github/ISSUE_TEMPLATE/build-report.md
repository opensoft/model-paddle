---
name: Build Report
about: Report a successful or failed build on a host that's not yet in the compatibility matrix.
title: "[build] <gfx-target> / ROCm <version> / Py<abi>"
labels: build-report
---

## Result

<!-- "success" or "failure". If failure, describe what went wrong. -->

## Host

- Distribution: <!-- e.g. Ubuntu 24.04, Fedora 40, WSL2 Ubuntu 22.04 -->
- Kernel: <!-- output of `uname -r` -->
- Hardware: <!-- e.g. AMD Radeon RX 7900 XTX, AMD Instinct MI300X -->
- ROCm version: <!-- e.g. 7.2.0 -->
- Python ABI: <!-- e.g. 3.12 -->
- gfx target: <!-- e.g. gfx1100 -->

## Reproduction

```bash
# Override flags you used:
AMDGPU_TARGETS=...
ROCM_PATH=...
PYTHON_BIN=...
# Command:
scripts/rebuild-and-verify-rocm-wheel.sh
```

## Attachments

Please paste or attach:

- [ ] Output of `scripts/detect-host.sh`
- [ ] Final 50 lines of build log (or full log on failure)
- [ ] On success: the relevant section of `release-manifest.json`
      (`paddle_tag`, `rocm_path`, `amdgpu_targets`, `python_bin`,
      `wheel.filename`, `wheel.sha256`, `host.rocminfo_gfx`)
- [ ] On success: the JSON from `scripts/verify-paddle-rocm-runtime.sh`

## What you'd like

- [ ] Add a row to `docs/compatibility-matrix.md`
- [ ] Help debugging a failure
- [ ] Cut a release for this host
- [ ] Something else (describe below)
