# Phase 2 - Coverage Gaps Analysis
## Audit Trace Contract Tests

### Current Status
- Total Tests: 94
- File Size: 2687 lines
- All tests passing: ✓

### Test Structure (Current MARK Comments)

1. **Test Helpers** (12-26)
2. **Schema Validation Tests (Priority 1)** (28-167)
   - schemaVersion_not1_rejected ✓
   - policyHash_empty_rejected ✓
   - policyHash_invalidLength_rejected ✓
   - policyHash_uppercase_rejected ✓
   - pipelineVersion_empty_rejected ✓
   - pipelineVersion_containsPipe_rejected ✓
   - entryType_mismatch_rejected ✓
   - traceId_wrongLength_rejected ✓
   - sceneId_wrongLength_rejected ✓

3. **ID Generation Tests** (168-262)
   - traceId_deterministic_sameInputs ✓
   - sceneId_deterministic_samePaths ✓
   - eventId_format_correct ✓
   - eventId_leadingZero_rejected ✓
   - eventIndex_negative_rejected ✓
   - eventIndex_tooLarge_rejected ✓
   - eventIndex_zero_allowed ✓
   - eventIndex_maxValue_allowed ✓
   - sceneId_emptyInputs ✓
   - sceneId_ignoresContentHash ✓
   - sceneId_ignoresByteSize ✓
   - traceId_includesPolicyHash ✓
   - traceId_includesPipelineVersion ✓
   - traceId_includesParamsSummary ✓
   - traceId_includesContentHash ✓

4. **Sequence Validation Tests (Priority 3)** (263-326)
   - emitStep_withoutStart_fails ✓
   - emitEnd_withoutStart_fails ✓
   - duplicateTraceStart_rejected ✓
   - stepAfterEnd_rejected ✓

5. **Field Constraint Tests (Priority 4)** (327-494)
   - actionType_requiredForStep ✓
   - metrics_requiredForEnd ✓
   - paramsSummary_nonEmpty_forStep_rejected ✓
   - inputs_notEmptyForEnd_rejected ✓
   - inputs_notEmptyForFail_rejected ✓
   - actionType_forbiddenForStart ✓
   - actionType_forbiddenForEnd ✓
   - metrics_forbiddenForStart ✓
   - metrics_forbiddenForStep ✓
   - errorCode_forbiddenForEnd ✓
   - qualityScore_forbiddenForFail ✓
   - artifactRef_forbiddenForStart ✓
   - artifactRef_forbiddenForStep ✓
   - artifactRef_forbiddenForFail ✓
   - paramsSummary_nonEmpty_forEnd_rejected ✓
   - paramsSummary_nonEmpty_forFail_rejected ✓
   - metrics_successMismatch_end ✓
   - metrics_successMismatch_fail ✓

6. **v7.1.0 Critical Tests** (495-581)
   - emitEnd_validationFails_isEndedFalse ✓
   - emitEnd_writeFails_isEndedTrue ✓

7. **Valid Sequences Tests** (582-624)
   - validSequence_startEnd ✓
   - validSequence_startStepEnd ✓
   - validSequence_startFail ✓

8. **JSON Encoding Tests (CodingKeys)** (625-686)
   - jsonEncoding_pr85EventType_mapsToEventType ✓
   - jsonDecoding_roundtrip ✓

9. **Orphan Detection Tests** (687-717)
   - orphanReport_whenOrphan_returnsReport ✓
   - orphanReport_whenComplete_returnsNil ✓

10. **Additional Field Validation Tests** (718-2687)
    - traceId_wrongLength_rejected ✓
    - sceneId_wrongLength_rejected ✓
    - policyHash_uppercase_rejected ✓
    - inputPath_forbiddenChars_rejected ✓
    - inputPath_tooLong_rejected ✓
    - inputContentHash_invalidLength_rejected ✓
    - inputContentHash_uppercase_rejected ✓
    - inputByteSize_negative_rejected ✓
    - duplicateInputPath_rejected ✓
    - paramsSummary_keyEmpty_rejected ✓
    - paramsSummary_keyContainsPipe_rejected ✓
    - paramsSummary_valueContainsPipe_rejected ✓
    - metrics_elapsedMs_negative_rejected ✓
    - metrics_elapsedMs_tooLarge_rejected ✓
    - metrics_qualityScore_outOfRange_rejected ✓
    - metrics_qualityScore_NaN_rejected ✓
    - metrics_errorCode_tooLong_rejected ✓
    - artifactRef_emptyString_rejected ✓
    - artifactRef_tooLong_rejected ✓
    - canonicalJSON_emptyDict ✓
    - canonicalJSON_singleEntry ✓
    - canonicalJSON_keyOrdering ✓
    - canonicalJSON_escapeQuotes ✓
    - canonicalJSON_escapeBackslash ✓
    - canonicalJSON_escapeNewline ✓
    - canonicalJSON_doesNotEscapeSlash ✓
    - traceIdMismatch_rejected ✓
    - sceneIdMismatch_rejected ✓
    - policyHashMismatch_rejected ✓
    - eventIndexMismatch_rejected ✓
    - validator_commit_updatesState ✓
    - validator_rollback_revertsState ✓
    - validator_twoPhase_commitThenRollback ✓
    - emitter_emitStart_returnsTraceId ✓
    - emitter_emitStep_incrementsEventIndex ✓
    - emitter_emitEnd_withQualityScore ✓
    - emitter_emitEnd_withArtifactRef ✓
    - emitter_emitFail_requiresErrorCode ✓
    - emitter_isTraceOrphan_afterStart ✓
    - emitter_isTraceComplete_afterEnd ✓
    - dateEncoding_utcNoFractional ✓
    - buildMeta_required ✓

