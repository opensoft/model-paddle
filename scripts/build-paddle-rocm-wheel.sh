#!/usr/bin/env bash
set -Eeuo pipefail

# Build a ROCm-enabled PaddlePaddle wheel for the LedgerLinc workstation path.
#
# This intentionally builds outside the repository and never modifies the
# project .venv. Defaults are tuned for the current WSL ROCm workstation:
# Python 3.12, ROCm 7.2, AMD gfx1151.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_ROOT="${PADDLE_BUILD_ROOT:-$HOME/.cache/ledgerlinc/paddle-rocm}"
SRC_DIR="${PADDLE_SRC_DIR:-$BUILD_ROOT/Paddle}"
BUILD_DIR="${PADDLE_CMAKE_BUILD_DIR:-$BUILD_ROOT/build-v3.3.1-rocm-amdclang}"
WHEELHOUSE="${PADDLE_WHEELHOUSE:-$BUILD_ROOT/wheelhouse}"
BUILD_VENV="${PADDLE_BUILD_VENV:-$BUILD_ROOT/.venv-build}"
PADDLE_TAG="${PADDLE_TAG:-v3.3.1}"
ROCM_PATH_VALUE="${ROCM_PATH:-/opt/rocm-7.2.0}"
AMDGPU_TARGETS_VALUE="${AMDGPU_TARGETS:-gfx1151}"
PYTHON_BIN_VALUE="${PYTHON_BIN:-python3.12}"
HOST_CC_VALUE="${PADDLE_HOST_CC:-$ROCM_PATH_VALUE/llvm/bin/amdclang}"
HOST_CXX_VALUE="${PADDLE_HOST_CXX:-$ROCM_PATH_VALUE/llvm/bin/amdclang++}"
BUILD_JOBS="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
PHASE="${1:-build}"

usage() {
  cat <<'EOF'
Usage: scripts/build-paddle-rocm-wheel.sh [prepare|configure|build]

Environment overrides:
  PADDLE_BUILD_ROOT       External working root. Default: ~/.cache/ledgerlinc/paddle-rocm
  PADDLE_TAG              Paddle tag to build. Default: v3.3.1
  ROCM_PATH               ROCm root. Default: /opt/rocm-7.2.0
  AMDGPU_TARGETS          ROCm offload targets. Default: gfx1151
  PYTHON_BIN              Python used for the wheel. Default: python3.12
  PADDLE_HOST_CC          Host C compiler. Default: $ROCM_PATH/llvm/bin/amdclang
  PADDLE_HOST_CXX         Host C++ compiler. Default: $ROCM_PATH/llvm/bin/amdclang++
  CMAKE_BUILD_PARALLEL_LEVEL
                          Build parallelism. Default: half of nproc, min 2

Phases:
  prepare    Clone/update Paddle, create build venv, patch ROCm CMake.
  configure  Run prepare, then run CMake configure.
  build      Run configure, then build the python_package target.
EOF
}

if [[ "$PHASE" == "-h" || "$PHASE" == "--help" ]]; then
  usage
  exit 0
fi

if [[ "$PHASE" != "prepare" && "$PHASE" != "configure" && "$PHASE" != "build" ]]; then
  usage >&2
  exit 2
fi

log() {
  printf '[paddle-rocm] %s\n' "$*"
}

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

resolve_python() {
  command -v "$PYTHON_BIN_VALUE"
}

setup_env() {
  export ROCM_PATH="$ROCM_PATH_VALUE"
  export HIP_PATH="$ROCM_PATH_VALUE"
  export HSA_ENABLE_DXG_DETECTION="${HSA_ENABLE_DXG_DETECTION:-1}"
  export HSA_ENABLE_SDMA="${HSA_ENABLE_SDMA:-0}"
  export AMDGPU_TARGETS="$AMDGPU_TARGETS_VALUE"
  export CC="$HOST_CC_VALUE"
  export CXX="$HOST_CXX_VALUE"
  export SKIP_STUB_GEN="${SKIP_STUB_GEN:-ON}"
  export PATH="$BUILD_VENV/bin:$ROCM_PATH/bin:$ROCM_PATH/llvm/bin:$PATH"
  export LD_LIBRARY_PATH="$ROCM_PATH/lib:$ROCM_PATH/lib/llvm/lib:${LD_LIBRARY_PATH:-}"
  if [[ -f "$ROCM_PATH/lib/libhsa-runtime64.so.1" ]]; then
    export LD_PRELOAD="$ROCM_PATH/lib/libhsa-runtime64.so.1${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
}

clone_source() {
  mkdir -p "$BUILD_ROOT" "$WHEELHOUSE"
  if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "cloning Paddle $PADDLE_TAG into $SRC_DIR"
    git clone --depth 1 --branch "$PADDLE_TAG" https://github.com/PaddlePaddle/Paddle.git "$SRC_DIR"
  else
    log "refreshing Paddle source at $SRC_DIR"
    git -C "$SRC_DIR" fetch --depth 1 origin "refs/tags/$PADDLE_TAG:refs/tags/$PADDLE_TAG"
    git -C "$SRC_DIR" checkout --detach "$PADDLE_TAG"
  fi
}

create_build_venv() {
  local python_bin
  python_bin="$(resolve_python)"
  if [[ ! -x "$BUILD_VENV/bin/python" ]]; then
    log "creating build venv at $BUILD_VENV"
    "$python_bin" -m venv "$BUILD_VENV"
  fi

  log "installing local build helper tools into $BUILD_VENV"
  "$BUILD_VENV/bin/python" -m pip install -U pip setuptools wheel
  "$BUILD_VENV/bin/python" -m pip install -U \
    numpy "protobuf>=3.20.2,<5" patchelf swig \
    requests httpx Pillow opt_einsum==3.3.0 networkx safetensors \
    pyyaml typing_extensions packaging decorator astor gast cython
}

