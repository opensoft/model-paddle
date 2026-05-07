#!/usr/bin/env bash
# Detect host AMD/ROCm capabilities and print:
#   - gfx target + GPU marketing name + ROCm version
#   - device files visible (native Linux vs WSL2)
#   - required tooling Y/N
#   - recommended override flags for build-paddle-rocm-wheel.sh
#
# Exit codes:
#   0  all critical checks passed
#   1  one or more critical checks failed (no GPU, no ROCm, etc.)
#   2  all critical checks passed but soft warnings present
#
# This script does not modify anything on the host. It only reads.

set -uo pipefail

# ---------- Color / status helpers ----------

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_OK=$'\033[32m'
  C_WARN=$'\033[33m'
  C_BAD=$'\033[31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_END=$'\033[0m'
else
  C_OK=""
  C_WARN=""
  C_BAD=""
  C_DIM=""
  C_BOLD=""
  C_END=""
fi

CRITICAL_FAIL=0
SOFT_WARN=0

mark_ok()      { printf '  %s[ ok ]%s %s\n' "$C_OK" "$C_END" "$1"; }
mark_warn()    { printf '  %s[warn]%s %s\n' "$C_WARN" "$C_END" "$1"; SOFT_WARN=1; }
mark_missing() { printf '  %s[fail]%s %s\n' "$C_BAD" "$C_END" "$1"; CRITICAL_FAIL=1; }
section()      { printf '\n%s== %s ==%s\n' "$C_BOLD" "$1" "$C_END"; }
hint()         { printf '         %s%s%s\n' "$C_DIM" "$1" "$C_END"; }

# ---------- Platform detection ----------

PLATFORM="linux"
WSL_VERSION=""
if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then
  PLATFORM="wsl"
  if grep -qiE 'wsl2' /proc/version 2>/dev/null; then
    WSL_VERSION="2"
  fi
fi

KERNEL="$(uname -r 2>/dev/null || echo unknown)"
DISTRO=""
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  DISTRO="$(. /etc/os-release && printf '%s %s' "${NAME:-?}" "${VERSION:-}")"
fi

section "Platform"
case "$PLATFORM" in
  wsl)
    mark_ok "WSL${WSL_VERSION:+ $WSL_VERSION} on $DISTRO (kernel $KERNEL)"
    hint "WSL hosts get the GPU through /dev/dxg. /dev/kfd is not present."
    ;;
  linux)
    mark_ok "Native Linux: $DISTRO (kernel $KERNEL)"
    hint "Native Linux hosts get the GPU through /dev/kfd + /dev/dri/renderD*."
    ;;
esac

# ---------- ROCm install detection ----------

section "ROCm install"

ROCM_CANDIDATES=()
shopt -s nullglob
for dir in /opt/rocm /opt/rocm-* ; do
  [[ -d "$dir" ]] && ROCM_CANDIDATES+=("$dir")
done
shopt -u nullglob

ROCM_PATH_DETECTED=""
ROCM_VERSION=""
if [[ -n "${ROCM_PATH:-}" && -d "$ROCM_PATH" ]]; then
  ROCM_PATH_DETECTED="$ROCM_PATH"
  mark_ok "ROCM_PATH already set in env: $ROCM_PATH_DETECTED"
