param(
    [ValidateSet('windows', 'android', 'all')][string]$Platform = 'all',
    [ValidateSet('debug', 'release')][string]$Configuration = 'release',
    [string]$RustToolchainRoot,
    [string]$AndroidNdkRoot
)

$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$manifest = Join-Path $projectRoot 'packages/ink_hwp_native/Cargo.toml'
$targetRoot = Join-Path $projectRoot 'build/hwp-native-target'

if (-not $RustToolchainRoot -and $env:LOCALAPPDATA) {
    $portableRust = Join-Path $env:LOCALAPPDATA 'PersonalInkVault/tools/rust'
    if (Test-Path -LiteralPath $portableRust -PathType Container) { $RustToolchainRoot = $portableRust }
}
if ($RustToolchainRoot) {
    $env:CARGO_HOME = Join-Path $RustToolchainRoot 'cargo'
    $env:RUSTUP_HOME = Join-Path $RustToolchainRoot 'rustup'
    $env:Path = (Join-Path $env:CARGO_HOME 'bin') + [IO.Path]::PathSeparator + $env:Path
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw 'Rust 1.99.1 is required. Pass -RustToolchainRoot or enable cargo in this process.'
}

function Build-Native([string]$Target, [string]$OutputFolder, [string]$Library) {
    $arguments = @('+1.99.1', 'build', '--locked', '--manifest-path', $manifest, '--target-dir', $targetRoot, '--target', $Target)
    if ($Configuration -eq 'release') { $arguments += '--release' }
    & cargo @arguments
    if ($LASTEXITCODE -ne 0) { throw "Native build failed for $Target ($LASTEXITCODE)." }
    $destination = Join-Path $projectRoot $OutputFolder
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $targetRoot "$Target/$Configuration/$Library") -Destination (Join-Path $destination $Library) -Force
    Write-Output (Join-Path $destination $Library)
}

if ($Platform -eq 'windows' -or $Platform -eq 'all') {
    Build-Native 'x86_64-pc-windows-msvc' 'build/native/windows' 'ink_hwp_native.dll'
}
if ($Platform -eq 'android' -or $Platform -eq 'all') {
    if (-not $AndroidNdkRoot) {
        $sdk = if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'PersonalInkVault/tools/android-sdk' }
        $AndroidNdkRoot = Join-Path $sdk 'ndk/28.2.13676358'
    }
    $bin = Join-Path $AndroidNdkRoot 'toolchains/llvm/prebuilt/windows-x86_64/bin'
    $linker = Join-Path $bin 'aarch64-linux-android24-clang.cmd'
    if (-not (Test-Path -LiteralPath $linker -PathType Leaf)) { throw "Android NDK linker missing: $linker" }
    $env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = $linker
    $env:AR_aarch64_linux_android = Join-Path $bin 'llvm-ar.exe'
    $env:CC_aarch64_linux_android = $linker
    $env:CXX_aarch64_linux_android = Join-Path $bin 'aarch64-linux-android24-clang++.cmd'
    $env:Path = $bin + [IO.Path]::PathSeparator + $env:Path
    Build-Native 'aarch64-linux-android' 'build/native/android/arm64-v8a' 'libink_hwp_native.so'
}
