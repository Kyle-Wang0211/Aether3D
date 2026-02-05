# Contributing Fixtures Guide

This guide explains how to work with golden fixtures in PR1 v2.4 Addendum.

## Fixture Format

All fixtures use the following header format:
```
# v=1 sha256=<64-hex-chars> len=<decimal>
```

The header is followed by fixture data (LF line endings only).

## Regenerating Fixtures

To regenerate all fixtures:

```bash
scripts/regen_fixtures.sh
```

This script:
1. Runs the Swift fixture generator (`swift run FixtureGen`)
2. Normalizes line endings to LF
3. Validates that regenerated fixtures match committed versions

**Important:** If regeneration produces diffs, review them carefully:
- Schema/layout changes require version bumping (v1 → v2)
- Never overwrite v1 fixtures unless SSOT explicitly allows

## Adding New Fixtures

1. **Update generator**: Modify `Sources/FixtureGen/main.swift`
2. **Regenerate**: Run `scripts/regen_fixtures.sh`
3. **Review diff**: Ensure changes are intentional
4. **Commit**: Include both generator changes and fixture updates

## Fixture Versioning

When canonical layout changes:
1. Create new fixture file: `*_v2.txt` (never overwrite v1)
2. Update generator to support both versions
3. Update tests to load appropriate version
4. Document change in SSOT

## Running iOS Tests Locally

### Prerequisites

1. Xcode installed
2. iOS Simulator available
3. Fixtures included as bundle resources

### Steps

1. **Open Xcode project/workspace**
2. **Select iOS Simulator** (e.g., iPhone 15)
3. **Run tests**: Product → Test (⌘U)
4. **Verify**: Tests should load fixtures from bundle

### Troubleshooting

- **Fixtures not found**: Ensure fixtures are added as bundle resources
- **Header validation fails**: Check line endings (must be LF)
- **Hash mismatch**: Verify fixture was generated with correct version

## Interpreting Golden Test Failures

When a golden test fails, `GoldenDiffPrinter` outputs:

1. **Platform info**: OS, build config, Swift version
2. **First mismatch location**: Byte index and hex char index
3. **Context window**: Bytes before/after mismatch
4. **Full expected/actual**: First 128 chars of hex strings

### Example Output

```
========================================
GOLDEN DIFF: DecisionHash
========================================
First mismatch at byte index: 16
Hex char index: 32

At mismatch:
Expected: a
Actual:   b

Full expected (first 128 chars):
1ac2b661e7f5f7ed0a6805474de687a38f2cf5506025310455e79a8e1b233f8a...

Full actual (first 128 chars):
1ac2b661e7f5f7ed0a6805474de687a38f2cf5506025310455e79a8e1b233f8b...
========================================
```

## Cross-Language Verification

Python reference verifier (`scripts/verify_decisionhash_fixtures.py`):

1. **Validates fixture headers** (SHA256, length)
2. **Computes BLAKE3-256** using Python `blake3` library
3. **Compares** Swift output vs Python output
4. **Reports** first mismatch location

### Usage

```bash
python3 scripts/verify_decisionhash_fixtures.py Tests/Fixtures/decision_hash_v1.txt
```

### Requirements

- Python 3.11+
- `blake3` library: `pip install blake3`

## CI Integration

CI automatically:
1. Regenerates fixtures on PR
2. Verifies no diff (`git diff --exit-code`)
3. Runs Python reference verification
4. Uploads diagnostic artifacts on failure

## Best Practices

1. **Never modify fixtures manually** - always regenerate
2. **Version fixtures** when layout changes
3. **Document changes** in SSOT
4. **Test locally** before pushing
5. **Review diffs** carefully in PR
