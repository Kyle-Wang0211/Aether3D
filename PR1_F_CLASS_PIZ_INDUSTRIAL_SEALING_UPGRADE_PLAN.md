# PR1 – F-Class (PIZ) Industrial Sealing Upgrade Plan

**Document Version:** 1.0  
**Status:** DESIGN SPECIFICATION  
**Created Date:** 2026-01-27  
**Scope:** PIZ Detection Industrial Sealing

---

## 1. Objective

PR1 establishes the industrial-grade foundation for F-class problems, specifically PIZ (Partial Information Zone) detection. The goal is to upgrade PIZ from a "works in practice" implementation to a fully sealed, contract-driven, machine-verifiable system that future F-class logic can safely build upon without technical debt.

**Long-term technical debt prevention:**
- Future F-class detection systems must inherit PIZ's contract discipline
- No hidden coupling between detection logic and state machine actions
- No threshold drift or configuration sprawl
- No platform-specific divergence
- No non-deterministic decision paths

**Success criterion:**
PIZ detection is considered "sealed" when every rule is spec-defined, fixture-mapped, test-enforced, and CI-blocking.

---

## 2. Core Principles

### 2.1 Closed-Set Validation

All enums, schemas, and configuration values must be closed sets. Unknown fields or values are rejected at decode time. No open-world assumptions.

**Enforcement requirement:**
- Schema decoding must explicitly enumerate all allowed fields
- Enum decoding must reject unknown raw values
- CI must verify closed-set behavior

### 2.2 Versioned Schemas

All output schemas must carry explicit version numbers. Version changes follow semantic versioning:
- Major: Breaking changes (incompatible)
- Minor: Additive changes (backward compatible)
- Patch: Bug fixes (backward compatible)

**Enforcement requirement:**
- Schema version must be present in all outputs
- Old versions must remain parseable
- Migration paths must be documented

### 2.3 SSOT Thresholds

All thresholds must be defined in a single source of truth file. No inline threshold values are permitted.

**Enforcement requirement:**
- CI grep/lint must detect bare threshold numbers
- All threshold references must use named constants from SSOT
- Threshold changes require explicit review

### 2.4 Fixtures as Constitutional Contracts

Test fixtures are treated as immutable contracts. Each fixture maps to one or more rule IDs. Fixture failures indicate contract violations.

**Enforcement requirement:**
- Fixtures must be versioned
- Fixture changes require explicit justification
- Fixture coverage must be complete for all rule IDs

### 2.5 Explicit Interfaces

No hidden coupling between layers. Detection logic must not directly access state machine internals. Policy mapping must be explicit and testable.

**Enforcement requirement:**
- Import analysis must verify layer boundaries
- Tests must verify decoupling
- No dynamic dispatch for policy decisions

### 2.6 Determinism and Reproducibility

Same input must produce same output, always. No random number generation, timestamps, or non-deterministic algorithms in decision paths.

**Enforcement requirement:**
- Tests must verify deterministic outputs
- Floating-point comparisons must use explicit tolerances
- Region IDs must be deterministic (e.g., based on bbox hash)

### 2.7 Machine-Verifiable Acceptance

All acceptance criteria must be objectively testable. No subjective "works correctly" judgments.

**Enforcement requirement:**
- Every rule must have corresponding fixtures
- Every fixture must have expected outputs
- CI must run all fixtures and fail on mismatch

---

## 3. Definition of "Works" (Machine-Verifiable)

"Works" means all rules are spec-defined, fixture-mapped, and test-enforced.

**Rule ID System:**
- Each rule must have a unique identifier (e.g., `PIZ_GLOBAL_001`)
- Rule IDs are immutable once assigned
- Rule IDs map to fixture categories

**Acceptance Matrix:**
- Each rule ID must have at least one fixture
- Each fixture must specify expected outputs
- Test execution must verify fixture outputs match expected values
- CI must block on any fixture failure

**Specification Coverage:**
- All threshold comparisons must be documented
- All combination logic must be explicit
- All edge cases must be enumerated
- All platform-specific behavior must be documented

**Test Coverage Requirements:**
- Nominal cases: Expected behavior under normal conditions
- Boundary cases: Behavior at threshold boundaries
- Failure cases: Error handling and edge conditions
- Cross-platform cases: Platform parity verification

---

## 4. PIZ Detection Specification (Conceptual)

### 4.1 Global Trigger

**Rule ID:** `PIZ_GLOBAL_001`

Global trigger fires when:
```
coverage_total < GLOBAL_COVERAGE_MIN
```

**Semantics:**
- `coverage_total` is the ratio of covered cells to total cells in the 32x32 heatmap grid
- Covered cells are those with value >= COVERED_CELL_MIN (SSOT constant, see section 4.1.1)
- When triggered, PIZ severity is at least MEDIUM
- Global trigger is independent of local region detection

### 4.1.1 Covered-Cell Definition (SSOT)

**Rule ID:** `PIZ_COVERED_CELL_001`

**Requirement:**
The predicate for determining whether a cell is "covered" must be defined as an SSOT constant. The operator is frozen and cannot be changed.

**SSOT Constant:**
- `COVERED_CELL_MIN = 0.5` (defined in `Core/Constants/PIZThresholds.swift`)

**Frozen Predicate:**
- Covered cell predicate: `value >= COVERED_CELL_MIN`
- Operator is frozen: `>=` (greater than or equal)
- No alternative operators permitted (e.g., `>` is forbidden)

**Boundary Behavior:**
- Value exactly equal to COVERED_CELL_MIN is considered covered
- Value less than COVERED_CELL_MIN is considered uncovered

**Enforcement requirement:**
- COVERED_CELL_MIN must be defined in SSOT
- Covered-cell predicate must reference COVERED_CELL_MIN constant
- Operator must be explicitly documented
- CI must detect any deviation from frozen predicate

**Required Boundary Fixtures:**
- Fixtures must exist for values: 0.4999 (uncovered), 0.5 (covered), 0.5001 (covered)
- Each boundary value must be tested
- Boundary fixtures must verify predicate behavior

**Threshold:**
- `GLOBAL_COVERAGE_MIN = 0.75` (SSOT)

**Behavior:**
- If global trigger fires, at least one region with severity >= MEDIUM must be reported
- Global trigger always results in RECAPTURE recommendation

### 4.1.2 Global Trigger Synthetic Region Requirement

**Rule ID:** `PIZ_GLOBAL_REGION_001`

**Requirement:**
When global trigger fires but no local regions exist, a synthetic region must be generated to satisfy the "at least one region" requirement.

**Synthetic Region Generation:**
- Trigger condition: `globalTrigger=true AND local regions list is empty`
- Generate synthetic region with the following properties:

**Synthetic Region Properties:**
- `bbox`: Full grid bounds [0..GRID_SIZE-1] for rows and cols (inclusive)
  - minRow = 0, maxRow = GRID_SIZE - 1
  - minCol = 0, maxCol = GRID_SIZE - 1
- `pixelCount`: TOTAL_GRID_CELLS (1024 for GRID_SIZE=32)
- `areaRatio`: 1.0 (full grid coverage)
- `centroid`: Explicitly defined as (15.5, 15.5) for GRID_SIZE=32
  - Formula: `centroid.row = (GRID_SIZE - 1) / 2.0`
  - Formula: `centroid.col = (GRID_SIZE - 1) / 2.0`
  - For GRID_SIZE=32: centroid = (15.5, 15.5)
- `severityScore`: Derived from coverage_total
  - Formula: `severityScore = clamp01(1.0 - coverage_total)`
  - clamp01 ensures value is in [0.0, 1.0]
- `principalDirection`: Computed per existing principal direction rule (section 5.3.1)
  - Use bbox corners: (0,0), (0,31), (31,0), (31,31)
  - Find farthest corner from centroid (15.5, 15.5)
  - Apply tie-breaking rules per section 5.3.2
- `id`: Computed using same deterministic ID algorithm (section 5.4)
  - Input: bbox (0, 31, 0, 31) + pixelCount (1024)
  - SHA-256 hash of canonical descriptor
  - Format: `"piz_region_"` + hex string

