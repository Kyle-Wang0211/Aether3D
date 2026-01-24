# Developer Failure Triage Map

**Document Version:** 1.1.1  
**Status:** IMMUTABLE

---

## Overview

This document explains what to do when SSOT Foundation tests fail. It categorizes failures and provides actionable guidance.

---

## Failure Categories

### Category 0: CI Infrastructure Failure (Workflow/Environment)

**CI Semantic Failures (GitHub Actions YAML/Expression Errors):**

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

**CI Semantic Failures:**

**Unrecognized named-value: 'env' (in concurrency.group):**
```
❌ Error: Unrecognized named-value: 'env'. Located at position X within expression: ${{ env.SSOT_CONCURRENCY_GROUP }}
Root cause: concurrency.group is evaluated at compile-time and cannot reference runtime contexts like env.*
Fix:
  1. Change concurrency.group to use ONLY github.* contexts:
     concurrency:
       group: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  2. Keep SSOT_CONCURRENCY_GROUP as runtime env for diagnostics only:
     env:
       SSOT_CONCURRENCY_GROUP: ${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  3. Run: bash scripts/ci/validate_concurrency_contexts.sh
Prevention: validate_concurrency_contexts.sh detects env.* in concurrency.group

**Guardrail wiring failure: validator exists but not invoked:**
```
❌ Guardrail wiring validation failed (SSOT blocking)
❌ REQUIRED: validate_concurrency_uniqueness.sh not invoked in preflight_ssot_foundation.sh or workflow
Root cause: Guardrail script exists but is not called by lint_workflows.sh or preflight_ssot_foundation.sh

**Merge contract violation:**
```
❌ Merge contract validation failed (SSOT blocking)
❌ Missing required jobs: gate_1_constitutional
OR
❌ Required jobs unreachable on pull_request: gate_2_determinism_trust (if: github.event_name == 'workflow_dispatch')
Root cause: Merge contract (MERGE_CONTRACT.md) defines required merge-blocking jobs. If a required job is missing, renamed, or gated behind workflow_dispatch/schedule only, the contract is violated.
Fix:
  1. Ensure all required jobs exist: gate_0_workflow_lint, gate_linux_preflight_only, gate_1_constitutional, gate_2_determinism_trust, golden_vector_governance.
  2. Ensure all required jobs are reachable on pull_request events (no if: conditions blocking pull_request).
  3. Ensure experimental jobs (gate_2_linux_native_crypto_experiment) are NOT in the merge contract.
Prevention: validate_merge_contract.sh enforces contract compliance. See docs/constitution/MERGE_CONTRACT.md for contract definition.

**Unpinned actions in SSOT workflow:**
```
❌ Actions pinning validation failed (SSOT blocking)
❌ Unpinned action (SSOT requires full SHA): gate_1_constitutional/Checkout: actions/checkout@v4
Root cause: SSOT workflows require all actions to be pinned to full commit SHAs (40 hex characters) to prevent silent upstream drift. Tags like @v4 can change without notice.
Fix:
  1. Find the commit SHA for the action version you want to use.
  2. Replace actions/checkout@v4 with actions/checkout@<full-40-char-sha>.
  3. Example: actions/checkout@v4 → actions/checkout@abc123def4567890abcdef1234567890abcdef12
Finding commit SHAs:
  - Visit the action's repository (e.g., https://github.com/actions/checkout)
  - Navigate to the tag/release (e.g., v4)
  - Copy the full commit SHA from the commit history
Prevention: validate_actions_pinning.sh enforces pinning for SSOT workflows (hard error) and warns for non-SSOT workflows.
Fix:
  1. Check scripts/ci/validate_guardrail_wiring.sh output for missing wiring
  2. Add missing guardrail invocation to lint_workflows.sh or preflight_ssot_foundation.sh
  3. Ensure guardrail is called with correct arguments
  4. Re-run: bash scripts/ci/validate_guardrail_wiring.sh
