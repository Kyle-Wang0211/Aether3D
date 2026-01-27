//
// PIZDetector.swift
// Aether3D
//
// PR1 PIZ Detection - Deterministic Detector
//
// Implements deterministic PIZ detection algorithm per spec v1.3:
// 1. Input validation (shape, float classification, range)
// 2. Connected components (4-neighborhood, row-major, deterministic neighbor order)
// 3. Filter by MIN_REGION_PIXELS
// 4. Evaluate local triggers
// 5. Compute region metrics (deterministic)
// 6. Global trigger with synthetic region if needed
// 7. Region ordering (bbox-based, not discovery order)
// **Rule ID:** PIZ_GLOBAL_REGION_001, PIZ_REGION_ORDER_002, PIZ_REGION_ID_001

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Deterministic PIZ detector.
public struct PIZDetector {
    private let gridSize: Int
    private let connectivityMode: ConnectivityMode
    
    public init(gridSize: Int = PIZThresholds.GRID_SIZE) {
        self.gridSize = gridSize
        self.connectivityMode = ConnectivityMode.frozen
    }
    
    /// Detect PIZ regions from coverage heatmap.
    /// 
    /// - Parameters:
    ///   - heatmap: 32x32 grid of coverage values (0.0-1.0, row-major)
    ///   - assetId: Asset identifier
    ///   - timestamp: Timestamp (for output only)
    ///   - computePhase: Compute phase
    ///   - previousRecommendation: Previous recommendation (for hysteresis, explicit)
    ///   - outputProfile: Output profile (DecisionOnly or FullExplainability)
    /// - Returns: PIZReport with detection results
    /// **Rule ID:** PIZ_STATEFUL_GATE_001, PIZ_OUTPUT_PROFILE_001
    public func detect(
        heatmap: [[Double]],
        assetId: String,
        timestamp: Date = Date(),
        computePhase: ComputePhase = .finalized,
        previousRecommendation: GateRecommendation? = nil,
        outputProfile: OutputProfile = .fullExplainability
    ) -> PIZReport {
        // Input validation first
        // **Rule ID:** PIZ_INPUT_VALIDATION_001, PIZ_INPUT_VALIDATION_002
        switch PIZInputValidator.validate(heatmap) {
        case .invalid(let reason):
            return PIZInputValidator.createInsufficientDataReport(reason: reason)
        case .valid:
            break
        }
        
        // Compute global coverage
        let globalCoverage = computeGlobalCoverage(heatmap: heatmap)
        let globalTrigger = globalCoverage < PIZThresholds.GLOBAL_COVERAGE_MIN
        
        // Find connected components (4-neighborhood, row-major scan)
        // **Rule ID:** PIZ_CONNECTIVITY_DETERMINISM_001, PIZ_COMPONENT_MEMBERSHIP_001
        let components = findConnectedComponents(heatmap: heatmap)
        
        // Filter by MIN_REGION_PIXELS
        // **Rule ID:** PIZ_NOISE_001
        let filteredComponents = components.filter { $0.count >= PIZThresholds.MIN_REGION_PIXELS }
        
        // Evaluate local triggers and compute region metrics
        // **Rule ID:** PIZ_LOCAL_001
        var pizRegions: [PIZRegion] = []
        for component in filteredComponents {
            if let region = evaluateLocalTrigger(component: component, heatmap: heatmap) {
                pizRegions.append(region)
            }
        }
        
        // Global trigger synthetic region requirement
        // **Rule ID:** PIZ_GLOBAL_REGION_001
        if globalTrigger && pizRegions.isEmpty {
            let syntheticRegion = createSyntheticRegion(globalCoverage: globalCoverage)
            pizRegions.append(syntheticRegion)
        }
        
        // Sort regions by bbox coordinates (NOT discovery order)
        // **Rule ID:** PIZ_REGION_ORDER_002
        pizRegions.sort { region1, region2 in
            let bbox1 = region1.bbox
            let bbox2 = region2.bbox
            
            // Primary: minRow
            if bbox1.minRow != bbox2.minRow {
                return bbox1.minRow < bbox2.minRow
            }
            // Secondary: minCol
            if bbox1.minCol != bbox2.minCol {
                return bbox1.minCol < bbox2.minCol
            }
            // Tertiary: maxRow
            if bbox1.maxRow != bbox2.maxRow {
                return bbox1.maxRow < bbox2.maxRow
            }
            // Quaternary: maxCol
            if bbox1.maxCol != bbox2.maxCol {
                return bbox1.maxCol < bbox2.maxCol
            }
            // Tie-break: region ID lexicographic
            return region1.id < region2.id
        }
        
        // Limit to MAX_REPORTED_REGIONS
        // **Rule ID:** PIZ_INPUT_BUDGET_001
        if pizRegions.count > PIZThresholds.MAX_REPORTED_REGIONS {
            pizRegions = Array(pizRegions.prefix(PIZThresholds.MAX_REPORTED_REGIONS))
        }
        
        // Compute gate recommendation
        // **Rule ID:** PIZ_COMBINE_001, PIZ_HYSTERESIS_001
        let gateRecommendation = PIZCombinationLogic.computeGateRecommendation(
            globalTrigger: globalTrigger,
            regions: pizRegions,
            previousRecommendation: previousRecommendation
        )
        
        // Generate recapture suggestion
        let recaptureSuggestion = generateRecaptureSuggestion(
            globalTrigger: globalTrigger,
            regions: pizRegions
        )
        
        // Create report based on output profile
        // **Rule ID:** PIZ_SCHEMA_PROFILE_001
        switch outputProfile {
        case .decisionOnly:
            return PIZReport(
                schemaVersion: PIZSchemaVersion.current,
                outputProfile: .decisionOnly,
                gateRecommendation: gateRecommendation,
                globalTrigger: globalTrigger,
                localTriggerCount: pizRegions.count
            )
            
        case .fullExplainability:
            return PIZReport(
                schemaVersion: PIZSchemaVersion.current,
                outputProfile: .fullExplainability,
                foundationVersion: "SSOT_FOUNDATION_v1.1",
                connectivityMode: connectivityMode.rawValue,
                gateRecommendation: gateRecommendation,
                globalTrigger: globalTrigger,
                localTriggerCount: pizRegions.count,
                heatmap: heatmap,
                regions: pizRegions,
                recaptureSuggestion: recaptureSuggestion,
                assetId: assetId,
                timestamp: timestamp,
                computePhase: computePhase
            )
        }
    }
    
