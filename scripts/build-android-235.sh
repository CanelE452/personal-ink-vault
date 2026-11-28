#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_root"

build_args=(apk --release --no-pub --target-platform android-arm64 --build-name 0.2.0 --build-number 136235)
# 235 measure 1 is a measurement build: the pen timing and replay hooks are compiled in.
build_args+=(--dart-define=PIV_INK_TIMING=true)
if [[ -n "${DRIVE_ANDROID_SERVER_CLIENT_ID:-}" ]]; then
  build_args+=(--dart-define="DRIVE_ANDROID_SERVER_CLIENT_ID=$DRIVE_ANDROID_SERVER_CLIENT_ID")
fi

flutter --suppress-analytics pub get --enforce-lockfile
flutter --suppress-analytics build "${build_args[@]}"
