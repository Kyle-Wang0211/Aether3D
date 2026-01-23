# Developer Failure Triage Map

**Document Version:** 1.1.1  
**Status:** IMMUTABLE

---

## Overview

This document explains what to do when SSOT Foundation tests fail. It categorizes failures and provides actionable guidance.

---

## Failure Categories

### Category 0: CI Infrastructure Failure (Workflow/Environment)

**What it means:**
- Xcode selection failed (`xcode-select: error: invalid developer directory`)
- Workflow job graph invalid
- Runner image mismatch
- Ubuntu compilation failure: `no such module 'CryptoKit'`

**What fixes are allowed:**
- ✅ Fix workflow YAML (use setup-xcode action, pin runner versions)
- ✅ Update matrix to match available Xcode versions
- ✅ Use cross-platform crypto shim (`CryptoShim`) instead of direct `CryptoKit` imports
- ✅ Add `swift-crypto` dependency to test targets that need SHA-256 on Linux
- ❌ **FORBIDDEN:** Hardcode `/Applications/Xcode_*.app` paths
- ❌ **FORBIDDEN:** Use floating `macos-latest` without Xcode version validation
- ❌ **FORBIDDEN:** Import `CryptoKit` directly in Linux-compiled code without conditional compilation

**How to proceed:**
1. Check CI logs for exact error message
2. If Xcode path error: Remove hardcoded path, use `maxim-lobanov/setup-xcode@v1`
3. If version mismatch: Update matrix to use available Xcode version
4. Pin `runs-on` to specific macOS version (e.g., `macos-14`)
5. If Ubuntu CryptoKit error: Replace direct `import CryptoKit` with `CryptoShim` usage

**Example errors:**

**Xcode Selection:**
```
❌ xcode-select: error: invalid developer directory '/Applications/Xcode_15.0.app/Contents/Developer'
Root cause: Runner image doesn't ship that Xcode version/path
Fix: 
  1. Remove hardcoded xcode-select command
  2. Use maxim-lobanov/setup-xcode@v1 action
  3. Pin runs-on to macos-14
  4. Update matrix to use available Xcode version (e.g., 15.4)
Prevention: lint_workflows.sh forbids hardcoded /Applications/Xcode paths
```

**Ubuntu CryptoKit:**
```
❌ error: no such module 'CryptoKit'
Root cause: CryptoKit is Apple-only; Linux builds fail when tests import it directly
File: Tests/Constants/EnumFrozenOrderTests.swift:11: import CryptoKit
Fix:
  1. Replace direct CryptoKit import with CryptoShim usage
  2. Use CryptoShim.sha256Hex(data) instead of SHA256.hash(data: data)
  3. Ensure Package.swift adds Crypto product dependency to ConstantsTests target
  4. Verify ban_apple_only_imports.sh passes
Prevention: ban_apple_only_imports.sh detects forbidden imports in Linux-compiled targets

How to verify locally:
  rg -n "import CryptoKit" . | grep -v "#if canImport\|CryptoShim\|SHA256Utility"
  rg -n "import Crypto" . | grep -v "#if canImport\|CryptoShim\|SHA256Utility"
  bash scripts/ci/ban_apple_only_imports.sh
```

**SHA-256 Output Mismatch Across Platforms:**
```
❌ CryptoShimConsistencyTests failure: SHA-256 output differs between macOS and Linux
Root cause: Byte ordering, hex formatting, or platform-specific crypto implementation drift
Fix:
  1. Run CryptoShimConsistencyTests locally on both platforms (if possible)
  2. Check CryptoShim.swift conversion logic (byte array ordering, hex format)
  3. Ensure both CryptoKit and swift-crypto Crypto produce identical byte arrays
  4. Verify hex encoding is consistently lowercase
Prevention: CryptoShimConsistencyTests validates cross-platform determinism
```