    /// Compute global coverage ratio.
    /// **Rule ID:** PIZ_GLOBAL_001, PIZ_COVERED_CELL_001
    private func computeGlobalCoverage(heatmap: [[Double]]) -> Double {
        var coveredCells = 0
        let totalCells = gridSize * gridSize
        
        for row in heatmap {
            for value in row {
                // Covered cell predicate: value >= COVERED_CELL_MIN
                // **Rule ID:** PIZ_COVERED_CELL_001
                if value >= PIZThresholds.COVERED_CELL_MIN {
                    coveredCells += 1
                }
            }
        }
        
        return Double(coveredCells) / Double(totalCells)
    }
    
    /// Find connected components using 4-neighborhood.
    /// **Rule ID:** PIZ_CONNECTIVITY_DETERMINISM_001, PIZ_COMPONENT_MEMBERSHIP_001
    ///
    /// Algorithm:
    /// - Row-major scan (row 0 to 31, col 0 to 31)
    /// - Membership predicate: value < COVERED_CELL_MIN
    /// - Iterative BFS queue (not DFS stack)
    /// - Neighbor order: up, down, left, right (deterministic)
    private func findConnectedComponents(heatmap: [[Double]]) -> [[(row: Int, col: Int)]] {
        var visited = Set<Int>()
        var components: [[(row: Int, col: Int)]] = []
        
        // Component membership predicate: value < COVERED_CELL_MIN
        // **Rule ID:** PIZ_COMPONENT_MEMBERSHIP_001
        let uncoveredThreshold = PIZThresholds.COVERED_CELL_MIN
        
        // Row-major scan: row 0 to gridSize-1, col 0 to gridSize-1
        // **Rule ID:** PIZ_CONNECTIVITY_DETERMINISM_001
        for row in 0..<gridSize {
            for col in 0..<gridSize {
                let cellIndex = row * gridSize + col
                
                // Skip if already visited
                if visited.contains(cellIndex) {
                    continue
                }
                
                // Skip if cell is covered (not part of uncovered component)
                if heatmap[row][col] >= uncoveredThreshold {
                    continue
                }
                
                // Start new component from this uncovered cell
                // Use iterative BFS queue (not DFS stack)
                var component: [(row: Int, col: Int)] = []
                var queue: [(row: Int, col: Int)] = [(row, col)]
                var queueIndex = 0
                
                while queueIndex < queue.count {
                    let (r, c) = queue[queueIndex]
                    queueIndex += 1
                    let idx = r * gridSize + c
                    
                    if visited.contains(idx) {
                        continue
                    }
                    
                    // Only add uncovered cells to component
                    if heatmap[r][c] < uncoveredThreshold {
                        visited.insert(idx)
                        component.append((row: r, col: c))
                        
                        // Add 4-neighbors in deterministic order: up, down, left, right
                        // **Rule ID:** PIZ_CONNECTIVITY_DETERMINISM_001
                        let neighbors = getDeterministicNeighbors(row: r, col: c)
                        for neighbor in neighbors {
                            let neighborIdx = neighbor.row * gridSize + neighbor.col
                            if !visited.contains(neighborIdx) && neighbor.row >= 0 && neighbor.row < gridSize && neighbor.col >= 0 && neighbor.col < gridSize {
                                queue.append(neighbor)
                            }
                        }
                    }
                }
                
                if !component.isEmpty {
                    components.append(component)
                }
            }
        }
        
        return components
    }
    
