#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-release}"
target_directory="${INK_VAULT_MCP_TARGET_DIR:-$project_root/build/mcp-target}"
case "$configuration" in debug|release) ;; *) echo 'Usage: build-mcp.sh [debug|release]' >&2; exit 2 ;; esac
if [[ -n "${INK_VAULT_RUST_ROOT:-}" ]]; then
  export CARGO_HOME="$INK_VAULT_RUST_ROOT/cargo"
  export RUSTUP_HOME="$INK_VAULT_RUST_ROOT/rustup"
  export PATH="$CARGO_HOME/bin:$PATH"
fi
case "$(uname -s):$(uname -m)" in
  Linux:x86_64) target=x86_64-unknown-linux-gnu; platform=linux ;;
  Linux:aarch64|Linux:arm64) target=aarch64-unknown-linux-gnu; platform=linux ;;
  Darwin:x86_64) target=x86_64-apple-darwin; platform=macos ;;
  Darwin:arm64) target=aarch64-apple-darwin; platform=macos ;;
  *) echo 'Use build-mcp.ps1 on Windows; this script supports Linux/macOS hosts.' >&2; exit 2 ;;
esac
arguments=(+1.99.1 build --locked --manifest-path "$project_root/packages/ink_vault_mcp/Cargo.toml" --target-dir "$target_directory" --target "$target")
if [[ "$configuration" == release ]]; then arguments+=(--release); fi
cargo "${arguments[@]}"
destination="$project_root/build/native/$platform"
mkdir -p "$destination"
cp "$target_directory/$target/$configuration/ink_vault_mcp" "$destination/ink_vault_mcp"
cp "$project_root/packages/ink_vault_mcp/THIRD_PARTY_LICENSES.txt" "$destination/ink-vault-mcp-THIRD-PARTY-LICENSES.txt"
printf '%s\n' "$destination/ink_vault_mcp"