patch_paddle_rocm_cmake() {
  local hip_cmake="$SRC_DIR/cmake/hip.cmake"
  local marker="LedgerLinc ROCm workstation patch"
  log "patching Paddle ROCm CMake for ROCm 7.x layout and AMDGPU_TARGETS=$AMDGPU_TARGETS_VALUE"
  "$BUILD_VENV/bin/python" - "$hip_cmake" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm workstation patch" in text:
    raise SystemExit(0)

text = text.replace(
'''if(NOT DEFINED ENV{ROCM_PATH})
  set(ROCM_PATH
      "/opt/rocm"
      CACHE PATH "Path to which ROCm has been installed")
  set(HIP_PATH
      ${ROCM_PATH}/hip
      CACHE PATH "Path to which HIP has been installed")
  set(HIP_CLANG_PATH
      ${ROCM_PATH}/llvm/bin
      CACHE PATH "Path to which clang has been installed")
else()
  set(ROCM_PATH
      $ENV{ROCM_PATH}
      CACHE PATH "Path to which ROCm has been installed")
  set(HIP_PATH
      ${ROCM_PATH}/hip
      CACHE PATH "Path to which HIP has been installed")
  set(HIP_CLANG_PATH
      ${ROCM_PATH}/llvm/bin
      CACHE PATH "Path to which clang has been installed")
endif()
set(CMAKE_MODULE_PATH "${HIP_PATH}/cmake" ${CMAKE_MODULE_PATH})
set(CMAKE_PREFIX_PATH "${ROCM_PATH}" ${CMAKE_PREFIX_PATH})
''',
'''# LedgerLinc ROCm workstation patch:
# ROCm 7.x packages on this workstation use a flat ${ROCM_PATH}/include
# and ${ROCM_PATH}/lib/cmake layout rather than the older ${ROCM_PATH}/hip
# tree that Paddle v3.3.1 assumes here.
if(NOT DEFINED ENV{ROCM_PATH})
  set(ROCM_PATH
      "/opt/rocm"
      CACHE PATH "Path to which ROCm has been installed")
else()
  set(ROCM_PATH
      $ENV{ROCM_PATH}
      CACHE PATH "Path to which ROCm has been installed")
endif()
if(EXISTS "${ROCM_PATH}/hip")
  set(HIP_PATH
      ${ROCM_PATH}/hip
      CACHE PATH "Path to which HIP has been installed")
else()
  set(HIP_PATH
      ${ROCM_PATH}
      CACHE PATH "Path to which HIP has been installed")
endif()
set(HIP_CLANG_PATH
    ${ROCM_PATH}/llvm/bin
    CACHE PATH "Path to which clang has been installed")
set(CMAKE_MODULE_PATH "${HIP_PATH}/cmake" "${ROCM_PATH}/lib/cmake/hip" ${CMAKE_MODULE_PATH})
set(CMAKE_PREFIX_PATH "${ROCM_PATH}" ${CMAKE_PREFIX_PATH})
''')

text = text.replace(
'''find_hip_version(${HIP_PATH}/include/hip/hip_version.h)
''',
'''if(EXISTS "${HIP_PATH}/include/hip/hip_version.h")
  find_hip_version(${HIP_PATH}/include/hip/hip_version.h)
else()
  find_hip_version(${ROCM_PATH}/include/hip/hip_version.h)
endif()
''')

old_arch_block = '''list(APPEND HIP_HCC_FLAGS --offload-arch=gfx906) # Z100 (ZIFANG)
list(APPEND HIP_HCC_FLAGS --offload-arch=gfx926) # K100 (KONGING)
list(APPEND HIP_HCC_FLAGS --offload-arch=gfx928) # K100_AI (KONGING_AI)
list(APPEND HIP_HCC_FLAGS --offload-arch=gfx936) # BW1000 (BOWEN)
list(APPEND HIP_CLANG_FLAGS -fno-gpu-rdc)
list(APPEND HIP_CLANG_FLAGS --offload-arch=gfx906) # Z100 (ZIFANG)
list(APPEND HIP_CLANG_FLAGS --offload-arch=gfx926) # K100 (KONGING)
list(APPEND HIP_CLANG_FLAGS --offload-arch=gfx928) # K100_AI (KONGING_AI)
list(APPEND HIP_CLANG_FLAGS --offload-arch=gfx936) # BW1000 (BOWEN)
'''
new_arch_block = '''# LedgerLinc ROCm workstation patch:
# Let the local build choose ROCm offload targets. The v3.3.1 default only
# targets older Hygon/Instinct architectures and will not produce code for
# gfx1151.
set(PADDLE_ROCM_OFFLOAD_ARCHS "$ENV{AMDGPU_TARGETS}")
if(NOT PADDLE_ROCM_OFFLOAD_ARCHS)
  set(PADDLE_ROCM_OFFLOAD_ARCHS "gfx906;gfx926;gfx928;gfx936")
endif()
foreach(_PADDLE_ROCM_ARCH IN LISTS PADDLE_ROCM_OFFLOAD_ARCHS)
  list(APPEND HIP_HCC_FLAGS --offload-arch=${_PADDLE_ROCM_ARCH})
endforeach()
list(APPEND HIP_CLANG_FLAGS -fno-gpu-rdc)
foreach(_PADDLE_ROCM_ARCH IN LISTS PADDLE_ROCM_OFFLOAD_ARCHS)
  list(APPEND HIP_CLANG_FLAGS --offload-arch=${_PADDLE_ROCM_ARCH})
endforeach()
'''
if old_arch_block not in text:
    raise SystemExit("expected ROCm offload-arch block was not found")
text = text.replace(old_arch_block, new_arch_block)
path.write_text(text)
PY

  write_warp_patch_helper
  patch_warp_external_projects
  patch_paddle_rocm_complex_header
  patch_paddle_rocm_enforce_header
  patch_paddle_rocm_platform_enforce_header
  patch_paddle_rocm_pointer_attribute
  patch_paddle_rocm_dynload_rocm_driver
  patch_paddle_rocm_allocator_facade
  patch_paddle_rocm_blas_complex_scalars
  patch_paddle_rocm_values_vectors_thrust
  patch_paddle_rocm_thrust_shuffle_header
  patch_paddle_rocm_argsort_rocprim_traits
  patch_paddle_rocm_topk_rocprim_traits
  patch_paddle_rocm_topk_shared_warp_count
  patch_paddle_rocm_mode_rocprim_traits
  patch_paddle_rocm_hiprand_includes
}

