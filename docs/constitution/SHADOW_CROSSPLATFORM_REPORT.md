# Shadow Cross-Platform Consistency Report

**Date:** 2026-01-23 13:21:32 UTC
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
Updating https://github.com/apple/swift-crypto.git
Updating https://github.com/apple/swift-asn1.git
Updated https://github.com/apple/swift-crypto.git (0.15s)
Updated https://github.com/apple/swift-asn1.git (0.15s)
Computing version for https://github.com/apple/swift-crypto.git
Computed https://github.com/apple/swift-crypto.git at 3.15.1 (0.20s)
Computing version for https://github.com/apple/swift-asn1.git
Computed https://github.com/apple/swift-asn1.git at 1.5.1 (0.03s)
Creating working copy for https://github.com/apple/swift-asn1.git
Working copy of https://github.com/apple/swift-asn1.git resolved at 1.5.1
Creating working copy for https://github.com/apple/swift-crypto.git
Working copy of https://github.com/apple/swift-crypto.git resolved at 3.15.1
[0/1] Planning build
Building for debugging...
[0/2] Write swift-version--58304C5D6DBC2206.txt
[1/4] Write sources
[2/4] Copying PrivacyInfo.xcprivacy
[4/79] Compiling Crypto EdDSA_boring.swift
[5/79] Compiling Crypto ECDSA.swift
[6/79] Compiling Crypto Ed25519.swift
[7/79] Compiling Crypto Signature.swift
[8/79] Compiling Crypto CryptoKitErrors_boring.swift
[9/79] Compiling Crypto RNG_boring.swift
[10/79] Compiling Crypto X25519Keys_boring.swift
[11/79] Compiling Crypto Curve25519.swift
[12/79] Compiling Crypto Ed25519Keys.swift
[13/79] Compiling Crypto NISTCurvesKeys.swift
[14/79] Compiling Crypto X25519Keys.swift
[15/79] Compiling Crypto SymmetricKeys.swift
[16/85] Compiling Crypto ASN1Any.swift
[17/85] Compiling Crypto ASN1BitString.swift
[18/85] Compiling Crypto ASN1Boolean.swift
[19/85] Compiling Crypto ASN1Identifier.swift
[20/85] Compiling Crypto ASN1Integer.swift
[21/85] Compiling Crypto ASN1Null.swift
[22/85] Compiling Crypto ASN1OctetString.swift
[23/85] Compiling Crypto ASN1Strings.swift
[24/85] Compiling Crypto ArraySliceBigint.swift
[25/85] Compiling Crypto GeneralizedTime.swift
[26/85] Compiling Crypto ObjectIdentifier.swift
[27/85] Compiling Crypto ECDSASignature.swift
[28/85] Compiling Crypto PEMDocument.swift
[29/85] Compiling Crypto PKCS8PrivateKey.swift
[30/85] Compiling Crypto HPKE-Context.swift
[31/85] Compiling Crypto HPKE-KeySchedule.swift
[32/85] Compiling Crypto HPKE-Modes.swift
[33/85] Compiling Crypto Insecure.swift
[34/85] Compiling Crypto Insecure_HashFunctions.swift
[35/85] Compiling Crypto KEM.swift
[36/85] Compiling Crypto ECDH_boring.swift
[37/85] Compiling Crypto SEC1PrivateKey.swift
[38/85] Compiling Crypto SubjectPublicKeyInfo.swift
[39/85] Compiling Crypto CryptoError_boring.swift
[40/85] Compiling Crypto CryptoKitErrors.swift
[41/85] Compiling Crypto Digest_boring.swift
[42/85] Compiling Crypto Digest.swift
[43/85] Compiling Crypto Digests.swift
[44/85] Compiling Crypto HMAC.swift
[45/85] Compiling Crypto MACFunctions.swift
[46/85] Compiling Crypto MessageAuthenticationCode.swift
[47/85] Compiling Crypto AES.swift
[48/85] Compiling Crypto ECDSASignature_boring.swift
[49/85] Compiling Crypto ECDSA_boring.swift
[50/85] Compiling Crypto HPKE-Utils.swift
[51/85] Compiling Crypto DHKEM.swift
[52/85] Compiling Crypto HPKE-KEM-Curve25519.swift
[53/85] Compiling Crypto HPKE-NIST-EC-KEMs.swift
[54/85] Compiling Crypto HPKE-KEM.swift
[55/85] Compiling Crypto HPKE-Errors.swift
[56/85] Compiling Crypto HPKE.swift
[57/85] Compiling Crypto HashFunctions.swift
[58/85] Compiling Crypto HashFunctions_SHA2.swift
[59/85] Compiling Crypto HPKE-AEAD.swift
[60/85] Compiling Crypto HPKE-Ciphersuite.swift
[61/85] Compiling Crypto HPKE-KDF.swift
[62/85] Compiling Crypto HPKE-KexKeyDerivation.swift
[63/85] Compiling Crypto HPKE-LabeledExtract.swift
[64/85] Compiling Crypto AES-GCM.swift
[65/85] Compiling Crypto AES-GCM_boring.swift
[66/85] Compiling Crypto ChaChaPoly_boring.swift
[67/85] Compiling Crypto ChaChaPoly.swift
[68/85] Compiling Crypto Cipher.swift
[69/85] Compiling Crypto Nonces.swift
[70/85] Compiling Crypto ASN1.swift
[71/85] Compiling Crypto DH.swift
[72/85] Compiling Crypto ECDH.swift
[73/85] Compiling Crypto HKDF.swift
[74/85] Compiling Crypto AESWrap.swift
[75/85] Compiling Crypto AESWrap_boring.swift
[76/85] Compiling Crypto Ed25519_boring.swift
[77/85] Compiling Crypto NISTCurvesKeys_boring.swift
[78/85] Emitting module Crypto
[79/85] Compiling Crypto SafeCompare_boring.swift
[80/85] Compiling Crypto Zeroization_boring.swift
[81/85] Compiling Crypto PrettyBytes.swift
[82/85] Compiling Crypto SafeCompare.swift
[83/85] Compiling Crypto SecureBytes.swift
[84/85] Compiling Crypto Zeroization.swift
Build complete! (2.87s)
Test Suite 'Selected tests' started at 2026-01-23 13:21:32.124.
Test Suite 'Aether3DPackageTests.xctest' started at 2026-01-23 13:21:32.125.
Test Suite 'CrossPlatformConsistencyTests' started at 2026-01-23 13:21:32.125.
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
Test Suite 'CrossPlatformConsistencyTests' passed at 2026-01-23 13:21:32.130.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
Test Suite 'Aether3DPackageTests.xctest' passed at 2026-01-23 13:21:32.130.
	 Executed 18 tests, with 0 failures (0 unexpected) in 0.004 (0.005) seconds
Test Suite 'Selected tests' passed at 2026-01-23 13:21:32.130.
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

**Report Generated:** 2026-01-23 13:21:32 UTC
