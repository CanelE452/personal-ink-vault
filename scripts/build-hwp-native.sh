#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
platform="${1:-android}"
configuration="${2:-release}"
case "$platform" in android|linux) ;; *) echo 'Usage: build-native.sh android|linux [debug|release]' >&2; exit 2 ;; esac
case "$configuration" in debug|release) ;; *) echo 'Configuration must be debug or release.' >&2; exit 2 ;; esac

if [[ -n "${INK_HWP_RUST_ROOT:-}" ]]; then
  export CARGO_HOME="$INK_HWP_RUST_ROOT/cargo"
  export RUSTUP_HOME="$INK_HWP_RUST_ROOT/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
arguments=(+1.99.1 build --locked --manifest-path "$project_root/packages/ink_hwp_native/Cargo.toml" --target-dir "$project_root/build/hwp-native-target")
if [[ "$configuration" == release ]]; then arguments+=(--release); fi

if [[ "$platform" == android ]]; then
  sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  ndk_root="${ANDROID_NDK_ROOT:-$sdk_root/ndk/28.2.13676358}"
  case "$(uname -s)" in Linux) host=linux-x86_64 ;; Darwin) host=darwin-x86_64 ;; *) echo 'Unsupported NDK host.' >&2; exit 2 ;; esac
  bin="$ndk_root/toolchains/llvm/prebuilt/$host/bin"
  export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$bin/aarch64-linux-android24-clang"
  export AR_aarch64_linux_android="$bin/llvm-ar"
  export CC_aarch64_linux_android="$bin/aarch64-linux-android24-clang"
  export CXX_aarch64_linux_android="$bin/aarch64-linux-android24-clang++"
  export PATH="$bin:$PATH"
  if [[ ! -x "$CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER" ]]; then echo "Android NDK linker missing in $bin" >&2; exit 1; fi
  target=aarch64-linux-android
  destination="$project_root/build/native/android/arm64-v8a"
else
  target=x86_64-unknown-linux-gnu
  destination="$project_root/build/native/linux"
fi
cargo "${arguments[@]}" --target "$target"
mkdir -p "$destination"
cp "$project_root/build/hwp-native-target/$target/$configuration/libink_hwp_native.so" "$destination/libink_hwp_native.so"
printf '%s\n' "$destination/libink_hwp_native.so"