elif (( ${#ROCM_CANDIDATES[@]} == 1 )); then
  ROCM_PATH_DETECTED="${ROCM_CANDIDATES[0]}"
  mark_ok "Found ROCm install: $ROCM_PATH_DETECTED"
elif (( ${#ROCM_CANDIDATES[@]} > 1 )); then
  ROCM_PATH_DETECTED="${ROCM_CANDIDATES[-1]}"
  mark_warn "Multiple ROCm installs found, picking newest: $ROCM_PATH_DETECTED"
  hint "Override with ROCM_PATH=<your-choice>. Candidates: ${ROCM_CANDIDATES[*]}"
else
  mark_missing "No ROCm install found under /opt/rocm*"
  hint "ROCm is not installed. Install it before continuing."
  hint "Official guide: https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-overview.html"
  hint "On Ubuntu 22.04/24.04, the supported install adds AMD's repo and runs 'apt install rocm-dev'."
  hint "Verified by this repo: ROCm 7.2.0 at /opt/rocm-7.2.0. ROCm 6.x may need additional patch work."
fi

if [[ -n "$ROCM_PATH_DETECTED" ]]; then
  if [[ -r "$ROCM_PATH_DETECTED/.info/version" ]]; then
    ROCM_VERSION="$(cat "$ROCM_PATH_DETECTED/.info/version" 2>/dev/null || true)"
  fi
  if [[ -z "$ROCM_VERSION" && -r "$ROCM_PATH_DETECTED/.info/version-utils" ]]; then
    ROCM_VERSION="$(cat "$ROCM_PATH_DETECTED/.info/version-utils" 2>/dev/null || true)"
  fi
  if [[ -z "$ROCM_VERSION" ]]; then
    # last-ditch: parse from path name
    ROCM_VERSION="${ROCM_PATH_DETECTED##*/rocm-}"
    [[ "$ROCM_VERSION" == "$ROCM_PATH_DETECTED" ]] && ROCM_VERSION=""
  fi
  if [[ -n "$ROCM_VERSION" ]]; then
    mark_ok "ROCm version: $ROCM_VERSION"
    case "$ROCM_VERSION" in
      7.*) : ;;  # verified band
      6.*)
        mark_warn "ROCm 6.x detected; verified path is ROCm 7.x"
        hint "Recommended: upgrade to ROCm 7.x via https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/install-overview.html"
        hint "If you must build on 6.x, expect patch groups 1, 3, and 4 (see docs/patch-inventory.md) to need version-specific work."
        ;;
      5.*|4.*|3.*)
        mark_warn "ROCm $ROCM_VERSION is far below the verified 7.x band"
        hint "Strongly recommended: upgrade ROCm before building. The patch set targets ROCm 7.x and is unlikely to apply cleanly here."
        ;;
    esac
  else
    mark_warn "Could not determine ROCm version (no .info/version file). Continuing."
  fi
fi

# ---------- ROCm tooling (rocminfo + amdclang) ----------

section "ROCm tooling"

ROCMINFO_BIN=""
if [[ -n "$ROCM_PATH_DETECTED" && -x "$ROCM_PATH_DETECTED/bin/rocminfo" ]]; then
  ROCMINFO_BIN="$ROCM_PATH_DETECTED/bin/rocminfo"
elif command -v rocminfo >/dev/null 2>&1; then
  ROCMINFO_BIN="$(command -v rocminfo)"
fi

if [[ -n "$ROCMINFO_BIN" ]]; then
  mark_ok "rocminfo present: $ROCMINFO_BIN"
else
  mark_missing "rocminfo not found"
  hint "rocminfo ships with ROCm; expected at \$ROCM_PATH/bin/rocminfo or on \$PATH"
fi

AMDCLANG=""
AMDCLANGPP=""
if [[ -n "$ROCM_PATH_DETECTED" ]]; then
  [[ -x "$ROCM_PATH_DETECTED/llvm/bin/amdclang"   ]] && AMDCLANG="$ROCM_PATH_DETECTED/llvm/bin/amdclang"
  [[ -x "$ROCM_PATH_DETECTED/llvm/bin/amdclang++" ]] && AMDCLANGPP="$ROCM_PATH_DETECTED/llvm/bin/amdclang++"
fi

if [[ -n "$AMDCLANG" ]]; then
  mark_ok "amdclang present: $AMDCLANG"
else
  mark_missing "amdclang not found at \$ROCM_PATH/llvm/bin/amdclang"
  hint "build-paddle-rocm-wheel.sh requires amdclang/amdclang++ as host compilers."
  hint "Plain GCC will fail mid-compile when ROCm headers enter normal C++ translation units."
fi

if [[ -n "$AMDCLANGPP" ]]; then
  mark_ok "amdclang++ present: $AMDCLANGPP"
else
  mark_missing "amdclang++ not found at \$ROCM_PATH/llvm/bin/amdclang++"
fi

# ---------- GPU detection (rocminfo) ----------

section "GPU"

GFX_TARGET=""
GPU_MARKETING=""
DEVICE_COUNT=0

if [[ -n "$ROCMINFO_BIN" ]]; then
  ROCMINFO_OUT="$("$ROCMINFO_BIN" 2>/dev/null || true)"
  if [[ -n "$ROCMINFO_OUT" ]]; then
    # gfxNNNN ids
    mapfile -t _gfx_lines < <(printf '%s\n' "$ROCMINFO_OUT" | grep -oE 'gfx[0-9a-f]+' | awk '!seen[$0]++')
    if (( ${#_gfx_lines[@]} > 0 )); then
      GFX_TARGET="${_gfx_lines[0]}"
      DEVICE_COUNT="${#_gfx_lines[@]}"
    fi
    # Marketing name lines (rocminfo prints "Marketing Name:")
    GPU_MARKETING="$(printf '%s\n' "$ROCMINFO_OUT" | awk -F':' '/Marketing Name/ {gsub(/^ +| +$/,"",$2); print $2; exit}')"
  fi
fi

if [[ -n "$GFX_TARGET" ]]; then
  mark_ok "GPU detected: ${GPU_MARKETING:-unknown marketing name} (${GFX_TARGET})"
  if (( DEVICE_COUNT > 1 )); then
    hint "$DEVICE_COUNT distinct gfx targets seen: ${_gfx_lines[*]}. The build will compile for AMDGPU_TARGETS only."
  fi
  case "$GFX_TARGET" in
    gfx1151)
      hint "Verified target. No override needed."
      ;;
    gfx110*)
      mark_warn "RDNA3 consumer/workstation target — same patch set is expected to apply, but unverified."
      hint "Set AMDGPU_TARGETS=$GFX_TARGET when invoking the build."
      ;;
    gfx90a|gfx940|gfx941|gfx942)
      mark_warn "CDNA target — patch set is expected to apply, but unverified."
      hint "Set AMDGPU_TARGETS=$GFX_TARGET when invoking the build."
      ;;
    gfx906|gfx908|gfx926|gfx928|gfx936)
      mark_warn "Older CDNA / Vega target — Paddle v3.3.1 ROCm CMake hard-codes some of these but ROCm 7.x patches may interact poorly. Treat as experimental."
      hint "Set AMDGPU_TARGETS=$GFX_TARGET when invoking the build."
      ;;
    gfx103*|gfx101*)
      mark_warn "Pre-RDNA3 desktop target — verified path is RDNA3+. Expect to need additional patch work."
      hint "Set AMDGPU_TARGETS=$GFX_TARGET when invoking the build."
      ;;
    *)
      mark_warn "Unrecognized gfx target. Builds may compile but are completely unverified."
      hint "Set AMDGPU_TARGETS=$GFX_TARGET when invoking the build, then capture verify output."
      ;;
  esac