**Semantic Requirements:**
- Synthetic region must satisfy "severity at least MEDIUM minimum" semantics
- severityScore must be >= SEVERITY_MEDIUM_THRESHOLD (0.3) when global trigger fires
- Synthetic region must not change decision logic beyond the already-triggered global rule
- Synthetic region is included in regions list for explainability

**Enforcement requirement:**
- Synthetic region generation must be deterministic
- Synthetic region must be generated when globalTrigger=true and regions.isEmpty
- Tests must verify synthetic region properties
- Cross-platform tests must verify identical synthetic regions

**Required Fixtures:**
- Fixtures where globalTrigger fires but no local components exist
- Fixtures must validate synthetic region is present
- Fixtures must validate synthetic region is deterministic
- Fixtures must validate synthetic region properties match specification

### 4.2 Local Trigger

**Rule ID:** `PIZ_LOCAL_001`

A local region is identified as PIZ when ALL of the following conditions are met:

1. **Coverage condition:**
   ```
   coverage_local < LOCAL_COVERAGE_MIN
   ```
   - `coverage_local` is the ratio of covered cells within the region to total cells in the region

2. **Area ratio condition:**
   ```
   region_area_ratio >= LOCAL_AREA_RATIO_MIN
   ```
   - `region_area_ratio` is the ratio of region pixels to total grid pixels (32x32 = 1024)

3. **Noise suppression:**
   ```
   region_pixel_count >= MIN_REGION_PIXELS
   ```
   - Prevents noise speckles from triggering false positives

**Thresholds:**
- `LOCAL_COVERAGE_MIN = 0.5` (SSOT)
- `LOCAL_AREA_RATIO_MIN = 0.05` (SSOT, 5% of grid)
- `MIN_REGION_PIXELS = 8` (SSOT, grid-based, resolution independent)

**Semantics:**
- All three conditions must be true for a region to be classified as PIZ
- Regions failing any condition are filtered out

### 4.3 Connectivity Model

**Rule ID:** `PIZ_CONNECTIVITY_001`

**Chosen connectivity:** 4-neighborhood (frozen, must be used everywhere)

**Definition:**
- Two cells are connected if they share an edge (not just a corner)
- A continuous region is a maximal set of connected cells
- Connectivity is computed on the 32x32 heatmap grid

**Algorithm requirement:**
- Use connected components labeling (4-neighborhood)
- Each component is a candidate region
- Regions are filtered by MIN_REGION_PIXELS before classification

**Rationale:**
- 4-neighborhood is more conservative (fewer false positives)
- Deterministic and unambiguous
- Must be stated explicitly and used consistently

**Enforcement requirement:**
- Connectivity mode must be frozen in schema
- No runtime switching allowed
- Tests must verify 4-neighborhood behavior

### 4.3.2 Connected-Component Membership Predicate

**Rule ID:** `PIZ_COMPONENT_MEMBERSHIP_001`

**Requirement:**
The predicate for determining component membership (which cells belong to a region) must be frozen and explicitly defined in terms of SSOT constants.

**Frozen Membership Predicate:**
- A cell belongs to an uncovered region component if: `heatmap[row][col] < COVERED_CELL_MIN`
- Component membership is determined solely by comparison with COVERED_CELL_MIN
- No alternative membership predicates are permitted

**Explicit Definition:**
- Component membership predicate: `value < COVERED_CELL_MIN`
- Operator is frozen: `<` (strict less than)
- Threshold is frozen: `COVERED_CELL_MIN` (SSOT constant)

**Prohibited:**
- Quietly changing what counts as a region cell
- Alternative membership criteria
- Dynamic membership thresholds
- Platform-specific membership rules

**Enforcement requirement:**
- Membership predicate must be explicitly documented
- Predicate must reference COVERED_CELL_MIN constant
- CI must detect any deviation from frozen predicate
- Tests must verify membership predicate behavior

### 4.3.1 Connectivity Algorithm Determinism

**Rule ID:** `PIZ_CONNECTIVITY_DETERMINISM_001`

**Traversal Order Requirement:**
- Traversal must be row-major (top-to-bottom, left-to-right)
- Starting cell selection must follow deterministic order
- No DFS/BFS implementations with order-dependent behavior allowed
- No parallel or non-deterministic traversal allowed

**Deterministic Traversal Specification:**
- Scan grid in row-major order: row 0 to 31, column 0 to 31
- When encountering unvisited uncovered cell, start component labeling
- Component labeling must follow deterministic neighbor order: (row-1, col), (row+1, col), (row, col-1), (row, col+1)
- Neighbor processing order must be fixed and documented

**Prohibited Patterns:**
- Random seed initialization
- Hash-based traversal ordering
- Parallel component labeling
- Non-deterministic neighbor selection
- Order-dependent algorithms (e.g., DFS with stack order dependency)

**Internal Ordering (Discovery Order):**
- Internal labeling uses deterministic discovery order for determinism guarantees
- Component discovery follows row-major scan order
- Internal ordering is used for component labeling and processing
- Internal ordering is NOT used for final serialized output

**Enforcement requirement:**
- Traversal order must be explicitly documented
- Internal discovery order must be deterministic
- Cross-platform tests must verify identical internal ordering
- Any order-dependent behavior must be eliminated

### 4.4 Noise Suppression via Minimum Region Size

**Rule ID:** `PIZ_NOISE_001`

**Threshold:** `MIN_REGION_PIXELS = 8`

**Semantics:**
- Grid-based, resolution independent
- Regions with pixel count < MIN_REGION_PIXELS are filtered out
- Prevents noise speckles from triggering PIZ detection

**Enforcement requirement:**
- Applied after connected components labeling
- Applied before local trigger evaluation
- Tests must verify filtering behavior

### 4.5 Severity Scoring and Combination Logic

**Rule ID:** `PIZ_COMBINE_001`

**Severity Calculation:**
```
severityScore = 1.0 - coverage_local
```
- Higher gap = higher severity
- Range: [0.0, 1.0]

**Gate Recommendation Logic:**
```
IF globalTrigger:
    gateRecommendation = RECAPTURE
    severity = MEDIUM (minimum)
ELSE IF localTriggerCount > 0:
    maxSeverity = max(region.severityScore for region in regions)
    IF maxSeverity >= SEVERITY_HIGH_THRESHOLD:
        gateRecommendation = RECAPTURE
    ELSE IF maxSeverity >= SEVERITY_MEDIUM_THRESHOLD:
        gateRecommendation = BLOCK_PUBLISH
    ELSE:
        gateRecommendation = ALLOW_PUBLISH
ELSE:
    gateRecommendation = ALLOW_PUBLISH
```

**Thresholds:**
- `SEVERITY_HIGH_THRESHOLD = 0.7` (SSOT)
- `SEVERITY_MEDIUM_THRESHOLD = 0.3` (SSOT)

**Enforcement requirement:**
- Logic must be deterministic and testable
- All branches must be covered by fixtures
- No dynamic heuristics allowed

### 4.6 Hysteresis / Decision Stability

**Rule ID:** `PIZ_HYSTERESIS_001`

**Concept:**
When PIZ score oscillates around thresholds, use hysteresis band to prevent flip-flopping.

**Hysteresis Band:**
- `HYSTERESIS_BAND = 0.05` (SSOT)

**Behavior:**
- Once recommendation is set, it requires crossing threshold + hysteresis to change
- Prevents rapid oscillation between states
- Applied only when previous recommendation exists

**Enforcement requirement:**
- Hysteresis logic must be explicit and testable
- Fixtures must cover oscillation scenarios
- Tests must verify stability

### 4.6.1 Hysteresis State Input Requirement

**Rule ID:** `PIZ_STATEFUL_GATE_001`

**Requirement:**
Hysteresis requires an explicit previous-state input. The state input must be explicit and cannot be inferred or defaulted silently.

**Explicit State Input:**
- Hysteresis function must accept explicit parameter: `prevGateRecommendation: GateRecommendation?`
- Previous state must be explicitly provided by caller
- No implicit state storage or inference allowed