    /// Get 4-neighbors in deterministic order: up, down, left, right.
    /// **Rule ID:** PIZ_CONNECTIVITY_DETERMINISM_001
    private func getDeterministicNeighbors(row: Int, col: Int) -> [(row: Int, col: Int)] {
        var neighbors: [(row: Int, col: Int)] = []
        
        // Up (row-1, col)
        if row > 0 {
            neighbors.append((row: row - 1, col: col))
        }
        
        // Down (row+1, col)
        if row < gridSize - 1 {
            neighbors.append((row: row + 1, col: col))
        }
        
        // Left (row, col-1)
        if col > 0 {
            neighbors.append((row: row, col: col - 1))
        }
        
        // Right (row, col+1)
        if col < gridSize - 1 {
            neighbors.append((row: row, col: col + 1))
        }
        
        return neighbors
    }
    
    /// Evaluate local trigger for a component.
    /// Returns PIZRegion if all conditions are met, nil otherwise.
    /// **Rule ID:** PIZ_LOCAL_001
    private func evaluateLocalTrigger(
        component: [(row: Int, col: Int)],
        heatmap: [[Double]]
    ) -> PIZRegion? {
        let pixelCount = component.count
        let totalGridCells = gridSize * gridSize
        let areaRatio = Double(pixelCount) / Double(totalGridCells)
        
        // Check area ratio condition (>= LOCAL_AREA_RATIO_MIN)
        guard areaRatio >= PIZThresholds.LOCAL_AREA_RATIO_MIN else {
            return nil
        }
        
        // Compute local coverage
        // Covered cell predicate: value >= COVERED_CELL_MIN
        // **Rule ID:** PIZ_COVERED_CELL_001
        var coveredInRegion = 0
        for (row, col) in component {
            if heatmap[row][col] >= PIZThresholds.COVERED_CELL_MIN {
                coveredInRegion += 1
            }
        }
        let localCoverage = Double(coveredInRegion) / Double(pixelCount)
        
        // Check local coverage condition (< LOCAL_COVERAGE_MIN)
        guard localCoverage < PIZThresholds.LOCAL_COVERAGE_MIN else {
            return nil
        }
        
        // All conditions met, compute region metrics
        let bbox = computeBoundingBox(component: component)
        let centroid = computeCentroid(component: component)
        let principalDirection = computePrincipalDirection(centroid: centroid, bbox: bbox)
        let severityScore = 1.0 - localCoverage
        
        // Generate deterministic ID from bbox + pixelCount hash
        // **Rule ID:** PIZ_REGION_ID_001
        let id = generateRegionId(bbox: bbox, pixelCount: pixelCount)
        
        return PIZRegion(
            id: id,
            pixelCount: pixelCount,
            areaRatio: areaRatio,
            bbox: bbox,
            centroid: centroid,
            principalDirection: principalDirection,
            severityScore: severityScore
        )
    }
    