**Ubuntu Gate 2 SIGILL Crash (Signal 4):**
```
❌ Ubuntu Gate 2 crashes immediately with signal 4 (SIGILL), 0 tests run
Root cause: Crypto asm illegal instruction - BoringSSL/OpenSSL CPU feature detection fails on CI CPUs
  OR environment variable not propagated to swift test process
Symptoms:
  - Test binary exits immediately with unexpected signal code 4
  - Register dump shown
  - "Test run started ... 0 tests ... then crash"
  - May happen before swift test command executes (toolchain init) or during test discovery
Fix (MUST apply all three):
  1. Set OPENSSL_ia32cap at JOB level in workflow YAML:
     env:
       OPENSSL_ia32cap: ${{ matrix.os == 'ubuntu-22.04' && ':0' || '' }}
  2. Export OPENSSL_ia32cap via GITHUB_ENV early in job (before any build/test):
     echo "OPENSSL_ia32cap=:0" >> $GITHUB_ENV
  3. Add guardrail verification step that fails if OPENSSL_ia32cap is not ":0":
     if [ -z "${OPENSSL_ia32cap:-}" ] || [ "${OPENSSL_ia32cap}" != ":0" ]; then
       echo "::error::OPENSSL_ia32cap must be ':0' on Ubuntu Gate 2 to prevent SIGILL"
       exit 1
     fi
  4. Verify canary test passes: swift test -c debug --filter CryptoShimConsistencyTests
Prevention: 
  - Gate Linux Preflight includes crypto shim canary check (catches SIGILL early)
  - Workflow sets OPENSSL_ia32cap=:0 at job level AND exports via GITHUB_ENV
  - Guardrail verification steps fail fast if env not set correctly
  - Canary test runs before full Gate 2 suite to localize failure

How to verify locally (if running on Linux or Docker):
  export OPENSSL_ia32cap=:0
  swift test -c debug --filter CryptoShimConsistencyTests
  # Should pass without SIGILL

If SIGILL persists after fix:
  - Check env propagation: print OPENSSL_ia32cap in step before swift test
  - Verify GITHUB_ENV export happened: check step logs
  - Check if wrapper scripts sanitize/clear env (preserve OPENSSL_ia32cap)
  - Add diagnostics: uname -a, lscpu, env | grep OPENSSL
```

**How to verify locally:**
```bash
# Check for forbidden imports
bash scripts/ci/ban_apple_only_imports.sh

# Verify Linux compilation (if Docker available)
bash scripts/ci/run_linux_spm_matrix.sh

# Or run Linux equivalence smoke (no Docker)
bash scripts/ci/linux_equivalence_smoke_no_docker.sh
```

**Prevention:**
- `scripts/ci/lint_workflows.sh` detects hardcoded Xcode paths
- `scripts/ci/validate_macos_xcode_selection.sh` validates Xcode selection
- `scripts/ci/ban_apple_only_imports.sh` detects Apple-only imports in Linux-compiled targets
- `scripts/ci/repo_hygiene.sh` includes Apple-only import check
- Workflow uses `setup-xcode` action instead of manual `xcode-select`
- All test code uses `CryptoShim` for cross-platform SHA-256 hashing

---

### Category 1: Constitutional Violation (Gate A Failure)

**What it means:**
- Enum case order changed
- Catalog schema violated
- Encoding/quantization golden vectors mismatched

**What fixes are allowed:**
- ✅ Fix test if test was wrong (rare, requires justification)
- ✅ Revert enum/catalog changes if accidental
- ❌ **FORBIDDEN:** Update golden vectors without breaking change documentation
- ❌ **FORBIDDEN:** Reorder enum cases
- ❌ **FORBIDDEN:** Delete enum cases

**How to proceed:**
1. Identify which invariant was violated (A2, A3, B3, etc.)
2. Check error message for specific file/entry
3. If accidental change: revert
4. If intentional breaking change: follow breaking change process

**Example error:**
```
❌ EdgeCaseType case order changed. Only legal change: append new cases to the end.
Invariant: B3
File: Core/Constants/EdgeCaseType.swift
Fix: Revert enum reorder OR append new case to end and update frozenCaseOrderHash
```

---

### Category 2: Determinism Violation (Gate B Failure)

**What it means:**
- Cross-platform consistency broken
- Color conversion tolerance exceeded
- meshEpochSalt closure violated

**What fixes are allowed:**
- ✅ Fix implementation if implementation was wrong
- ✅ Update tolerance if tolerance was incorrectly specified
- ❌ **FORBIDDEN:** Loosen tolerances without RFC
- ❌ **FORBIDDEN:** Change encoding/quantization without breaking change process

**How to proceed:**
1. Identify which platform/config failed
2. Check if failure is consistent or flaky
3. If consistent: implementation bug, fix implementation
4. If flaky: investigate floating-point precision issues

**Example error:**
```
❌ Lab L* channel mismatch for 'sRGB_red': expected 53.2408, got 53.2420, diff=0.0012
Invariant: CL2, CE
Tolerance: 1e-3 absolute per channel
Fix: Check color conversion implementation OR update tolerance with RFC
```

