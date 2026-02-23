# PIZ Detection Specification (v1)

**Document Version:** 1.0  
**Status:** IMMUTABLE  
**Created Date:** 2026-01-27  
**Scope:** PR1 PIZ Detection Contract

---

## Overview

This specification defines machine-verifiable acceptance criteria for PIZ (Patch Inclusion Zone) detection. PIZ detection identifies spatial gaps in coverage that require user attention or recapture.

**Core Principle:** Closed-world, deterministic, testable.

---

## 1. Global Trigger

**Rule ID:** PIZ_GLOBAL_001  
**Status:** IMMUTABLE

A global PIZ trigger fires when:

```
coverage_total < GLOBAL_COVERAGE_MIN
```

**Semantics:**
- `coverage_total` is the ratio of covered cells to total cells in the 32x32 heatmap grid
- Covered cells are those with state `COVERED` (value >= threshold)
- When triggered, PIZ severity is at least `MEDIUM`

**Threshold:**
- `GLOBAL_COVERAGE_MIN = 0.75` (defined in SSOT constants)

**Behavior:**
- Global trigger is independent of local region detection
- If global trigger fires, at least one region with severity >= MEDIUM must be reported

---

## 2. Local Trigger

**Rule ID:** PIZ_LOCAL_001  
**Status:** IMMUTABLE

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

---

## 3. Continuous Region Definition

**Rule ID:** PIZ_CONNECTIVITY_001  
**Status:** IMMUTABLE

**Chosen connectivity:** 4-neighborhood (frozen, must be used everywhere)

**Definition:**
- Two cells are connected if they share an edge (not just a corner)
- A continuous region is a maximal set of connected cells
- Connectivity is computed on the 32x32 heatmap grid

**Algorithm:**
- Use connected components labeling (4-neighborhood)
- Each component is a candidate region
- Regions are filtered by MIN_REGION_PIXELS before classification

**Rationale:**
- 4-neighborhood is more conservative (fewer false positives)
- Deterministic and unambiguous
- Must be stated explicitly and used consistently

---

## 4. Minimum Region Threshold

**Rule ID:** PIZ_NOISE_001  
**Status:** IMMUTABLE

**Threshold:** `MIN_REGION_PIXELS = 8`

**Semantics:**
- Grid-based, resolution independent
- Regions with pixel count < MIN_REGION_PIXELS are filtered out
- Prevents noise speckles from triggering PIZ detection

**Enforcement:**
- Applied after connected components labeling
- Applied before local trigger evaluation

---

## 5. Output Explainability Requirements

**Rule ID:** PIZ_OUTPUT_001  
**Status:** IMMUTABLE

PIZReport MUST include the following fields for UI explainability:

### Required Fields

1. **heatmap** (32x32 grid)
   - Type: `[[Double]]` (row-major, values 0.0-1.0)
   - Represents coverage density per cell

2. **regions** (list of detected PIZ regions)
   - Each region includes:
     - `id`: String (unique identifier)
     - `bbox`: BoundingBox (minRow, maxRow, minCol, maxCol)
     - `centroid`: Point (row, col)
     - `areaRatio`: Double (region pixels / total grid pixels)
     - `principalDirection`: Vector (from centroid to farthest point in bbox)
     - `severityScore`: Double (0.0-1.0, computed from coverage_local)

3. **triggers_fired**
   - `globalTrigger`: Bool
   - `localTriggerCount`: Int (number of regions passing local trigger)

4. **gateRecommendation**
   - Enum: `ALLOW_PUBLISH`, `BLOCK_PUBLISH`, `RECAPTURE`, `INSUFFICIENT_DATA`
   - Determined by combination logic (see Section 6)

5. **recaptureSuggestion**
   - Structured fields:
     - `suggestedRegions`: [String] (region IDs requiring recapture)
     - `priority`: Enum (`HIGH`, `MEDIUM`, `LOW`)
     - `reason`: String (explanation for UI)

---

## 6. Combination Logic

**Rule ID:** PIZ_COMBINE_001  
**Status:** IMMUTABLE

Gate recommendation is determined by the following deterministic logic:

```
IF globalTrigger:
    gateRecommendation = RECAPTURE
    severity = MEDIUM (minimum)
ELSE IF localTriggerCount > 0:
    maxSeverity = max(region.severityScore for region in regions)
    IF maxSeverity >= 0.7:
        gateRecommendation = RECAPTURE
    ELSE IF maxSeverity >= 0.3:
        gateRecommendation = BLOCK_PUBLISH
    ELSE:
        gateRecommendation = ALLOW_PUBLISH
ELSE:
    gateRecommendation = ALLOW_PUBLISH
```

**Hysteresis Rule:**
- When PIZ score oscillates around thresholds, use hysteresis band of 0.05
- Once recommendation is set, it requires crossing threshold + hysteresis to change
- Prevents flip-flopping

**Severity Calculation:**
```
severityScore = 1.0 - coverage_local
```
- Higher gap = higher severity
- Range: [0.0, 1.0]

---

## 7. Coupling Policy

**Rule ID:** PIZ_COUPLING_001  
**Status:** IMMUTABLE

**Strict separation of concerns:**

1. **PIZ Detector:**
   - MUST NOT directly change StateMachine states
   - Outputs only PIZReport with gateRecommendation

2. **StateMachine:**
   - Consumes only `PIZReport.gateRecommendation`
   - Does not access internal PIZ detection logic

3. **Policy Mapper:**
   - Separate layer translates `gateRecommendation` -> (S3/S4 actions)
   - Fully test-covered
   - Non-dynamic (explicit mapping, no heuristics)

**Enforcement:**
- PIZ detector has no import of JobStateMachine
- Policy mapper is in separate module
- Tests verify decoupling

---

## 8. Threshold Comparison Operators

**Rule ID:** PIZ_THRESHOLD_001  
**Status:** IMMUTABLE

**Global trigger:**
- Uses `<` (strict less than)
- `coverage_total < GLOBAL_COVERAGE_MIN` triggers

**Local coverage:**
- Uses `<` (strict less than)
- `coverage_local < LOCAL_COVERAGE_MIN` required

**Area ratio:**
- Uses `>=` (greater than or equal)
- `region_area_ratio >= LOCAL_AREA_RATIO_MIN` required

**Pixel count:**
- Uses `>=` (greater than or equal)
- `region_pixel_count >= MIN_REGION_PIXELS` required

**Boundary behavior:**
- Exact equality at threshold follows the operator (>= includes equality, < excludes it)
- Fixtures must test boundary cases explicitly

---

## 9. Determinism Requirements

**Rule ID:** PIZ_DETERMINISM_001  
**Status:** IMMUTABLE

**Prohibited in decision path:**
- Random number generation
- Date/time (except for timestamps in output)
- UUID generation (use deterministic IDs)
- Non-deterministic algorithms

**Required:**
- Same input → same output (always)
- Deterministic region ID generation (e.g., based on bbox hash)
- Deterministic principalDirection calculation

---

## 10. Schema Versioning

**Rule ID:** PIZ_SCHEMA_001  
**Status:** IMMUTABLE

**Current version:** 1

**Fields:**
- `schema_version`: Int (must be 1 for v1)
- `connectivity_mode`: String ("FOUR" or "EIGHT", frozen to "FOUR")

**Future versions:**
- Schema version increments only on breaking changes
- Old versions must remain parseable (backward compatibility)
- Unknown fields are rejected (closed-world)

---

## Appendix: Threshold Values (SSOT)

All thresholds are defined in `Core/Constants/PIZThresholds.swift`:

```swift
public static let GLOBAL_COVERAGE_MIN: Double = 0.75
public static let LOCAL_COVERAGE_MIN: Double = 0.5
public static let LOCAL_AREA_RATIO_MIN: Double = 0.05
public static let MIN_REGION_PIXELS: Int = 8
public static let HYSTERESIS_BAND: Double = 0.05
public static let SEVERITY_HIGH_THRESHOLD: Double = 0.7
public static let SEVERITY_MEDIUM_THRESHOLD: Double = 0.3
```

**Enforcement:**
- No bare threshold numbers outside this file
- CI grep/lint enforces this rule

---

**Document Status:** IMMUTABLE  
**Last Updated:** 2026-01-27  
**Maintainer:** PR1 PIZ Detection Team
