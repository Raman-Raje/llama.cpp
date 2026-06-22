#!/bin/bash
# Build script for llama.cpp targeting Android (Snapdragon/Adreno)
# Usage: build-adreno.sh [OPTIONS]
#
# Options:
#   --backend  vulkan|opencl      (default: vulkan)
#   --ndk      <path>             Android NDK root (default: $ANDROID_NDK_HOME / $ANDROID_NDK_ROOT / $ANDROID_NDK)
#   --spirv-headers <path>        SPIRV-Headers cmake config dir (vulkan only; default: $SPIRV_HEADERS_DIR or ~/spirv-headers-install/share/cmake/SPIRV-Headers)
#   --root     <path>             llama.cpp root   (default: auto-detected)
#   --prefix   <path>             Install into <path> (bin/ + lib/) after build
#   --debug                       Enable debug build / Vulkan debug layer
#   -h, --help                    Show this help

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Resolve llama.cpp root: 3 levels up from scripts/snapdragon/adreno/
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

BACKEND="vulkan"
# Fall back to the standard Android NDK env vars when --ndk is not given
NDK_PATH="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-${ANDROID_NDK:-}}}"
# SPIRV-Headers cmake config dir (required by the Vulkan backend)
SPIRV_HEADERS_DIR="${SPIRV_HEADERS_DIR:-$HOME/spirv-headers-install/share/cmake/SPIRV-Headers}"
LLAMA_ROOT="$DEFAULT_ROOT"
PREFIX=""
DEBUG=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
  grep '^#' "$0" | sed -n "2,12p" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)        BACKEND="$2";           shift 2 ;;
    --ndk)            NDK_PATH="$2";          shift 2 ;;
    --spirv-headers)  SPIRV_HEADERS_DIR="$2"; shift 2 ;;
    --root)           LLAMA_ROOT="$2";        shift 2 ;;
    --prefix)         PREFIX="$2";            shift 2 ;;
    --debug)          DEBUG=1;                shift   ;;
    -h|--help)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
case "$BACKEND" in
  vulkan|opencl) ;;
  *) echo "Error: --backend must be 'vulkan' or 'opencl' (got '$BACKEND')"; exit 1 ;;
esac

if [ ! -f "$LLAMA_ROOT/CMakeLists.txt" ]; then
  echo "Error: llama.cpp root not found at '$LLAMA_ROOT' (no CMakeLists.txt)"
  exit 1
fi

if [ -z "$NDK_PATH" ]; then
  echo "Error: Android NDK root not found. Pass --ndk <path> or set ANDROID_NDK_HOME/ANDROID_NDK_ROOT/ANDROID_NDK"
  exit 1
fi

if [ ! -d "$NDK_PATH" ]; then
  echo "Error: NDK path does not exist: $NDK_PATH"
  exit 1
fi

# ---------------------------------------------------------------------------
# Derive build directory name and cmake flags
# ---------------------------------------------------------------------------
BUILD_DIR="$LLAMA_ROOT/build-android"

BACKEND_FLAGS=()
case "$BACKEND" in
  vulkan)
    if [ ! -d "$SPIRV_HEADERS_DIR" ]; then
      echo "Error: SPIRV-Headers cmake config dir not found: $SPIRV_HEADERS_DIR"
      echo "       Pass --spirv-headers <path> or set SPIRV_HEADERS_DIR (dir containing SPIRV-HeadersConfig.cmake)"
      exit 1
    fi
    BACKEND_FLAGS+=("-DGGML_VULKAN=ON")
    BACKEND_FLAGS+=("-DSPIRV-Headers_DIR=$SPIRV_HEADERS_DIR")
    # Allow find_package to locate SPIRV-Headers outside the NDK sysroot when cross-compiling
    BACKEND_FLAGS+=("-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH")
    [ "$DEBUG" -eq 1 ] && BACKEND_FLAGS+=("-DGGML_VULKAN_DEBUG=ON")
    ;;
  opencl)
    # CLML is the Qualcomm ML SDK acceleration path for Adreno
    BACKEND_FLAGS+=("-DGGML_OPENCL=ON" "-DGGML_OPENCL_USE_CLML=ON")
    ;;
esac

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
echo "Target   : android"
echo "Backend  : $BACKEND"
echo "Root     : $LLAMA_ROOT"
echo "Build dir: $BUILD_DIR"
echo "NDK      : $NDK_PATH"
[ "$BACKEND" = "vulkan" ] && echo "SPIRV    : $SPIRV_HEADERS_DIR"
[ "$DEBUG"  -eq 1 ]       && echo "Debug    : ON"
echo ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

cmake \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
  -DCMAKE_SYSTEM_NAME=Android \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-31 \
  -DGGML_OPENMP=OFF \
  -DLLAMA_CURL=OFF \
  "${BACKEND_FLAGS[@]}" \
  "$LLAMA_ROOT"

make -j"$(nproc)"
[ -n "$PREFIX" ] && cmake --install . --prefix "$PREFIX"

echo ""
echo "Build completed: $BUILD_DIR"
[ -n "$PREFIX" ] && echo "Installed to   : $PREFIX"