---

### Category 3: Catalog Completeness Violation

**What it means:**
- Enum case missing from explanation catalog
- Minimum explanation set not satisfied
- Duplicate codes or labels

**What fixes are allowed:**
- ✅ Add missing catalog entry
- ✅ Fix duplicate codes/labels
- ❌ **FORBIDDEN:** Remove enum case to satisfy catalog
- ❌ **FORBIDDEN:** Mark enum case as "non-user-facing" without justification

**How to proceed:**
1. Identify missing entry
2. Add entry to `USER_EXPLANATION_CATALOG.json`
3. Ensure all required fields present
4. Run tests again

**Example error:**
```
❌ EdgeCaseType.NEGATIVE_INPUT (code: 'NEGATIVE_INPUT') missing from USER_EXPLANATION_CATALOG.json (B1)
Fix: Add explanation entry for NEGATIVE_INPUT to USER_EXPLANATION_CATALOG.json
```

---

### Category 4: Golden Vector Mismatch

**What it means:**
- Encoding/quantization/color output doesn't match golden vector
- Implementation changed behavior

**What fixes are allowed:**
- ✅ Fix implementation if implementation drifted
- ✅ Update golden vector WITH breaking change documentation (rare)
- ❌ **FORBIDDEN:** Update golden vector silently
- ❌ **FORBIDDEN:** Change implementation to match wrong golden vector

**How to proceed:**
1. Determine if implementation or golden vector is wrong
2. If implementation wrong: fix implementation
3. If golden vector wrong: update golden vector + breaking change docs
4. If intentional change: follow breaking change process

**Example error:**
```
❌ Encoding mismatch for 'simple_ascii': Expected: 0000000568656c6c6f, Got: 0000000568656c6c6f00
Invariant: A2
Fix: Fix encoding implementation OR update golden vector with breaking change documentation
```

---

### Category 5: Breaking Change Surface Violation

**What it means:**
- Changed breaking surface without RFC
- Changed breaking surface without version bump

**What fixes are allowed:**
- ✅ Add RFC and version bump
- ✅ Revert breaking change
- ❌ **FORBIDDEN:** Change breaking surface without documentation

**How to proceed:**
1. Identify which breaking surface was changed
2. Create RFC documenting change
3. Update `BREAKING_CHANGE_SURFACE.json`
4. Increment `contractVersion`
5. Update `MIGRATION_GUIDE.md`

**Example error:**
```
❌ BREAKING_CHANGE_SURFACE.json missing required surface 'quant.geom_precision' (C1)
Fix: Add entry to BREAKING_CHANGE_SURFACE.json OR revert quantization precision change
```

---

## Quick Reference: Fix Decision Tree

```
Test Failed
│
├─ Enum/Catalog Schema?
│  ├─ Accidental change? → Revert
│  └─ Intentional? → Follow breaking change process
│
├─ Golden Vector Mismatch?
│  ├─ Implementation wrong? → Fix implementation
│  ├─ Golden vector wrong? → Update + breaking change docs
│  └─ Intentional change? → Follow breaking change process
│
├─ Determinism Violation?
│  ├─ Implementation bug? → Fix implementation
│  ├─ Tolerance too strict? → RFC to adjust tolerance
│  └─ Platform-specific? → Investigate platform differences
│
└─ Catalog Completeness?
   ├─ Missing entry? → Add catalog entry
   ├─ Duplicate? → Fix duplicate
   └─ Wrong structure? → Fix structure
```

---

## Forbidden Fixes (Will Cause CI Failure)

1. **Silent golden vector updates** (without breaking change docs)
2. **Enum case reorder** (without updating frozenCaseOrderHash)
3. **Enum case deletion** (append-only rule)
4. **Tolerance loosening** (without RFC)
5. **Breaking surface changes** (without RFC + version bump)
6. **Catalog code deletion** (append-only rule)

---

## Getting Help

If you're unsure which category your failure falls into:

1. **Check error message:** Look for invariant ID (A2, A3, B3, etc.)
2. **Check file mentioned:** Identifies which artifact violated
3. **Check CI logs:** Full context in test output
4. **Ask platform architect:** For breaking change decisions

---

## Common Mistakes

### Mistake 1: "Just update the golden vector"
**Problem:** Golden vectors are constitutional artifacts
**Fix:** Update golden vector + breaking change documentation

