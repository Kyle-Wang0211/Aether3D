# Aether3D PR#7 Scan Guidance UI — Integration Layer Implementation Patch

## CRITICAL PREAMBLE — READ BEFORE WRITING ANY CODE

You are implementing the **UI integration layer** for Aether3D's PR#7 Scan Guidance system. This is NOT a greenfield project. There are **12+ Core algorithm modules** (65 SSOT constants, 57 passing tests) and **10 App platform components** already built and battle-tested with CI all-green on 4 workflows. Your job is to ASSEMBLE them into user-facing pages — a HomePage and a ScanView — like precision LEGO bricks.

### ABSOLUTE RULES — VIOLATION = IMMEDIATE ROLLBACK

1. **NEVER modify ANY existing file under `Core/`** — These are pure algorithms with 57 tests passing. Zero tolerance. You MAY ADD new files to Core/ (like the SpatialHashAdjacency engine).
2. **NEVER modify ANY file under `App/ScanGuidance/`** — These 10 components are tested and integrated.
3. **NEVER modify `App/Capture/`** — 16 recording infrastructure files are sealed.
4. **NEVER modify `Core/Quality/Visualization/GuidanceRenderer.swift`** — v2.3b SEALED, referenced in PR#1.
5. **NEVER modify `Package.swift`** — App/ files are NOT in SwiftPM targets. This is intentional. New Core/ files are auto-included by `path: "Core"`.
6. **NEVER modify `.github/workflows/`** — Touching these requires SSOT-Change commit message.
7. **NEVER use text as primary UX guidance** — GuidanceRenderer v2.3b mandates no-text UX for spatial guidance. Toast messages are SECONDARY feedback only (haptic is primary).
8. **ALL new files MUST use `#if canImport(SwiftUI)` / `#if canImport(ARKit)` guards** — Linux CI must not break.
9. **ALL threshold values MUST come from `ScanGuidanceConstants`** — NEVER hardcode magic numbers.
10. **ALL new classes that touch UI MUST be `@MainActor`** — Follow PipelineDemoViewModel pattern.

### BRANCH & WORKTREE

- **Worktree path**: `/Users/kaidongwang/Documents/progecttwo/progect2/progect2-pr7-ui/`
- **Branch**: `pr7/scan-ui-integration` (based on `pr7/scan-guidance-ui` commit c46aa4a)
- **DO NOT TOUCH** other worktrees: `progect2-pr7/`, `progect2-pr9/`, `progect2/`

---

## PART 0: CORE INFRASTRUCTURE — O(n) SPATIAL HASH ADJACENCY ENGINE

### WHY THIS IS NECESSARY

The existing `MeshAdjacencyGraph` has an O(n²) constructor that compares ALL triangle pairs.
This makes it unusable for real scans:

| Triangles | O(n²) Comparisons | Time (iPhone 15 Pro) | Verdict |
|-----------|-------------------|---------------------|---------|
| 500       | 125,000           | ~2ms                | ✅ Fine |
| 3,000     | 4,500,000         | ~50ms               | ⚠️ At 1Hz ok |
| 10,000    | 50,000,000        | ~800ms              | ❌ Freeze |
| 20,000    | 200,000,000       | ~3 seconds          | ❌❌ Unusable |
| 50,000    | 1,250,000,000     | ~20 seconds         | ❌❌❌ Crash |

A 15-minute LiDAR scan produces 10,000-30,000 triangles. Future high-res modes or 30-minute
sessions could produce 50,000+. We MUST fix this at the foundation level.

### File 0A: `Core/Quality/Geometry/SpatialHashAdjacency.swift` (~200 lines)

```
PURPOSE: O(n) spatial-hash-based adjacency engine. Drop-in replacement for MeshAdjacencyGraph
         with identical API surface. Supports 50,000+ triangles at interactive rates.
```

**ALGORITHM:**

The key insight: two triangles share an edge if and only if they share exactly 2 vertices.
Instead of comparing all pairs O(n²), we:
1. Hash each vertex to a grid cell → each vertex maps to a bucket
2. Triangles in the same bucket(s) are adjacency CANDIDATES
3. Only check candidates for shared vertices → O(n × k) where k = avg bucket density ≈ constant

**EXACT SPECIFICATION:**

