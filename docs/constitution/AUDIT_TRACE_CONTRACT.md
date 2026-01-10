# Audit Trace Contract (PR#8.5)

**Version**: v0.0.1  
**Status**: Active  
**Supersedes**: N/A

---

## Overview

The Audit Trace Contract (PR#8.5) defines an append-only factual log for world model training. All audit entries must comply with this contract to ensure deterministic ID generation, consistent validation, and proper trace lifecycle management.

---

## Contract Components

### 1. Entry Schema

#### 1.1 Schema Version
- **Required**: `schemaVersion = 1`
- **Validation**: Priority 1 (schema errors)

#### 1.2 Core Identifiers

| Field | Format | Length | Validation |
|-------|--------|--------|------------|
| `traceId` | Lowercase hex | 64 | SHA256("WMTRACE/v0.0.1\|{policyHash}\|{pipelineVersion}\|{canonicalInputs}\|{canonicalParams}") |
| `sceneId` | Lowercase hex | 64 | SHA256("WMSCENE/v0.0.1\|{sortedPaths joined by ;}") |
| `eventId` | `{traceId}:{eventIndex}` | Variable | `eventIndex` must be 0-1,000,000, no leading zeros except "0" |
| `policyHash` | Lowercase hex | 64 | Must not contain `\|` |
| `pipelineVersion` | String | >0 | Must not contain `\|` or control chars (< 0x20, = 0x7F) |

#### 1.3 Event Types

| Event Type | JSON Key | Required Fields | Forbidden Fields |
|------------|----------|----------------|------------------|
| `trace_start` | `"event_start"` | `traceId`, `sceneId`, `eventId`, `policyHash`, `pipelineVersion` | `metrics`, `actionType`, `artifactRef` |
| `action_step` | `"action_step"` | `actionType`, `eventId` (index > 0) | `metrics`, `artifactRef`, non-empty `paramsSummary`, `inputs` |
| `trace_end` | `"trace_end"` | `metrics` (success=true), `eventId` | `errorCode`, `actionType`, non-empty `inputs`, non-empty `paramsSummary` |
| `trace_fail` | `"trace_fail"` | `metrics` (success=false), `errorCode`, `eventId` | `qualityScore`, `actionType`, `artifactRef`, non-empty `inputs`, non-empty `paramsSummary` |

---

## Validation Priority

Validation follows strict priority order (fail fast):

1. **Priority 1: Schema Validation**
   - Schema version, ID formats, entry type consistency

2. **Priority 2: Deep Field Validation**
   - Input paths, content hashes, metrics ranges, artifact refs, paramsSummary

3. **Priority 3: Sequence Validation**
   - Trace lifecycle state machine (start → step → end/fail)

4. **Priority 4: Field Constraints by Event Type**
   - Event-specific required/forbidden field rules

5. **Priority 5: Cross-Event Consistency**
   - `traceId`, `sceneId`, `policyHash` must match across events
   - `eventId` index must match committed event count

---

## Trace Lifecycle State Machine

### Valid Sequences

| Sequence | Description |
|----------|-------------|
| `start → end` | Minimal successful trace |
| `start → step → end` | Trace with actions |
| `start → fail` | Failed trace (no actions) |
| `start → step → fail` | Failed trace (after actions) |

### Invalid Sequences (Rejected)

- `step` without `start`
- `end` without `start`
- `fail` without `start`
- `end` after `fail`
- `fail` after `end`
- `fail` after `fail`
- `step` after `end`/`fail`
- Duplicate `start`

---

## Deterministic ID Generation

### Trace ID Formula

```
SHA256("WMTRACE/v0.0.1|{policyHash}|{pipelineVersion}|{canonicalInputs}|{canonicalParams}")
```

**Inputs**:
- Sorted by path (lexicographic)
- Format: `{path}|{contentHash}|{byteSize};` (repeated)
- `contentHash` and `byteSize` are optional

**ParamsSummary**:
- Canonical JSON encoding (sorted keys, UTF-8 byte order)
- Format: `{"key1":"value1","key2":"value2"}`

### Scene ID Formula

```
SHA256("WMSCENE/v0.0.1|{sortedPaths joined by ;}")
```

**Paths**: Sorted lexicographically before joining

### Event ID Format

```
{traceId}:{eventIndex}
```

**Index Rules**:
- `trace_start`: Always 0
- Subsequent events: Incremental (1, 2, 3, ...)
- Maximum: 1,000,000
- No leading zeros (except "0" itself)
- No `+` prefix

---

## Field Constraints Matrix

| Field | `trace_start` | `action_step` | `trace_end` | `trace_fail` |
|-------|--------------|---------------|-------------|--------------|
| `metrics` | ❌ Forbidden | ❌ Forbidden | ✅ Required | ✅ Required |
| `metrics.success` | N/A | N/A | ✅ Must be `true` | ✅ Must be `false` |
| `metrics.errorCode` | N/A | N/A | ❌ Forbidden | ✅ Required (non-empty) |
| `metrics.qualityScore` | N/A | N/A | ⚪ Optional [0.0, 1.0] | ❌ Forbidden |
| `actionType` | ❌ Forbidden | ✅ Required | ❌ Forbidden | ❌ Forbidden |
| `artifactRef` | ❌ Forbidden | ❌ Forbidden | ⚪ Optional | ❌ Forbidden |
| `inputs` | ⚪ Optional | ⚪ Optional | ✅ Must be empty | ✅ Must be empty |
| `paramsSummary` | ⚪ Optional (non-empty allowed) | ✅ Must be empty | ✅ Must be empty | ✅ Must be empty |

---

## Input Validation Rules

### Input Path
- **Empty**: Rejected
- **Length**: ≤ 2048 characters
- **Forbidden Chars**: `|`, `;`, `\n`, `\r`, `\t`
- **Duplicates**: Rejected (by path)

### Input Content Hash
- **Length**: Exactly 64 (if present)
- **Format**: Lowercase hex
- **Optional**: Yes

### Input Byte Size
- **Range**: ≥ 0 (if present)
- **Optional**: Yes

---

## Metrics Validation Rules

### Elapsed Milliseconds (`elapsedMs`)
- **Range**: [0, 604,800,000] (0 to 7 days)
- **Required**: Yes (for `trace_end` and `trace_fail`)

### Quality Score (`qualityScore`)
- **Range**: [0.0, 1.0]
- **Type**: Finite `Double`
- **Required**: No (only for `trace_end`)

### Error Code (`errorCode`)
- **Length**: 1-64 characters (if present)
- **Required**: Yes (for `trace_fail`)
- **Forbidden**: Yes (for `trace_end`)

---

## Artifact Reference Validation

### Format
- **Empty String**: Rejected
- **Whitespace Only**: Rejected
- **Length**: ≤ 2048 characters
- **Control Chars**: Forbidden (except tab `0x09`)
- **Allowed Events**: `trace_end` only

---

## ParamsSummary Validation

### Keys
- **Empty**: Rejected
- **Pipe (`|`)**: Forbidden

### Values
- **Pipe (`|`)**: Forbidden

### Encoding
- **Format**: Canonical JSON
- **Key Order**: UTF-8 byte lexicographic order
- **Escaping**: JSON standard (`"`, `\`, `\n`, `\r`, `\t`, control chars as `\u00XX`)

---

## Two-Phase Commit Protocol

### Phase 1: Validate
- Updates **pending** state
- Does NOT modify **committed** state
- Returns `ValidationError?`

### Phase 2: Commit or Rollback
- **Commit**: Copies pending → committed (after successful append)
- **Rollback**: Reverts pending → committed (after failed append)

### State Anchors (Set on `trace_start`)
- `traceId` (immutable after start)
- `sceneId` (immutable after start)
- `policyHash` (immutable after start)

---

## Orphan Trace Detection

### Definition
A trace is **orphan** if:
- `hasStarted == true`
- `isComplete == false`

### Reporting
- **Orphan Report**: Contains `traceId`, `committedEventCount`, `lastEventType`
- **Not Orphan**: After successful `trace_end` or `trace_fail` commit

---

## Canonical JSON Encoding

### Key Ordering
- UTF-8 byte lexicographic order (not Swift String comparison)
- Example: `{"a":"1","z":"2"}` (not `{"z":"2","a":"1"}`)

### Escaping Rules
- `"` → `\"`
- `\` → `\\`
- `\n` → `\\n`
- `\r` → `\\r`
- `\t` → `\\t`
- `/` → NOT escaped
- Control chars (< 0x20, = 0x7F) → `\u00XX` (uppercase hex)

---

## Banned Patterns

The following patterns are **forbidden** in `Core/Audit`:

- `UUID` / `NSUUID` (use deterministic ID generation)
- `random()` / `arc4random` (non-deterministic)
- `Date()` (use `WallClock.now()`)
- `print()` / `NSLog()` / `os_log()` (no logging)
- `@unchecked Sendable` (unsafe concurrency)
- `FileManager` (use dependency injection)

---

## JSON Encoding (CodingKeys)

### Legacy Fields (Backward Compat)
- `eventType` → JSON key: `"legacyEventType"`
- `detailsJson` → JSON key: `"detailsJson"`
- `detailsSchemaVersion` → JSON key: `"detailsSchemaVersion"`

### PR#8.5 Fields
- `pr85EventType` → JSON key: `"eventType"`
- All other PR#8.5 fields use their property names

---

## Cross-Platform Compatibility

### SHA256 Implementation
- **macOS/iOS**: `CryptoKit` (`import CryptoKit`)
- **Linux**: `swift-crypto` (`import Crypto`)
- Encapsulated in `TraceIdGenerator.sha256Hex()`

---

## Version Information

- **Contract Version**: v0.0.1
- **Schema Version**: 1
- **Constitutional Prompt**: v7.1.0 (Contradiction Patch Release)

---

## Related Documents

- [AUDIT_SPEC.md](AUDIT_SPEC.md) - General audit specification
- [DETERMINISM_SPEC.md](DETERMINISM_SPEC.md) - Determinism requirements
- [FP1_v1.3.10.md](FP1_v1.3.10.md) - Supreme specification

---

## Implementation Files

### Core
- `Core/Audit/AuditEventType.swift`
- `Core/Audit/AuditActionType.swift`
- `Core/Audit/InputDescriptor.swift`
- `Core/Audit/TraceMetrics.swift`
- `Core/Audit/CanonicalJSONEncoder.swift`
- `Core/Audit/TraceIdGenerator.swift`
- `Core/Audit/TraceValidator.swift`
- `Core/Audit/AuditTraceEmitter.swift`
- `Core/Audit/OrphanTraceReport.swift`
- `Core/Audit/AuditEntry.swift` (modified)
- `Core/Utils/Clock.swift` (modified)
- `Core/BuildMeta/BuildMeta.swift` (modified)

### Tests
- `Tests/Audit/AuditTraceContractTests.swift` (108 tests)
- `Tests/Audit/AuditTraceContractTests_Smoke.swift`
- `Tests/Audit/AuditStaticLintTests.swift` (3 tests)
- `Tests/Audit/TestHelpers/InMemoryAuditLog.swift`
- `Tests/Audit/TestHelpers/AuditTraceTestFactories.swift`

