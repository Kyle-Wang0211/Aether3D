#!/usr/bin/env bash
set -euo pipefail

# Validate C++ core buildability across host + Android NDK + Harmony NDK.
# - Default: non-strict (missing mobile SDKs are reported as SKIP).
# - --strict: missing toolchain or build failure causes non-zero exit.
# - --strict-if-ci: strict mode only when CI env is present.

STRICT=0
STRICT_IF_CI=0
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --strict)
      STRICT=1
      shift
      ;;
    --strict-if-ci)
      STRICT_IF_CI=1
      shift
      ;;
    --repo-root)
      REPO_ROOT="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: $0 [--strict] [--strict-if-ci] [--repo-root PATH]"
      exit 2
      ;;
  esac
done

if [[ $STRICT_IF_CI -eq 1 && -n "${CI:-}" ]]; then
  if [[ "${AETHER_MOBILE_TOOLCHAIN_REQUIRED:-0}" == "1" ]]; then
    STRICT=1
  else
    echo "cross-platform: CI detected, but AETHER_MOBILE_TOOLCHAIN_REQUIRED!=1; running non-strict mobile checks"
  fi
fi

CPP_DIR="$REPO_ROOT/aether_cpp"
HOST_BUILD_DIR="$CPP_DIR/build.host"
ANDROID_BUILD_DIR="$CPP_DIR/build.android.arm64"
OHOS_BUILD_DIR="$CPP_DIR/build.ohos.arm64"

if [[ ! -d "$CPP_DIR" || ! -f "$CPP_DIR/CMakeLists.txt" ]]; then
  echo "cross-platform: missing aether_cpp/CMakeLists.txt at $CPP_DIR"
  exit 1
fi

HOST_STATUS="SKIP"
ANDROID_STATUS="SKIP"
OHOS_STATUS="SKIP"

build_host() {
  echo "[host] configure + build (aether3d_core, aether3d_c)"
  cmake -S "$CPP_DIR" -B "$HOST_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="-ffp-contract=off -fno-fast-math -fno-exceptions -fno-rtti"
  cmake --build "$HOST_BUILD_DIR" --target aether3d_core aether3d_c
  HOST_STATUS="PASS"
}

build_android() {
  local ndk_root="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [[ -z "$ndk_root" ]]; then
    if [[ $STRICT -eq 1 ]]; then
      echo "[android] missing ANDROID_NDK_HOME/ANDROID_NDK_ROOT (strict mode)"
      return 1
    fi
    echo "[android] SKIP (ANDROID_NDK_HOME/ANDROID_NDK_ROOT not set)"
    ANDROID_STATUS="SKIP"
    return 0
  fi

  local toolchain="$ndk_root/build/cmake/android.toolchain.cmake"
  if [[ ! -f "$toolchain" ]]; then
    if [[ $STRICT -eq 1 ]]; then
      echo "[android] toolchain file not found: $toolchain (strict mode)"
      return 1
    fi
    echo "[android] SKIP (toolchain file not found: $toolchain)"
    ANDROID_STATUS="SKIP"
    return 0
  fi

  echo "[android] configure + build (arm64-v8a, API 24)"
  cmake -S "$CPP_DIR" -B "$ANDROID_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
    -DANDROID_ABI=arm64-v8a \
    -DANDROID_PLATFORM=24 \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="-ffp-contract=off -fno-fast-math -fno-exceptions -fno-rtti"
  cmake --build "$ANDROID_BUILD_DIR" --target aether3d_core aether3d_c
  ANDROID_STATUS="PASS"
}

resolve_ohos_toolchain() {
  local ndk_root="$1"
  local candidate_a="$ndk_root/native/build/cmake/ohos.toolchain.cmake"
  local candidate_b="$ndk_root/build/cmake/ohos.toolchain.cmake"
  if [[ -f "$candidate_a" ]]; then
    echo "$candidate_a"
    return 0
  fi
  if [[ -f "$candidate_b" ]]; then
    echo "$candidate_b"
    return 0
  fi
  return 1
}

build_ohos() {
  local ohos_ndk="${OHOS_NDK_HOME:-${HARMONY_NDK_HOME:-}}"
  if [[ -z "$ohos_ndk" ]]; then
    if [[ $STRICT -eq 1 ]]; then
      echo "[ohos] missing OHOS_NDK_HOME/HARMONY_NDK_HOME (strict mode)"
      return 1
    fi
    echo "[ohos] SKIP (OHOS_NDK_HOME/HARMONY_NDK_HOME not set)"
    OHOS_STATUS="SKIP"
    return 0
  fi

  local toolchain=""
  if ! toolchain="$(resolve_ohos_toolchain "$ohos_ndk")"; then
    if [[ $STRICT -eq 1 ]]; then
      echo "[ohos] ohos.toolchain.cmake not found under $ohos_ndk (strict mode)"
      return 1
    fi
    echo "[ohos] SKIP (ohos.toolchain.cmake not found under $ohos_ndk)"
    OHOS_STATUS="SKIP"
    return 0
  fi

  echo "[ohos] configure + build (arm64-v8a)"
  cmake -S "$CPP_DIR" -B "$OHOS_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
    -DOHOS_ARCH=arm64-v8a \
    -DOHOS_STL=c++_shared \
    -DCMAKE_CXX_STANDARD=20 \
    -DCMAKE_CXX_FLAGS="-ffp-contract=off -fno-fast-math -fno-exceptions -fno-rtti"
  cmake --build "$OHOS_BUILD_DIR" --target aether3d_core aether3d_c
  OHOS_STATUS="PASS"
}

build_host
build_android
build_ohos

echo ""
echo "cross-platform summary:"
echo "  host:    $HOST_STATUS"
echo "  android: $ANDROID_STATUS"
echo "  ohos:    $OHOS_STATUS"

if [[ "$HOST_STATUS" != "PASS" ]]; then
  exit 1
fi

if [[ $STRICT -eq 1 ]]; then
  if [[ "$ANDROID_STATUS" != "PASS" || "$OHOS_STATUS" != "PASS" ]]; then
    echo "cross-platform strict mode failed: android/ohos must both PASS"
    exit 1
  fi
fi

exit 0
