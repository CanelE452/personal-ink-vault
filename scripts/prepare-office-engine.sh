#!/usr/bin/env bash
set -euo pipefail
repository="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
arguments=("$repository/android/office_engine/prepare_engine.py")
if [[ -n "${1:-}" ]]; then arguments+=(--apk-path "$1"); fi
python3 "${arguments[@]}"