Prevention: validate_guardrail_wiring.sh ensures all required guardrails are invoked
```

**Duplicate YAML keys ('steps' is already defined):**
```
❌ Error: 'steps' is already defined
Root cause: YAML key duplication - a job has multiple 'steps:' keys
Fix:
  1. Locate the duplicate 'steps:' keys in the job (check workflow file)
  2. Merge all steps into a single 'steps:' key
  3. Ensure steps are ordered correctly (diagnostics first, then checkout, then build/test)
  4. Run: bash scripts/ci/validate_no_duplicate_steps_keys.sh
Prevention: validate_no_duplicate_steps_keys.sh detects duplicate steps keys
```

**Bash syntax error in workflow run blocks (unexpected end of file):**
```
❌ Error: syntax error: unexpected end of file
  from /home/runner/work/_temp/<id>.sh line N
Root cause: Shell script syntax error in a workflow `run: |` block
  - Missing closing quote (`"`, `'`)
  - Missing `fi` for `if ...; then`
  - Missing `done` for loops
  - Malformed heredoc (`<<EOF` without matching `EOF`)
  - Stray backslash line continuation at end of file
  - Unbalanced parentheses or braces in bash
Symptoms:
  - CI fails immediately with shell parse error
  - Error points to temporary script file (not workflow YAML)
  - Not a test failure; script never executes
Fix:
  1. Locate the offending step in workflow YAML (check step name from error)
  2. Inspect the entire `run: |` block for unclosed structures
  3. Common issues:
     - `if` without matching `fi`
     - `while`/`for` without matching `done`
     - Unclosed quotes (check for `"` or `'` pairs)
     - Line continuation `\` at end of file or before `fi`/`done`
  4. Run: bash scripts/ci/validate_workflow_bash_syntax.sh <workflow_file>
  5. Fix syntax error and re-run validation
Prevention:
  - validate_workflow_bash_syntax.sh checks all `run:` blocks before CI runs
  - Integrated into lint_workflows.sh and preflight_ssot_foundation.sh
  - Runs automatically in CI preflight (Gate 0 and Linux Preflight)
  - Catches syntax errors before they reach GitHub Actions runners
  - FAILS if `set -euo pipefail` is missing (hard requirement for all run blocks)

How to run locally:
  bash scripts/ci/validate_workflow_bash_syntax.sh .github/workflows/ssot-foundation-ci.yml

Best practices for workflow run blocks:
  - Always start with `set -euo pipefail` for safety (REQUIRED)
  - Use structured control flow (if/else/fi, not || { ... })
  - Avoid line continuations (\) mixed with conditionals
  - Consolidate complex arguments into variables (e.g., FILTERS="--filter ...")
  - Ensure every `if` has a matching `fi` on its own line
  - Ensure every loop has a matching `done`
  - Close all quotes properly
```

**Dependency Drift (swift-crypto version change):**
```
⚠️  Warning: swift-crypto revision changed in Package.resolved
Root cause: Dependency version/revision updated without explicit marker
Fix:
  1. If intentional: Add "Dependency-Change: yes" to commit message body
  2. OR create marker file: touch .dependency-change-marker
  3. Commit both Package.resolved and the marker/commit message together
Prevention:
  - Linux Preflight checks Package.resolved for swift-crypto revision
  - Fails if revision changes without explicit marker
  - Ensures dependency updates are intentional and documented
```

**Cross-Workflow Concurrency Collision:**
```
❌ Error: Concurrency group lacks workflow-specific prefix
Root cause: concurrency.group does not include github.workflow or workflow name
  - Multiple workflows may share same concurrency group
  - New workflow run cancels unrelated workflow runs
Fix:
  1. Ensure concurrency.group includes \${{ github.workflow }}:
     concurrency:
       group: \${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  2. OR include workflow name explicitly in group pattern
Prevention:
  - validate_concurrency_uniqueness.sh checks all workflows
  - Integrated into lint_workflows.sh
  - Fails if group is constant or lacks workflow identifier
```