**Initialization Behavior:**
- When `prevGateRecommendation` is `nil` (absent):
  - Hysteresis is not applied
  - Gate recommendation is computed using standard combination logic (section 4.5)
  - No hysteresis band is used for first decision

**State Transition:**
- When `prevGateRecommendation` is present:
  - Hysteresis logic is applied
  - Threshold crossings require crossing threshold + HYSTERESIS_BAND
  - State transitions follow explicit hysteresis rules

**Enforcement requirement:**
- Hysteresis function signature must explicitly require previous state parameter
- Initialization behavior must be documented
- Tests must verify nil state initialization
- Tests must verify stateful transitions

**Required Sequence Fixtures:**
- Fixtures must exist for oscillation scenarios:
  - Sequence: ALLOW_PUBLISH → BLOCK_PUBLISH → ALLOW_PUBLISH
  - Sequence: BLOCK_PUBLISH → RECAPTURE → BLOCK_PUBLISH
  - Sequence: RECAPTURE → BLOCK_PUBLISH → RECAPTURE
- Each sequence must verify hysteresis prevents flip-flopping
- Fixtures must test threshold boundary + hysteresis band behavior

### 4.7 Input Validation Sealing

**Rule ID:** `PIZ_INPUT_VALIDATION_001`

**Invalid Input Rejection:**
All heatmap inputs must be validated before processing. Invalid inputs result in `INSUFFICIENT_DATA` gate recommendation.

**Required Validations:**
1. **Shape validation:**
   - Heatmap must be exactly 32×32 cells
   - Non-32×32 shapes are rejected
   - Rejection must occur before any detection logic

2. **Floating-point validation:**
   - NaN values are forbidden
   - ±Inf values are forbidden
   - Subnormal floats are forbidden
   - Zero (0.0) is allowed
   - All values must be finite and normal (or zero)

3. **Range validation:**
   - All values must be in closed interval [0.0, 1.0]
   - Values outside [0.0, 1.0] are rejected

**Behavior on Invalid Input:**
- Detection must return `gateRecommendation = INSUFFICIENT_DATA`
- No regions may be reported
- No triggers may fire
- Error condition must be logged but not affect decision path determinism

**Enforcement requirement:**
- Input validation must occur before any detection logic
- CI fixtures must cover all invalid input categories
- Invalid input rejection must be deterministic
- Tests must verify INSUFFICIENT_DATA output for invalid inputs

**Fixture Coverage requirement:**
- Fixtures must exist for: non-32×32 shapes, NaN values, ±Inf values, subnormal floats, values < 0.0, values > 1.0
- Each invalid input category must have at least one fixture
- Fixture failures for invalid inputs must block CI

### 4.7.1 Subnormal Float Classification

**Rule ID:** `PIZ_FLOAT_CLASSIFICATION_001`

**Requirement:**
Subnormal float detection method must be explicitly defined and deterministic.

**Subnormal Detection Method:**
- Use Swift `Double.isSubnormal` property OR classify via `floatingPointClass`
- Method: `Double.isSubnormal` (preferred, explicit)
- Alternative: Check `floatingPointClass == .subnormal` (if using FloatingPointClassification)
- Detection method must be deterministic and platform-independent

**Float Classification Rules:**
- Zero (0.0, -0.0): Allowed
- Subnormal: Rejected (forbidden)
- NaN: Rejected (forbidden)
- ±Inf: Rejected (forbidden)
- Normal: Required (allowed)

**Validation Logic:**
- For each heatmap value:
  1. Check `value.isNaN` → reject if true
  2. Check `value.isInfinite` → reject if true
  3. Check `value.isSubnormal` → reject if true
  4. Check `value >= 0.0 && value <= 1.0` → reject if false
  5. Otherwise: value is valid (normal finite in [0.0, 1.0])

**Enforcement requirement:**
- Subnormal detection method must be explicitly documented
- Detection must use Swift standard library methods
- Tests must verify subnormal rejection
- Cross-platform tests must verify identical classification

**Required Fixtures:**
- Fixture: Construct subnormal value deterministically (e.g., `Double.leastNonzeroMagnitude / 2`)
- Fixture must ensure validator rejects subnormal as INSUFFICIENT_DATA
- Fixture must verify subnormal detection works correctly

---

## 5. PIZ Output Contract

### 5.1 Decision Layer vs Explainability Layer

**Rule ID:** `PIZ_DECISION_EXPLAINABILITY_SEPARATION_001`

**Separation:**
- Decision layer: Fields required for gating (gateRecommendation, triggers_fired)
- Explainability layer: Fields required for UI explanation (regions, recaptureSuggestion, heatmap)

**Enforcement requirement:**
- Decision fields must be minimal and deterministic
- Explainability fields may be richer but must not affect decisions
- Tests must verify separation

### 5.1.1 Decision vs Explainability Verification

**Rule ID:** `PIZ_DECISION_INDEPENDENCE_001`

**Requirement:**
Decision-layer outputs must be serializable independently. Removing explainability fields must not change gate decisions.

**Independence Verification:**
- Decision-layer output must be a valid, complete subset of full output
- Decision-layer output must contain only: `gateRecommendation`, `globalTrigger`, `localTriggerCount`
- Removing all explainability fields must not affect gate decision
- Decision-layer output must be sufficient for all gate logic

**Serialization Requirement:**
- Decision-layer output must be independently serializable
- Decision-layer output must be independently deserializable
- Decision-layer output must be independently testable

**Verification Tests Requirement:**
- CI must include tests that validate decision-layer independence
- Tests must verify that removing explainability fields does not change gateRecommendation
- Tests must verify that decision-layer output alone is sufficient for gating
- Tests must verify that explainability fields do not influence gate decisions

**Enforcement requirement:**
- Decision-layer serialization must be explicit and documented
- CI tests must verify independence
- Any coupling between decision and explainability layers must be eliminated
- Tests must verify that explainability fields are truly optional for gating

### 5.1.2 Output Profiles

**Rule ID:** `PIZ_OUTPUT_PROFILE_001`

**Requirement:**
Output profiles must be explicitly defined to remove ambiguity about which fields are required in different contexts.

**Output Profile Definitions:**

1. **DecisionOnly Profile:**
   - Required fields: `gateRecommendation`, `globalTrigger`, `localTriggerCount`
   - Optional fields: None
   - Purpose: Minimal output for gate decisions only
   - Use case: State machine gating logic

2. **FullExplainability Profile:**
   - Required fields: All decision fields + `heatmap`, `regions`, `recaptureSuggestion`, `assetId`, `timestamp`, `computePhase`, `schemaVersion`, `foundationVersion`, `connectivityMode`
   - Optional fields: None
   - Purpose: Complete output for UI explanation and audit
   - Use case: User-facing reports, debugging, audit trails

**Profile Selection:**
- Profile must be explicitly specified by caller
- Default profile must be documented (FullExplainability)
- Profile selection must not affect gate decisions
- DecisionOnly profile must be sufficient for all gate logic

**Compatibility with Independence:**
- DecisionOnly profile must be identical to decision-layer output
- Removing explainability fields from FullExplainability must produce DecisionOnly
- Profile selection must not create coupling between layers

**Enforcement requirement:**
- Output profiles must be explicitly documented
- Profile selection must be explicit in API
- Tests must verify profile behavior
- Tests must verify profile independence

### 5.1.2.1 Schema Profile Integration

**Rule ID:** `PIZ_SCHEMA_PROFILE_001`

**Requirement:**
Output profiles must be integrated with schema rules to remove ambiguity between profile requirements and schema validation.

**Chosen Model:** Option A (RECOMMENDED): One schema with profile-gated required-set.

**Schema Structure:**
- Single schema `PIZReport` with explicit `outputProfile` field
- `outputProfile`: enum {DecisionOnly, FullExplainability} (closed set)
- Schema versioning applies to entire schema (including outputProfile field)

**Profile-Gated Required Fields:**

**For DecisionOnly Profile:**
- Required fields exactly: `schemaVersion`, `outputProfile`, `gateRecommendation`, `globalTrigger`, `localTriggerCount`
- Explainability fields: NOT present (must be absent or null)
- Closed-set decoding: When `outputProfile=DecisionOnly`, explainability fields are rejected (strictness)

