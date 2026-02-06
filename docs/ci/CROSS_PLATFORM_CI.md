# Cross-Platform CI Guide

This document describes the cross-platform CI setup for PR1 v2.4 Addendum verification suite.

## Overview

The verification suite runs on multiple platforms:
- macOS (Debug + Release)
- Ubuntu Linux (Debug + Release)
- iOS Simulator (via Xcode)

## GitHub Actions Workflow

The workflow file `.github/workflows/pr1_v24_cross_platform.yml` defines the following jobs:

### SwiftPM Tests

1. **swiftpm-macos-debug**: macOS Debug build and tests
2. **swiftpm-macos-release**: macOS Release build and tests
3. **swiftpm-ubuntu-debug**: Ubuntu Debug build and tests
4. **swiftpm-ubuntu-release**: Ubuntu Release build and tests

### Fixture Verification

- **fixtures-no-diff**: Regenerates fixtures and verifies no diff from committed versions

### iOS Simulator Tests

- **ios-simulator**: Runs iOS unit tests on iPhone 15 Simulator (requires Xcode project)

### Python Reference Verification

- **python-reference-verify**: Cross-language verification using Python blake3 library

## Environment Variables

All jobs set:
- `LANG=C`
- `LC_ALL=C`

This ensures deterministic locale behavior across platforms.

## Portability to Xcode Cloud

To port this workflow to Xcode Cloud:

1. **Create `ci_scripts/ci_post_clone.sh`**:
```bash
#!/bin/bash
set -euo pipefail

# Install Linux dependencies (if needed)
if [ "$PLATFORM_NAME" = "linux" ]; then
    sudo apt-get update
    sudo apt-get install -y libsqlite3-dev
fi

# Regenerate fixtures
swift run FixtureGen

# Verify no diff
git diff --exit-code Tests/Fixtures || {
    echo "ERROR: Fixtures differ"
    exit 1
}
```

2. **Create `ci_scripts/ci_post_xcodebuild.sh`**:
```bash
#!/bin/bash
set -euo pipefail

# Extract CHECKS_TOTAL from test output
if [ -f "test_output.log" ]; then
    grep -E "CHECKS_TOTAL=|VERIFICATION SUITE SUMMARY" test_output.log || echo "CHECKS_TOTAL not found"
fi
```

3. **Xcode Cloud Build Settings**:
   - **Pre-actions**: Run `ci_scripts/ci_post_clone.sh`
   - **Test actions**: Run SwiftPM tests
   - **Post-actions**: Run `ci_scripts/ci_post_xcodebuild.sh`

## Running Locally

### macOS/Linux

```bash
# Debug
swift test

# Release
swift test -c release

# Regenerate fixtures
scripts/regen_fixtures.sh

# Verify fixtures
python3 scripts/verify_decisionhash_fixtures.py Tests/Fixtures/decision_hash_v1.txt
```

### iOS Simulator

```bash
# Requires Xcode project
xcodebuild test \
  -scheme Aether3DCoreTests \
  -destination 'platform=iOS Simulator,name=iPhone 15,OS=latest'
```

## Troubleshooting

### Fixture Mismatch

If fixtures differ after regeneration:
1. Check that `scripts/regen_fixtures.sh` runs successfully
2. Verify line endings are LF (not CRLF)
3. Check that fixture headers are valid (SHA256 matches)

### iOS Tests Not Running

If iOS Simulator tests are skipped:
1. Ensure Xcode project/workspace exists
2. Verify test target includes iOS test files
3. Check that fixtures are included as bundle resources

### Python Verification Fails

If Python verification fails:
1. Ensure `blake3` library is installed: `pip install blake3`
2. Check that fixture file path is correct
3. Verify fixture header is valid

## CI Artifacts

On failure, CI uploads:
- Test logs
- Fixture diffs (if regeneration differs)
- Diagnostic bundles (from `GoldenDiffPrinter`)