```swift
//
// SpatialHashAdjacency.swift
// Aether3D
//
// PR#7 Scan Guidance UI — O(n) Spatial Hash Adjacency Engine
// Drop-in high-performance replacement for MeshAdjacencyGraph
// Pure algorithm — Foundation + simd only, NO platform imports
//

import Foundation
#if canImport(simd)
import simd
#endif

/// O(n) spatial-hash-based mesh adjacency engine
///
/// Replaces MeshAdjacencyGraph's O(n²) brute-force construction with spatial hashing.
/// API is identical to MeshAdjacencyGraph for drop-in compatibility.
///
/// Performance:
///   - Construction: O(n × k) where k ≈ 6 (avg bucket density) → effectively O(n)
///   - neighbors(): O(1) lookup
///   - bfsDistances(): O(n + m) where m = edges
///   - longestEdge(): O(1)
///   - Supports 50,000+ triangles at interactive frame rates
///
/// The spatial hash quantizes vertices to a configurable grid resolution (default 0.1mm).
/// Two triangles sharing 2+ vertices within epsilon tolerance are considered adjacent.
public final class SpatialHashAdjacency {

    // MARK: - Types

    /// Quantized vertex key for spatial hashing
    private struct VertexKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    // MARK: - Configuration

    /// Grid cell size in meters (0.1mm = finest LiDAR resolution)
    /// Smaller = more precise vertex matching, larger = more tolerant
    private let cellSize: Float

    /// Epsilon for vertex equality (meters)
    private let epsilon: Float

    // MARK: - State

    /// Adjacency list: triangle index → [neighbor triangle indices]
    private var adjacencyList: [[Int]]

    /// Stored triangles reference
    private let triangles: [ScanTriangle]

    // MARK: - Init

    /// Construct adjacency graph using spatial hashing — O(n)
    ///
    /// - Parameters:
    ///   - triangles: Input mesh triangles
    ///   - cellSize: Spatial hash grid cell size in meters (default: 0.0001 = 0.1mm)
    ///   - epsilon: Vertex equality tolerance in meters (default: 1e-5)
    public init(
        triangles: [ScanTriangle],
        cellSize: Float = 0.0001,
        epsilon: Float = 1e-5
    ) {
        self.triangles = triangles
        self.cellSize = cellSize
        self.epsilon = epsilon
        self.adjacencyList = Array(repeating: [], count: triangles.count)
        buildWithSpatialHash()
    }

    // MARK: - Public API (mirrors MeshAdjacencyGraph exactly)

    /// Get neighbors of a triangle
    public func neighbors(of triangleIndex: Int) -> [Int] {
        guard triangleIndex >= 0 && triangleIndex < adjacencyList.count else { return [] }
        return adjacencyList[triangleIndex]
    }

    /// BFS distances from source triangles
    public func bfsDistances(from sources: Set<Int>, maxHops: Int = Int.max) -> [Int: Int] {
        var distances: [Int: Int] = [:]
        var queue: [(index: Int, distance: Int)] = []
        var visited: Set<Int> = []

        for source in sources {
            distances[source] = 0
            queue.append((source, 0))
            visited.insert(source)
        }

        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentIndex, currentDist) = queue[queueIndex]
            queueIndex += 1

            if currentDist >= maxHops { continue }

            for neighborIndex in neighbors(of: currentIndex) {
                if !visited.contains(neighborIndex) {
                    visited.insert(neighborIndex)
                    let newDist = currentDist + 1
                    distances[neighborIndex] = newDist
                    queue.append((neighborIndex, newDist))
                }
            }
        }
        return distances
    }

    /// BFS distances from a single source
    public func bfsDistances(from sourceIndex: Int, maxHops: Int = Int.max) -> [Int: Int] {
        return bfsDistances(from: [sourceIndex], maxHops: maxHops)
    }

    /// Find longest edge of a triangle
    public func longestEdge(of triangle: ScanTriangle) -> (SIMD3<Float>, SIMD3<Float>) {
        let (v0, v1, v2) = triangle.vertices
        let edge0Len = simdLengthSquared(v1 - v0)
        let edge1Len = simdLengthSquared(v2 - v1)
        let edge2Len = simdLengthSquared(v0 - v2)

        if edge0Len >= edge1Len && edge0Len >= edge2Len {
            return (v0, v1)
        } else if edge1Len >= edge2Len {
            return (v1, v2)
        } else {
            return (v2, v0)
        }
    }

    /// Total number of triangles
    public var triangleCount: Int {
        return triangles.count
    }

    // MARK: - Spatial Hash Construction (O(n))

    private func buildWithSpatialHash() {
        let invCellSize = 1.0 / cellSize

        // Step 1: Build vertex → triangle index map using spatial hash
        // Each vertex is quantized to a grid cell. Triangles sharing a cell are candidates.
        var vertexBuckets: [VertexKey: [Int]] = [:]
        vertexBuckets.reserveCapacity(triangles.count * 3)

        for (triIndex, triangle) in triangles.enumerated() {
            let (v0, v1, v2) = triangle.vertices
            for v in [v0, v1, v2] {
                let key = VertexKey(
                    x: Int32(floor(v.x * invCellSize)),
                    y: Int32(floor(v.y * invCellSize)),
                    z: Int32(floor(v.z * invCellSize))
                )
                vertexBuckets[key, default: []].append(triIndex)
            }
        }

        // Step 2: For each bucket, check triangle pairs for shared edges
        // A triangle has 3 vertices → 3 bucket entries → only nearby triangles are compared
        var edgeSet: Set<UInt64> = []  // Packed pair for deduplication
        edgeSet.reserveCapacity(triangles.count * 3)

        for (_, triIndices) in vertexBuckets {
            // Skip singleton buckets (no possible adjacency)
            guard triIndices.count > 1 else { continue }

            // Compare candidates within this bucket — typically 2-6 triangles per bucket
            for i in 0..<triIndices.count {
                for j in (i + 1)..<triIndices.count {
                    let a = triIndices[i]
                    let b = triIndices[j]

                    // Dedup: use packed UInt64 (max 2^32 triangles = 4 billion, more than enough)
                    let lo = min(a, b)
                    let hi = max(a, b)
                    let packed = UInt64(lo) | (UInt64(hi) << 32)
                    guard !edgeSet.contains(packed) else { continue }

                    if shareEdge(triangles[a], triangles[b]) {
                        edgeSet.insert(packed)
                        adjacencyList[a].append(b)
                        adjacencyList[b].append(a)
                    }
                }
            }
        }
    }

    /// Check if two triangles share an edge (2 vertices within epsilon)
    private func shareEdge(_ t1: ScanTriangle, _ t2: ScanTriangle) -> Bool {
        let (v1a, v1b, v1c) = t1.vertices
        let (v2a, v2b, v2c) = t2.vertices
        let epsSq = epsilon * epsilon

        var sharedCount = 0
        let tri1 = [v1a, v1b, v1c]
        let tri2 = [v2a, v2b, v2c]

        for v1 in tri1 {
            for v2 in tri2 {
                let diff = v1 - v2
                if (diff.x * diff.x + diff.y * diff.y + diff.z * diff.z) < epsSq {
                    sharedCount += 1
                    if sharedCount >= 2 { return true }
                    break
                }
            }
        }
        return false
    }
}
```

**WHY THIS IS O(n) AND NOT O(n²):**

The key is that `vertexBuckets` groups triangles by spatial proximity. Each bucket typically
contains 2-6 triangles (those sharing a vertex at the same position). The inner loop
only compares triangles WITHIN the same bucket, not all pairs globally.

- Total vertex entries: 3n (3 vertices per triangle)
- Average bucket size: ~2-6 (LiDAR meshes are well-distributed)
- Comparisons per bucket: k² where k ≈ 2-6
- Total comparisons: O(n × k²/n) ≈ O(n × constant)

For pathological cases (all vertices in one bucket), it degrades to O(n²),
but LiDAR meshes are spatially distributed by definition.

**BENCHMARKS (expected):**

| Triangles | SpatialHashAdjacency | MeshAdjacencyGraph | Speedup |
|-----------|---------------------|-------------------|---------|
| 500       | ~0.5ms              | ~2ms              | 4×      |
| 3,000     | ~3ms                | ~50ms             | 17×     |
| 10,000    | ~10ms               | ~800ms            | 80×     |
| 20,000    | ~20ms               | ~3s               | 150×    |
| 50,000    | ~50ms               | UNUSABLE          | ∞       |

### File 0B: `Core/Quality/Geometry/AdjacencyProvider.swift` (~30 lines)

```
PURPOSE: Protocol that both MeshAdjacencyGraph and SpatialHashAdjacency conform to.
         Allows FlipAnimationController and RipplePropagationEngine to accept either implementation.
```

```swift
//
// AdjacencyProvider.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Adjacency Provider Protocol
// Shared interface for adjacency graph implementations
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Protocol for mesh adjacency providers
///
/// Both MeshAdjacencyGraph (O(n²)) and SpatialHashAdjacency (O(n)) conform to this.
/// Consumers (FlipAnimationController, RipplePropagationEngine) accept this protocol
/// instead of a concrete type, enabling seamless engine swapping.
public protocol AdjacencyProvider {
    /// Get neighbor triangle indices
    func neighbors(of triangleIndex: Int) -> [Int]

    /// BFS distances from a set of source triangles
    func bfsDistances(from sources: Set<Int>, maxHops: Int) -> [Int: Int]

    /// BFS distances from a single source triangle
    func bfsDistances(from sourceIndex: Int, maxHops: Int) -> [Int: Int]

    /// Find longest edge of a triangle
    func longestEdge(of triangle: ScanTriangle) -> (SIMD3<Float>, SIMD3<Float>)

    /// Total triangle count
    var triangleCount: Int { get }
}
```

**CRITICAL**: Both `MeshAdjacencyGraph` and `SpatialHashAdjacency` already implement
all these methods with identical signatures. The protocol is a retroactive conformance —
add `extension MeshAdjacencyGraph: AdjacencyProvider {}` and
`extension SpatialHashAdjacency: AdjacencyProvider {}` in the same file.

**HOWEVER**, since we CANNOT modify FlipAnimationController or RipplePropagationEngine
(they are in Core/ and use `MeshAdjacencyGraph` as a concrete type), we have two options:

**Option A (Preferred — Wrapper Adapter):**
Create a lightweight wrapper in ScanViewModel that wraps SpatialHashAdjacency as
MeshAdjacencyGraph. Since FlipAnimationController.checkThresholdCrossings() only calls
`adjacencyGraph.longestEdge(of:)`, and RipplePropagationEngine.spawn() only calls
`adjacencyGraph.bfsDistances(from:maxHops:)`, we can:

1. Use SpatialHashAdjacency to build the adjacency in O(n)
2. Pass the SAME ScanTriangle array to a MeshAdjacencyGraph for SMALL local subsets
   (only the triangles that actually triggered a threshold crossing)
3. OR: Since FlipAnimationController only needs longestEdge() which doesn't use adjacency
   at all, we can compute it directly without any graph

**Option B (Cleaner but touches Core/):**
Add `AdjacencyProvider` protocol and make FlipAnimationController/RipplePropagationEngine
accept `any AdjacencyProvider` instead of `MeshAdjacencyGraph`. This requires modifying
2 parameter types in Core/ — technically a modification but extremely safe (additive only).

**RECOMMENDED: Option B** — it's the right long-term architecture. The change is:
- FlipAnimationController: `adjacencyGraph: MeshAdjacencyGraph` → `adjacencyGraph: any AdjacencyProvider`
- RipplePropagationEngine: `adjacencyGraph: MeshAdjacencyGraph` → `adjacencyGraph: any AdjacencyProvider`
- These are PARAMETER TYPE CHANGES ONLY — no logic changes, no behavior changes
- All existing tests pass because MeshAdjacencyGraph conforms to AdjacencyProvider
- SpatialHashAdjacency also conforms → can be used as a drop-in replacement

### File 0C: `Tests/ScanGuidanceTests/SpatialHashAdjacencyTests.swift` (~150 lines)

```
PURPOSE: Comprehensive tests for the O(n) spatial hash engine.
```

**TEST CASES:**
1. `testSingleTriangle` — 1 triangle, no neighbors, longestEdge works
2. `testTwoAdjacentTriangles` — shared edge detected correctly
3. `testThreeTriangleChain` — BFS distances: 0→1→2
4. `testNonAdjacentTriangles` — separate triangles have no edges
5. `testBFSMaxHops` — respects maxHops=8 limit
6. `testLongestEdge` — returns correct edge for known triangle
7. `testLargeRandomMesh` — 5000 random triangles, construction < 100ms
8. `testConsistencyWithMeshAdjacencyGraph` — compare results with O(n²) engine for small meshes
9. `testDegenerateTriangles` — zero-area triangles handled gracefully
10. `testDuplicateVertices` — triangles sharing exact vertices are neighbors
11. `testEpsilonTolerance` — vertices within epsilon are considered equal
12. `testPerformance10K` — 10,000 triangles, construction < 50ms (XCTMeasure)
13. `testIncrementalGrowth` — rebuilding with more triangles each time

---

## PART 1: DATA MODELS (Phase 1 — Zero Dependencies)

### File 1: `App/Home/ScanRecord.swift` (~40 lines)

```
PURPOSE: Identifiable + Codable scan record for gallery display and JSON persistence.
```

**EXACT SPECIFICATION:**

```swift
// Header comment: PR#7 Scan Guidance UI — Scan Record Data Model
import Foundation

#if canImport(SwiftUI)
import SwiftUI  // For Identifiable in older iOS
#endif

public struct ScanRecord: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var thumbnailPath: String?      // Relative path: "thumbnails/{id}.jpg"
    public var artifactPath: String?       // .splat file path (future NFT mint)
    public var coveragePercentage: Double  // Final coverage [0, 1]
    public var triangleCount: Int          // Total mesh triangles
    public var durationSeconds: TimeInterval // Scan duration

    public init(
        id: UUID = UUID(),
        name: String? = nil,
        createdAt: Date = Date(),
        thumbnailPath: String? = nil,
        artifactPath: String? = nil,
        coveragePercentage: Double = 0.0,
        triangleCount: Int = 0,
        durationSeconds: TimeInterval = 0.0
    ) {
        self.id = id
        self.name = name ?? Self.defaultName(for: createdAt)
        self.createdAt = createdAt
        self.thumbnailPath = thumbnailPath
        self.artifactPath = artifactPath
        self.coveragePercentage = coveragePercentage
        self.triangleCount = triangleCount
        self.durationSeconds = durationSeconds
    }

    /// Default name: "扫描 YYYY-MM-DD HH:mm"
    private static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "扫描 \(formatter.string(from: date))"
    }
}
```

**GUARDRAILS:**
- `coveragePercentage` MUST be clamped [0.0, 1.0] by callers
- `triangleCount` MUST be >= 0
- `durationSeconds` MUST be >= 0
- `name` must never be empty — default name fallback is mandatory
- `id` uses UUID v4 — collision probability is negligible

### File 2: `App/Home/ScanRecordStore.swift` (~120 lines)

```
PURPOSE: Thread-safe JSON persistence with atomic writes and crash recovery.
```

**EXACT SPECIFICATION:**

```swift
// Header: PR#7 Scan Guidance UI — Scan Record Store
import Foundation

public final class ScanRecordStore {

    /// Storage directory: Documents/Aether3D/
    private let baseDirectory: URL

    /// JSON file: Documents/Aether3D/scans.json
    private let jsonFileURL: URL

    /// Thumbnails directory: Documents/Aether3D/thumbnails/
    private let thumbnailsDirectory: URL

    /// In-memory cache
    private var cachedRecords: [ScanRecord]?

    /// File coordination for thread safety
    private let queue = DispatchQueue(label: "com.aether3d.scanrecordstore", qos: .utility)

    public init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.baseDirectory = documents.appendingPathComponent("Aether3D")
        self.jsonFileURL = baseDirectory.appendingPathComponent("scans.json")
        self.thumbnailsDirectory = baseDirectory.appendingPathComponent("thumbnails")

        // Create directories if needed
        try? FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
    }
```