### Mistake 2: "Reorder enum cases for clarity"
**Problem:** Enum order is frozen (B3)
**Fix:** Append new cases to end, never reorder

### Mistake 3: "Loosen tolerance to make test pass"
**Problem:** Tolerances are contractual (CL2)
**Fix:** Fix implementation OR RFC to change tolerance

### Mistake 4: "Delete unused enum case"
**Problem:** Append-only rule
**Fix:** Mark as deprecated, never delete

### Mistake 5: "Hardcode Xcode path in workflow"
**Problem:** Runner images don't guarantee specific Xcode paths
**Fix:** Use `maxim-lobanov/setup-xcode@v1` action + pin `runs-on` to specific macOS version

---

## How to Run Full Local CI

Before pushing, run the local CI matrix to catch failures early:

### Quick Check (Fast Mode)
```bash
CI_FAST=1 bash scripts/ci/run_local_ci_matrix.sh
```
Runs:
- Workflow lint
- Preflight checks
- Swift build (debug)
- Fast tests only (Gate 1 tests)

### Full Check (Normal Mode)
```bash
bash scripts/ci/run_local_ci_matrix.sh
```
Runs:
- All quick checks
- Swift build (release)
- Full test suite (debug + release)

### Deep Check (Deep Mode)
```bash
CI_DEEP=1 bash scripts/ci/run_local_ci_matrix.sh
```
Runs full matrix (same as normal, with additional checks if implemented)

### Individual Checks

**Workflow validation:**
```bash
bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml
bash scripts/ci/lint_workflows.sh
```

**Preflight:**
```bash
bash scripts/ci/preflight_ssot_foundation.sh
```

**Documentation markers:**
```bash
bash scripts/ci/audit_docs_markers.sh
```

**Swift tests (specific filters):**
```bash
swift test -c debug --filter EnumFrozenOrderTests
swift test -c debug --filter CatalogSchemaTests
swift test -c debug --filter ExplanationIntegrityTests
swift test -c debug --filter CrossPlatformConsistencyTests
```

**All SSOT Foundation tests:**
```bash
swift test -c debug --filter ConstantsTests
```

---

## Test File → Invariant Mapping

| Test File | Invariants Guarded |
|-----------|-------------------|
| `EnumFrozenOrderTests.swift` | B3 (frozen case order) |
| `CatalogSchemaTests.swift` | B1, D2 (catalog schema, minimum explanation set) |
| `CatalogUniquenessTests.swift` | 5.1 (code uniqueness, severity consistency) |
| `CatalogCrossReferenceTests.swift` | B1, B2 (enum ↔ catalog cross-reference) |
| `CatalogActionabilityRulesTests.swift` | EIA_001 (actionability rules) |
| `ExplanationIntegrityTests.swift` | EIA_001 (explanation integrity, user trust) |
| `DeterministicEncodingContractTests.swift` | A2 (deterministic encoding, byte order) |
| `DeterministicQuantizationContractTests.swift` | A3, A4 (quantization precision, rounding) |
| `DeterministicQuantizationHalfAwayFromZeroBoundaryTests.swift` | A4 (rounding boundary behavior) |
| `CrossPlatformConsistencyTests.swift` | A2, A3, A4, A5, CE, CL2 (cross-platform determinism) |
| `DomainPrefixesClosureTests.swift` | G1 (domain separation prefix closure) |
| `ColorMatrixIntegrityTests.swift` | CE (color matrix integrity, D65 lock) |
| `ReproducibilityBoundaryTests.swift` | E2 (reproducibility boundary) |
| `BreakingSurfaceTests.swift` | C1 (breaking change surface) |
| `ReasonCompatibilityTests.swift` | U1, U16 (reason compatibility rules) |
| `MinimumExplanationSetTests.swift` | D2 (minimum explanation set) |
| `GoldenVectorsRoundTripTests.swift` | A2, A3, A4, CE (golden vector stability) |

---

## Scripts Reference

All scripts are in `scripts/ci/`:

- `validate_workflow_graph.sh` - Validates GitHub Actions workflow job graph
- `lint_workflows.sh` - Lints all workflow YAML files
- `audit_docs_markers.sh` - Audits Guardian Layer documentation markers
- `preflight_ssot_foundation.sh` - Comprehensive preflight checks
- `run_local_ci_matrix.sh` - Local CI runner (mirrors GitHub Actions gates)

---

**Status:** APPROVED FOR PR#1 v1.1.1  
**Audience:** All contributors  
**Purpose:** Prevent frustration and accidental violations
