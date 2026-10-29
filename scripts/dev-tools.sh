#!/usr/bin/env bash
# Source: . ./scripts/dev-tools.sh /path/to/flutter /path/to/android-sdk /path/to/jdk
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' 'Source this script so its environment applies to your current shell.' >&2
  exit 1
fi
_ink_tools_setup() {
  local flutter_root="${1:-}" android_sdk_root="${2:-}" java_root="${3:-}" tool_root
  for tool_root in "$flutter_root" "$android_sdk_root" "$java_root"; do
    if [[ -n "$tool_root" && ! -d "$tool_root" ]]; then
      printf 'Tool directory does not exist: %s\n' "$tool_root" >&2
      return 1
    fi
  done
  if [[ -n "$flutter_root" ]]; then export PATH="$flutter_root/bin:$PATH"; fi
  if [[ -n "$android_sdk_root" ]]; then
    export ANDROID_HOME="$android_sdk_root" ANDROID_SDK_ROOT="$android_sdk_root"
    export PATH="$android_sdk_root/platform-tools:$PATH"
  fi
  if [[ -n "$java_root" ]]; then export JAVA_HOME="$java_root"; export PATH="$java_root/bin:$PATH"; fi
  if ! command -v flutter >/dev/null 2>&1; then
    printf '%s\n' 'Pass a Flutter root or put Flutter on the existing PATH.' >&2
    return 1
  fi
  printf '%s\n' 'Development tools enabled for this shell. No global settings changed.'
}
_ink_tools_setup "$@"
_ink_tools_result=$?
unset -f _ink_tools_setup
return "$_ink_tools_result"