write_warp_patch_helper() {
  local helper="$SRC_DIR/patches/ledgerlinc_rocm_patch_warp.py"
  cat >"$helper" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm workstation patch" in text:
    raise SystemExit(0)

text = text.replace(
'''if(NOT DEFINED ENV{ROCM_PATH})
    set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to which ROCm has been installed")
    set(HIP_PATH ${ROCM_PATH}/hip CACHE PATH "Path to which HIP has been installed")
    set(HIP_CLANG_PATH ${ROCM_PATH}/llvm/bin CACHE PATH "Path to which clang has been installed")
else()
    set(ROCM_PATH $ENV{ROCM_PATH} CACHE PATH "Path to which ROCm has been installed")
    set(HIP_PATH ${ROCM_PATH}/hip CACHE PATH "Path to which HIP has been installed")
    set(HIP_CLANG_PATH ${ROCM_PATH}/llvm/bin CACHE PATH "Path to which clang has been installed")
endif()
set(CMAKE_MODULE_PATH "${HIP_PATH}/cmake" ${CMAKE_MODULE_PATH})
''',
'''# LedgerLinc ROCm workstation patch:
# ROCm 7.x uses a flat ${ROCM_PATH}/include and ${ROCM_PATH}/lib/cmake layout.
if(NOT DEFINED ENV{ROCM_PATH})
    set(ROCM_PATH "/opt/rocm" CACHE PATH "Path to which ROCm has been installed")
else()
    set(ROCM_PATH $ENV{ROCM_PATH} CACHE PATH "Path to which ROCm has been installed")
endif()
if(EXISTS "${ROCM_PATH}/hip")
    set(HIP_PATH ${ROCM_PATH}/hip CACHE PATH "Path to which HIP has been installed")
else()
    set(HIP_PATH ${ROCM_PATH} CACHE PATH "Path to which HIP has been installed")
endif()
set(HIP_CLANG_PATH ${ROCM_PATH}/llvm/bin CACHE PATH "Path to which clang has been installed")
set(CMAKE_MODULE_PATH "${HIP_PATH}/cmake" "${ROCM_PATH}/lib/cmake/hip" ${CMAKE_MODULE_PATH})
set(CMAKE_PREFIX_PATH "${ROCM_PATH}" ${CMAKE_PREFIX_PATH})
''')

for old in (
    '''list(APPEND HIP_HCC_FLAGS -fno-gpu-rdc)
list(APPEND HIP_HCC_FLAGS --amdgpu-target=gfx906)
list(APPEND HIP_HCC_FLAGS --amdgpu-target=gfx926)
list(APPEND HIP_HCC_FLAGS --amdgpu-target=gfx928)
list(APPEND HIP_CLANG_FLAGS -fno-gpu-rdc)
list(APPEND HIP_CLANG_FLAGS --amdgpu-target=gfx906)
list(APPEND HIP_CLANG_FLAGS --amdgpu-target=gfx926)
list(APPEND HIP_CLANG_FLAGS --amdgpu-target=gfx928)
''',
    '''list(APPEND HIP_HCC_FLAGS -fno-gpu-rdc)
list(APPEND HIP_HCC_FLAGS --amdgpu-target=gfx906)
list(APPEND HIP_CLANG_FLAGS -fno-gpu-rdc)
list(APPEND HIP_CLANG_FLAGS --amdgpu-target=gfx906)
''',
):
    if old in text:
        text = text.replace(
            old,
            '''list(APPEND HIP_HCC_FLAGS -fno-gpu-rdc)
set(PADDLE_ROCM_OFFLOAD_ARCHS "$ENV{AMDGPU_TARGETS}")
if(NOT PADDLE_ROCM_OFFLOAD_ARCHS)
  set(PADDLE_ROCM_OFFLOAD_ARCHS "gfx906;gfx926;gfx928;gfx936")
endif()
foreach(_PADDLE_ROCM_ARCH IN LISTS PADDLE_ROCM_OFFLOAD_ARCHS)
  list(APPEND HIP_HCC_FLAGS --offload-arch=${_PADDLE_ROCM_ARCH})
endforeach()
list(APPEND HIP_CLANG_FLAGS -fno-gpu-rdc)
foreach(_PADDLE_ROCM_ARCH IN LISTS PADDLE_ROCM_OFFLOAD_ARCHS)
  list(APPEND HIP_CLANG_FLAGS --offload-arch=${_PADDLE_ROCM_ARCH})
endforeach()
''',
        )
        break

text = text.replace(
    'find_library(ROCM_HIPRTC_LIB ${hip_library_name} HINTS ${HIP_PATH}/lib)',
    'find_library(ROCM_HIPRTC_LIB ${hip_library_name} HINTS ${HIP_PATH}/lib ${ROCM_PATH}/lib)',
)

path.write_text(text)
PY
}

patch_warp_external_projects() {
  local marker="ledgerlinc_rocm_patch_warp.py"
  local warpctc="$SRC_DIR/cmake/external/warpctc.cmake"
  local warprnnt="$SRC_DIR/cmake/external/warprnnt.cmake"

  if ! rg -q "$marker" "$warpctc"; then
    "$BUILD_VENV/bin/python" - "$warpctc" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''-p1 < ${PADDLE_SOURCE_DIR}/patches/warpctc/devicetypes.cuh.patch && patch
      -p1 < ${PADDLE_SOURCE_DIR}/patches/warpctc/hip.cmake.patch)'''
new = '''-p1 < ${PADDLE_SOURCE_DIR}/patches/warpctc/devicetypes.cuh.patch && patch
      -p1 < ${PADDLE_SOURCE_DIR}/patches/warpctc/hip.cmake.patch &&
      ${PYTHON_EXECUTABLE}
      ${PADDLE_SOURCE_DIR}/patches/ledgerlinc_rocm_patch_warp.py
      ${SOURCE_DIR}/cmake/hip.cmake)'''
if old not in text:
    raise SystemExit("expected warpctc ROCm patch command was not found")
path.write_text(text.replace(old, new))
PY
  fi

  if ! rg -q "$marker" "$warprnnt"; then
    "$BUILD_VENV/bin/python" - "$warprnnt" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
old = '''patch -p1 <
      ${PADDLE_SOURCE_DIR}/patches/warprnnt/CMakeLists.txt.rocm.patch)'''
new = '''patch -p1 <
      ${PADDLE_SOURCE_DIR}/patches/warprnnt/CMakeLists.txt.rocm.patch &&
      ${PYTHON_EXECUTABLE}
      ${PADDLE_SOURCE_DIR}/patches/ledgerlinc_rocm_patch_warp.py
      ${SOURCE_DIR}/cmake/hip.cmake)'''
if old not in text:
    raise SystemExit("expected warprnnt ROCm patch command was not found")
path.write_text(text.replace(old, new))
PY
  fi
}

patch_paddle_rocm_complex_header() {
  local complex_header="$SRC_DIR/paddle/phi/common/complex.h"
  log "patching Paddle ROCm complex header for ROCm 7.x host C++ includes"
  "$BUILD_VENV/bin/python" - "$complex_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm thrust host-include patch" in text:
    raise SystemExit(0)

text = text.replace(
'''#ifdef PADDLE_WITH_HIP
#include <hip/hip_complex.h>
#include <thrust/complex.h>  // NOLINT
#endif
''',
'''#ifdef PADDLE_WITH_HIP
#include <hip/hip_complex.h>
// LedgerLinc ROCm thrust host-include patch:
// ROCm 7.x thrust includes rocPRIM device intrinsics that cannot be parsed by
// normal host-only .cc targets. Keep thrust complex conversions for HIP
// translation units, but avoid exposing rocPRIM to ordinary Paddle host code.
#if defined(__HIPCC__) || defined(__HIP__)
#include <thrust/complex.h>  // NOLINT
#define PADDLE_WITH_HIP_THRUST_COMPLEX
#endif
#endif
''')

old = '''#if defined(PADDLE_WITH_CUDA) || defined(PADDLE_WITH_HIP)

  template <typename T1>
  HOSTDEVICE inline explicit complex(const thrust::complex<T1>& c) {
    real = c.real();
    imag = c.imag();
  }