**Operation was canceled:**
```
❌ "Error: The operation was canceled."
Root cause: Job was cancelled by GitHub Actions due to concurrency cancel-in-progress
  - New push to same PR cancels old run (expected behavior)
  - Cross-workflow cancellation if concurrency groups collide (unexpected)
Symptoms:
  - Job shows "canceled" status, not "failed"
  - No test failures or assertion errors
  - May happen mid-execution
Diagnosis:
  1. Check "Concurrency Diagnostics" step output in job logs
  2. Verify concurrency.group value matches expected pattern
  3. Check if another run with same group started (check run_id, run_attempt)
  4. Review cancellation notice step output (if job reached that step)
Fix:
  - If cancellation was expected (new push): no action needed, new run will execute
  - If cancellation was unexpected: verify concurrency.group is unique per workflow
  - Ensure concurrency.group uses: github.workflow + PR number or ref
Prevention: Concurrency diagnostics step logs group value; cancellation notice clarifies it's not a test failure
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

Layered Mitigation (MUST apply all layers):
  (a) Job-level env: Set OPENSSL_ia32cap=:0 at job level for ubuntu Gate 2 jobs
  (b) Step-level env: Set OPENSSL_ia32cap=:0 at step level for test execution steps
  (c) GITHUB_ENV export: echo 'OPENSSL_ia32cap=:0' >> "$GITHUB_ENV" early in job
  (d) Inline prefix: Use OPENSSL_ia32cap=:0 swift test ... (guarantees env even if propagation fails)
  (e) Guardrail verification: Fail fast if OPENSSL_ia32cap != ":0" before tests run
  (f) Canary test: Run CryptoShimConsistencyTests early to catch SIGILL before full suite
  (g) Pure Swift fallback: SHA256PureSwift provides test-only fallback if native crypto SIGILLs

Fix steps:
  1. Set OPENSSL_ia32cap at JOB level in workflow YAML:
     env:
       OPENSSL_ia32cap: ${{ matrix.os == 'ubuntu-22.04' && ':0' || '' }}
  2. Export OPENSSL_ia32cap via GITHUB_ENV early in job (before any build/test):
     echo 'OPENSSL_ia32cap=:0' >> "$GITHUB_ENV"
  3. Set OPENSSL_ia32cap at STEP level for test execution steps:
     env:
       OPENSSL_ia32cap: ${{ matrix.os == 'ubuntu-22.04' && ':0' || '' }}
  4. Use inline prefix in swift test command:
     OPENSSL_ia32cap=:0 swift test -c debug --filter CryptoShimConsistencyTests
  5. Add guardrail verification step that fails if OPENSSL_ia32cap is not ":0"
  6. Run canary test early: OPENSSL_ia32cap=:0 swift test -c debug --filter CryptoShimConsistencyTests

Prevention: 
  - Gate Linux Preflight includes crypto shim canary check (catches SIGILL early)
  - Workflow sets OPENSSL_ia32cap=:0 at job level + step level + GITHUB_ENV + inline prefix
  - Guardrail verification steps fail fast if env not set correctly
  - Canary test runs before full Gate 2 suite to localize failure
  - Pure Swift SHA-256 fallback (SHA256PureSwift) available as last resort

How to verify locally (if running on Linux or Docker):
  export OPENSSL_ia32cap=:0
  OPENSSL_ia32cap=:0 swift test -c debug --filter CryptoShimConsistencyTests
  # Should pass without SIGILL

If SIGILL persists after all layers:
  - Check env propagation: print OPENSSL_ia32cap in step before swift test
  - Verify GITHUB_ENV export happened: check step logs
  - Check if wrapper scripts sanitize/clear env (preserve OPENSSL_ia32cap)
  - Review Linux diagnostics: uname -a, lscpu, env | grep OPENSSL, ldd xctest output
  - Enable pure Swift fallback explicitly: Set SSOT_PURE_SWIFT_SHA256=1 in test step env
    (This bypasses native crypto entirely and uses SHA256PureSwift)

Pure Swift SHA-256 Fallback (Explicit Control):
  - Environment variable: SSOT_PURE_SWIFT_SHA256=1 (Linux-only)
  - When enabled: CryptoShim uses SHA256PureSwift instead of native crypto backend
  - Default behavior: Uses native crypto with OPENSSL_ia32cap=:0 mitigation
  - Usage: Set in step env for Gate 2 tests if SIGILL persists despite all mitigations
  - Example:
    env:
      SSOT_PURE_SWIFT_SHA256: "1"
    run: swift test -c debug --filter CryptoShimConsistencyTests
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
