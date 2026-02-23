#!/usr/bin/env bash
set -euo pipefail

# Emits environment exports for Android/OHOS toolchains.
# Usage:
#   eval "$(scripts/ci/setup_mobile_toolchains_env.sh)"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

ANDROID_NDK_CANDIDATES=(
  "${ANDROID_NDK_HOME:-}"
  "${ANDROID_NDK_ROOT:-}"
  "/opt/homebrew/share/android-ndk"
)

ANDROID_NDK=""
for cand in "${ANDROID_NDK_CANDIDATES[@]}"; do
  if [[ -n "$cand" && -f "$cand/build/cmake/android.toolchain.cmake" ]]; then
    ANDROID_NDK="$cand"
    break
  fi
done

OHOS_CANDIDATES=(
  "${OHOS_NDK_HOME:-}"
  "${HARMONY_NDK_HOME:-}"
)

OHOS_NDK=""
for cand in "${OHOS_CANDIDATES[@]}"; do
  if [[ -n "$cand" && -f "$cand/native/build/cmake/ohos.toolchain.cmake" ]]; then
    OHOS_NDK="$cand"
    break
  fi
  if [[ -n "$cand" && -f "$cand/build/cmake/ohos.toolchain.cmake" ]]; then
    OHOS_NDK="$cand"
    break
  fi
done

if [[ -z "$OHOS_NDK" ]]; then
  OHOS_NDK="$REPO_ROOT/toolchains/ohos-ndk-shim"
fi

if [[ -n "$ANDROID_NDK" ]]; then
  echo "export ANDROID_NDK_HOME=\"$ANDROID_NDK\""
  echo "export ANDROID_NDK_ROOT=\"$ANDROID_NDK\""
fi
echo "export OHOS_NDK_HOME=\"$OHOS_NDK\""
echo "export HARMONY_NDK_HOME=\"$OHOS_NDK\""