#if defined(PADDLE_WITH_CCCL)
  template <typename T1>
  HOSTDEVICE inline explicit complex(const cuda::std::complex<T1>& c) {
    real = c.real();
    imag = c.imag();
  }
#endif

  template <typename T1>
  HOSTDEVICE inline explicit operator thrust::complex<T1>() const {
    return thrust::complex<T1>(real, imag);
  }

#ifdef PADDLE_WITH_HIP
'''
new = '''#if defined(PADDLE_WITH_CUDA) || defined(PADDLE_WITH_HIP_THRUST_COMPLEX)

  template <typename T1>
  HOSTDEVICE inline explicit complex(const thrust::complex<T1>& c) {
    real = c.real();
    imag = c.imag();
  }

#if defined(PADDLE_WITH_CCCL)
  template <typename T1>
  HOSTDEVICE inline explicit complex(const cuda::std::complex<T1>& c) {
    real = c.real();
    imag = c.imag();
  }
#endif

  template <typename T1>
  HOSTDEVICE inline explicit operator thrust::complex<T1>() const {
    return thrust::complex<T1>(real, imag);
  }

#endif

#ifdef PADDLE_WITH_HIP
'''
if old not in text:
    raise SystemExit("expected thrust complex block was not found")
text = text.replace(old, new)

old = '''#else
  HOSTDEVICE inline explicit operator cuFloatComplex() const {
    return make_cuFloatComplex(real, imag);
  }

  HOSTDEVICE inline explicit operator cuDoubleComplex() const {
    return make_cuDoubleComplex(real, imag);
  }
#endif
#endif
'''
new = '''#elif defined(PADDLE_WITH_CUDA)
  HOSTDEVICE inline explicit operator cuFloatComplex() const {
    return make_cuFloatComplex(real, imag);
  }

  HOSTDEVICE inline explicit operator cuDoubleComplex() const {
    return make_cuDoubleComplex(real, imag);
  }
#endif
'''
if old not in text:
    raise SystemExit("expected CUDA/HIP complex conversion tail was not found")
text = text.replace(old, new)

path.write_text(text)
PY
}

patch_paddle_rocm_enforce_header() {
  local enforce_header="$SRC_DIR/paddle/phi/core/enforce.h"
  log "patching Paddle ROCm enforce header for ROCm 7.x host C++ includes"
  "$BUILD_VENV/bin/python" - "$enforce_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm thrust system error host-include patch v2" in text:
    raise SystemExit(0)

original = '''#ifdef PADDLE_WITH_HIP
#include <hiprand/hiprand.h>
#include <miopen/miopen.h>
#include <rocblas/rocblas.h>
#include <thrust/system/hip/error.h>
#include <thrust/system_error.h>  // NOLINT
#endif
'''
patched_v1 = '''#ifdef PADDLE_WITH_HIP
#include <hiprand/hiprand.h>
#include <miopen/miopen.h>
#include <rocblas/rocblas.h>
// LedgerLinc ROCm thrust system error host-include patch:
// ROCm 7.x thrust/system/hip/error.h pulls in rocPRIM device intrinsics.
// Avoid exposing that path to ordinary host-only .cc targets.
#if defined(__HIPCC__) || defined(__HIP__)
#include <thrust/system/hip/error.h>
#endif
#include <thrust/system_error.h>  // NOLINT
#endif
'''
new = '''#ifdef PADDLE_WITH_HIP
#include <hiprand/hiprand.h>
#include <miopen/miopen.h>
#include <rocblas/rocblas.h>
// LedgerLinc ROCm thrust system error host-include patch v2:
// ROCm 7.x thrust system headers pull in rocPRIM device intrinsics. Avoid
// exposing that path to ordinary host-only .cc targets.
#if defined(__HIPCC__) || defined(__HIP__)
#include <thrust/system/hip/error.h>
#include <thrust/system_error.h>  // NOLINT
#endif
#endif
'''
if original in text:
    path.write_text(text.replace(original, new))
elif patched_v1 in text:
    path.write_text(text.replace(patched_v1, new))
else:
    raise SystemExit("expected HIP thrust system error block was not found")
PY
}

patch_paddle_rocm_platform_enforce_header() {
  local enforce_header="$SRC_DIR/paddle/fluid/platform/enforce.h"
  log "patching Paddle platform enforce header for ROCm 7.x host C++ includes"
  "$BUILD_VENV/bin/python" - "$enforce_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm platform thrust system error host-include patch" in text:
    raise SystemExit(0)

original = '''#ifdef PADDLE_WITH_HIP
#include <hiprand/hiprand.h>
#include <miopen/miopen.h>
#include <rocblas/rocblas.h>
#include <thrust/system/hip/error.h>
#include <thrust/system_error.h>  // NOLINT
#endif
'''
new = '''#ifdef PADDLE_WITH_HIP
#include <hiprand/hiprand.h>
#include <miopen/miopen.h>
#include <rocblas/rocblas.h>
// LedgerLinc ROCm platform thrust system error host-include patch:
// ROCm 7.x thrust system headers pull in rocPRIM device intrinsics. Keep them
// out of ordinary host-only framework targets.
#if defined(__HIPCC__) || defined(__HIP__)
#include <thrust/system/hip/error.h>
#include <thrust/system_error.h>  // NOLINT
#endif
#endif
'''
if original not in text:
    raise SystemExit("expected platform HIP thrust system error block was not found")
path.write_text(text.replace(original, new))
PY
}

patch_paddle_rocm_pointer_attribute() {
  local tensor_utils="$SRC_DIR/paddle/phi/api/lib/tensor_utils.cc"
  log "patching Paddle HIP pointer attribute API for ROCm 7.x"
  "$BUILD_VENV/bin/python" - "$tensor_utils" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm hipPointerAttribute_t API patch" in text:
    raise SystemExit(0)

old = '''  hipPointerAttribute_t attr = {};
  hipError_t status = hipPointerGetAttributes(&attr, data);
  if (status == hipSuccess && attr.memoryType == hipMemoryTypeDevice) {
    return phi::GPUPlace(attr.device);
  }
'''
new = '''  hipPointerAttribute_t attr = {};
  hipError_t status = hipPointerGetAttributes(&attr, data);
  // LedgerLinc ROCm hipPointerAttribute_t API patch:
  // ROCm 7.x exposes pointer memory classification as attr.type.
  if (status == hipSuccess && attr.type == hipMemoryTypeDevice) {
    return phi::GPUPlace(attr.device);
  }
