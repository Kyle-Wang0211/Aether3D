# Legacy Migration Report - SSOT Foundation v1.1

**Date:** 2026-01-24  
**Purpose:** Document removal of legacy mechanisms in favor of closed-world, executable-policy model

---

## Section A — Legacy Inventory

### A1. Grep-Based Backend Detection (LEGACY)

**File:** `.github/workflows/ssot-foundation-ci.yml`  
**Lines:** 701, 907, 1151  
**Purpose:** Extract backend name from print statements using grep  
**Why it existed:** Historical approach before `activeBackendName()` API existed  
**Status:** **REPLACED** by `CryptoBackendPolicyTests` using `activeBackendName()`

**Legacy Code Pattern:**
```bash
BACKEND_NAME=$(echo "$TEST_OUTPUT" | grep -oE "CryptoShim backend: (PURE_SWIFT|NATIVE)" | head -1 | sed 's/CryptoShim backend: //' || echo "unknown")
```

**Replacement:** `CryptoBackendPolicyTests` enforces policy via executable assertions using `CryptoShim.activeBackendName()`

---

### A2. Grep-Based YAML Parsing Fallback (LEGACY)

**File:** `scripts/ci/validate_no_duplicate_steps_keys.sh`  
**Line:** 128  
**Purpose:** Fallback grep check for duplicate `steps:` keys  
**Why it existed:** Added as safety net before Python YAML parsing was primary  
**Status:** **REPLACED** by Python YAML parsing (primary mechanism)

**Legacy Code Pattern:**
```bash
STEPS_COUNT=$(grep -c "^\s*steps:" "$WORKFLOW_FILE" || echo "0")
```

**Replacement:** Python YAML parser (`yaml.safe_load`) detects duplicate keys structurally

---

### A3. Unpinned Runners (LEGACY)

**File:** `.github/workflows/ssot-foundation-ci.yml`  
**Line:** 960 (`golden_vector_governance` job)  
**Purpose:** Uses `ubuntu-latest`  
**Why it existed:** Historical default before runner pinning policy  
**Status:** **REPLACED** by pinned runner policy

**File:** `.github/workflows/ci-gate.yml`  
**Line:** 10  
**Purpose:** Uses `macos-latest`  
**Status:** **TO BE REVIEWED** (may be non-blocking, but should still be pinned)

**Replacement:** All blocking gates use pinned runners (ubuntu-22.04, macos-14)

---

### A4. Print-Based Backend Logging (LEGACY, BUT KEPT FOR DIAGNOSTICS)

**File:** `Tests/Constants/TestHelpers/CryptoShim.swift`  
**Lines:** 81, 85, 95  
**Purpose:** Print statements for backend selection visibility  
**Why it existed:** Early diagnostic logging before executable policy API  
**Status:** **KEPT** (diagnostic only, not used for correctness)

**Rationale:** Print statements remain for CI log visibility, but correctness is enforced via `activeBackendName()` API and `CryptoBackendPolicyTests`. This is acceptable as long as:
- Print statements are clearly marked as diagnostic-only
- Policy enforcement uses executable API
- No grep-based extraction relies on print format

---

### A5. Error Masking Patterns (LEGACY)

**Files:** `.github/workflows/quality_precheck.yml`, `.github/workflows/ci.yml`  
**Patterns:** `|| true`, `|| echo`, `set +e`  
**Purpose:** Mask failures or allow partial failures  
**Status:** **TO BE REVIEWED** (some may be intentional for non-blocking diagnostics)

**Note:** Some `|| echo` patterns are legitimate for diagnostic commands that may fail (e.g., `lscpu` not available). These are kept but clearly marked as diagnostic-only.

---

## Section B — Replacement Mapping

| Legacy Mechanism | New Mechanism | Coverage Proof |
|----------------|---------------|----------------|
| Grep-based backend detection | `CryptoBackendPolicyTests` + `activeBackendName()` API | Test runs first in Gate 2, fails fast if policy violated |
| Grep-based YAML duplicate detection | Python YAML parser (`yaml.safe_load`) | Detects duplicate keys at parse time, reports job + line |
| `ubuntu-latest` in gates | Pinned `ubuntu-22.04` | Validator `validate_runner_pinning.sh` enforces |
| `macos-latest` in gates | Pinned `macos-14` | Validator `validate_runner_pinning.sh` enforces |
| Print-based backend detection (for correctness) | `activeBackendName()` API | Executable policy test enforces correctness |

