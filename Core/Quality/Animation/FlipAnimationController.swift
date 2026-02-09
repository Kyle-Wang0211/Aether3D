//
// FlipAnimationController.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Flip Animation Controller
// Pure algorithm — Foundation + simd only
// Phase 3: Full implementation
//

import Foundation
#if canImport(simd)
import simd
#endif

/// Flip animation state for a single triangle
public struct FlipState {
    /// Triangle index
    public let triangleIndex: Int
    
    /// Start time of flip animation
    public let startTime: TimeInterval
    
    /// Flip axis origin (for rotation)
    public let axisOrigin: SIMD3<Float>
    
    /// Flip axis direction (normalized)
    public let axisDirection: SIMD3<Float>
    
    /// Initial display value (before threshold crossing)
    public let initialDisplay: Double
    
    /// Target display value (after threshold crossing)
    public let targetDisplay: Double
    
    public init(
        triangleIndex: Int,
        startTime: TimeInterval,
        axisOrigin: SIMD3<Float>,
        axisDirection: SIMD3<Float>,
        initialDisplay: Double,
        targetDisplay: Double
    ) {
        self.triangleIndex = triangleIndex
        self.startTime = startTime
        self.axisOrigin = axisOrigin
        self.axisDirection = axisDirection
        self.initialDisplay = initialDisplay
        self.targetDisplay = targetDisplay
    }
}

public final class FlipAnimationController {
    
    /// Active flip animations (triangle index → FlipState)
    private var activeFlips: [Int: FlipState] = [:]
    
    /// Previous display snapshot (for threshold detection)
    private var previousDisplay: [String: Double] = [:]
    
    /// Current time source (cross-platform)
    private func currentTime() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
    
    public init() {}
    
    /// Check for threshold crossings between previous and current display snapshots
    ///
    /// Returns triangle indices that crossed S-thresholds (0.10, 0.25, 0.50, 0.75, 0.88)
    public func checkThresholdCrossings(
        previousDisplay: [String: Double],
        currentDisplay: [String: Double],
        triangles: [ScanTriangle],
        adjacencyGraph: any AdjacencyProvider
    ) -> [Int] {
        let thresholds = [
            ScanGuidanceConstants.s0ToS1Threshold,
            ScanGuidanceConstants.s1ToS2Threshold,
            ScanGuidanceConstants.s2ToS3Threshold,
            ScanGuidanceConstants.s3ToS4Threshold,
            ScanGuidanceConstants.s4ToS5Threshold
        ]
        
        var crossedTriangles: [Int] = []
        let now = currentTime()
        
        for (triIndex, triangle) in triangles.enumerated() {
            let patchId = triangle.patchId
            let prevValue: Double
            if let known = previousDisplay[patchId] { prevValue = known } else { prevValue = 0.0 }
            let currValue: Double
            if let known = currentDisplay[patchId] { currValue = known } else { currValue = 0.0 }
            
            // Check if display increased enough to trigger flip
            let delta = currValue - prevValue
            guard delta >= ScanGuidanceConstants.flipMinDisplayDelta else {
                continue
            }
            
            // Check if crossed any threshold
            var crossedThreshold = false
            for threshold in thresholds {
                if prevValue < threshold && currValue >= threshold {
                    crossedThreshold = true
                    break
                }
            }
            
            if crossedThreshold && !activeFlips.keys.contains(triIndex) {
                // Check max concurrent limit
                if activeFlips.count >= ScanGuidanceConstants.flipMaxConcurrent {
                    continue
                }
                
                // Find flip axis (longest edge)
                let (axisStart, axisEnd) = adjacencyGraph.longestEdge(of: triangle)
                let edgeVec = axisEnd - axisStart
                let edgeLen = simdLength(edgeVec)
                let axisDir = edgeLen > 1e-6 ? edgeVec / edgeLen : SIMD3<Float>(1, 0, 0)
                let axisOrigin = axisStart
                
                // Apply stagger delay for adjacent triangles
                let staggerDelay = Double(triIndex) * ScanGuidanceConstants.flipStaggerDelayS
                let adjustedStartTime = now + staggerDelay
                
                activeFlips[triIndex] = FlipState(
                    triangleIndex: triIndex,
                    startTime: adjustedStartTime,
                    axisOrigin: axisOrigin,
                    axisDirection: axisDir,
                    initialDisplay: prevValue,
                    targetDisplay: currValue
                )
                
                crossedTriangles.append(triIndex)
            }
        }
        
        self.previousDisplay = currentDisplay
        return crossedTriangles
    }
    