'''
if old not in text:
    raise SystemExit("expected HIP pointer attribute block was not found")
path.write_text(text.replace(old, new))
PY
}

patch_paddle_rocm_dynload_rocm_driver() {
  local rocm_driver="$SRC_DIR/paddle/phi/backends/dynload/rocm_driver.cc"
  log "patching Paddle ROCm dynload wrapper definitions for VMM and graph APIs"
  "$BUILD_VENV/bin/python" - "$rocm_driver" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm dynload VMM wrapper patch" in text:
    raise SystemExit(0)

old = '''#define DEFINE_WRAP(__name) DynLoad__##__name __name

ROCM_ROUTINE_EACH(DEFINE_WRAP);
'''
new = '''#define DEFINE_WRAP(__name) DynLoad__##__name __name

// LedgerLinc ROCm dynload VMM wrapper patch:
// rocm_driver.h declares VMM and graph wrappers, but Paddle v3.3.1 only
// instantiates the base driver wrappers here. Linkers that disallow unresolved
// shared-library symbols then fail on hipMemCreate/hipMemRelease.
ROCM_ROUTINE_EACH_VVM(DEFINE_WRAP);
ROCM_ROUTINE_EACH_GPU_GRAPH(DEFINE_WRAP);
ROCM_ROUTINE_EACH(DEFINE_WRAP);
'''
if old not in text:
    raise SystemExit("expected ROCm dynload DEFINE_WRAP block was not found")
path.write_text(text.replace(old, new))
PY
}

patch_paddle_rocm_allocator_facade() {
  local allocator_facade="$SRC_DIR/paddle/phi/core/memory/allocation/allocator_facade.cc"
  log "patching Paddle allocator facade to avoid CUDA driver headers in ROCm builds"
  "$BUILD_VENV/bin/python" - "$allocator_facade" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm allocator facade CUDA-header patch" in text:
    raise SystemExit(0)

old = '''#if defined(PADDLE_WITH_CUDA)
#include "paddle/phi/backends/gpu/cuda/cuda_graph.h"
#elif defined(PADDLE_WITH_HIP)
#include "paddle/phi/backends/gpu/rocm/hip_graph.h"
#endif

#include "paddle/phi/backends/dynload/cuda_driver.h"
#include "paddle/phi/core/memory/allocation/cuda_malloc_async_allocator.h"
#include "paddle/phi/core/memory/allocation/cuda_virtual_mem_allocator.h"
#include "paddle/phi/core/memory/allocation/virtual_memory_auto_growth_best_fit_allocator.h"

#ifdef PADDLE_WITH_HIP
#include "paddle/phi/core/memory/allocation/cuda_malloc_async_allocator.h"  // NOLINT
#endif
'''
new = '''#if defined(PADDLE_WITH_CUDA)
// LedgerLinc ROCm allocator facade CUDA-header patch:
// These headers depend on the CUDA driver API and must not be included in
// ROCm-only builds. HIP uses the ordinary auto-growth allocator path below.
#include "paddle/phi/backends/gpu/cuda/cuda_graph.h"
#include "paddle/phi/backends/dynload/cuda_driver.h"
#include "paddle/phi/core/memory/allocation/cuda_malloc_async_allocator.h"
#include "paddle/phi/core/memory/allocation/cuda_virtual_mem_allocator.h"
#include "paddle/phi/core/memory/allocation/virtual_memory_auto_growth_best_fit_allocator.h"
#elif defined(PADDLE_WITH_HIP)
#include "paddle/phi/backends/gpu/rocm/hip_graph.h"
#endif
'''
if old not in text:
    raise SystemExit("expected allocator facade CUDA/HIP include block was not found")
path.write_text(text.replace(old, new))
PY
}

patch_paddle_rocm_blas_complex_scalars() {
  local blas_impl="$SRC_DIR/paddle/phi/kernels/funcs/blas/blas_impl.hip.h"
  log "patching Paddle hipBLAS complex scalar construction for host C++"
  "$BUILD_VENV/bin/python" - "$blas_impl" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm hipBLAS complex scalar host patch" in text:
    raise SystemExit(0)

replacements = {
'''  thrust::complex<float> c_alpha =
      thrust::complex<float>(alpha.real, alpha.imag);
  thrust::complex<float> c_beta = thrust::complex<float>(beta.real, beta.imag);
''':
'''  // LedgerLinc ROCm hipBLAS complex scalar host patch:
  // Use ROCm BLAS complex PODs here because this header is included from
  // ordinary host C++ translation units where ROCm Thrust is intentionally
  // not exposed.
  rocblas_float_complex c_alpha{alpha.real, alpha.imag};
  rocblas_float_complex c_beta{beta.real, beta.imag};
''',
'''  thrust::complex<double> c_alpha =
      thrust::complex<double>(alpha.real, alpha.imag);
  thrust::complex<double> c_beta =
      thrust::complex<double>(beta.real, beta.imag);
''':
'''  rocblas_double_complex c_alpha{alpha.real, alpha.imag};
  rocblas_double_complex c_beta{beta.real, beta.imag};