**For FullExplainability Profile:**
- Required fields: All decision fields (`schemaVersion`, `outputProfile`, `gateRecommendation`, `globalTrigger`, `localTriggerCount`) + explainability fields (`heatmap`, `regions`, `recaptureSuggestion`, `assetId`, `timestamp`, `computePhase`, `foundationVersion`, `connectivityMode`)
- All fields must be present and non-null

**Closed-Set Decoding Rules:**
- Closed-set decoding must be applied per schemaVersion-gated compatibility model (see section 12.1) AND per selected profile's allowed field set
- When `outputProfile=DecisionOnly`: Unknown fields are rejected (strict closed-set)
- When `outputProfile=DecisionOnly`: Explainability fields are rejected (strictness)
- When `outputProfile=FullExplainability`: All fields per profile definition are required; unknown fields rejected per schemaVersion compatibility model

**Decoding Behavior:**
- DecisionOnly decoding: Rejects explainability fields when outputProfile=DecisionOnly (strictness)
- This ensures DecisionOnly outputs cannot contain explainability data
- FullExplainability decoding: Requires all fields; rejects unknown fields per schemaVersion rules

**Enforcement requirement:**
- Schema must include outputProfile field
- Profile-gated field sets must be enforced in decoding
- Closed-set decoding must respect both schemaVersion and outputProfile
- Tests must verify profile-gated decoding behavior
- Tests must verify DecisionOnly rejects explainability fields

### 5.2 Explicit Fields Required for Gating

**Required Fields:**
- `gateRecommendation`: Enum (ALLOW_PUBLISH, BLOCK_PUBLISH, RECAPTURE, INSUFFICIENT_DATA)
- `globalTrigger`: Bool
- `localTriggerCount`: Int

**Enforcement requirement:**
- These fields must be present in all outputs
- These fields must be sufficient for gate decisions
- No additional fields required for gating

### 5.3 Explicit Fields Required for UI Explanation

**Required Fields:**
- `heatmap`: 32x32 grid (row-major, values 0.0-1.0)
- `regions`: List of detected PIZ regions
- `recaptureSuggestion`: Structured suggestion with priority and reason

**Region Fields:**
- `id`: String (unique identifier, deterministic)
- `bbox`: BoundingBox (minRow, maxRow, minCol, maxCol)
- `centroid`: Point (row, col)
- `areaRatio`: Double (region pixels / total grid pixels)
- `principalDirection`: Vector (from centroid to farthest point in bbox)
- `severityScore`: Double (0.0-1.0, computed from coverage_local)

**Enforcement requirement:**
- These fields must be present for explainability
- These fields must not affect gate decisions
- Tests must verify explainability completeness

### 5.3.1 Explainability Geometry Determinism

**Rule ID:** `PIZ_GEOMETRY_DETERMINISM_001`

**Requirement:**
All explainability geometry fields must be computed deterministically. Computation methods must be frozen and documented.

**Bounding Box Semantics:**
- Bbox bounds are inclusive: `[minRow, maxRow]` and `[minCol, maxCol]`
- minRow: Minimum row index of all pixels in region (inclusive)
- maxRow: Maximum row index of all pixels in region (inclusive)
- minCol: Minimum column index of all pixels in region (inclusive)
- maxCol: Maximum column index of all pixels in region (inclusive)
- Bbox computation must be deterministic and documented

**Centroid Computation:**
- Centroid = arithmetic mean of all pixel coordinates in region
- Formula: `centroid.row = sum(pixel.row) / pixelCount`
- Formula: `centroid.col = sum(pixel.col) / pixelCount`
- Rounding: No rounding applied (exact floating-point result)
- Precision: Full double precision maintained

**Principal Direction Computation:**
- Principal direction = normalized vector from centroid to farthest point in bbox
- Farthest point selection: Find corner of bbox farthest from centroid
- Distance metric: Euclidean distance squared (dx² + dy²)
- Normalization: Vector normalized to unit length
- Tie-breaking: See section 5.3.2

**Enforcement requirement:**
- Bbox semantics must be explicitly documented
- Centroid computation must be deterministic
- Principal direction computation must be deterministic
- Tests must verify geometry computation
- Cross-platform tests must verify identical geometry

### 5.3.2 Principal Direction Tie-Breaking

**Rule ID:** `PIZ_DIRECTION_TIEBREAK_001`

**Requirement:**
When multiple bbox corners are equidistant from centroid, tie-breaking must be deterministic.

**Tie-Breaking Rule:**
- When multiple corners have identical distance from centroid:
  1. Select corner with minimum row coordinate
  2. If still tied, select corner with minimum column coordinate
  3. If still tied (should not occur), select first corner in deterministic order: (minRow, minCol), (minRow, maxCol), (maxRow, minCol), (maxRow, maxCol)

**Deterministic Order:**
- Corner evaluation order: (minRow, minCol), (minRow, maxCol), (maxRow, minCol), (maxRow, maxCol)
- First corner meeting farthest distance criterion is selected
- Tie-breaking uses row-major minimum coordinate rule

**Enforcement requirement:**
- Tie-breaking rule must be explicitly documented
- Tests must verify tie-breaking behavior
- Fixtures must exist for symmetric/tie cases
- Cross-platform tests must verify identical tie-breaking

### 5.4 Deterministic Region Identity and Ordering

**Rule ID:** `PIZ_REGION_ID_001`

**Region ID Generation Lockdown:**
Region IDs must be generated using explicit, deterministic algorithm. No alternative ID strategies are permitted.

**Explicit ID Construction Rule:**
- Region ID = SHA-256 hash of canonical region descriptor
- Canonical descriptor format (Big-Endian encoding):
  1. `uint32_be minRow`
  2. `uint32_be maxRow`
  3. `uint32_be minCol`
  4. `uint32_be maxCol`
  5. `uint32_be pixelCount`
- Hash output: First 16 bytes of SHA-256, encoded as lowercase hex string
- Prefix: `"piz_region_"` + hex string

**Byte Order Requirement:**
- All integers must be Big-Endian
- String encoding: UTF-8
- No platform-specific byte order allowed

**Input Fields Requirement:**
- ID must be computed from: bbox (minRow, maxRow, minCol, maxCol) and pixelCount
- No other fields may influence ID generation
- Same bbox + pixelCount must produce identical ID across platforms

**Prohibited ID Strategies:**
- Random UUIDs
- Timestamp-based IDs
- Incremental counters
- Platform-specific hash functions
- Non-deterministic ID generation

**Enforcement requirement:**
- ID generation algorithm must be explicitly documented
- ID generation must be testable and verifiable
- Cross-platform tests must verify identical IDs for same inputs
- Alternative ID strategies must be rejected by CI

**Region Ordering requirement:**
- Final serialized output ordering MUST be bbox coordinate sort (NOT discovery order)
- Primary sort: minRow (ascending)
- Secondary sort: minCol (ascending)
- Tertiary sort: maxRow (ascending)
- Quaternary sort: maxCol (ascending)
- If bbox ties occur: Tiebreak by region id lexicographic ascending (explicit)
- Same input must produce same ordering across platforms

**Ordering Clarification:**
- Internal labeling uses deterministic discovery order (row-major scan) for component processing
- Final serialized output uses bbox coordinate sort (NOT discovery order)
- Discovery order is internal only; output ordering is bbox-based

**Enforcement requirement:**
- Ordering rules must be explicitly documented
- Tests must verify deterministic ordering
- Tests must verify bbox-based sort (not discovery order)
- Tests must verify tie-breaking by region id
- Cross-platform tests must verify identical ordering

---

## 6. Threshold Governance (SSOT)

### 6.1 Single Source of Truth

**Location requirement:**
- All thresholds must be defined in `Core/Constants/PIZThresholds.swift`
- No thresholds may exist elsewhere

**Enforcement requirement:**
- CI grep/lint must detect bare threshold numbers
- All threshold references must use named constants
- Threshold file must be versioned

### 6.2 Snapshot-Based Consumption

**Pattern requirement:**
- Thresholds are consumed as snapshots at detection time
- No dynamic threshold updates during detection
- Threshold changes require code changes and recompilation