    /// Compute bounding box for a component.
    private func computeBoundingBox(component: [(row: Int, col: Int)]) -> BoundingBox {
        var minRow = Int.max
        var maxRow = Int.min
        var minCol = Int.max
        var maxCol = Int.min
        
        for (row, col) in component {
            minRow = min(minRow, row)
            maxRow = max(maxRow, row)
            minCol = min(minCol, col)
            maxCol = max(maxCol, col)
        }
        
        return BoundingBox(minRow: minRow, maxRow: maxRow, minCol: minCol, maxCol: maxCol)
    }
    
    /// Compute centroid for a component.
    private func computeCentroid(component: [(row: Int, col: Int)]) -> Point {
        var sumRow = 0.0
        var sumCol = 0.0
        
        for (row, col) in component {
            sumRow += Double(row)
            sumCol += Double(col)
        }
        
        let count = Double(component.count)
        return Point(row: sumRow / count, col: sumCol / count)
    }
    
    /// Compute principal direction (from centroid to farthest point in bbox).
    /// **Rule ID:** PIZ_DIRECTION_TIEBREAK_001, PIZ_GEOMETRY_DETERMINISM_001
    private func computePrincipalDirection(centroid: Point, bbox: BoundingBox) -> Vector {
        // Find farthest corner from centroid
        // Corner evaluation order: (minRow, minCol), (minRow, maxCol), (maxRow, minCol), (maxRow, maxCol)
        // **Rule ID:** PIZ_DIRECTION_TIEBREAK_001
        let corners = [
            Point(row: Double(bbox.minRow), col: Double(bbox.minCol)),
            Point(row: Double(bbox.minRow), col: Double(bbox.maxCol)),
            Point(row: Double(bbox.maxRow), col: Double(bbox.minCol)),
            Point(row: Double(bbox.maxRow), col: Double(bbox.maxCol))
        ]
        
        var maxDist = 0.0
        var farthestCorner: Point? = nil
        
        // Distance metric: Euclidean distance squared (dx² + dy²)
        for corner in corners {
            let dx = corner.col - centroid.col
            let dy = corner.row - centroid.row
            let dist = dx * dx + dy * dy
            
            if dist > maxDist {
                maxDist = dist
                farthestCorner = corner
            } else if dist == maxDist && farthestCorner != nil {
                // Tie-breaking: select corner with minimum row coordinate
                // **Rule ID:** PIZ_DIRECTION_TIEBREAK_001
                if corner.row < farthestCorner!.row {
                    farthestCorner = corner
                } else if corner.row == farthestCorner!.row {
                    // If still tied, select corner with minimum column coordinate
                    if corner.col < farthestCorner!.col {
                        farthestCorner = corner
                    }
                }
            }
        }
        
        guard let corner = farthestCorner else {
            // Should not occur, but handle deterministically
            return Vector(dx: 0.0, dy: 0.0)
        }
        
        let dx = corner.col - centroid.col
        let dy = corner.row - centroid.row
        
        // Normalize to unit length
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.0 else {
            return Vector(dx: 0.0, dy: 0.0)
        }
        
        return Vector(dx: dx / length, dy: dy / length)
    }
    
