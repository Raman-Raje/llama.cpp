# Adreno GPU (Vulkan) build & test

This covers building llama.cpp for the Qualcomm **Adreno** GPU via the Vulkan
backend and running the test suite on a real Android phone attached over `adb`.
There is no cloud dependency; CI runs on a self-hosted runner with the device
connected.

## Build

`scripts/snapdragon/adreno/build-adreno.sh` builds and (optionally) installs a
package:

```bash
# Android (cross-compiled with the NDK) -> produces build-android/
scripts/snapdragon/adreno/build-adreno.sh \
    --target android --backend vulkan --ndk "$ANDROID_NDK_ROOT"
```

Building Vulkan needs `glslc` (shaderc) available on the build host;
`vulkan-shaders-gen` is built for the host automatically. Pass `--prefix <dir>`
to additionally `cmake --install` into a package directory.

## Deploy + run on device

`run-android.sh` pushes the whole build to the device, preserving the layout
`<dst>/bin`, `<dst>/lib`, `<dst>/models`, runs a binary, and pulls its output
log back to the host:

```bash
# Run test-backend-ops on the Adreno GPU (prompts for dst, default "android")
scripts/snapdragon/adreno/run-android.sh \
    --bin test-backend-ops -- -b Vulkan0 -o MUL_MAT

# Pick device + destination explicitly, push a model, run llama-cli
scripts/snapdragon/adreno/run-android.sh \
    --device <serial> --dst adreno --model model.gguf \
    --bin llama-cli -- -m models/model.gguf --device Vulkan0 -ngl 99 -p "Hi"
```

A bare `--dst` name maps to `/data/local/tmp/<name>`; an absolute path is used
as-is. `--env K=V` (repeatable) sets environment for the on-device run, e.g.
`--env GGML_VK_DISABLE_COOPMAT=1`. Use `--no-push` to re-run without
re-deploying. The binary's stdout/stderr is pulled back to `./<binary>.log`.

## Cooperative matrix coverage

The coopmat path is gated to `QUALCOMM_ADRENO_MALU` tiers (devices that expose
`VK_KHR_cooperative_matrix`) in `ggml_vk_khr_cooperative_matrix_support()`.
Older Adreno without a matrix ALU fall through to the scalar Vulkan path,
untouched.

Practical consequence for the test matrix:

| Device tier | coopmat path | scalar fallback |
| ----------- | ------------ | --------------- |
| MALU (matrix-ALU Adreno) | exercised | exercised (`GGML_VK_DISABLE_COOPMAT=1`) |
| non-MALU (e.g. SM8750 / SM8850) | gated off → no-op | exercised (both passes) |

On a non-MALU device the two passes validate the same scalar path; add a MALU
device to actually cover the coopmat/warptile code.

## CI

`.github/workflows/build-and-test-adreno.yml` defines a self-hosted job
`adreno-android` (`runs-on: [self-hosted, Adreno, Android]`): it builds with the
NDK, deploys via `run-android.sh`, and runs `test-backend-ops -b Vulkan0` twice
(coopmat on, then `GGML_VK_DISABLE_COOPMAT=1`). Expects `ANDROID_NDK_ROOT` (and
optionally `ADRENO_ADB_SERIAL`) on the runner.

Register the runner with matching labels. The workflow triggers on changes to
the Vulkan backend or the Adreno scripts.
