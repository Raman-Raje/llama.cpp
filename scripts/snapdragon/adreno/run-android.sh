#!/bin/bash
# Deploy a llama.cpp Android build to a device and run a binary, pulling output back.
#
# Pushes ALL binaries and shared libraries from the build directory to the device,
# preserving the layout:
#   <dst>/bin      all executables  (build/bin/*)
#   <dst>/lib      all *.so         (+ libc++_shared.so from the NDK)
#   <dst>/models   model files      (optional, via --model)
# then runs the requested binary on-device and pulls its output log back to the host.
#
# Usage:
#   run-android.sh [OPTIONS] [-- <binary args...>]
#
# Options:
#   --device <id>    adb serial (-s <id>). Default: the sole attached device.
#   --bin    <name>  binary under bin/ to run (default: llama-cli)
#   --dst    <dir>   device destination. A bare name maps to /data/local/tmp/<name>;
#                    an absolute path is used as-is. If omitted, you are prompted
#                    (default: android).
#   --build  <dir>   local build directory (default: <repo>/build-android)
#   --ndk    <path>  NDK root for libc++_shared.so (default: $ANDROID_NDK_ROOT)
#   --model  <path>  model file to push into <dst>/models (repeatable)
#   --env    <K=V>   environment variable to set for the on-device run (repeatable)
#   --no-push        skip deployment, just run
#   --no-run         deploy only, do not run
#   -h, --help       show this help

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

DEVICE_ID=""
BINARY_NAME="llama-cli"
DST=""
BUILD_DIR="$DEFAULT_ROOT/build-android"
NDK_PATH="${ANDROID_NDK_ROOT:-}"
MODELS=()
ENVS=()
DO_PUSH=1
DO_RUN=1
BIN_ARGS=()

usage() { grep '^#' "$0" | sed -n "2,28p" | sed 's/^# \{0,1\}//'; exit 0; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE_ID="$2";   shift 2 ;;
    --bin)    BINARY_NAME="$2"; shift 2 ;;
    --dst)    DST="$2";         shift 2 ;;
    --build)  BUILD_DIR="$2";   shift 2 ;;
    --ndk)    NDK_PATH="$2";    shift 2 ;;
    --model)  MODELS+=("$2");   shift 2 ;;
    --env)    ENVS+=("$2");     shift 2 ;;
    --no-push) DO_PUSH=0;       shift   ;;
    --no-run)  DO_RUN=0;        shift   ;;
    -h|--help) usage ;;
    --) shift; BIN_ARGS=("$@"); break ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve destination (prompt if not supplied; default "android")
# ---------------------------------------------------------------------------
if [ -z "$DST" ]; then
  if [ -t 0 ]; then
    read -r -p "Destination folder on device [android]: " DST
  fi
  DST="${DST:-android}"
fi
# Bare name -> /data/local/tmp/<name>; absolute path used as-is.
case "$DST" in
  /*) REMOTE_DIR="$DST" ;;
  *)  REMOTE_DIR="/data/local/tmp/$DST" ;;
esac
BIN_DIR="$REMOTE_DIR/bin"
LIB_DIR="$REMOTE_DIR/lib"
MODEL_DIR="$REMOTE_DIR/models"

# ---------------------------------------------------------------------------
# adb wrapper
# ---------------------------------------------------------------------------
ADB=(adb)
[ -n "$DEVICE_ID" ] && ADB=(adb -s "$DEVICE_ID")

echo "Build dir : $BUILD_DIR"
echo "Device dst: $REMOTE_DIR"
echo "Binary    : $BINARY_NAME"
echo ""

"${ADB[@]}" wait-for-device || { echo "Error: no adb device"; exit 1; }

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
if [ "$DO_PUSH" -eq 1 ]; then
  if [ ! -d "$BUILD_DIR/bin" ]; then
    echo "Error: '$BUILD_DIR/bin' not found (build with build-adreno.sh first)"
    exit 1
  fi

  echo "=== create device dirs ==="
  "${ADB[@]}" shell "mkdir -p $BIN_DIR $LIB_DIR $MODEL_DIR"

  # All executables from build/bin.
  echo "=== push binaries -> $BIN_DIR ==="
  "${ADB[@]}" push "$BUILD_DIR"/bin/. "$BIN_DIR" >/dev/null
  "${ADB[@]}" shell "chmod 755 $BIN_DIR/*"

  # All shared libraries (Android cmake may place them under bin/ and/or lib/).
  echo "=== push libraries -> $LIB_DIR ==="
  mapfile -t SO_FILES < <(find "$BUILD_DIR" -name '*.so' -type f 2>/dev/null)
  if [ "${#SO_FILES[@]}" -gt 0 ]; then
    "${ADB[@]}" push "${SO_FILES[@]}" "$LIB_DIR" >/dev/null
  fi

  # libc++_shared.so from the NDK.
  if [ -n "$NDK_PATH" ]; then
    LIBCXX="$(find "$NDK_PATH"/toolchains/llvm/prebuilt -name 'libc++_shared.so' -path '*aarch64-linux-android*' 2>/dev/null | head -1)"
    if [ -n "$LIBCXX" ]; then
      echo "=== push libc++_shared.so ==="
      "${ADB[@]}" push "$LIBCXX" "$LIB_DIR" >/dev/null
    else
      echo "Warning: libc++_shared.so not found under '$NDK_PATH'"
    fi
  else
    echo "Warning: --ndk/ANDROID_NDK_ROOT not set; skipping libc++_shared.so"
  fi

  # Models.
  for m in "${MODELS[@]:-}"; do
    [ -z "$m" ] && continue
    echo "=== push model $(basename "$m") -> $MODEL_DIR ==="
    "${ADB[@]}" push "$m" "$MODEL_DIR/" >/dev/null
  done
fi

# ---------------------------------------------------------------------------
# Run + pull output
# ---------------------------------------------------------------------------
if [ "$DO_RUN" -eq 1 ]; then
  ENV_PREFIX=""
  for e in "${ENVS[@]:-}"; do
    [ -z "$e" ] && continue
    ENV_PREFIX="$ENV_PREFIX $e"
  done

  OUTPUT_FILE="${BINARY_NAME}.log"
  REMOTE_LOG="$REMOTE_DIR/$OUTPUT_FILE"

  echo "=== run $BINARY_NAME on device ==="
  out="$("${ADB[@]}" shell "cd $BIN_DIR; \
    LD_LIBRARY_PATH=$LIB_DIR:\$LD_LIBRARY_PATH \
    $ENV_PREFIX ./$BINARY_NAME ${BIN_ARGS[*]:-} > $REMOTE_LOG 2>&1; \
    echo __RC__:\$?")"
  echo "$out"

  run_rc=1
  case "$out" in *__RC__:0*) run_rc=0 ;; esac

  echo "=== pull output -> ./$OUTPUT_FILE ==="
  "${ADB[@]}" pull "$REMOTE_LOG" "./$OUTPUT_FILE" >/dev/null && \
    echo "Output saved: $PWD/$OUTPUT_FILE"

  [ "$run_rc" -eq 0 ] || echo "Binary exited non-zero"
  exit $run_rc
fi
