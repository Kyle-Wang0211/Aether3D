# Shadow Cross-Platform Consistency Report

**Date:** 2026-01-24 15:09:04 UTC
**Branch:** pr1/ssot-foundation-v1_1
**Status:** ⚠️  0
0 failure(s)

---

## Summary

This report documents the results of the shadow CrossPlatformConsistencyTests suite.
These tests are intentionally excluded from Gate 2 to avoid blocking CI on known precision issues,
but they are run locally to catch cross-platform determinism problems.

**Tests Executed:** 18
**Failures:** 0
0

---

## Test Output

```
[0/1] Planning build
Building for debugging...
[0/2] Write swift-version--58304C5D6DBC2206.txt
Build complete! (1.12s)
Test Suite 'Selected tests' started at 2026-01-24 15:09:04.722.
Test Suite 'Aether3DPackageTests.xctest' started at 2026-01-24 15:09:04.723.
Test Suite 'CrossPlatformConsistencyTests' started at 2026-01-24 15:09:04.723.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_d65_whitePoint_fixed]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_d65_whitePoint_fixed]' passed (0.001 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_goldenVectors_withinTolerance]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_goldenVectors_withinTolerance]' passed (0.001 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_matrices_explicit_ssot]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_colorConversion_matrices_explicit_ssot]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_coverageRatio_tolerance_1e4_relative]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_coverageRatio_tolerance_1e4_relative]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_domainPrefixes_matchConstants]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_domainPrefixes_matchConstants]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_embeddedNul_rejected]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_embeddedNul_rejected]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_emptyString_lengthZero]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_emptyString_lengthZero]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_goldenVectors_exactBytes]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_encoding_goldenVectors_exactBytes]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_labColor_tolerance_1e3_absolute]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_labColor_tolerance_1e3_absolute]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_auditOnlyFields]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_auditOnlyFields]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_excludedFields]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_excludedFields]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_includedFields]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_includedFields]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_manifestDigest]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_meshEpochSalt_closure_manifestDigest]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_goldenVectors_exactResults]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_goldenVectors_exactResults]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_nanInf_rejected]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_nanInf_rejected]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_negativeZero_normalized]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_negativeZero_normalized]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_precisionSeparation]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_precisionSeparation]' passed (0.000 seconds).
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_roundingMode_halfAwayFromZero]' started.
Test Case '-[ConstantsTests.CrossPlatformConsistencyTests test_quantization_roundingMode_halfAwayFromZero]' passed (0.000 seconds).
Test Suite 'CrossPlatformConsistencyTests' passed at 2026-01-24 15:09:04.728.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
Test Suite 'Aether3DPackageTests.xctest' passed at 2026-01-24 15:09:04.728.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
Test Suite 'Selected tests' passed at 2026-01-24 15:09:04.728.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.004 (0.006) seconds
◇ Test run started.
↳ Testing Library Version: 1501
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

---

## Known Issues

✅ No failures detected. All cross-platform consistency tests passing.

---

## Next Steps

- Continue monitoring cross-platform consistency
- Update golden vectors as needed with proper governance

---

**Report Generated:** 2026-01-24 15:09:04 UTC
