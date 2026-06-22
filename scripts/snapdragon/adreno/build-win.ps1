<#
.SYNOPSIS
    Build llama.cpp targeting Windows on ARM (Snapdragon/Adreno).

.DESCRIPTION
    Native PowerShell build script. Run from a "Developer PowerShell" or any
    shell where cmake/ninja and the LLVM/clang toolchain are on PATH.

.PARAMETER Backend
    vulkan | opencl   (default: vulkan)

.PARAMETER SpirvHeaders
    SPIRV-Headers cmake config dir (vulkan only).
    Default: $env:SPIRV_HEADERS_DIR or ~\spirv-headers-install\share\cmake\SPIRV-Headers

.PARAMETER Root
    llama.cpp root (default: auto-detected, 3 levels up from this script)

.PARAMETER Prefix
    Install into <Prefix> (bin\ + lib\) after build

.PARAMETER DebugBuild
    Enable debug build / Vulkan debug layer

.EXAMPLE
    .\build-adreno-win.ps1 -Backend vulkan -SpirvHeaders C:\spirv-headers\share\cmake\SPIRV-Headers
#>

[CmdletBinding()]
param(
    [ValidateSet("vulkan", "opencl")]
    [string]$Backend = "vulkan",

    [string]$SpirvHeaders,

    [string]$Root,

    [string]$Prefix = "",

    [switch]$DebugBuild
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Resolve llama.cpp root: 3 levels up from scripts/snapdragon/adreno/
$DefaultRoot = (Resolve-Path (Join-Path $ScriptDir "..\..\..")).Path

if (-not $Root) { $Root = $DefaultRoot }

# SPIRV-Headers cmake config dir (required by the Vulkan backend)
if (-not $SpirvHeaders) {
    if ($env:SPIRV_HEADERS_DIR) {
        $SpirvHeaders = $env:SPIRV_HEADERS_DIR
    } else {
        $SpirvHeaders = Join-Path $HOME "spirv-headers-install\share\cmake\SPIRV-Headers"
    }
}

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if (-not (Test-Path (Join-Path $Root "CMakeLists.txt"))) {
    Write-Error "llama.cpp root not found at '$Root' (no CMakeLists.txt)"
    exit 1
}

$ToolchainFile = Join-Path $Root "cmake\arm64-windows-llvm.cmake"
if (-not (Test-Path $ToolchainFile)) {
    Write-Error "Windows toolchain not found: $ToolchainFile"
    exit 1
}

# ---------------------------------------------------------------------------
# Derive build directory name and cmake flags
# ---------------------------------------------------------------------------
$BuildDir = Join-Path $Root "build-win"

$BackendFlags = @()
switch ($Backend) {
    "vulkan" {
        if (-not (Test-Path $SpirvHeaders)) {
            Write-Error ("SPIRV-Headers cmake config dir not found: $SpirvHeaders`n" +
                "       Pass -SpirvHeaders <path> or set `$env:SPIRV_HEADERS_DIR (dir containing SPIRV-HeadersConfig.cmake)")
            exit 1
        }
        $BackendFlags += "-DGGML_VULKAN=ON"
        $BackendFlags += "-DSPIRV-Headers_DIR=$SpirvHeaders"
        # Allow find_package to locate SPIRV-Headers outside the toolchain sysroot when cross-compiling
        $BackendFlags += "-DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=BOTH"
        if ($DebugBuild) { $BackendFlags += "-DGGML_VULKAN_DEBUG=ON" }
    }
    "opencl" {
        $BackendFlags += "-DGGML_OPENCL=ON"
    }
}

$BuildType = if ($DebugBuild) { "Debug" } else { "Release" }

# Parallel build: number of logical processors
$Jobs = [Environment]::ProcessorCount

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
Write-Host "Target   : win"
Write-Host "Backend  : $Backend"
Write-Host "Root     : $Root"
Write-Host "Build dir: $BuildDir"
if ($Backend -eq "vulkan") { Write-Host "SPIRV    : $SpirvHeaders" }
if ($DebugBuild) { Write-Host "Debug    : ON" }
Write-Host ""

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
if (Test-Path $BuildDir) { Remove-Item -Recurse -Force $BuildDir }
New-Item -ItemType Directory -Path $BuildDir | Out-Null
Push-Location $BuildDir

try {
    cmake $Root `
        -G Ninja `
        "-DCMAKE_TOOLCHAIN_FILE=$ToolchainFile" `
        "-DCMAKE_BUILD_TYPE=$BuildType" `
        -DBUILD_SHARED_LIBS=OFF `
        @BackendFlags
    if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }

    cmake --build . --config $BuildType --parallel $Jobs
    if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }

    if ($Prefix) {
        cmake --install . --config $BuildType --prefix $Prefix
        if ($LASTEXITCODE -ne 0) { throw "cmake install failed" }
    }
}
finally {
    Pop-Location
}

Write-Host ""
Write-Host "Build completed: $BuildDir"
if ($Prefix) { Write-Host "Installed to   : $Prefix" }
