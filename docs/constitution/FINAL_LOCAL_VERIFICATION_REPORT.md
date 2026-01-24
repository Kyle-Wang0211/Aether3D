# Final Local Verification Report

**Date:** 2026-01-24 15:09:17 UTC
**Branch:** pr1/ssot-foundation-v1_1
**Duration:** 56s
**Status:** ✅ All checks passed

**Note:** This report is regenerated on each verification run. Timestamps and durations may vary.

---

## Toolchain Versions

- **Swift:** Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)
- **Xcode:** Xcode 26.2
- **OS:** Darwin 25.1.0
- **Architecture:** arm64

---

## Summary

This report documents the comprehensive all-up local verification run that mirrors GitHub Actions CI.
All SSOT Foundation gates and validation checks were executed locally.

### Test Results

| Phase | Check | Status |
|-------|-------|--------|
| 0 | Snapshot & Safety | ✅ PASSED |
| 1.1 | Workflow Lint | ✅ PASSED |
| 1.2 | Workflow Graph | ✅ PASSED |
| 1.3 | Xcode Selection | ✅ PASSED |
| 1.4 | Test Selection | ✅ PASSED |
| 2.1 | Repository Hygiene | ✅ PASSED |
| 2.2 | Docs Markers | ✅ PASSED |
| 2.3 | Markdown Links | ✅ PASSED |
| 2.4 | JSON Catalogs | ✅ PASSED |
| 3.1 | Swift Package Resolve | ✅ PASSED |
| 3.2 | Swift Build (Debug) | ✅ PASSED |
| 3.3 | Swift Build (Release) | ✅ PASSED |
| 4.0 | Crypto Shim Canary (Debug) | ⚠️  SKIPPED |
| 4.0 | Crypto Shim Canary (Release) | ⚠️  SKIPPED |
| 4.1 | Gate 1 Tests (Debug) | ✅ PASSED |
| 4.2 | Gate 2 Tests (Debug) | ✅ PASSED |
| 4.3 | Gate 1 Tests (Release) | ✅ PASSED |
| 4.4 | Gate 2 Tests (Release) | ✅ PASSED |
| 5 | Shadow Cross-Platform | ✅ COMPLETED |
| 6 | Linux Equivalence Smoke | ✅ PASSED |
| 7 | SSOT Preflight | ✅ PASSED |

---

## Commands Executed

```bash
# Phase 1: Workflow & CI Guardrails
bash scripts/ci/lint_workflows.sh
bash scripts/ci/validate_workflow_graph.sh .github/workflows/ssot-foundation-ci.yml
bash scripts/ci/validate_macos_xcode_selection.sh
bash scripts/ci/validate_ssot_gate_test_selection.sh

# Phase 2: Repo Hygiene & Docs Integrity
bash scripts/ci/repo_hygiene.sh
bash scripts/ci/audit_docs_markers.sh
bash scripts/ci/check_markdown_links.sh
python3 -c "import json; json.load(open('docs/constitution/constants/USER_EXPLANATION_CATALOG.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_ENCODING.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_QUANTIZATION.json'))"
python3 -c "import json; json.load(open('docs/constitution/constants/GOLDEN_VECTORS_COLOR.json'))"

# Phase 3: Swift Build Sanity
swift package resolve
swift build -c debug
swift build -c release

# Phase 4: SSOT Foundation Tests
swift test -c debug --filter [Gate 1 tests]
swift test -c debug --filter [Gate 2 tests]
swift test -c release --filter [Gate 1 tests]
swift test -c release --filter [Gate 2 tests]

# Phase 5: Shadow Cross-Platform Consistency
bash scripts/ci/run_shadow_crossplatform_consistency.sh

# Phase 6: Linux Equivalence Smoke
bash scripts/ci/linux_equivalence_smoke_no_docker.sh

# Phase 7: SSOT Preflight
bash scripts/ci/preflight_ssot_foundation.sh
```

---

## Gate 1 Test Results (Debug)

```
	 Executed 36 tests, with 0 failures (0 unexpected) in 0.010 (0.013) seconds
```

---

## Gate 2 Test Results (Debug)

```
	 Executed 52 tests, with 0 failures (0 unexpected) in 0.019 (0.022) seconds
```

---

## Gate 1 Test Results (Release)

```
	 Executed 36 tests, with 0 failures (0 unexpected) in 0.009 (0.011) seconds
```

---

## Gate 2 Test Results (Release)

```
	 Executed 52 tests, with 0 failures (0 unexpected) in 0.017 (0.021) seconds
```

---

## Known Non-Blocking Issues

See SHADOW_CROSSPLATFORM_REPORT.md for cross-platform consistency shadow suite results.

---

## Next Steps

✅ All checks passed. Ready for commit and push.

**Commit Command:**
```bash
git add -A
git commit -t COMMIT_MESSAGE_TEMPLATE.txt
```

**Note:** No push was performed as requested.

---

**Report Generated:** 2026-01-24 15:09:18 UTC
**Note:** Report timestamps reflect verification run time. Test execution times may vary.