**Enforcement requirement:**
- Tests must verify snapshot behavior
- No runtime threshold configuration allowed
- Threshold changes must be explicit and reviewed

### 6.3 Prohibition of Inline Thresholds

**Rule:**
- No bare threshold numbers in detection logic
- All thresholds must reference SSOT constants
- Magic numbers are forbidden

**Enforcement requirement:**
- CI must scan for bare numbers in threshold ranges
- Code review must verify SSOT usage
- Tests must verify threshold references

### 6.4 Floating-Point Tolerance as SSOT

**Rule ID:** `PIZ_TOLERANCE_SSOT_001`

**Requirement:**
All numeric tolerances used in floating-point comparisons must be defined in SSOT. No inline epsilon values are permitted.

**SSOT Tolerance Constants:**
All tolerance values must be defined in `Core/Constants/PIZThresholds.swift`:
- `COVERAGE_RELATIVE_TOLERANCE = 1e-4` (for coverage/ratio comparisons)
- `LAB_COLOR_ABSOLUTE_TOLERANCE = 1e-3` (for Lab color component comparisons)
- Any additional tolerances must be explicitly named and documented

**Prohibited:**
- Inline epsilon values in code (e.g., `if abs(a - b) < 0.0001`)
- Hardcoded tolerances in tests
- Magic number tolerances
- Platform-specific tolerance values

**Enforcement requirement:**
- CI must detect inline tolerance values
- All tolerance references must use SSOT constants
- Tolerance values must be documented
- CI must fail if hardcoded tolerances are detected

### 6.5 CI-Enforced Access Rules

**Enforcement requirement:**
- CI must verify SSOT compliance
- CI must block on threshold violations
- CI must verify threshold documentation
- CI must verify tolerance SSOT compliance

### 6.6 SSOT Constants Summary

**Required SSOT Constants:**
All constants must be defined in `Core/Constants/PIZThresholds.swift`:

**Coverage Thresholds:**
- `COVERED_CELL_MIN = 0.5` (covered cell predicate threshold)
- `GLOBAL_COVERAGE_MIN = 0.75` (global trigger threshold)
- `LOCAL_COVERAGE_MIN = 0.5` (local trigger threshold)

**Region Thresholds:**
- `LOCAL_AREA_RATIO_MIN = 0.05` (minimum area ratio)
- `MIN_REGION_PIXELS = 8` (minimum region size)

**Severity Thresholds:**
- `SEVERITY_HIGH_THRESHOLD = 0.7` (high severity threshold)
- `SEVERITY_MEDIUM_THRESHOLD = 0.3` (medium severity threshold)

**Hysteresis:**
- `HYSTERESIS_BAND = 0.05` (hysteresis band width)

**Tolerances:**
- `COVERAGE_RELATIVE_TOLERANCE = 1e-4` (coverage/ratio comparisons)
- `LAB_COLOR_ABSOLUTE_TOLERANCE = 1e-3` (Lab color comparisons)
- `JSON_CANON_QUANTIZATION_PRECISION = 1e-6` (JSON canonicalization)
- `JSON_CANON_DECIMAL_PLACES = 6` (derived: -log10(JSON_CANON_QUANTIZATION_PRECISION))

**Grid Constants:**
- `GRID_SIZE = 32` (heatmap grid size)
- `TOTAL_GRID_CELLS = 1024` (32 * 32)

**Derived Constants:**
- `MAX_REPORTED_REGIONS = 128` (derived: floor(TOTAL_GRID_CELLS / MIN_REGION_PIXELS))

**Enforcement requirement:**
- All constants must be defined in SSOT
- No inline constants permitted
- CI must verify SSOT compliance

---

## 7. Fixtures as Contracts

### 7.1 Nominal / Boundary / Failure Fixtures

**Fixture Categories:**
- Nominal: Expected behavior under normal conditions
- Boundary: Behavior at threshold boundaries (exact equality, just above/below)
- Failure: Error handling and edge conditions

**Enforcement requirement:**
- Each category must have representative fixtures
- Fixtures must cover all rule IDs
- Fixture coverage must be complete

### 7.2 Fixtures Mapped to Rule IDs

**Mapping requirement:**
- Each fixture must specify which rule IDs it exercises
- Each rule ID must have at least one fixture
- Fixture metadata must include rule ID references

**Enforcement requirement:**
- Fixture metadata must be explicit
- Rule ID coverage must be verified
- Missing rule ID coverage must fail CI

### 7.3 Fixtures Treated as Closed-Set Schemas

**Schema requirement:**
- Fixtures must follow explicit schema
- Unknown fields in fixtures are rejected
- Fixture schema must be versioned

**Enforcement requirement:**
- Fixture validation must be strict
- Schema violations must fail CI
- Schema changes must be versioned

### 7.4 Diagnostic Requirements on Failure

**On Fixture Failure requirement:**
- Must report which rule ID failed
- Must report expected vs actual values
- Must report input conditions
- Must provide diagnostic information

**Enforcement requirement:**
- Test framework must provide diagnostics
- Failure reports must be actionable
- Diagnostics must be machine-readable

### 7.5 Semantic Parity Fixtures (Cross-Platform Proof)

**Rule ID:** `PIZ_SEMANTIC_PARITY_001`

**Requirement:**
A dedicated fixture class must exist that proves semantic parity between macOS and Linux platforms.

**Parity Mode Selection:**
Path A (RECOMMENDED): Canonicalize floats using SSOT quantization, then require byte-identical JSON.

**Chosen Path:** Path A

**Rationale:**
- Byte-identical JSON provides strongest guarantee of semantic parity
- Float canonicalization eliminates platform-specific floating-point representation differences
- SSOT quantization ensures deterministic canonicalization

### 7.5.1 Float Canonicalization (Path A)

**Rule ID:** `PIZ_FLOAT_CANON_001`

**Requirement:**
Floating-point values must be canonicalized using SSOT quantization before JSON serialization.

**SSOT Quantization:**
- Quantization precision must be defined in SSOT: `JSON_CANON_QUANTIZATION_PRECISION` (e.g., 1e-6)
- All floating-point values must be quantized: `quantized = round(value / precision) * precision`
- Quantization must use ROUND_HALF_AWAY_FROM_ZERO (see SSOT Foundation)
- Rounding is applied on the scaled value (value / precision), then multiplied back by precision
- Quantized values must be serialized with fixed precision

**Enforcement requirement:**
- Quantization precision must be SSOT constant
- Quantization algorithm must be explicitly documented
- CI must verify quantization behavior
- Tests must verify canonicalization

### 7.5.1.1 Numeric Formatting and Quantization

**Rule ID:** `PIZ_NUMERIC_FORMAT_001`

**Requirement:**
Numeric quantization and JSON numeric formatting must be unambiguous and deterministic.

**Decimal Places Derivation:**
- `decimalPlaces = -log10(JSON_CANON_QUANTIZATION_PRECISION)`
- decimalPlaces MUST be an integer; otherwise spec is invalid
- For `JSON_CANON_QUANTIZATION_PRECISION = 1e-6`, decimalPlaces = 6
- This derivation must be verified at compile-time or runtime (precondition in debug + CI test)

**JSON Float Formatting:**
- All floating-point values MUST be rendered with exactly `decimalPlaces` digits after the decimal point
- Fixed-point format required (no scientific notation)
- Format: `"X.XXXXXX"` where X represents digits (exactly decimalPlaces digits after decimal)
- No exponent form (no "e" or "E" in output)
- No trailing zeros removal (fixed width)

**Zero Normalization:**
- Normalize `-0.0` to `0.0` before serialization
- Both `0.0` and `-0.0` must serialize as `"0.000000"` (with decimalPlaces digits)

**Quantization Rounding:**
- Rounding method: ROUND_HALF_AWAY_FROM_ZERO
- Algorithm: `scaled = value / JSON_CANON_QUANTIZATION_PRECISION`
- Round scaled value using ROUND_HALF_AWAY_FROM_ZERO
- `quantized = rounded_scaled * JSON_CANON_QUANTIZATION_PRECISION`
- This formatting applies to ALL floating-point fields included in canonicalization outputs