''',
}

next_text = text
for old, new in replacements.items():
    if old not in next_text:
        raise SystemExit("expected hipBLAS complex scalar block was not found")
    next_text = next_text.replace(old, new)
path.write_text(next_text)
PY
}

patch_paddle_rocm_values_vectors_thrust() {
  local values_vectors="$SRC_DIR/paddle/phi/kernels/funcs/values_vectors_functor.h"
  log "patching Paddle values/vectors helper to keep ROCm Thrust out of host C++"
  "$BUILD_VENV/bin/python" - "$values_vectors" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm values/vectors Thrust host patch" in text:
    raise SystemExit(0)

old_include = '''#ifdef PADDLE_WITH_HIP
#include <thrust/device_vector.h>
#include "paddle/phi/backends/dynload/rocsolver.h"
#endif  // PADDLE_WITH_HIP
'''
new_include = '''#ifdef PADDLE_WITH_HIP
#include "paddle/phi/backends/dynload/rocsolver.h"
// LedgerLinc ROCm values/vectors Thrust host patch:
// ROCm 7.x Thrust includes rocPRIM device intrinsics. Keep device_vector
// usage inside HIP translation units so CPU .cc kernels can include this
// helper while PADDLE_WITH_HIP is globally enabled.
#if defined(__HIPCC__) || defined(__HIP__)
#include <thrust/device_vector.h>
#define PADDLE_WITH_HIP_DEVICE_VECTOR
#endif
#endif  // PADDLE_WITH_HIP
'''
if old_include not in text:
    raise SystemExit("expected HIP thrust include block was not found")
text = text.replace(old_include, new_include)

old_block = '''#ifdef PADDLE_WITH_HIP
#define ROCSOLVER_SYEVJ_BATCHED_ARGTYPES(scalar_t, value_t)            \\
'''
new_block = '''#if defined(PADDLE_WITH_HIP) && defined(PADDLE_WITH_HIP_DEVICE_VECTOR)
#define ROCSOLVER_SYEVJ_BATCHED_ARGTYPES(scalar_t, value_t)            \\
'''
if old_block not in text:
    raise SystemExit("expected HIP MatrixEighFunctor block was not found")
text = text.replace(old_block, new_block, 1)

path.write_text(text)
PY
}

patch_paddle_rocm_thrust_shuffle_header() {
  local shuffle_header="$SRC_DIR/patches/thrust/thrust/shuffle.h"
  local shuffle_inl="$SRC_DIR/patches/thrust/thrust/detail/shuffle.inl"
  local generic_shuffle_header="$SRC_DIR/patches/thrust/thrust/system/detail/generic/shuffle.h"
  local generic_shuffle_inl="$SRC_DIR/patches/thrust/thrust/system/detail/generic/shuffle.inl"
  log "patching Paddle bundled Thrust shuffle shims for ROCm 7.x"
  "$BUILD_VENV/bin/python" - "$shuffle_header" "$shuffle_inl" "$generic_shuffle_header" "$generic_shuffle_inl" <<'PY'
from pathlib import Path
import sys

header = Path(sys.argv[1])
inl = Path(sys.argv[2])
generic_header = Path(sys.argv[3])
generic_inl = Path(sys.argv[4])
text = header.read_text()

if "LedgerLinc ROCm Thrust shuffle shim patch" in text:
    pass
else:
    old_head = '''#include <thrust/detail/config.h>
#include <thrust/detail/cpp11_required.h>

#if THRUST_CPP_DIALECT >= 2011

#include <thrust/detail/config.h>
'''
    new_head = '''#include <thrust/detail/config.h>
// LedgerLinc ROCm Thrust shuffle shim patch:
// ROCm 7.x no longer ships thrust/detail/cpp11_required.h. The Paddle shim is
// compiled as C++17 in this build, so the old C++11 gate is unnecessary.

#include <thrust/detail/config.h>
'''
    if old_head not in text:
        raise SystemExit("expected old Thrust shuffle C++11 gate was not found")
    text = text.replace(old_head, new_head, 1)

    old_tail = '''#include <thrust/detail/shuffle.inl>
#endif
'''
    new_tail = '''#include <thrust/detail/shuffle.inl>
'''
    if old_tail not in text:
        raise SystemExit("expected old Thrust shuffle trailing endif was not found")
    header.write_text(text.replace(old_tail, new_tail, 1))

text = inl.read_text()
if "LedgerLinc ROCm Thrust shuffle detail shim patch" in text:
    pass
else:
    old_head = '''#include <thrust/detail/config.h>
#include <thrust/detail/cpp11_required.h>

#if THRUST_CPP_DIALECT >= 2011

#include <thrust/iterator/iterator_traits.h>
'''
    new_head = '''#include <thrust/detail/config.h>
// LedgerLinc ROCm Thrust shuffle detail shim patch:
// ROCm 7.x removed thrust/detail/cpp11_required.h. This source build uses
// C++17, so keep the implementation unconditional.

#include <thrust/iterator/iterator_traits.h>
'''
    if old_head not in text:
        raise SystemExit("expected old Thrust shuffle detail C++11 gate was not found")
    text = text.replace(old_head, new_head, 1)

    old_tail = '''}  // namespace thrust

#endif
'''
    new_tail = '''}  // namespace thrust
'''
    if old_tail not in text:
        raise SystemExit("expected old Thrust shuffle detail trailing endif was not found")
    inl.write_text(text.replace(old_tail, new_tail, 1))

text = generic_header.read_text()
if "LedgerLinc ROCm Thrust generic shuffle shim patch" in text:
    pass
else:
    old_head = '''#include <thrust/detail/config.h>
#include <thrust/detail/cpp11_required.h>

#if THRUST_CPP_DIALECT >= 2011

#include <thrust/system/detail/generic/tag.h>
'''
    new_head = '''#include <thrust/detail/config.h>
// LedgerLinc ROCm Thrust generic shuffle shim patch:
// ROCm 7.x removed thrust/detail/cpp11_required.h. This source build uses
// C++17, so keep the generic shuffle declaration path unconditional.

#include <thrust/system/detail/generic/tag.h>
'''
    if old_head not in text:
        raise SystemExit("expected old Thrust generic shuffle C++11 gate was not found")
    text = text.replace(old_head, new_head, 1)

    old_tail = '''#include <thrust/system/detail/generic/shuffle.inl>

#endif
'''
    new_tail = '''#include <thrust/system/detail/generic/shuffle.inl>
'''
    if old_tail not in text:
        raise SystemExit("expected old Thrust generic shuffle trailing endif was not found")
    generic_header.write_text(text.replace(old_tail, new_tail, 1))

text = generic_inl.read_text()
if "LedgerLinc ROCm Thrust generic shuffle detail shim patch" not in text:
    text = text.replace(
        "#include <thrust/detail/config.h>\n",
        '''#include <thrust/detail/config.h>