else
  if [[ -n "$ROCMINFO_BIN" ]]; then
    mark_missing "rocminfo ran but reported no gfx targets"
    hint "Likely means the kernel driver isn't seeing the GPU. On native Linux check 'lsmod | grep amdgpu' and 'dmesg | grep -i amdgpu'. On WSL check that you're on WSL2 and have a recent Adrenalin driver on the Windows side."
  else
    mark_missing "Cannot detect GPU without rocminfo. Install ROCm first."
  fi
fi

# ---------- Device files ----------

section "Device files"

case "$PLATFORM" in
  wsl)
    if [[ -e /dev/dxg ]]; then
      mark_ok "/dev/dxg present (WSL2 GPU passthrough)"
    else
      mark_missing "/dev/dxg missing — WSL2 GPU passthrough not active"
      hint "Confirm Windows-side Adrenalin/AMD driver supports WSL2 GPU and you're on WSL2 (not WSL1)."
    fi
    if [[ -e /dev/kfd ]]; then
      mark_warn "/dev/kfd present on WSL — unusual; native ROCm device file shouldn't normally exist on WSL"
    fi
    ;;
  linux)
    if [[ -e /dev/kfd ]]; then
      mark_ok "/dev/kfd present (ROCm KFD driver)"
    else
      mark_missing "/dev/kfd missing — kernel doesn't expose the ROCm device"
      hint "Confirm 'lsmod | grep amdgpu' shows the module loaded; install rocm-smi-lib + run as a user in the 'render' group."
    fi
    if compgen -G '/dev/dri/renderD*' >/dev/null; then
      mark_ok "/dev/dri/renderD* present"
    else
      mark_missing "/dev/dri/renderD* missing — no render node, GPU effectively invisible to userspace"
    fi
    ;;
esac

# ---------- Native-Linux-only: kernel module + groups ----------

if [[ "$PLATFORM" == "linux" ]]; then
  section "Native Linux extras"
  if lsmod 2>/dev/null | grep -q '^amdgpu'; then
    mark_ok "amdgpu kernel module loaded"
  else
    mark_warn "amdgpu kernel module not detected (lsmod). May still be built into the kernel — check 'cat /sys/class/drm/card*/device/vendor' for 0x1002."
  fi
  USER_GROUPS="$(id -nG 2>/dev/null || true)"
  if printf '%s\n' "$USER_GROUPS" | tr ' ' '\n' | grep -q '^video$'; then
    mark_ok "user is in 'video' group"
  else
    mark_warn "user is not in 'video' group"
    hint "sudo usermod -aG video \"\$USER\" && newgrp video"
  fi
  if printf '%s\n' "$USER_GROUPS" | tr ' ' '\n' | grep -q '^render$'; then
    mark_ok "user is in 'render' group"
  else
    mark_warn "user is not in 'render' group"
    hint "sudo usermod -aG render \"\$USER\" && newgrp render"
  fi
