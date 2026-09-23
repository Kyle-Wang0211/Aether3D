#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

apply_vendor_patch() {
  local vendor_repo="$1"
  local patch_file="$2"
  local label="$3"

  # .deps/* are git submodules, whose .git is a gitdir pointer file rather
  # than a directory.
  if [[ ! -e "$vendor_repo/.git" ]]; then
    echo "ERROR: expected vendored git repo at $vendor_repo"
    echo "Run: git submodule update --init .deps"
    exit 1
  fi

  if git -C "$vendor_repo" apply --check "$patch_file" >/dev/null 2>&1; then
    git -C "$vendor_repo" apply "$patch_file"
    echo "Applied $label patch"
    return
  fi

  if git -C "$vendor_repo" apply --check --reverse "$patch_file" >/dev/null 2>&1; then
    echo "$label patch already applied"
    return
  fi

  echo "ERROR: $label drift detected"
  echo "Vendor repo: $vendor_repo"
  echo "Patch file: $patch_file"
  exit 1
}

apply_vendor_patch \
  "$ROOT/.deps/swift-ssh-client" \
  "$ROOT/patches/vendor/swift-ssh-client-Package.swift.patch" \
  "swift-ssh-client manifest"

apply_vendor_patch \
  "$ROOT/.deps/swift-ssh-client" \
  "$ROOT/patches/vendor/swift-ssh-client-sources.patch" \
  "swift-ssh-client sources"

apply_vendor_patch \
  "$ROOT/.deps/swift-crypto" \
  "$ROOT/patches/vendor/swift-crypto-Package.swift.patch" \
  "swift-crypto manifest"