**Enforcement requirement:**
- decimalPlaces derivation must be verified (compile-time assertion or runtime precondition)
- JSON encoder must never emit scientific notation
- JSON encoder must normalize -0.0 to 0.0
- Fixed decimal places must be enforced
- CI must verify numeric formatting

**Required Fixtures:**
- Fixture: value = -0.0 serializes as "0.000000" (with decimalPlaces digits)
- Fixture: fixed decimals are respected (no exponent form appears)
- Fixture: scientific notation absence (ensure encoder never emits "e" or "E")

### 7.5.2 JSON Canonicalization (Path A)

**Rule ID:** `PIZ_JSON_CANON_001`

**Requirement:**
JSON serialization must follow canonical format to ensure byte-identical outputs.

**Canonical JSON Format:**
- Encoding: UTF-8 only
- Key ordering: Lexicographic sort (alphabetical)
- Pretty-print: Disabled (compact format)
- Numeric formatting: Fixed precision (as per quantization)
- No trailing whitespace
- No platform-specific formatting

**Stable Numeric Formatting:**
- Floating-point values: Fixed decimal places (as per quantization precision)
- Integers: No scientific notation
- No locale-specific formatting
- No platform-specific numeric representations

**Enforcement requirement:**
- JSON serialization must use canonical format
- CI must verify byte-identical JSON outputs
- Tests must verify canonicalization
- Any deviation from canonical format must fail CI

**Semantic Parity Fixture Specification:**
- Fixtures must run identical inputs on both macOS and Linux
- Outputs must be canonicalized (floats quantized, JSON canonicalized)
- Serialized outputs must be byte-identical after canonicalization
- Any byte-level divergence must be treated as CI failure

**Enforcement requirement:**
- Semantic parity fixtures must exist for all nominal cases
- Cross-platform comparison must run in CI
- Any divergence must block CI
- Divergence reports must be machine-readable

**Failure Treatment:**
- Byte-level divergence is treated as hard CI failure
- Divergence must be documented and fixed
- Platform-specific behavior is forbidden

---

## 8. Determinism & Stability Guarantees

### 8.1 Floating-Point Comparison Policy

**Rule ID:** `PIZ_FLOAT_COMPARISON_001`

**Policy requirement:**
- Floating-point comparisons must use explicit tolerances
- Equality comparisons must use relative or absolute tolerance
- Tolerance values must be SSOT constants (see section 6.4)

**Tolerances (SSOT):**
- Coverage/ratio values: Relative error ≤ `COVERAGE_RELATIVE_TOLERANCE` (1e-4)
- Lab color components: Absolute error ≤ `LAB_COLOR_ABSOLUTE_TOLERANCE` (1e-3)

**Comparison Rules:**
- Relative tolerance: `abs(a - b) <= max(abs(a), abs(b)) * tolerance`
- Absolute tolerance: `abs(a - b) <= tolerance`
- Tolerance selection must be explicit and documented

**Enforcement requirement:**
- No direct equality comparisons for floats (`==` or `!=` without tolerance)
- Tolerance usage must be explicit
- All tolerances must reference SSOT constants
- Tests must verify tolerance behavior
- CI must detect direct float equality comparisons

### 8.2 Timestamp Exclusion from Decisions

**Rule:**
- Timestamps must not affect detection decisions
- Timestamps are for output only (audit/explainability)
- Decision logic must be time-independent

**Enforcement requirement:**
- Timestamps must not be used in comparisons
- Decision logic must be testable without timestamps
- Tests must verify time-independence

### 8.3 Stable Ordering and Tie-Breaking Rules

**Ordering requirement:**
- Regions must be ordered deterministically
- Tie-breaking rules must be explicit
- Same input must produce same ordering

**Tie-Breaking requirement:**
- Use bbox coordinates (minRow, then minCol)
- Or use region ID lexicographic order
- Rules must be documented

**Enforcement requirement:**
- Ordering must be deterministic
- Tests must verify stable ordering
- Tie-breaking rules must be explicit

---

## 9. Policy Boundary

### 9.1 Separation Between Detection & Scoring

**Boundary requirement:**
- Detection logic identifies regions and computes metrics
- Scoring logic computes severity scores
- Combination logic determines gate recommendation

**Enforcement requirement:**
- Each layer must be independently testable
- No cross-layer logic leakage
- Tests must verify separation

### 9.2 Separation Between Gate Recommendation and State Machine Actions

**Boundary requirement:**
- Gate recommendation is output from detection
- State machine actions are separate policy decisions
- Policy mapper translates recommendation to actions

**Enforcement requirement:**
- Detection must not directly change state machine states
- Policy mapper must be explicit and testable
- Tests must verify decoupling

### 9.3 Explicit Prohibition of Cross-Layer Logic Leakage

**Prohibited:**
- Detection logic accessing state machine internals
- State machine logic accessing detection internals
- Dynamic policy decisions based on detection internals

**Enforcement requirement:**
- Import analysis must verify boundaries
- Tests must verify decoupling
- Code review must verify separation

---

## 10. Cross-Platform Contract

### 10.1 macOS / Linux Parity

**Requirement:**
- Same input must produce same output on macOS and Linux
- Numerical differences must be within tolerance
- Behavioral differences are forbidden

**Tolerances:**
- Coverage/ratio values: Relative error ≤ 1e-4
- Lab color components: Absolute error ≤ 1e-3

**Enforcement requirement:**
- CI must run tests on both platforms
- Cross-platform comparison must pass
- Platform divergence must fail CI

### 10.2 Allowed Dependencies Only

**Allowed:**
- Standard library only
- Foundation framework (Swift)
- Explicitly approved dependencies

**Prohibited:**
- Platform-specific APIs for decision logic
- Non-deterministic system calls
- External configuration files

**Enforcement requirement:**
- Dependency analysis must verify allowed list
- CI must verify dependency compliance
- New dependencies require approval

### 10.2.1 Explicit Ban on Platform-Specific Numeric Acceleration

**Rule ID:** `PIZ_NUMERIC_ACCELERATION_BAN_001`

**Prohibited APIs and Libraries:**
- SIMD (Single Instruction Multiple Data) intrinsics
- Accelerate framework (macOS)
- vDSP (Vector Digital Signal Processing)
- BLAS (Basic Linear Algebra Subprograms)
- LAPACK (Linear Algebra Package)
- Any hardware-dependent numeric acceleration APIs
- GPU-accelerated numeric operations

**Rationale:**
- Platform-specific acceleration may introduce non-deterministic behavior
- Hardware differences may cause cross-platform divergence
- Accelerated operations may have different precision guarantees

**Required Approach:**
- Detection logic must rely on deterministic scalar operations only
- All numeric operations must be platform-independent
- Floating-point arithmetic must follow IEEE 754 standard
- No hardware-specific optimizations allowed

**Enforcement requirement:**
- Import analysis must detect prohibited APIs
- CI must verify absence of acceleration libraries
- Code review must verify scalar-only operations
- Any use of prohibited APIs must block CI

**Exception:**
- No exceptions permitted for detection logic
- Explainability layer may use platform-specific rendering (not decision logic)

### 10.3 Platform Divergence as CI Failure

**Enforcement requirement:**
- Cross-platform test failures must block CI
- Platform-specific behavior must be documented
- Divergence must be treated as bug

---

## 11. CI Enforcement Strategy

### 11.1 Blocking vs Near-Blocking Gates

**Blocking Gates:**
- Fixture failures
- Schema violations
- Threshold SSOT violations
- Cross-platform divergence

**Near-Blocking Gates:**
- Test coverage below threshold
- Performance regression
- Linter warnings

**Enforcement requirement:**
- Blocking gates must prevent merge
- Near-blocking gates must require explicit override
- Gate configuration must be explicit

### 11.2 Fixture Gates

**Enforcement requirement:**
- All fixtures must pass
- Fixture coverage must be complete
- Fixture failures must block CI

### 11.3 Schema Gates

**Enforcement requirement:**
- Schema validation must pass
- Unknown fields must be rejected
- Schema versioning must be correct