fi

# ---------- General build tooling ----------

section "Build tooling"

check_cmd() {
  # check_cmd <cmd> <required|optional> [note]
  local cmd="$1"
  local kind="${2:-required}"
  local note="${3:-}"
  if command -v "$cmd" >/dev/null 2>&1; then
    local ver=""
    case "$cmd" in
      python3.12) ver="$($cmd --version 2>&1 | head -1)" ;;
      git|cmake|ninja|ccache) ver="$($cmd --version 2>&1 | head -1)" ;;
      *)          ver="" ;;
    esac
    mark_ok "$cmd present${ver:+ — $ver}"
  else
    if [[ "$kind" == "required" ]]; then
      mark_missing "$cmd not found${note:+ — $note}"
    else
      mark_warn "$cmd not found (optional)${note:+ — $note}"
    fi
  fi
}

check_cmd python3.12 required "verified ABI"
check_cmd git        required
check_cmd cmake      required
check_cmd rg         required "used by the build wrapper to inspect CMake targets"
check_cmd ninja      optional "speeds up the build"
check_cmd ccache     optional "speeds up rebuilds"

# ---------- Resource budget ----------

section "Resources"

if command -v nproc >/dev/null 2>&1; then
  NPROC="$(nproc)"
  RECOMMENDED_PARALLEL=$(( NPROC / 2 ))
  (( RECOMMENDED_PARALLEL < 2 )) && RECOMMENDED_PARALLEL=2
  mark_ok "CPU: $NPROC logical cores (CMAKE_BUILD_PARALLEL_LEVEL recommended ≤ $RECOMMENDED_PARALLEL)"
else
  mark_warn "nproc not available; can't recommend CMAKE_BUILD_PARALLEL_LEVEL"
fi

if command -v free >/dev/null 2>&1; then
  RAM_GB="$(free -g | awk '/^Mem:/ {print $2}')"
  if [[ -n "$RAM_GB" ]]; then
    if (( RAM_GB >= 24 )); then
      mark_ok "RAM: ${RAM_GB} GB"
    elif (( RAM_GB >= 16 )); then
      mark_warn "RAM: ${RAM_GB} GB — link step of libpaddle.so can use 12–16 GB. Set CMAKE_BUILD_PARALLEL_LEVEL=2 or add swap."
    else
      mark_warn "RAM: ${RAM_GB} GB — likely too low for parallel link; expect OOM. Build serially or use a bigger machine."
    fi
  fi
fi

if command -v df >/dev/null 2>&1; then
  HOME_FREE_GB="$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [[ -n "$HOME_FREE_GB" ]]; then
    if (( HOME_FREE_GB >= 20 )); then
      mark_ok "Home free: ${HOME_FREE_GB} GB (~12 GB used by full build)"
    else
      mark_warn "Home free: ${HOME_FREE_GB} GB — tight; the full build cache can use ~12 GB"
    fi
  fi
fi

# ---------- Summary + recommended overrides ----------

section "Recommended overrides"

if (( CRITICAL_FAIL )); then
  printf '  %sCritical checks failed.%s Fix the [fail] items above before building.\n' "$C_BAD" "$C_END"
elif [[ -n "$GFX_TARGET" && -n "$ROCM_PATH_DETECTED" ]]; then
  printf '  Run with these env vars set (or export them before sourcing build-manifest.env):\n\n'
  printf '%s    AMDGPU_TARGETS=%s\n' "$C_BOLD" "$GFX_TARGET"
  printf '    ROCM_PATH=%s%s\n\n' "$ROCM_PATH_DETECTED" "$C_END"
  printf '  One-liner for the canonical rebuild:\n\n'
  printf '%s    AMDGPU_TARGETS=%s ROCM_PATH=%s scripts/rebuild-and-verify-rocm-wheel.sh%s\n' \
         "$C_BOLD" "$GFX_TARGET" "$ROCM_PATH_DETECTED" "$C_END"
fi

printf '\n'

if (( CRITICAL_FAIL )); then
  printf '%s== Result: NOT READY ==%s\n' "$C_BAD" "$C_END"
  exit 1
elif (( SOFT_WARN )); then
  printf '%s== Result: ready with warnings ==%s\n' "$C_WARN" "$C_END"
  exit 2
else
  printf '%s== Result: ready ==%s\n' "$C_OK" "$C_END"
  exit 0
fi