    /// Generate deterministic region ID from bbox + pixelCount hash.
    /// **Rule ID:** PIZ_REGION_ID_001, PIZ_REGION_ID_SPEC_001
    ///
    /// Algorithm:
    /// - Canonical descriptor: Big-Endian uint32(minRow, maxRow, minCol, maxCol, pixelCount)
    /// - SHA-256 hash of descriptor
    /// - First 16 bytes hex lowercase, prefixed "piz_region_"
    private func generateRegionId(bbox: BoundingBox, pixelCount: Int) -> String {
        // Create canonical descriptor (Big-Endian)
        var descriptor = Data()
        
        // uint32_be minRow
        descriptor.append(contentsOf: withUnsafeBytes(of: UInt32(bbox.minRow).bigEndian) { Array($0) })
        
        // uint32_be maxRow
        descriptor.append(contentsOf: withUnsafeBytes(of: UInt32(bbox.maxRow).bigEndian) { Array($0) })
        
        // uint32_be minCol
        descriptor.append(contentsOf: withUnsafeBytes(of: UInt32(bbox.minCol).bigEndian) { Array($0) })
        
        // uint32_be maxCol
        descriptor.append(contentsOf: withUnsafeBytes(of: UInt32(bbox.maxCol).bigEndian) { Array($0) })
        
        // uint32_be pixelCount
        descriptor.append(contentsOf: withUnsafeBytes(of: UInt32(pixelCount).bigEndian) { Array($0) })
        
        // SHA-256 hash
        let hashHex = SHA256Utility.sha256(descriptor)
        
        // First 16 bytes (32 hex characters) lowercase
        let first16Bytes = String(hashHex.prefix(32))
        
        return "piz_region_\(first16Bytes)"
    }
    
    /// Create synthetic region for global trigger when no local regions exist.
    /// **Rule ID:** PIZ_GLOBAL_REGION_001
    private func createSyntheticRegion(globalCoverage: Double) -> PIZRegion {
        // Full grid bbox
        let bbox = BoundingBox(
            minRow: 0,
            maxRow: gridSize - 1,
            minCol: 0,
            maxCol: gridSize - 1
        )
        
        let pixelCount = PIZThresholds.TOTAL_GRID_CELLS
        let areaRatio = 1.0
        
        // Centroid: ((GRID_SIZE-1)/2, (GRID_SIZE-1)/2)
        // For GRID_SIZE=32: (15.5, 15.5)
        let centroidRow = Double(gridSize - 1) / 2.0
        let centroidCol = Double(gridSize - 1) / 2.0
        let centroid = Point(row: centroidRow, col: centroidCol)
        
        // Severity score: clamp01(1.0 - coverage_total)
        let severityScore = max(0.0, min(1.0, 1.0 - globalCoverage))
        
        // Principal direction computed using bbox corners + tie-break
        let principalDirection = computePrincipalDirection(centroid: centroid, bbox: bbox)
        
        // ID computed with region ID algorithm
        let id = generateRegionId(bbox: bbox, pixelCount: pixelCount)
        
        return PIZRegion(
            id: id,
            pixelCount: pixelCount,
            areaRatio: areaRatio,
            bbox: bbox,
            centroid: centroid,
            principalDirection: principalDirection,
            severityScore: severityScore
        )
    }
    
    /// Generate recapture suggestion.
    private func generateRecaptureSuggestion(
        globalTrigger: Bool,
        regions: [PIZRegion]
    ) -> RecaptureSuggestion {
        if globalTrigger {
            return RecaptureSuggestion(
                suggestedRegions: regions.map { $0.id },
                priority: .high,
                reason: "Global coverage below threshold"
            )
        }
        
        if regions.isEmpty {
            return RecaptureSuggestion(
                suggestedRegions: [],
                priority: .low,
                reason: "No PIZ regions detected"
            )
        }
        
        // Sort regions by severity (highest first)
        let sortedRegions = regions.sorted { $0.severityScore > $1.severityScore }
        let highPriorityRegions = sortedRegions.filter { $0.severityScore >= PIZThresholds.SEVERITY_HIGH_THRESHOLD }
        
        if !highPriorityRegions.isEmpty {
            return RecaptureSuggestion(
                suggestedRegions: highPriorityRegions.map { $0.id },
                priority: .high,
                reason: "High severity PIZ regions detected"
            )
        }
        
        return RecaptureSuggestion(
            suggestedRegions: regions.map { $0.id },
            priority: .medium,
            reason: "PIZ regions detected"
        )
    }
}