### 11.4 Threshold Access Gates

**Enforcement requirement:**
- SSOT compliance must be verified
- Inline thresholds must be detected
- Threshold documentation must be complete

### 11.5 Cross-Platform Matrix

**Enforcement requirement:**
- Tests must run on macOS and Linux
- Cross-platform comparison must pass
- Platform divergence must fail CI

### 11.6 Time-Budget Discipline

**Rule:**
- No weakening gates for speed
- Performance optimization must not reduce coverage
- Time budgets must be explicit

**Enforcement requirement:**
- Performance tests must be maintained
- Coverage must not decrease
- Time budgets must be documented

### 11.7 CI Failure Taxonomy

**Rule ID:** `PIZ_CI_FAILURE_TAXONOMY_001`

**Requirement:**
CI failures must be categorized explicitly. Categories must be documented and machine-readable.

**Failure Categories:**

1. **Spec Violation (Hard Fail):**
   - Schema violations
   - Unknown fields in outputs
   - Missing required fields
   - Invalid enum values
   - Rule ID violations
   - **CI Action:** Block merge, require fix

2. **Numeric Drift (Hard Fail):**
   - Cross-platform numeric divergence beyond tolerance
   - Floating-point comparison failures
   - Determinism violations
   - Region ID mismatches
   - Region ordering mismatches
   - **CI Action:** Block merge, require fix

3. **Coverage Regression (Near-Blocking):**
   - Test coverage below threshold
   - Missing fixture coverage for rule IDs
   - Missing boundary case coverage
   - Missing failure case coverage
   - **CI Action:** Require explicit override, document reason

4. **Performance Regression (Warning):**
   - Execution time exceeds time budget
   - Memory usage exceeds limits
   - **CI Action:** Warning only, document for review

**Machine-Readable Format Requirement:**
- CI failure reports must include category tags
- Categories must be parseable by automated tools
- Failure reports must be structured (JSON/YAML)
- Categories must be searchable and filterable

**Documentation Requirement:**
- Failure taxonomy must be documented
- Each category must have clear definition
- CI action for each category must be explicit
- Taxonomy must be versioned

**Enforcement requirement:**
- CI must categorize all failures
- Failure reports must be machine-readable
- Categories must be documented
- Taxonomy violations must be detected

---

## 12. Schema Evolution Rules

### 12.1 Major / Minor / Patch Semantics

**Rule ID:** `PIZ_SCHEMA_COMPAT_001`

**Compatibility Model Selection:**
SchemaVersion-gated closed-set behavior (chosen model).

**Rationale:**
- Strict closed-set always would prevent backward compatibility for minor versions
- SchemaVersion-gated allows old parsers to ignore new fields (minor version compatibility)
- Maintains closed-set enforcement for same-version parsing

**Compatibility Model:**

**Major Version:**
- Breaking changes (incompatible)
- Old versions may not parse new data
- Requires migration path
- Closed-set decoding enforced (unknown fields rejected)

**Minor Version:**
- Additive changes (backward compatible)
- Old versions can parse new data (ignore unknown fields)
- New fields added, existing fields unchanged
- Closed-set decoding enforced for same schemaVersion
- Old schemaVersion parsers use open-set decoding (ignore unknown fields)

**Patch Version:**
- Bug fixes (backward compatible)
- Behavior changes only, no schema changes
- No migration required
- Closed-set decoding enforced

**Closed-Set Decoding Rules:**
- Same schemaVersion: Strict closed-set (unknown fields rejected)
- Older schemaVersion parsing newer data: Open-set (unknown fields ignored)
- Newer schemaVersion parsing older data: Closed-set (missing fields cause error if required)

**Profile-Gated Decoding (see section 5.1.2.1):**
- Closed-set decoding must be applied per schemaVersion-gated compatibility model AND per selected profile's allowed field set
- When `outputProfile=DecisionOnly`: Explainability fields are rejected (strictness)
- When `outputProfile=FullExplainability`: All fields per profile definition are required
- Profile field sets take precedence over schemaVersion compatibility for field presence/absence

**Enforcement requirement:**
- Compatibility model must be explicitly documented
- Schema versioning must follow chosen model
- Profile-gated decoding must be integrated with schemaVersion compatibility
- Tests must verify compatibility behavior
- Tests must verify profile-gated field set enforcement
- Closed-set vs open-set behavior must be version-gated and profile-gated

### 12.2 Deprecation Windows

**Rule:**
- Deprecated fields must be supported for at least one major version
- Deprecation must be announced in advance
- Migration guides must be provided

**Enforcement requirement:**
- Deprecation notices must be explicit
- Support period must be documented
- Migration tools must be provided

### 12.3 Migration Requirements

**Requirements:**
- Migration scripts must be provided
- Migration must be reversible
- Migration must be tested

**Enforcement requirement:**
- Migration tools must be versioned
- Migration tests must be maintained
- Migration documentation must be complete

### 12.4 Fixture Coverage Expectations

**Requirements:**
- All schema versions must have fixtures
- Fixture coverage must be complete
- Fixture coverage must be maintained

**Enforcement requirement:**
- Fixture coverage must be measured
- Coverage gaps must be addressed
- Coverage reports must be generated

---

## 13. Definition of Done (DoD)

### 13.1 Specification Completeness

- [ ] All rule IDs are defined and documented
- [ ] All thresholds are specified in SSOT
- [ ] All combination logic is explicit
- [ ] All edge cases are enumerated

### 13.2 Implementation Completeness

- [ ] Detection logic implements all rules
- [ ] Output schema matches specification
- [ ] Thresholds are consumed from SSOT
- [ ] Determinism is verified

### 13.3 Test Completeness

- [ ] All rule IDs have fixtures
- [ ] Nominal, boundary, and failure cases are covered
- [ ] Cross-platform tests pass
- [ ] Test coverage meets threshold

### 13.4 CI Enforcement Completeness

- [ ] Fixture gates are blocking
- [ ] Schema gates are blocking
- [ ] Threshold gates are blocking
- [ ] Cross-platform gates are blocking

### 13.5 Documentation Completeness

- [ ] Specification is complete
- [ ] API contracts are documented
- [ ] Migration guides are provided
- [ ] Examples are provided

### 13.6 Verification Completeness

- [ ] All DoD items are objectively testable
- [ ] All DoD items are verified
- [ ] Verification results are documented
- [ ] DoD checklist is complete

---

## 14. Implementation Phases

### Phase 1: Specification

**Deliverables:**
- Complete PIZ detection specification
- All rule IDs defined
- All thresholds specified in SSOT
- All combination logic documented

**Acceptance criteria:**
- Specification review approved
- Rule IDs assigned
- Thresholds documented

### Phase 2: SSOT Foundation

**Deliverables:**
- PIZThresholds.swift with all constants
- CI enforcement for SSOT compliance
- Threshold documentation

**Acceptance criteria:**
- SSOT file complete
- CI gates passing
- Documentation complete

### Phase 3: Schema Definition

**Deliverables:**
- PIZReport schema (v1)
- Schema validation logic
- Schema versioning support

**Acceptance criteria:**
- Schema complete
- Validation passing
- Versioning working

### Phase 4: Detection Implementation

**Deliverables:**
- PIZDetector implementation
- All rules implemented
- Determinism verified

**Acceptance criteria:**
- Implementation complete
- Rules verified
- Determinism tested

### Phase 5: Fixture Suite

**Deliverables:**
- Nominal fixtures
- Boundary fixtures
- Failure fixtures
- Fixture runner

**Acceptance criteria:**
- Fixtures complete
- Coverage verified
- Runner working

### Phase 6: CI Enforcement

**Deliverables:**
- Fixture gates
- Schema gates
- Threshold gates
- Cross-platform gates

**Acceptance criteria:**
- Gates configured
- Gates blocking
- Coverage complete

### Phase 7: Documentation and Verification

**Deliverables:**
- Complete documentation
- DoD verification
- Migration guides

**Acceptance criteria:**
- Documentation complete
- DoD verified
- Ready for merge

---

## 15. Technical Debt Prevention Summary