---

## Section C — Deletions Performed

### C1. Removed Grep-Based Backend Detection

**Deleted from:** `.github/workflows/ssot-foundation-ci.yml`  
**Lines removed:** 
- Line 701: `grep -q "CryptoShim backend: PURE_SWIFT"` check in canary test
- Line 907: `BACKEND_NAME=$(echo "$TEST_OUTPUT" | grep -oE "CryptoShim backend: (PURE_SWIFT|NATIVE)"...)` extraction
- Line 1151: Same grep-based extraction in experimental lane

**Why safe to remove:**
- `CryptoBackendPolicyTests` runs first in Gate 2 and enforces policy via executable assertions
- `activeBackendName()` API provides stable, programmatic backend identification
- Grep-based extraction was fragile and relied on print statement format
- Policy test fails fast if backend selection violates policy

**Replacement:** Backend correctness is enforced by `CryptoBackendPolicyTests` using `CryptoShim.activeBackendName()`. No log parsing required.

---

### C2. Removed Grep-Based YAML Fallback

**Deleted from:** `scripts/ci/validate_no_duplicate_steps_keys.sh`  
**Lines removed:** Fallback grep check (lines 125-132)

**Why safe to remove:**
- Python YAML parser is primary and detects duplicates structurally
- Grep fallback was fragile and could miss structural issues
- Meta-validator `validate_no_grep_yaml_for_policies.sh` ensures critical policies use Python parsing

**Replacement:** Python YAML parsing is the single authoritative mechanism.

---

### C3. Pinned Unpinned Runners

**Fixed in:** 
- `.github/workflows/ssot-foundation-ci.yml`: `golden_vector_governance` job: `ubuntu-latest` → `ubuntu-22.04`
- `.github/workflows/ci-gate.yml`: `gate` job: `macos-latest` → `macos-14`

**Why safe:**
- Prevents runner image drift (Ubuntu and macOS images update independently)
- Aligns with runner pinning policy enforced by `validate_runner_pinning.sh`
- All blocking gates now use pinned runners
- Comments added explaining replacement of legacy `-latest` tags

---

## Section D — Remaining Legacy (Justified)

### D1. Print Statements in CryptoShim (KEPT)

**Rationale:** Print statements remain for CI log visibility and diagnostics. They are:
- Clearly marked as diagnostic-only
- Not used for correctness (policy enforced via executable test)
- Useful for debugging backend selection issues

**Removal condition:** If we add structured logging that replaces print statements, these can be removed.

---

### D2. Diagnostic `|| echo` Patterns (KEPT)

**Rationale:** Some `|| echo` patterns are legitimate for diagnostic commands:
- `lscpu | grep ... || echo "not available"` - diagnostic only
- `swift --version || echo "not available"` - diagnostic only

These are kept because:
- They are clearly diagnostic (not correctness-critical)
- They improve CI log readability
- They do not mask actual failures

**Removal condition:** If we add structured diagnostic collection, these can be replaced.

---

## Section E — Verification

After all deletions:

✅ `bash scripts/ci/lint_workflows.sh` - PASSED  
✅ `bash scripts/ci/preflight_ssot_foundation.sh` - PASSED  
✅ `bash scripts/ci/run_all_up_local_verification.sh` - PASSED

**No script references deleted files.**  
**No workflow mentions removed env vars or flags.**  
**Documentation updated to reflect new mechanisms.**

---

## Section F — Structural Enforcement

The following mechanisms prevent regression:

1. **`validate_no_grep_yaml_for_policies.sh`** - Ensures critical policies use Python YAML parsing
2. **`validate_runner_pinning.sh`** - Ensures gates use pinned runners
3. **`CryptoBackendPolicyTests`** - Executable policy enforcement for backend selection
4. **`validate_gate2_backend_policy_test_first.sh`** - Ensures policy test runs first

These validators are integrated into `lint_workflows.sh` and `preflight_ssot_foundation.sh`, ensuring they run on every CI execution.

---

**Report Status:** ✅ COMPLETE  
**Migration Status:** ✅ LEGACY REMOVED  
**Verification Status:** ✅ ALL TESTS PASS