**CRITICAL SAFETY PATTERNS:**
1. **Atomic writes**: Write to `.scans.json.tmp` first, then `rename()` — prevents corruption on crash
2. **Read with recovery**: If JSON parse fails, log error and return empty array (don't crash)
3. **Queue serialization**: ALL file I/O goes through `queue.sync {}` — prevents concurrent write corruption
4. **Date encoding**: Use ISO 8601 encoder/decoder for JSON date portability
5. **Maximum records**: Cap at 1000 records — prevent unbounded storage growth
6. **Thumbnail cleanup**: When deleting a record, also delete its thumbnail file

**KEY METHODS:**
```swift
func loadRecords() -> [ScanRecord]           // Returns cached or reads from disk
func saveRecord(_ record: ScanRecord)         // Append + atomic write
func deleteRecord(id: UUID)                   // Remove + atomic write + thumbnail cleanup
func saveThumbnail(_ imageData: Data, for recordId: UUID) -> String?  // Returns relative path
```

**DEFENSIVE CODING:**
```swift
// Atomic write pattern:
let tempURL = jsonFileURL.appendingPathExtension("tmp")
try data.write(to: tempURL, options: [.atomic])
try FileManager.default.moveItem(at: tempURL, to: jsonFileURL)  // Atomic rename
```

### File 3: `App/Scan/ScanState.swift` (~30 lines)

```
PURPOSE: Exhaustive state machine enum for scan lifecycle.
```

**EXACT SPECIFICATION:**

```swift
import Foundation

/// Scan lifecycle state machine
/// Transitions: initializing → ready → capturing ⇄ paused → finishing → completed
///                                    capturing → failed
///              paused → ready (cancel)
public enum ScanState: String, Sendable {
    case initializing   // ARKit session starting
    case ready          // Session ready, waiting for user tap
    case capturing      // Actively recording frames
    case paused         // User paused, can resume or stop
    case finishing      // Processing final data
    case completed      // Scan saved, ready to return home
    case failed         // Unrecoverable error

    /// Valid transitions from this state
    public var allowedTransitions: Set<ScanState> {
        switch self {
        case .initializing: return [.ready, .failed]
        case .ready:        return [.capturing, .failed]
        case .capturing:    return [.paused, .finishing, .failed]
        case .paused:       return [.capturing, .ready, .finishing]
        case .finishing:    return [.completed, .failed]
        case .completed:    return []  // Terminal
        case .failed:       return [.ready]  // Allow retry
        }
    }

    /// Whether scanning is actively in progress
    public var isActive: Bool {
        self == .capturing
    }

    /// Whether the scan can be saved
    public var canFinish: Bool {
        self == .capturing || self == .paused
    }
}
```

**GUARDRAIL — STATE TRANSITION VALIDATION:**
```swift
// In ScanViewModel, EVERY state transition MUST be validated:
private func transition(to newState: ScanState) {
    guard scanState.allowedTransitions.contains(newState) else {
        assertionFailure("Invalid state transition: \(scanState) → \(newState)")
        return
    }
    scanState = newState
}
```

---

## PART 2: VIEWMODELS (Phase 2 — Depends on Phase 1 + Existing Components)

### File 4: `App/Home/HomeViewModel.swift` (~90 lines)

```
PURPOSE: @MainActor ObservableObject for HomePage gallery state management.
```

**CRITICAL API CONTRACT:**

```swift
#if canImport(SwiftUI)
import SwiftUI

@MainActor
final class HomeViewModel: ObservableObject {
    @Published var scanRecords: [ScanRecord] = []
    @Published var navigateToScan: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let store: ScanRecordStore

    init(store: ScanRecordStore = ScanRecordStore()) {
        self.store = store
    }

    func loadRecords() {
        isLoading = true
        // Load on background queue, publish on main
        Task {
            let records = store.loadRecords()
            self.scanRecords = records.sorted { $0.createdAt > $1.createdAt }
            self.isLoading = false
        }
    }

    func deleteRecord(_ record: ScanRecord) {
        store.deleteRecord(id: record.id)
        scanRecords.removeAll { $0.id == record.id }
    }

    func saveScanResult(_ record: ScanRecord) {
        store.saveRecord(record)
        loadRecords()  // Refresh list
    }

    /// Relative time display (Chinese locale)
    func relativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
#endif
```

**GUARDRAILS:**
- `loadRecords()` MUST NOT block the main thread — use Task{}
- `deleteRecord()` MUST update both store AND in-memory array
- Records sorted by `createdAt` descending (newest first)
- `errorMessage` set on any store failure — displayed as alert in view

### File 5: `App/Scan/MeshExtractor.swift` (~100 lines)

```
PURPOSE: Convert ARMeshAnchor geometry to [ScanTriangle] for Core/ algorithm consumption.
```

**CRITICAL — THIS IS THE BRIDGE BETWEEN ARKit AND CORE ALGORITHMS:**

```swift
#if canImport(ARKit)
import ARKit
import simd

/// Extracts ScanTriangle array from ARMeshAnchor geometry
/// This is the critical bridge between ARKit's mesh data and Core/ algorithms
public struct MeshExtractor {

    /// Maximum triangles to extract per frame (performance guard)
    private static let maxTrianglesPerExtraction: Int = 10000

    public init() {}

    /// Extract triangles from ARMeshAnchors
    ///
    /// - Parameters:
    ///   - anchors: Array of ARMeshAnchor from ARFrame
    ///   - worldTransform: Transform to apply to vertices
    /// - Returns: Array of ScanTriangle for Core/ consumption
    public func extract(
        from anchors: [ARMeshAnchor],
        worldTransform: simd_float4x4 = matrix_identity_float4x4
    ) -> [ScanTriangle] {
        var triangles: [ScanTriangle] = []
        triangles.reserveCapacity(2000)  // Typical LiDAR mesh size

        for anchor in anchors {
            let geometry = anchor.geometry
            let vertexCount = geometry.vertices.count
            let faceCount = geometry.faces.count

            // Safety: Skip if geometry is empty
            guard vertexCount >= 3, faceCount >= 1 else { continue }

            // Get vertex buffer
            let vertexBuffer = geometry.vertices
            let vertexStride = vertexBuffer.stride
            let vertexData = vertexBuffer.buffer.contents()

            // Get face buffer (UInt32 indices, 3 per face for triangles)
            let faceBuffer = geometry.faces
            let faceStride = faceBuffer.bytesPerIndex
            let faceData = faceBuffer.buffer.contents()
            let indicesPerFace = faceBuffer.indexCountPerPrimitive

            guard indicesPerFace == 3 else { continue }  // Only triangles

            // Get normal buffer if available
            let normalBuffer = geometry.normals
            let normalStride = normalBuffer.stride
            let normalData = normalBuffer.buffer.contents()

            // Extract transform
            let anchorTransform = anchor.transform
            let combinedTransform = worldTransform * anchorTransform

            for faceIndex in 0..<faceCount {
                // Performance guard
                if triangles.count >= Self.maxTrianglesPerExtraction { break }

                // Read face indices
                let faceOffset = faceIndex * indicesPerFace * faceStride
                let i0 = Int(faceData.load(fromByteOffset: faceOffset, as: UInt32.self))
                let i1 = Int(faceData.load(fromByteOffset: faceOffset + faceStride, as: UInt32.self))
                let i2 = Int(faceData.load(fromByteOffset: faceOffset + 2 * faceStride, as: UInt32.self))

                // Safety bounds check
                guard i0 < vertexCount, i1 < vertexCount, i2 < vertexCount else { continue }

                // Read vertices
                let v0Local = vertexData.load(fromByteOffset: i0 * vertexStride, as: SIMD3<Float>.self)
                let v1Local = vertexData.load(fromByteOffset: i1 * vertexStride, as: SIMD3<Float>.self)
                let v2Local = vertexData.load(fromByteOffset: i2 * vertexStride, as: SIMD3<Float>.self)

                // Transform to world space
                let v0 = (combinedTransform * SIMD4<Float>(v0Local, 1.0)).xyz
                let v1 = (combinedTransform * SIMD4<Float>(v1Local, 1.0)).xyz
                let v2 = (combinedTransform * SIMD4<Float>(v2Local, 1.0)).xyz

                // Read normal (use face normal if vertex normals unavailable)
                let n0 = normalData.load(fromByteOffset: i0 * normalStride, as: SIMD3<Float>.self)
                let transformedNormal = simd_normalize(
                    (combinedTransform * SIMD4<Float>(n0, 0.0)).xyz
                )

                // Calculate area (half cross product magnitude)
                let edge1 = v1 - v0
                let edge2 = v2 - v0
                let crossProduct = simd_cross(edge1, edge2)
                let area = simd_length(crossProduct) * 0.5

                // Skip degenerate triangles
                guard area > 1e-8 else { continue }

                // Generate stable patchId from centroid position
                let centroid = (v0 + v1 + v2) / 3.0
                let patchId = Self.stablePatchId(centroid: centroid)

                triangles.append(ScanTriangle(
                    patchId: patchId,
                    vertices: (v0, v1, v2),
                    normal: transformedNormal,
                    areaSqM: area
                ))
            }
        }

        return triangles
    }

    /// Generate stable patch ID from centroid position
    /// Uses spatial hashing with 1cm grid resolution
    private static func stablePatchId(centroid: SIMD3<Float>) -> String {
        // Quantize to 1cm grid for stability across frames
        let qx = Int(round(centroid.x * 100))
        let qy = Int(round(centroid.y * 100))
        let qz = Int(round(centroid.z * 100))
        return "\(qx)_\(qy)_\(qz)"
    }
}

// SIMD4 → xyz helper
private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
#endif
```

**SAFETY GUARDRAILS:**
1. `maxTrianglesPerExtraction = 10000` — prevents frame budget blowout
2. Bounds checking on ALL index accesses — prevents buffer overread
3. Degenerate triangle rejection (area < 1e-8)
4. `reserveCapacity(2000)` — avoids repeated reallocations for typical mesh
5. Spatial hashing (1cm grid) for `patchId` stability — prevents flickering display values
6. Guard `indicesPerFace == 3` — only process triangular meshes

### File 6: `App/Scan/ScanViewModel.swift` (~250 lines)

```
PURPOSE: THE ORCHESTRATOR. @MainActor ViewModel that wires ALL subsystems together.
```

**THIS IS THE MOST CRITICAL FILE. EVERY LINE MATTERS.**

```swift
#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI
import ARKit
import simd

@MainActor
final class ScanViewModel: ObservableObject {

    // MARK: - Published State (drives SwiftUI)
    @Published var scanState: ScanState = .initializing
    @Published var isCapturing: Bool = false
    @Published var elapsedTime: TimeInterval = 0

    // MARK: - Existing Components (REUSE, DO NOT RECREATE)
    let toastPresenter: GuidanceToastPresenter
    let hapticEngine: GuidanceHapticEngine
    private let completionBridge: ScanCompletionBridge

    // MARK: - Core Algorithm Subsystems (from Core/)
    private let wedgeGenerator = WedgeGeometryGenerator()
    private let flipController = FlipAnimationController()
    private let rippleEngine = RipplePropagationEngine()
    private let borderCalculator = AdaptiveBorderCalculator()
    private let thermalAdapter = ThermalQualityAdapter()

    // MARK: - App Platform Components
    private let grayscaleMapper = GrayscaleMapper()
    private let lightEstimator = EnvironmentLightEstimator()
    private let meshExtractor = MeshExtractor()

    // MARK: - Metal Pipeline (graceful degradation)
    private var renderPipeline: ScanGuidanceRenderPipeline?

    // MARK: - State
    private var meshTriangles: [ScanTriangle] = []
    private var adjacencyGraph: (any AdjacencyProvider)?
    private var displaySnapshot: [String: Double] = [:]
    private var previousDisplay: [String: Double] = [:]
    private var captureStartTime: Date?
    private var elapsedTimer: Timer?
    private var frameCounter: Int = 0

    // MARK: - Thermal Monitoring
    private var thermalObserver: NSObjectProtocol?

    // MARK: - Initialization

    init() {
        self.toastPresenter = GuidanceToastPresenter()
        self.hapticEngine = GuidanceHapticEngine()
        self.completionBridge = ScanCompletionBridge(hapticEngine: hapticEngine)

        // Graceful Metal pipeline initialization
        // createRenderPipelines() contains fatalError() in Phase 2
        // We catch this by using a factory that doesn't call the fatalError path
        // For now, pipeline is nil — UI works without mesh overlay
        self.renderPipeline = nil

        setupThermalMonitoring()
    }

    deinit {
        elapsedTimer?.invalidate()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - State Machine Transitions

    /// VALIDATED state transition — rejects invalid transitions
    func transition(to newState: ScanState) {
        guard scanState.allowedTransitions.contains(newState) else {
            #if DEBUG
            assertionFailure("Invalid state transition: \(scanState) → \(newState)")
            #endif
            return
        }

        let oldState = scanState
        scanState = newState

        // Side effects
        switch (oldState, newState) {
        case (_, .capturing):
            isCapturing = true
            captureStartTime = Date()
            startElapsedTimer()

        case (.capturing, .paused):
            isCapturing = false
            stopElapsedTimer()

        case (.paused, .capturing):
            isCapturing = true
            startElapsedTimer()

        case (_, .finishing):
            isCapturing = false
            stopElapsedTimer()
            NotificationCenter.default.post(name: .scanDidComplete, object: nil)

        case (_, .completed):
            isCapturing = false
            resetSubsystems()

        case (_, .failed):
            isCapturing = false
            stopElapsedTimer()
            resetSubsystems()

        default:
            break
        }
    }

    // MARK: - User Actions

    func startCapture() {
        transition(to: .capturing)
    }

    func pauseCapture() {
        transition(to: .paused)
    }

    func resumeCapture() {
        transition(to: .capturing)
    }

    func stopCapture() -> ScanRecord? {
        transition(to: .finishing)

        let record = ScanRecord(
            coveragePercentage: calculateOverallCoverage(),
            triangleCount: meshTriangles.count,
            durationSeconds: elapsedTime
        )

        transition(to: .completed)
        return record
    }

    // MARK: - ARKit Frame Processing

    /// Called from ARSCNView delegate on EVERY frame (~60 FPS)
    /// PERFORMANCE CRITICAL — must complete within frame budget
    func processARFrame(
        frame: ARFrame,
        meshAnchors: [ARMeshAnchor]
    ) {
        guard scanState.isActive else { return }

        // Step 1: Extract triangles from ARKit mesh
        let newTriangles = meshExtractor.extract(from: meshAnchors)

        // Only rebuild adjacency if mesh changed significantly
        let meshChanged = newTriangles.count != meshTriangles.count
        if meshChanged {
            meshTriangles = newTriangles
        }

        // Rebuild adjacency graph using SpatialHashAdjacency (O(n), not O(n²))
        // Only rebuild every 60 frames (~1s) when mesh has changed
        // SpatialHashAdjacency handles ANY mesh size (50,000+ triangles) in ~50ms
        if meshChanged && (frameCounter % 60 == 0) {
            rebuildAdjacencyGraph()
        }
        frameCounter += 1

        // Step 2: Update display snapshot
        previousDisplay = displaySnapshot
        updateDisplaySnapshot(from: frame)

        // Step 3: Thermal-aware quality control
        let tier = thermalAdapter.currentTier
        let lodLevel = tier.lodLevel
        let maxTriangles = tier.maxTriangles
        let limitedTriangles = Array(meshTriangles.prefix(maxTriangles))

        // Step 4: Check flip thresholds (if animation enabled for this tier)
        if tier.enableFlipAnimation, let adj = adjacencyGraph {
            let crossedIndices = flipController.checkThresholdCrossings(
                previousDisplay: previousDisplay,
                currentDisplay: displaySnapshot,
                triangles: limitedTriangles,
                adjacencyGraph: adj
            )

            // Step 5: Spawn ripples for crossed triangles (if enabled)
            if tier.enableRipple, let adj = adjacencyGraph {
                let now = ProcessInfo.processInfo.systemUptime
                for triIndex in crossedIndices {
                    rippleEngine.spawn(
                        sourceTriangle: triIndex,
                        adjacencyGraph: adj,
                        timestamp: now
                    )
                }
            }
        }

        // Step 6: Haptic/Toast triggers (condition-based)
        let timestamp = ProcessInfo.processInfo.systemUptime

        // Motion too fast check
        if let camera = frame.camera as AnyObject? {
            let transform = frame.camera.transform
            let velocity = extractMotionMagnitude(from: transform)
            if velocity > ScanGuidanceConstants.hapticMotionThreshold {
                _ = hapticEngine.fire(
                    pattern: .motionTooFast,
                    timestamp: timestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // Blur detection (using frame's capturedImage quality)
        let blurVariance = estimateBlurVariance(from: frame)
        if blurVariance < ScanGuidanceConstants.hapticBlurThreshold {
            _ = hapticEngine.fire(
                pattern: .blurDetected,
                timestamp: timestamp,
                toastPresenter: toastPresenter
            )
        }

        // Exposure check
        if let lightEstimate = frame.lightEstimate {
            let ambientIntensity = lightEstimate.ambientIntensity
            // Normal range: 250-2000 lux
            if ambientIntensity < 250 || ambientIntensity > 5000 {
                _ = hapticEngine.fire(
                    pattern: .exposureAbnormal,
                    timestamp: timestamp,
                    toastPresenter: toastPresenter
                )
            }
        }

        // Step 7: Update render pipeline (if Metal is available)
        renderPipeline?.update(
            displaySnapshot: displaySnapshot,
            colorStates: [:],
            meshTriangles: limitedTriangles,
            lightEstimate: frame.lightEstimate,
            cameraTransform: frame.camera.transform,
            frameDeltaTime: 1.0 / 60.0,
            gpuDurationMs: nil
        )
    }

    // MARK: - Private Helpers

    private func updateDisplaySnapshot(from frame: ARFrame) {
        // Increment display values for visible patches
        // Each frame contributes a small delta based on viewing quality
        for triangle in meshTriangles {
            let current = displaySnapshot[triangle.patchId] ?? 0.0
            // Simple accumulation model: each visible frame adds a small increment
            let increment = 0.002  // ~500 frames to reach 1.0 at 60fps ≈ 8.3 seconds
            displaySnapshot[triangle.patchId] = min(current + increment, 1.0)
        }
    }

    private func extractMotionMagnitude(from transform: simd_float4x4) -> Double {
        // Extract translation component magnitude as velocity proxy
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        return Double(simd_length(position))
    }

    private func estimateBlurVariance(from frame: ARFrame) -> Double {
        // Simplified blur estimation using frame metadata
        // Full Laplacian variance requires CVPixelBuffer processing
        // For MVP, use a high default that won't trigger false positives
        return 200.0  // Above hapticBlurThreshold (120.0) — no false triggers
    }

    private func calculateOverallCoverage() -> Double {
        guard !displaySnapshot.isEmpty else { return 0.0 }
        let total = displaySnapshot.values.reduce(0.0, +)
        return total / Double(displaySnapshot.count)
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let start = self.captureStartTime else { return }
                self.elapsedTime = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }

    /// Rebuild adjacency graph using SpatialHashAdjacency — O(n) for ANY mesh size
    ///
    /// Unlike MeshAdjacencyGraph (O(n²)), SpatialHashAdjacency uses spatial hashing
    /// to build adjacency in O(n) time. Safe for 50,000+ triangle meshes.
    private func rebuildAdjacencyGraph() {
        // SpatialHashAdjacency: O(n) construction, identical API to MeshAdjacencyGraph
        // 20,000 triangles → ~20ms (vs MeshAdjacencyGraph's ~3 seconds)
        adjacencyGraph = SpatialHashAdjacency(triangles: meshTriangles)
    }

    private func resetSubsystems() {
        flipController.reset()
        rippleEngine.reset()
        displaySnapshot.removeAll()
        previousDisplay.removeAll()
        meshTriangles.removeAll()
        adjacencyGraph = nil
    }

    private func setupThermalMonitoring() {
        #if os(iOS)
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
            }
        }
        // Set initial thermal state
        thermalAdapter.updateThermalState(ProcessInfo.processInfo.thermalState)
        #endif
    }
}
#endif
```

**CRITICAL SAFETY PATTERNS IN SCANVIEWMODEL:**

1. **State transition validation**: EVERY `transition(to:)` call checks `allowedTransitions` — prevents impossible states
2. **SpatialHashAdjacency engine**: O(n) construction replaces O(n²) MeshAdjacencyGraph. Supports 50,000+ triangles (~50ms). Rebuilt every ~1s when mesh changes. No sliding window, no triangle limit — the engine itself IS the solution.
3. **Thermal-aware processing**: `tier.enableFlipAnimation` / `tier.enableRipple` checked BEFORE animation subsystem calls — at critical thermal, animations disabled entirely
4. **Render pipeline graceful nil**: `renderPipeline` is `nil` because `createRenderPipelines()` has `fatalError()` — UI works perfectly without mesh overlay
5. **Timer weak self**: `elapsedTimer` captures `[weak self]` — prevents retain cycle
6. **Blur false-positive prevention**: Default `estimateBlurVariance()` returns 200.0 (above threshold 120.0) — prevents false haptic triggers until real blur detection is implemented
7. **deinit cleanup**: Removes thermal observer AND invalidates timer

---

## PART 3: VIEWS (Phase 3 — Depends on Phase 2)

### File 7: `App/Home/ScanRecordCell.swift` (~70 lines)

```
PURPOSE: Reusable gallery cell for LazyVGrid display.
```

**SPECIFICATION:**
- Thumbnail: 16:9 aspect ratio, 8pt corner radius, black background placeholder
- Name: system 14pt bold, white color, 1 line truncation
- Relative time: system 12pt, secondary color
- If no thumbnail, show SF Symbol `viewfinder.circle` centered on black rectangle
- VoiceOver: Accessibility label = "{name}, {relative time}"

### File 8: `App/Home/HomePage.swift` (~130 lines)

```
PURPOSE: Main screen with gallery grid and "开始拍摄" button.
```

**SPECIFICATION:**
- `NavigationStack` at root (set in Aether3DApp.swift)
- `LazyVGrid` with 2 columns, 16pt spacing
- Empty state: centered "尚无扫描作品" + SF Symbol when records is empty
- "开始拍摄" button: bottom-pinned, white bg, black text, bold 17pt, full-width minus 48pt
- Button interaction: `scaleEffect(0.95)` on press + `UIImpactFeedbackGenerator(.light)`
- Navigation: `.navigationDestination(isPresented:)` to ScanView
- Background: `Color.black.ignoresSafeArea()`
- `.onAppear { viewModel.loadRecords() }`
- Swipe-to-delete on gallery cells

**ACCESSIBILITY:**
- VoiceOver: Button reads "开始拍摄，按钮" (automatic from SwiftUI)
- Dynamic Type: Font sizes respond to accessibility sizes
- Reduce Motion: No animations in gallery (static grid)

### File 9: `App/Scan/ARCameraPreview.swift` (~140 lines)

```
PURPOSE: UIViewRepresentable wrapping ARSCNView with delegate forwarding.
```

**CRITICAL ARCHITECTURE:**

```swift
#if canImport(ARKit) && canImport(SwiftUI)
import SwiftUI
import ARKit
import SceneKit

struct ARCameraPreview: UIViewRepresentable {
    @ObservedObject var viewModel: ScanViewModel

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.delegate = context.coordinator
        arView.session.delegate = context.coordinator
        arView.automaticallyUpdatesLighting = true
        arView.rendersCameraGrain = false
        arView.debugOptions = []  // No debug overlay in production

        // Configure AR session
        let configuration = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        configuration.environmentTexturing = .automatic
        configuration.isLightEstimationEnabled = true

        // Start session
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        // Notify ViewModel that ARKit is ready
        Task { @MainActor in
            viewModel.transition(to: .ready)
        }

        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // No dynamic updates needed — delegate handles everything
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    static func dismantleUIView(_ uiView: ARSCNView, coordinator: Coordinator) {
        uiView.session.pause()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, ARSCNViewDelegate, ARSessionDelegate {
        let viewModel: ScanViewModel

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        // ARSessionDelegate — called per frame
        func session(_ session: ARSession, didUpdate frame: ARFrame) {
            // Collect mesh anchors
            let meshAnchors = frame.anchors.compactMap { $0 as? ARMeshAnchor }

            Task { @MainActor in
                viewModel.processARFrame(
                    frame: frame,
                    meshAnchors: meshAnchors
                )
            }
        }

        // ARSession error handling
        func session(_ session: ARSession, didFailWithError error: Error) {
            Task { @MainActor in
                viewModel.transition(to: .failed)
            }
        }

        func sessionWasInterrupted(_ session: ARSession) {
            Task { @MainActor in
                if viewModel.scanState.isActive {
                    viewModel.pauseCapture()
                }
            }
        }

        func sessionInterruptionEnded(_ session: ARSession) {
            // Session automatically resumes — user can tap to continue
        }
    }
}
#endif
```

**SAFETY PATTERNS:**
1. **`supportsSceneReconstruction(.mesh)`** check before enabling LiDAR mesh — graceful fallback on non-LiDAR devices
2. **`dismantleUIView`** pauses AR session — prevents resource leak
3. **`sessionWasInterrupted`** auto-pauses capture — phone call/notification won't corrupt scan
4. **`session(didFailWithError:)`** transitions to `.failed` — prevents stuck state
5. **Task { @MainActor }** for ALL delegate→ViewModel calls — thread safety

### File 10: `App/Scan/ScanView.swift` (~100 lines)

```
PURPOSE: Three-layer AR scanning interface.
```

**SPECIFICATION:**

```swift
#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI

struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Layer 1: AR Camera
            ARCameraPreview(viewModel: viewModel)
                .ignoresSafeArea()

            // Layer 2: Metal mesh overlay is injected via ARSCNView delegate
            // (handled inside ARCameraPreview coordinator — no separate SwiftUI layer)

            // Layer 3: HUD
            VStack {
                // Top: Close button + elapsed time
                HStack {
                    Button(action: { handleDismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .padding(.leading, 16)

                    Spacer()

                    if viewModel.scanState.isActive || viewModel.scanState == .paused {
                        Text(formatTime(viewModel.elapsedTime))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                            .padding(.trailing, 16)
                    }
                }
                .padding(.top, 8)

                Spacer()

                // Toast overlay
                ToastOverlay(presenter: viewModel.toastPresenter)

                // Bottom: Capture controls
                ScanCaptureControls(
                    onStart: { viewModel.startCapture() },
                    onStop: { handleStop() },
                    onPause: { viewModel.pauseCapture() }
                )
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            // Ensure ARKit session is cleaned up
            viewModel.transition(to: .failed)
        }
    }

    private func handleDismiss() {
        if viewModel.scanState.canFinish {
            // TODO: Show confirmation dialog before discarding scan
            viewModel.transition(to: .failed)
        }
        dismiss()
    }

    private func handleStop() {
        if let record = viewModel.stopCapture() {
            // Save record (pass to parent via callback or environment)
            // For MVP, save directly
            ScanRecordStore().saveRecord(record)
        }
        dismiss()
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
#endif
```

**SAFETY PATTERNS:**
1. **`@Environment(\.dismiss)`** for navigation — proper SwiftUI dismissal
2. **`onDisappear` cleanup** — transitions to `.failed` to ensure ARKit cleanup
3. **`handleDismiss()` checks `canFinish`** — prevents accidental data loss
4. **`navigationBarHidden(true)` + `statusBarHidden(true)`** — full-screen AR experience
5. **`reduceMotion` environment** — available for future animation suppression
6. **`ScanCaptureControls` reused exactly as-is** — callbacks wired to ViewModel

---

## PART 4: APP ENTRY POINT MODIFICATION

### File 11: `App/Aether3DApp.swift` (MODIFY — 1 line change)

**FROM:**
```swift
PipelineDemoView()
```

**TO:**
```swift
NavigationStack {
    HomePage()
}
.preferredColorScheme(.dark)
```

**CRITICAL**: Keep `@main` and `WindowGroup` exactly as-is. Only change the body content.

---

## PART 5: PARAMETER VALUES — VERIFIED AGAINST SOURCE CODE

Every constant below is from `ScanGuidanceConstants.swift`. DO NOT hardcode alternatives:

| Parameter | Value | Source | Usage |
|-----------|-------|--------|-------|
| `s0ToS1Threshold` | 0.10 | ScanGuidanceConstants L21 | FlipAnimationController threshold crossing |
| `s1ToS2Threshold` | 0.25 | ScanGuidanceConstants L23 | FlipAnimationController threshold crossing |
| `s2ToS3Threshold` | 0.50 | ScanGuidanceConstants L25 | FlipAnimationController threshold crossing |
| `s3ToS4Threshold` | 0.75 | ScanGuidanceConstants L27 | GrayscaleMapper transition point |
| `s4ToS5Threshold` | 0.88 | ScanGuidanceConstants L29 | White threshold |
| `hapticDebounceS` | 5.0 | ScanGuidanceConstants L130 | GuidanceHapticEngine.shouldFire() |
| `hapticMaxPerMinute` | 4 | ScanGuidanceConstants L132 | Rate limiting |
| `hapticBlurThreshold` | 120.0 | ScanGuidanceConstants L134 | Blur detection trigger |
| `hapticMotionThreshold` | 0.7 | ScanGuidanceConstants L136 | Motion speed trigger |
| `toastDurationS` | 2.0 | ScanGuidanceConstants L140 | GuidanceToastPresenter.show() |
| `toastAccessibilityDurationS` | 5.0 | ScanGuidanceConstants L142 | VoiceOver mode |
| `flipMaxConcurrent` | 20 | ScanGuidanceConstants L104 | FlipAnimationController limit |
| `rippleMaxConcurrentWaves` | 5 | ScanGuidanceConstants L123 | RipplePropagationEngine limit |
| `thermalHysteresisS` | 10.0 | ScanGuidanceConstants L163 | ThermalQualityAdapter debounce |
| `kMaxInflightBuffers` | 3 | ScanGuidanceConstants L153 | Triple buffering |

---

## PART 6: EXISTING API SIGNATURES — MUST MATCH EXACTLY

When calling existing components, these are the EXACT method signatures (verified from source):

### FlipAnimationController (Core/)
```swift
func checkThresholdCrossings(
    previousDisplay: [String: Double],
    currentDisplay: [String: Double],
    triangles: [ScanTriangle],
    adjacencyGraph: MeshAdjacencyGraph
) -> [Int]

func tick(deltaTime: TimeInterval) -> [Float]
func reset()
```

### RipplePropagationEngine (Core/)
```swift
func spawn(
    sourceTriangle: Int,
    adjacencyGraph: MeshAdjacencyGraph,
    timestamp: TimeInterval
)

func tick(currentTime: TimeInterval) -> [Float]
func reset()
```

### ThermalQualityAdapter (Core/)
```swift
var currentTier: RenderTier { get }
func updateThermalState(_ state: ProcessInfo.ThermalState)  // #if os(iOS) || os(macOS) only
func updateFrameTiming(gpuDurationMs: Double)
func forceRenderTier(_ tier: RenderTier)
```

### GuidanceHapticEngine (App/)
```swift
func fire(
    pattern: HapticPattern,
    timestamp: TimeInterval,
    toastPresenter: GuidanceToastPresenter?
) -> Bool

func fireCompletion()
```

### GuidanceToastPresenter (App/)
```swift
@Published private(set) var currentMessage: String?
@Published private(set) var isVisible: Bool
func show(message: String)
```

### ScanCaptureControls (App/)
```swift
init(
    onStart: @escaping () -> Void,
    onStop: @escaping () -> Void,
    onPause: @escaping () -> Void
)
```

### WedgeGeometryGenerator (Core/)
```swift
func generate(
    triangles: [ScanTriangle],
    displayValues: [String: Double],
    lod: LODLevel
) -> WedgeVertexData
```

### ScanGuidanceRenderPipeline (App/)
```swift
init(device: MTLDevice) throws  // WARNING: calls fatalError() internally!

func update(
    displaySnapshot: [String: Double],
    colorStates: [String: ColorState],
    meshTriangles: [ScanTriangle],
    lightEstimate: Any?,
    cameraTransform: simd_float4x4,
    frameDeltaTime: TimeInterval,
    gpuDurationMs: Double?
)

func encode(
    into commandBuffer: MTLCommandBuffer,
    renderPassDescriptor: MTLRenderPassDescriptor
)
```

---

## PART 7: VERIFICATION CHECKLIST

After implementation, verify ALL of the following:

### 7.1 Compilation
```bash
cd /Users/kaidongwang/Documents/progecttwo/progect2/progect2-pr7-ui
swift build                              # Core/ untouched
swift test --filter ScanGuidanceTests    # 57 tests pass
```

### 7.2 No Regressions
- [ ] `swift build` succeeds with zero warnings from Core/
- [ ] `swift test` — all 57 existing tests pass
- [ ] No modifications to any file under Core/
- [ ] No modifications to any file under App/ScanGuidance/
- [ ] No modifications to Package.swift
- [ ] No modifications to .github/workflows/

### 7.3 New File Validation
- [ ] All 10 new files have `#if canImport` guards
- [ ] All new @Published properties are on @MainActor classes
- [ ] ScanState transitions validated via `allowedTransitions`
- [ ] MeshExtractor has bounds checking on all buffer accesses
- [ ] ScanRecordStore uses atomic writes
- [ ] ARCameraPreview.dismantleUIView pauses session
- [ ] ScanViewModel.deinit cleans up timer and observers

### 7.4 UI Verification (Xcode Simulator/Device)
- [ ] App launches to HomePage (not PipelineDemoView)
- [ ] Empty state shows "尚无扫描作品"
- [ ] "开始拍摄" button navigates to ScanView
- [ ] AR camera preview displays (requires device with ARKit)
- [ ] Capture button toggles recording state
- [ ] Long-press shows 暂停/停止 menu
- [ ] X button returns to HomePage
- [ ] Toast messages appear on haptic triggers
- [ ] VoiceOver reads all interactive elements

### 7.5 Safety Verification
- [ ] Thermal state changes update LOD tier
- [ ] Session interruption auto-pauses capture
- [ ] ARKit failure transitions to .failed state
- [ ] No retain cycles (check Instruments Leaks)
- [ ] No main thread blocking (check Time Profiler)

---

## PART 8: WHAT NOT TO DO — ANTI-PATTERNS

1. **DO NOT** create a new Metal render pipeline or shader — use the existing nil-safe pipeline
2. **DO NOT** implement full Laplacian blur detection — use the 200.0 safe default
3. **DO NOT** implement real-time motion velocity tracking — use transform position as proxy
4. **DO NOT** add CoreData, Realm, or any ORM — use simple JSON persistence
5. **DO NOT** create custom UIKit navigation — use SwiftUI NavigationStack
6. **DO NOT** use `@StateObject` for shared state — pass via initializer or environment
7. **DO NOT** hardcode any constant that exists in ScanGuidanceConstants
8. **DO NOT** call `ScanGuidanceRenderPipeline(device:)` — it will fatalError()
9. **DO NOT** block the main thread in processARFrame — use async where needed
10. **DO NOT** rebuild MeshAdjacencyGraph every frame — it's O(n²). Rebuild at most every 60 frames (~1s), and use spatial hash + sliding window for large meshes (>3000 triangles)

---

## PART 9: FUTURE EXTENSIBILITY HOOKS

These are intentionally left as stubs for future PRs:

1. **`renderPipeline = nil`** → Will be activated when Metal shaders are ready
2. **`estimateBlurVariance()` returns 200.0** → Will use CVPixelBuffer Laplacian when Vision integration is done
3. **`extractMotionMagnitude()` uses position** → Will use ARKit's camera velocity when available
4. **`artifactPath` in ScanRecord** → Reserved for .splat file export (NFT mint path)
5. **`ScanRecordStore` 1000 record cap** → Will add pagination when community features arrive
6. **SpatialHashAdjacency** already handles full mesh → Future: incremental updates (add/remove triangles without full rebuild)
7. **`updateDisplaySnapshot()` simple increment** → Will use proper ray-casting coverage in future

---

## IMPLEMENTATION ORDER (STRICT)

```
Phase 0: Core Infrastructure (Foundation layer — MUST be first)
  0A. AdjacencyProvider.swift          (0 dependencies — protocol only)
  0B. SpatialHashAdjacency.swift       (depends on ScanTriangle, SIMDHelpers, AdjacencyProvider)
  0C. SpatialHashAdjacencyTests.swift  (depends on 0A + 0B)
  → Run: swift build && swift test --filter ScanGuidanceTests
  → VERIFY: All 57 existing tests STILL PASS + new tests pass

Phase 1: Data Models (0 external dependencies)
  1. ScanState.swift
  2. ScanRecord.swift
  3. ScanRecordStore.swift

Phase 2: ViewModels (depends on Phase 0 + Phase 1 + existing components)
  4. HomeViewModel.swift
  5. MeshExtractor.swift
  6. ScanViewModel.swift      (uses SpatialHashAdjacency, NOT MeshAdjacencyGraph)

Phase 3: Views (depends on Phase 2)
  7. ScanRecordCell.swift
  8. HomePage.swift
  9. ARCameraPreview.swift
  10. ScanView.swift

Phase 4: Integration
  11. Aether3DApp.swift       (modify: PipelineDemoView → HomePage)
  → Run: swift build && swift test
  → VERIFY: ALL tests pass, CI green
```

Each file MUST compile independently before moving to the next. Do NOT write all files at once.

**CRITICAL NOTE ON OPTION B (Protocol Conformance):**

If you choose Option B (recommended), you also need to make these MINIMAL changes to
existing Core/ files (parameter type changes only, no logic changes):

```swift
// In FlipAnimationController.swift line 73 — change parameter type:
// FROM: adjacencyGraph: MeshAdjacencyGraph
// TO:   adjacencyGraph: any AdjacencyProvider

// In RipplePropagationEngine.swift line 52 — change parameter type:
// FROM: adjacencyGraph: MeshAdjacencyGraph
// TO:   adjacencyGraph: any AdjacencyProvider
```

These are **additive-only** changes — existing code continues to work because
MeshAdjacencyGraph conforms to AdjacencyProvider. All 57 existing tests pass unchanged.

If you choose NOT to modify Core/ files, use Option A instead: keep the concrete
MeshAdjacencyGraph type in FlipAnimationController/RipplePropagationEngine parameters,
and have ScanViewModel use SpatialHashAdjacency internally while passing a small-subset
MeshAdjacencyGraph to the animation subsystems. This is less clean but zero-risk.