This plan explicitly prevents the following classes of technical debt:

### 15.1 Threshold Debt

**Prevented:**
- Threshold drift (values changing without documentation)
- Configuration sprawl (thresholds scattered across codebase)
- Magic numbers (unexplained threshold values)

**Prevention mechanism:**
- SSOT enforcement
- CI detection of inline thresholds
- Explicit threshold documentation

### 15.2 Coupling Debt

**Prevented:**
- Hidden coupling between detection and state machine
- Implicit policy decisions
- Cross-layer logic leakage

**Prevention mechanism:**
- Explicit interface boundaries
- Import analysis
- Decoupling tests

### 15.3 Non-Determinism Debt

**Prevented:**
- Non-deterministic outputs
- Platform-specific behavior
- Time-dependent decisions

**Prevention mechanism:**
- Determinism tests
- Cross-platform verification
- Timestamp exclusion

### 15.4 Schema Debt

**Prevented:**
- Schema drift (fields added without versioning)
- Backward incompatibility
- Migration complexity

**Prevention mechanism:**
- Versioned schemas
- Migration requirements
- Deprecation windows

### 15.5 Test Debt

**Prevented:**
- Incomplete test coverage
- Subjective acceptance criteria
- Missing edge cases

**Prevention mechanism:**
- Fixture contracts
- Rule ID mapping
- Complete coverage requirements

### 15.6 Platform Debt

**Prevented:**
- Platform-specific behavior
- Dependency sprawl
- Cross-platform divergence

**Prevention mechanism:**
- Cross-platform contract
- Dependency restrictions
- Platform parity enforcement

---

---

## 16. Input Validation Contract

### 16.1 Heatmap Input Validation

**Rule ID:** `PIZ_INPUT_VALIDATION_002`

**Pre-Processing Validation:**
All heatmap inputs must pass validation before any detection logic executes.

**Validation Checklist:**
1. Shape validation: Exactly 32×32 cells
2. Floating-point validation: No NaN, ±Inf, or subnormal values
3. Range validation: All values in [0.0, 1.0]

**Invalid Input Handling:**
- Invalid inputs must result in `gateRecommendation = INSUFFICIENT_DATA`
- No regions may be reported for invalid inputs
- No triggers may fire for invalid inputs
- Error logging must not affect determinism

**Enforcement requirement:**
- Validation must occur before detection logic
- CI fixtures must cover all invalid input cases
- Invalid input handling must be deterministic
- Tests must verify INSUFFICIENT_DATA output

---

## 17. Algorithm Determinism Guarantees

### 17.1 Traversal Order Lockdown

**Rule ID:** `PIZ_TRAVERSAL_ORDER_001`

**Frozen Traversal Specification:**
- Row-major scan: row 0 to 31, column 0 to 31
- Component labeling: deterministic neighbor order
- No order-dependent algorithms permitted

**Enforcement requirement:**
- Traversal order must be documented
- Tests must verify deterministic ordering
- Cross-platform tests must verify identical ordering

### 17.2 Region ID Generation Specification

**Rule ID:** `PIZ_REGION_ID_SPEC_001`

**Canonical ID Algorithm:**
- Input: bbox (minRow, maxRow, minCol, maxCol) + pixelCount
- Encoding: Big-Endian integers
- Hash: SHA-256 of canonical descriptor
- Output: `"piz_region_"` + first 16 bytes (hex)

**Enforcement requirement:**
- Algorithm must be explicitly documented
- Tests must verify ID generation
- Cross-platform tests must verify identical IDs

### 17.3 Input Budget and Algorithmic Limits

**Rule ID:** `PIZ_INPUT_BUDGET_001`

**Requirement:**
Maximum input budgets and algorithmic limits must be defined to prevent abuse and ensure deterministic behavior.

**Input Budget Limits:**
- Maximum heatmap size: 32×32 (frozen, cannot exceed)
- Maximum regions reported: `MAX_REPORTED_REGIONS` (SSOT-derived constant, see section 17.3.1)
- Maximum component queue size: `MAX_COMPONENT_QUEUE_SIZE = 1024` (SSOT, grid cells)
- Maximum recursion depth: Not applicable (iterative algorithms required)

### 17.3.1 Maximum Regions Derived Constant

**Rule ID:** `PIZ_MAX_REGIONS_DERIVED_001`

**Requirement:**
MAX_REPORTED_REGIONS must be derived from SSOT constants rather than arbitrary value.

**Derivation Formula:**
- `MAX_REPORTED_REGIONS = floor(TOTAL_GRID_CELLS / MIN_REGION_PIXELS)`
- For GRID_SIZE=32: TOTAL_GRID_CELLS = 1024, MIN_REGION_PIXELS = 8
- `MAX_REPORTED_REGIONS = floor(1024 / 8) = 128`
- This derivation ensures maximum regions is mathematically bounded by grid capacity

**SSOT Constant Definition:**
- MAX_REPORTED_REGIONS must be defined in `Core/Constants/PIZThresholds.swift`
- Either as computed static let: `static let MAX_REPORTED_REGIONS = TOTAL_GRID_CELLS / MIN_REGION_PIXELS`
- Or as generated constant with explicit derivation comment
- Must be deterministic and visible in SSOT file

**Derivation Documentation:**
- Derivation must be documented in thresholds file and/or spec
- Formula must be explicit: `floor(TOTAL_GRID_CELLS / MIN_REGION_PIXELS)`
- Rationale: Maximum regions cannot exceed grid capacity divided by minimum region size

**Change Behavior:**
- If computed value ever changes due to SSOT changes (GRID_SIZE, MIN_REGION_PIXELS), it is intentional and reviewed
- Changes to GRID_SIZE or MIN_REGION_PIXELS automatically affect MAX_REPORTED_REGIONS
- This ensures consistency between grid capacity and maximum regions

**Enforcement requirement:**
- MAX_REPORTED_REGIONS must be derived from SSOT constants
- Derivation must be documented
- Derivation must be visible in SSOT file
- CI must verify derivation correctness

**Algorithmic Limits:**
- Maximum iterations for component labeling: `MAX_LABELING_ITERATIONS = TOTAL_GRID_CELLS` (1024)
- Maximum memory allocation: Bounded by grid size (deterministic)
- Maximum computation time: Must be bounded (see time budget discipline)

**Behavior When Budget Exceeded:**
- If input exceeds maximum heatmap size: Reject with `INSUFFICIENT_DATA`
- If regions exceed MAX_REPORTED_REGIONS: Report first MAX_REPORTED_REGIONS (deterministic ordering)
- If component queue exceeds limit: Fail deterministically (should not occur with 32×32 grid)
- All budget violations must be deterministic and testable

**Deterministic Budget Enforcement:**
- Budget checks must occur before processing
- Budget violations must result in deterministic error state
- Budget limits must be SSOT constants
- No silent truncation or non-deterministic behavior

**Enforcement requirement:**
- Budget limits must be defined in SSOT
- Budget enforcement must be deterministic
- Tests must verify budget behavior
- Budget violations must be testable

---

**Document Status:** DESIGN SPECIFICATION  
**Document Version:** 1.3  
**Last Updated:** 2026-01-27  
**Changes:** 
- Version 1.2: Added additional industrial sealing constraints
- Version 1.3: Fixed 6 specification gaps:
  - Section 7.5.1.1: Numeric quantization + JSON numeric formatting ambiguity (PIZ_NUMERIC_FORMAT_001)
  - Section 5.1.2.1: Output profiles vs schema rules ambiguity (PIZ_SCHEMA_PROFILE_001, Option A chosen)
  - Section 4.1.2: Global trigger synthetic region requirement (PIZ_GLOBAL_REGION_001)
  - Section 4.3.1 & 5.4: Region ordering contradiction resolved (PIZ_REGION_ORDER_002, discovery order internal, bbox sort for output)
  - Section 4.7.1: Subnormal float classification method specified (PIZ_FLOAT_CLASSIFICATION_001)
  - Section 17.3.1: MAX_REPORTED_REGIONS derived from SSOT (PIZ_MAX_REGIONS_DERIVED_001)
**Next Review:** After specification approval
