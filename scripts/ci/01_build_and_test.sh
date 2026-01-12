#!/usr/bin/env bash
set -euo pipefail

echo "==> swift build"
swift build

echo "==> swift test"
swift test