    /// Tick animation and return per-triangle rotation angles
    ///
    /// - Parameter deltaTime: Time delta since last tick
    /// - Returns: Array of rotation angles [0, PI] for each triangle (indexed by triangle index)
    public func tick(deltaTime: TimeInterval) -> [Float] {
        let now = currentTime()
        var angles: [Int: Float] = [:]
        
        // Update active flips
        var completedFlips: [Int] = []
        for (triIndex, flipState) in activeFlips {
            let elapsed = now - flipState.startTime
            let duration = ScanGuidanceConstants.flipDurationS
            
            if elapsed < 0 {
                // Not started yet (stagger delay)
                angles[triIndex] = 0.0
            } else if elapsed >= duration {
                // Completed
                angles[triIndex] = Float.pi
                completedFlips.append(triIndex)
            } else {
                // In progress: normalize time to [0, 1]
                let t = Float(elapsed / duration)
                let eased = Self.easingWithOvershoot(t: t)
                // Map eased value [0, ~1.1] to angle [0, PI]
                let normalizedEased = min(eased, 1.0)  // Clamp overshoot to 1.0 for angle
                angles[triIndex] = normalizedEased * Float.pi
            }
        }
        
        // Remove completed flips
        for triIndex in completedFlips {
            activeFlips.removeValue(forKey: triIndex)
        }
        
        // Return angles array (all triangles, 0.0 for non-flipping)
        // Note: Caller needs to know triangle count to create full array
        return Array(angles.values)
    }
    
    /// Get flip angles for specific triangle indices
    ///
    /// - Parameter triangleIndices: Array of triangle indices to query
    /// - Returns: Array of angles corresponding to triangleIndices
    public func getFlipAngles(for triangleIndices: [Int]) -> [Float] {
        let now = currentTime()
        return triangleIndices.map { triIndex in
            guard let flipState = activeFlips[triIndex] else {
                return 0.0
            }
            let elapsed = now - flipState.startTime
            let duration = ScanGuidanceConstants.flipDurationS
            
            if elapsed < 0 {
                return 0.0
            } else if elapsed >= duration {
                return Float.pi
            } else {
                let t = Float(elapsed / duration)
                let eased = Self.easingWithOvershoot(t: t)
                let normalizedEased = min(eased, 1.0)
                return normalizedEased * Float.pi
            }
        }
    }
    
    /// Get flip axis for a triangle (for Metal shader)
    public func getFlipAxis(for triangleIndex: Int) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard let flipState = activeFlips[triangleIndex] else {
            return nil
        }
        return (flipState.axisOrigin, flipState.axisDirection)
    }
    
    /// Cubic Bezier easing with overshoot
    ///
    /// Control points from ScanGuidanceConstants:
    /// - CP1: (0.34, 1.56) - overshoot
    /// - CP2: (0.64, 1.0)
    ///
    /// At t≈0.6, value should be ≈1.1 (overshoot)
    public static func easingWithOvershoot(t: Float) -> Float {
        let t = max(0.0, min(1.0, t))  // Clamp to [0, 1]
        
        // Cubic Bezier: B(t) = (1-t)^3 * P0 + 3*(1-t)^2*t * P1 + 3*(1-t)*t^2 * P2 + t^3 * P3
        // P0 = (0, 0), P1 = (0.34, 1.56), P2 = (0.64, 1.0), P3 = (1, 1)
        let cp1y = Float(ScanGuidanceConstants.flipEasingCP1Y)
        let cp2y = Float(ScanGuidanceConstants.flipEasingCP2Y)
        
        let oneMinusT = 1.0 - t
        let t2 = t * t
        let t3 = t2 * t
        let oneMinusT2 = oneMinusT * oneMinusT
        let oneMinusT3 = oneMinusT2 * oneMinusT
        
        // P0 = (0, 0), P3 = (1, 1)
        let y = oneMinusT3 * 0.0 +
                3.0 * oneMinusT2 * t * cp1y +
                3.0 * oneMinusT * t2 * cp2y +
                t3 * 1.0
        
        return y
    }
    
    /// Clear all active flips
    public func reset() {
        activeFlips.removeAll()
        previousDisplay.removeAll()
    }
}