// LedgerLinc ROCm Thrust generic shuffle detail shim patch:
// ROCm 7.x uses THRUST_EXEC_CHECK_DISABLE and already exposes
// thrust::iterator_value_t through its versioned namespace.
''',
        1,
    )

text = text.replace(
    '''namespace thrust {
template <typename Iterator>
using iterator_value_t = typename iterator_value<Iterator>::type;

namespace system {
''',
    '''namespace thrust {
namespace system {
''',
)
text = text.replace("__thrust_exec_check_disable__", "THRUST_EXEC_CHECK_DISABLE")
text = text.replace("__host__ __device__", "THRUST_HOST_DEVICE")
generic_inl.write_text(text)

for path in (header, inl, generic_header):
    text = path.read_text()
    text = text.replace("__thrust_exec_check_disable__", "THRUST_EXEC_CHECK_DISABLE")
    text = text.replace("__host__ __device__", "THRUST_HOST_DEVICE")
    path.write_text(text)
PY
}

patch_paddle_rocm_argsort_rocprim_traits() {
  log "patching Paddle argsort rocPRIM traits for ROCm 7.x"
  "$BUILD_VENV/bin/python" - "$SRC_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
files = [
    root / "paddle/phi/kernels/gpu/argsort_kernel.cu",
    root / "paddle/phi/kernels/gpu/argsort_grad_kernel.cu",
]

new_block = '''#ifdef __HIPCC__
// LedgerLinc ROCm argsort rocPRIM trait patch:
// ROCm 7.x moved custom radix-sort traits from rocprim::detail template
// specializations to rocprim::traits::define<T>.
namespace rocprim {
namespace traits {
template <>
struct define<phi::float16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7C00, 0x03FF>;
};

template <>
struct define<phi::bfloat16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7F80, 0x007F>;
};
}  // namespace traits
}  // namespace rocprim
#else
'''

old_blocks = [
'''#ifdef __HIPCC__
namespace rocprim {
namespace detail {
template <>
struct radix_key_codec_base<phi::float16>
    : radix_key_codec_integral<phi::float16, uint16_t> {};

template <>
struct radix_key_codec_base<phi::bfloat16>
    : radix_key_codec_integral<phi::bfloat16, uint16_t> {};

#if HIP_VERSION >= 50400000
template <>
struct float_bit_mask<phi::float16> : float_bit_mask<rocprim::half> {};

template <>
struct float_bit_mask<phi::bfloat16> : float_bit_mask<rocprim::bfloat16> {};
#endif
}  // namespace detail
}  // namespace rocprim
#else
''',
'''#ifdef __HIPCC__
namespace rocprim {
namespace detail {
template <>
struct radix_key_codec_base<phi::float16>
    : radix_key_codec_integral<phi::float16, uint16_t> {};

template <>
struct radix_key_codec_base<phi::bfloat16>
    : radix_key_codec_integral<phi::bfloat16, uint16_t> {};
}  // namespace detail
}  // namespace rocprim
#else
''',
]

for path in files:
    text = path.read_text()
    if "LedgerLinc ROCm argsort rocPRIM trait patch" in text:
        text = text.replace(
            "  using is_arithmetic = rocprim::traits::is_arithmetic::values<true>;\n",
            "",
        )
        path.write_text(text)
        continue
    for old in old_blocks:
        if old in text:
            path.write_text(text.replace(old, new_block, 1))
            break
    else:
        raise SystemExit(f"expected argsort ROCm trait block was not found: {path}")
PY
}

patch_paddle_rocm_topk_rocprim_traits() {
  local topk_header="$SRC_DIR/paddle/phi/kernels/funcs/top_k_function_cuda.h"
  log "patching Paddle top-k rocPRIM traits for ROCm 7.x"
  "$BUILD_VENV/bin/python" - "$topk_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

new_block = '''#ifdef __HIPCC__
// LedgerLinc ROCm top-k rocPRIM trait patch:
// ROCm 7.x moved custom radix-sort traits from rocprim::detail template
// specializations to rocprim::traits::define<T>.
namespace rocprim {
namespace traits {
template <>
struct define<phi::float16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7C00, 0x03FF>;
};

template <>
struct define<phi::bfloat16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7F80, 0x007F>;
};
}  // namespace traits
}  // namespace rocprim
namespace cub = hipcub;
#else
'''

old_block = '''#ifdef __HIPCC__
namespace rocprim {
namespace detail {
template <>
struct radix_key_codec_base<phi::float16>
    : radix_key_codec_integral<phi::float16, uint16_t> {};

template <>
struct radix_key_codec_base<phi::bfloat16>
    : radix_key_codec_integral<phi::bfloat16, uint16_t> {};

#if HIP_VERSION >= 50400000
template <>
struct float_bit_mask<phi::float16> : float_bit_mask<rocprim::half> {};

template <>
struct float_bit_mask<phi::bfloat16> : float_bit_mask<rocprim::bfloat16> {};
#endif
}  // namespace detail
}  // namespace rocprim
namespace cub = hipcub;
#else
'''

if "LedgerLinc ROCm top-k rocPRIM trait patch" in text:
    text = text.replace(
        "  using is_arithmetic = rocprim::traits::is_arithmetic::values<true>;\n",
        "",
    )
    path.write_text(text)
elif old_block in text:
    path.write_text(text.replace(old_block, new_block, 1))
else:
    raise SystemExit("expected top-k ROCm trait block was not found")
PY
}

patch_paddle_rocm_topk_shared_warp_count() {
  local topk_header="$SRC_DIR/paddle/phi/kernels/funcs/top_k_function_cuda.h"
  log "patching Paddle top-k shared warp count for ROCm wave64"
  "$BUILD_VENV/bin/python" - "$topk_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = "    __shared__ Pair<T> shared_max[BlockSize / WARP_SIZE];\n"
new = """    // LedgerLinc ROCm top-k wave64 patch:
    // HIP wave64 can instantiate this kernel with BlockSize < WARP_SIZE.
    __shared__ Pair<T> shared_max[(BlockSize + WARP_SIZE - 1) / WARP_SIZE];
"""

if "LedgerLinc ROCm top-k wave64 patch" in text:
    raise SystemExit(0)
if old not in text:
    raise SystemExit("expected top-k shared_max declaration was not found")
path.write_text(text.replace(old, new, 1))
PY
}

patch_paddle_rocm_mode_rocprim_traits() {
  local mode_header="$SRC_DIR/paddle/phi/kernels/funcs/mode.h"
  log "patching Paddle mode rocPRIM traits for ROCm 7.x"
  "$BUILD_VENV/bin/python" - "$mode_header" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

if "LedgerLinc ROCm mode rocPRIM trait patch" in text:
    text = text.replace(
        "  using is_arithmetic = rocprim::traits::is_arithmetic::values<true>;\n",
        "",
    )
    path.write_text(text)
    raise SystemExit(0)

needle = '''#include "paddle/phi/kernels/funcs/math_function.h"

namespace phi {
'''
new = '''#include "paddle/phi/kernels/funcs/math_function.h"

#ifdef __HIPCC__
// LedgerLinc ROCm mode rocPRIM trait patch:
// ROCm 7.x requires custom radix-sort traits through
// rocprim::traits::define<T> for Paddle's float16/bfloat16 key sorts.
namespace rocprim {
namespace traits {
template <>
struct define<phi::float16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7C00, 0x03FF>;
};

template <>
struct define<phi::bfloat16> {
  using number_format = rocprim::traits::number_format::values<
      rocprim::traits::number_format::kind::floating_point_type>;
  using float_bit_mask =
      rocprim::traits::float_bit_mask::values<uint16_t, 0x8000, 0x7F80, 0x007F>;
};
}  // namespace traits
}  // namespace rocprim
#endif