### Identified Coverage Gaps

#### Priority 1: Schema Validation
- ✓ schemaVersion != 1
- ✓ policyHash empty, invalid length, uppercase, contains pipe
- ✓ pipelineVersion empty, contains pipe, control chars
- ✓ traceId empty, wrong length, not lowercase hex
- ✓ sceneId empty, wrong length, not lowercase hex
- ✓ eventId format (prefix, index parsing, leading zeros, + prefix, negative, > 1M)
- ✓ entryType mismatch
- ⚠️ **MISSING**: pipelineVersion control character tests (0x00-0x1F, 0x7F) - partially covered
- ⚠️ **MISSING**: traceId/sceneId/policyHash contains pipe test
- ⚠️ **MISSING**: eventId index out of range (> 1_000_000) explicit test
- ⚠️ **MISSING**: eventId has + prefix test

#### Priority 2: Deep Field Validation
- ✓ inputPath empty, too long, forbidden chars
- ✓ inputContentHash invalid length, uppercase
- ✓ inputByteSize negative
- ✓ duplicateInputPath
- ✓ metrics elapsedMs negative, too large
- ✓ metrics qualityScore out of range, NaN
- ✓ metrics errorCode empty, too long
- ✓ artifactRef empty, whitespace only, too long, control chars (except tab)
- ✓ paramsSummary key empty, key/value contains pipe
- ⚠️ **MISSING**: inputPath empty at specific index
- ⚠️ **MISSING**: inputContentHash invalid length at specific index
- ⚠️ **MISSING**: artifactRef control character tests (explicit for each char)
- ⚠️ **MISSING**: artifactRef tab allowed test

#### Priority 3: Sequence Validation
- ✓ emitStep without start
- ✓ emitEnd without start
- ✓ duplicateTraceStart
- ✓ stepAfterEnd
- ⚠️ **MISSING**: emitEnd after fail
- ⚠️ **MISSING**: emitFail after end
- ⚠️ **MISSING**: emitFail after fail
- ⚠️ **MISSING**: emitStep after end
- ⚠️ **MISSING**: emitStep after fail

#### Priority 4: Field Constraints
- ✓ All major constraints covered
- ⚠️ **MISSING**: explicit tests for each event type constraint combination

#### Priority 5: Cross-Event Consistency
- ✓ traceIdMismatch
- ✓ sceneIdMismatch
- ✓ policyHashMismatch
- ✓ eventIndexMismatch

#### ID Generation Determinism
- ✓ traceId deterministic same inputs
- ✓ sceneId deterministic same paths
- ⚠️ **MISSING**: traceId order sensitivity (input order changes)
- ⚠️ **MISSING**: sceneId order sensitivity (path order changes)
- ⚠️ **MISSING**: traceId paramsSummary key order sensitivity
- ⚠️ **MISSING**: traceId with different contentHash but same path
- ⚠️ **MISSING**: traceId with different byteSize but same path

#### Canonical JSON
- ✓ Empty dict, single entry, key ordering
- ✓ Escape quotes, backslash, newline
- ✓ Does not escape slash
- ⚠️ **MISSING**: Control character escaping (\u00XX uppercase hex)
- ⚠️ **MISSING**: Multiple entries ordering
- ⚠️ **MISSING**: UTF-8 byte lexicographic ordering edge cases

#### Emitter Behavior
- ✓ emitStart returns traceId
- ✓ emitStep increments eventIndex
- ✓ emitEnd with qualityScore/artifactRef
- ✓ emitFail requires errorCode
- ✓ isTraceOrphan/isTraceComplete
- ⚠️ **MISSING**: emitEnd without qualityScore
- ⚠️ **MISSING**: emitFail without errorCode (should fail)
- ⚠️ **MISSING**: emitStart/Step/End/Fail write failure handling

### Recommended New Tests (Gap Filling)

1. **Illegal Sequences** (5 tests):
   - end_afterFail_rejected
   - fail_afterEnd_rejected
   - fail_afterFail_rejected
   - step_afterEnd_rejected
   - step_afterFail_rejected

2. **Determinism & Ordering** (4 tests):
   - traceId_inputOrderSensitivity
   - sceneId_pathOrderSensitivity
   - traceId_paramsSummaryKeyOrderSensitivity
   - traceId_differentContentHash_samePath

3. **Schema Edge Cases** (3 tests):
   - eventId_indexPlusPrefix_rejected
   - eventId_indexOutOfRange_rejected
   - pipelineVersion_controlChar0x00_rejected

4. **Canonical JSON Edge Cases** (2 tests):
   - canonicalJSON_controlCharEscaping
   - canonicalJSON_multipleEntriesOrdering

### Final Count Estimate
- Current: 94 tests
- Proposed additions: ~14 tests
- Final: ~108 tests

