# PR1 PIZ Sealing Evidence

**Generated:** 2026-02-05T21:27:06Z

## Spec Document

- **Path:** PR1_F_CLASS_PIZ_INDUSTRIAL_SEALING_UPGRADE_PLAN.md
- **Git Blob Hash:** a7126ae9b3c4c7afa078dabb7c34ed86dfbe015b
- **Commit Hash:** 4827a72b0d379e4f02bea2c7745126f547f194b3

## Schema Version

- **Implemented:** 1.0.0
- **Major:** 1
- **Minor:** 0
- **Patch:** 0

## Output Profile Evidence

- **DecisionOnly Strict Rejection:** ✅
- **FullExplainability Required Fields:** ✅
- **Proof:** Tests/PIZ/PIZReportSchemaTests.swift validates DecisionOnly rejects explainability fields

## SSOT Constants Snapshot

| Constant | Value |
|----------|-------|
| GRID_SIZE | 32 |
| TOTAL_GRID_CELLS | 1024 |
| COVERED_CELL_MIN | 0.5 |
| GLOBAL_COVERAGE_MIN | 0.75 |
| LOCAL_COVERAGE_MIN | 0.5 |
| LOCAL_AREA_RATIO_MIN | 0.05 |
| MIN_REGION_PIXELS | 8 |
| SEVERITY_HIGH_THRESHOLD | 0.7 |
| SEVERITY_MEDIUM_THRESHOLD | 0.3 |
| HYSTERESIS_BAND | 0.05 |
| COVERAGE_RELATIVE_TOLERANCE | 0.0001 |
| LAB_COLOR_ABSOLUTE_TOLERANCE | 0.001 |
| JSON_CANON_QUANTIZATION_PRECISION | 1e-06 |
| JSON_CANON_DECIMAL_PLACES | 6 |
| MAX_REPORTED_REGIONS | 128 |
| MAX_COMPONENT_QUEUE_SIZE | 1024 |
| MAX_LABELING_ITERATIONS | 1024 |

## Lint Checks

| Check | Status | Description |
|-------|--------|-------------|
| inline_thresholds | ✅ PASS | Check for inline threshold numbers (must use PIZThresholds) |
| forbidden_imports | ✅ PASS | Check for forbidden numeric acceleration imports |
| inline_epsilon | ✅ PASS | Check for inline epsilon/tolerance values |

## Cross-Platform Canonical Evidence

- **macOS SHA256:** 182cf89232edfddeb5d4df075c09f2939de0494513e0d88681c5c6362d88c657
- **Linux SHA256:** 182cf89232edfddeb5d4df075c09f2939de0494513e0d88681c5c6362d88c657
- **Byte Identical:** ✅ YES

## Fixtures

| Fixture | Rule IDs | Expected Gate | Canonical SHA256 |
|---------|----------|---------------|------------------|
| nominal_001_global_trigger | PIZ_GLOBAL_001, PIZ_COVERED_CELL_001, PIZ_GLOBAL_REGION_001, PIZ_INPUT_VALIDATION_002 | RECAPTURE | fbee6cc39fce3283... |
| nominal_002_local_trigger | PIZ_LOCAL_001, PIZ_COVERED_CELL_001, PIZ_COMPONENT_MEMBERSHIP_001, PIZ_CONNECTIVITY_DETERMINISM_001, PIZ_NOISE_001, PIZ_REGION_ORDER_002 | RECAPTURE | 658c15aa0b1cddba... |
| nominal_003_invalid_input | PIZ_INPUT_VALIDATION_001, PIZ_INPUT_VALIDATION_002, PIZ_FLOAT_CLASSIFICATION_001 | INSUFFICIENT_DATA | 9cb3f05f2bd99b0b... |

## Coverage Matrix

| Rule ID | Covered | Fixtures |
|---------|---------|----------|
| PIZ_CI_FAILURE_TAXONOMY_001 | ❌ | N/A |
| PIZ_COMBINE_001 | ❌ | N/A |
| PIZ_COMPONENT_MEMBERSHIP_001 | ✅ | nominal_002_local_trigger |
| PIZ_CONNECTIVITY_001 | ❌ | N/A |
| PIZ_CONNECTIVITY_DETERMINISM_001 | ✅ | nominal_002_local_trigger |
| PIZ_COVERED_CELL_001 | ✅ | nominal_001_global_trigger, nominal_002_local_trigger |
| PIZ_DECISION_EXPLAINABILITY_SEPARATION_001 | ❌ | N/A |
| PIZ_DECISION_INDEPENDENCE_001 | ❌ | N/A |
| PIZ_DIRECTION_TIEBREAK_001 | ❌ | N/A |
| PIZ_FLOAT_CANON_001 | ❌ | N/A |
| PIZ_FLOAT_CLASSIFICATION_001 | ✅ | nominal_003_invalid_input |
| PIZ_FLOAT_COMPARISON_001 | ❌ | N/A |
| PIZ_GEOMETRY_DETERMINISM_001 | ❌ | N/A |
| PIZ_GLOBAL_001 | ✅ | nominal_001_global_trigger |
| PIZ_GLOBAL_REGION_001 | ✅ | nominal_001_global_trigger |
| PIZ_HYSTERESIS_001 | ❌ | N/A |
| PIZ_INPUT_BUDGET_001 | ❌ | N/A |
| PIZ_INPUT_VALIDATION_001 | ✅ | nominal_003_invalid_input |
| PIZ_INPUT_VALIDATION_002 | ✅ | nominal_001_global_trigger, nominal_003_invalid_input |
| PIZ_JSON_CANON_001 | ❌ | N/A |
| PIZ_LOCAL_001 | ✅ | nominal_002_local_trigger |
| PIZ_MAX_REGIONS_DERIVED_001 | ❌ | N/A |
| PIZ_NOISE_001 | ✅ | nominal_002_local_trigger |
| PIZ_NUMERIC_ACCELERATION_BAN_001 | ❌ | N/A |
| PIZ_NUMERIC_FORMAT_001 | ❌ | N/A |
| PIZ_OUTPUT_PROFILE_001 | ❌ | N/A |
| PIZ_REGION_ID_001 | ❌ | N/A |
| PIZ_REGION_ID_SPEC_001 | ❌ | N/A |
| PIZ_REGION_ORDER_002 | ✅ | nominal_002_local_trigger |
| PIZ_SCHEMA_COMPAT_001 | ❌ | N/A |
| PIZ_SCHEMA_PROFILE_001 | ❌ | N/A |
| PIZ_SEMANTIC_PARITY_001 | ❌ | N/A |
| PIZ_STATEFUL_GATE_001 | ❌ | N/A |
| PIZ_TOLERANCE_SSOT_001 | ❌ | N/A |
| PIZ_TRAVERSAL_ORDER_001 | ❌ | N/A |

## DoD Checklist

- **Thresholds in SSOT:** ✅
- **Profile Gating Strict Decode:** ✅
- **Determinism:** ✅
- **No Forbidden Imports:** ✅
- **Fixture Schema Closed-Set:** ✅
- **All Passed:** ✅ YES