namespace phi {
'''
if needle not in text:
    raise SystemExit("expected mode include/namespace boundary was not found")
path.write_text(text.replace(needle, new, 1))
PY
}

patch_paddle_rocm_hiprand_includes() {
  log "patching Paddle ROCm component includes for ROCm 7.x flat include layout"
  "$BUILD_VENV/bin/python" - "$SRC_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
replacements = {
    "#include <hipblas.h>": "#include <hipblas/hipblas.h>",
    "#include <hipblaslt.h>": "#include <hipblaslt/hipblaslt.h>",
    "#include <hipsparse.h>": "#include <hipsparse/hipsparse.h>",
    "#include <hiprand.h>": "#include <hiprand/hiprand.h>",
    "#include <hiprand_kernel.h>": "#include <hiprand/hiprand_kernel.h>",
    "#include <rocblas.h>": "#include <rocblas/rocblas.h>",
    "#include <rocfft.h>": "#include <rocfft/rocfft.h>",
    "#include <rocsolver.h>": "#include <rocsolver/rocsolver.h>",
    "#include <rocsparse.h>": "#include <rocsparse/rocsparse.h>",
}
patched = 0
already_patched = 0
for path in root.rglob("*"):
    if path.suffix not in {".cc", ".cu", ".cuh", ".h", ".hpp"}:
        continue
    try:
        text = path.read_text()
    except (OSError, UnicodeDecodeError):
        continue
    next_text = text
    for old, new in replacements.items():
        next_text = next_text.replace(old, new)
        if new in next_text:
            already_patched += 1
    if next_text != text:
        path.write_text(next_text)
        patched += 1

if patched == 0 and already_patched == 0:
    raise SystemExit("expected at least one legacy ROCm component include")
PY
}

generate_paddle_phi_ops_map() {
  local source_map="$SRC_DIR/python/paddle/incubate/autograd/phi_ops_map.py"
  log "generating Paddle incubate autograd phi_ops_map.py"
  "$BUILD_VENV/bin/python" \
    "$SRC_DIR/python/paddle/incubate/autograd/generate_op_map.py" \
    "--ops_yaml_path=$SRC_DIR/paddle/phi/ops/yaml/ops.yaml" \
    "--ops_legacy_yaml_path=$SRC_DIR/paddle/phi/ops/yaml/inconsistent/dygraph_ops.yaml" \
    "--ops_compat_yaml_path=$SRC_DIR/paddle/phi/ops/yaml/op_compat.yaml" \
    "--phi_ops_map_path=$source_map"

  local build_map_dir="$BUILD_DIR/python/paddle/incubate/autograd"
  if [[ -d "$build_map_dir" ]]; then
    cp -f "$source_map" "$build_map_dir/phi_ops_map.py"
  fi
}

reset_warp_external_patch_stamps() {
  rm -f \
    "$BUILD_DIR/third_party/warpctc/src/extern_warpctc-stamp/extern_warpctc-patch" \
    "$BUILD_DIR/third_party/warprnnt/src/extern_warprnnt-stamp/extern_warprnnt-patch"
}

configure_build() {
  local py include_dir library_path generator_args=()
  py="$BUILD_VENV/bin/python"
  include_dir="$($py - <<'PY'
import sysconfig
print(sysconfig.get_path("include"))
PY
)"
  library_path="$($py - <<'PY'
import sysconfig
print(sysconfig.get_config_var("LIBDIR") + "/" + sysconfig.get_config_var("LDLIBRARY"))
PY
)"

  mkdir -p "$BUILD_DIR"
  if command -v ninja >/dev/null 2>&1; then
    generator_args=(-G Ninja)
  fi

  log "configuring Paddle build in $BUILD_DIR"
  cmake "${generator_args[@]}" -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$BUILD_DIR/install" \
    -DCMAKE_C_COMPILER="$HOST_CC_VALUE" \
    -DCMAKE_CXX_COMPILER="$HOST_CXX_VALUE" \
    -DWITH_ROCM=ON \
    -DWITH_GPU=OFF \
    -DWITH_TESTING=OFF \
    -DWITH_CPP_TEST=OFF \
    -DWITH_DISTRIBUTE=OFF \
    -DWITH_RCCL=OFF \
    -DWITH_TENSORRT=OFF \
    -DWITH_CINN=OFF \
    -DWITH_ONNXRUNTIME=OFF \
    -DWITH_INFERENCE_API_TEST=OFF \
    -DBUILD_WHL_PACKAGE=ON \
    -DWITH_MKL=ON \
    -DWITH_AVX=ON \
    -DWITH_PYTHON=ON \
    -DPY_VERSION=3.12 \
    -DPYTHON_EXECUTABLE="$py" \
    -DPYTHON_INCLUDE_DIR="$include_dir" \
    -DPYTHON_LIBRARY="$library_path" \
    -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
}

build_wheel() {
  if [[ -z "$BUILD_JOBS" ]]; then
    local nproc_value
    nproc_value="$(nproc 2>/dev/null || printf '4')"
    BUILD_JOBS=$(( nproc_value / 2 ))
    if (( BUILD_JOBS < 2 )); then
      BUILD_JOBS=2
    fi
  fi
  log "building Paddle wheel target with $BUILD_JOBS jobs"
  generate_paddle_phi_ops_map
  local targets_file="$BUILD_DIR/.ledgerlinc-cmake-targets.txt"
  cmake --build "$BUILD_DIR" --target help >"$targets_file"
  if rg -q '(^|[[:space:]])paddle_copy($|[[:space:]])' "$targets_file"; then
    cmake --build "$BUILD_DIR" --target paddle_copy --parallel "$BUILD_JOBS"
  else
    cmake --build "$BUILD_DIR" --target paddle_python --parallel "$BUILD_JOBS"
    (cd "$BUILD_DIR/python" && "$BUILD_VENV/bin/python" setup.py bdist_wheel)
  fi

  log "collecting wheels into $WHEELHOUSE"
  find "$BUILD_DIR" -path '*/dist/*.whl' -type f -print -exec cp -f {} "$WHEELHOUSE/" \;
}

main() {
  need_cmd git
  need_cmd cmake
  need_cmd rg
  need_cmd "$PYTHON_BIN_VALUE"
  if [[ ! -d "$ROCM_PATH_VALUE" ]]; then
    printf 'ROCM_PATH does not exist: %s\n' "$ROCM_PATH_VALUE" >&2
    exit 1
  fi
  if [[ ! -x "$HOST_CC_VALUE" || ! -x "$HOST_CXX_VALUE" ]]; then
    printf 'ROCm clang compilers are required for this build:\n  %s\n  %s\n' \
      "$HOST_CC_VALUE" "$HOST_CXX_VALUE" >&2
    exit 1
  fi

  setup_env
  clone_source
  create_build_venv
  patch_paddle_rocm_cmake

  if [[ "$PHASE" == "prepare" ]]; then
    log "prepare complete"
    return
  fi

  configure_build
  reset_warp_external_patch_stamps
  if [[ "$PHASE" == "configure" ]]; then
    log "configure complete"
    return
  fi

  build_wheel
  log "build complete; wheelhouse: $WHEELHOUSE"
}

main "$@"
