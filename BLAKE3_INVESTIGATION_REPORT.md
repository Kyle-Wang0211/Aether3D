# BLAKE3 Golden Vector Investigation Report

## Status: STEP 1 & STEP 2 Complete

### STEP 1: Preimage Instrumentation ✅

**Preimage Fixture Created:**
- File: `Tests/Fixtures/decisionhash_preimage_v1.hex`
- Preimage length: 77 bytes
- Preimage hex: `41455448455233445f4445434953494f4e5f484153485f563100010001123456789abcdef0fedcba98765432100123456789abcdef02000000000000000000000003e804000100020003000400`

**DOMAIN_TAG Verification:**
- Length: 26 bytes ✅ (matches SSOT)
- Hex: `41455448455233445f4445434953494f4e5f484153485f563100` ✅
- Ends with 0x00: ✅

**Tests Created:**
- `DecisionHashPreimageTests` - Verifies preimage construction
- All tests passing ✅

### STEP 2: Official BLAKE3 Test Vectors ✅

**Tests Created:**
- `BLAKE3KnownVectorsTests` - Validates against official test vectors
- `BLAKE3DirectAPITests` - Verifies direct API usage

**Results:**
- ✅ Empty input test: PASSES (matches official vector `af1349b9f5f9a1a6a0404dea36dcc9499bcb25c9adc112b7cc9a93cae41f3262`)
- ✅ Direct API matches Facade: PASSES
- ✅ Not using keyed mode: PASSES
- ✅ Raw bytes (not hex strings): PASSES

**BLAKE3 Library Status:**
- ✅ Library implementation is CORRECT (empty input matches official vector)
- ✅ API usage is CORRECT (direct API and facade produce same output)
- ✅ Not using keyed/derive_key mode incorrectly

### Current Mismatch

**Input:** "abc" (bytes: `0x61 0x62 0x63`)

**Our Library Output:**
```
6437b3ac38465133ffb63b75273a8db548c558465d79db03fd359c6cd5bd9d85
```

**Test Expected Output:**
```
6437b8acd6da8a3f8c14a5f5877223b8348fc64e7e1e27bd65e032899e7e1d5c
```

**Difference:**
- First 6 bytes match: `6437b3` vs `6437b8`
- Difference starts at byte 3-4: `b3ac` vs `b8ac`

### Next Steps

**STEP 3:** Verify "abc" correct value using independent reference
- Need to verify using:
  1. Online BLAKE3 calculator
  2. Official BLAKE3 reference implementation (Rust/C)
  3. Python blake3 library (if available)

**STEP 4:** Independent cross-check
- Once reference value confirmed, compare:
  - Our library output
  - Reference implementation output
  - Expected test vector

**Resolution Path:**
- If reference matches our output (`6437b3ac...`): Test expected vector is WRONG → Update SSOT + test
- If reference matches expected (`6437b8ac...`): Our library has a bug → Investigate further
- If reference differs from both: Need deeper investigation

### Evidence Collected

1. ✅ BLAKE3 library correctly implements empty input hash
2. ✅ Our API usage is correct (not keyed mode, not hex strings)
3. ✅ Direct API and Facade produce identical output
4. ✅ Preimage construction is correct (DOMAIN_TAG + canonical input)
5. ⚠️ "abc" hash mismatch needs independent verification

### Files Modified/Created

1. `Core/Infrastructure/Hashing/DecisionHash.swift` - Added debug helpers
2. `Tests/Infrastructure/DecisionHashPreimageTests.swift` - NEW
3. `Tests/Infrastructure/BLAKE3KnownVectorsTests.swift` - NEW
4. `Tests/Infrastructure/BLAKE3DirectAPITests.swift` - NEW
5. `Tests/Fixtures/decisionhash_preimage_v1.hex` - NEW
