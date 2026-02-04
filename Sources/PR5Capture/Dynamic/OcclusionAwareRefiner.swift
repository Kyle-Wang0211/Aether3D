//
// OcclusionAwareRefiner.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 4 + F: 动态场景和细化
// 遮挡感知细化，遮挡检测，区域处理
//

import Foundation

/// Occlusion-aware refiner
///
/// Refines processing with occlusion awareness.
/// Detects occlusions and applies region-specific processing.
public actor OcclusionAwareRefiner {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Occlusion regions
    private var occlusionRegions: [OcclusionRegion] = []
    
    /// Refinement history
    private var refinementHistory: [(timestamp: Date, regions: [OcclusionRegion])] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Occlusion Detection
    
    /// Detect occlusions
    ///
    /// Identifies occluded regions in the scene
    public func detectOcclusions(
        depthMap: [Double],
        motionVectors: [MotionComplexityAnalyzer.MotionVector]
    ) -> OcclusionDetectionResult {
        // Simplified occlusion detection based on depth discontinuities
        var detectedRegions: [OcclusionRegion] = []
        
        // Analyze depth map for discontinuities
        let occlusionMask = analyzeDepthDiscontinuities(depthMap)
        
        // Create regions from mask
        let regions = extractRegions(from: occlusionMask)
        
        for region in regions {
            let occlusionRegion = OcclusionRegion(
                id: UUID(),
                bounds: region.bounds,
                confidence: region.confidence,
                timestamp: Date()
            )
            detectedRegions.append(occlusionRegion)
        }
        
        occlusionRegions = detectedRegions
        
        // Record refinement
        refinementHistory.append((timestamp: Date(), regions: detectedRegions))
        
        // Keep only recent history (last 100)
        if refinementHistory.count > 100 {
            refinementHistory.removeFirst()
        }
        
        return OcclusionDetectionResult(
            regions: detectedRegions,
            count: detectedRegions.count
        )
    }
    
    /// Analyze depth discontinuities
    private func analyzeDepthDiscontinuities(_ depthMap: [Double]) -> [Bool] {
        guard depthMap.count >= 2 else { return Array(repeating: false, count: depthMap.count) }
        
        var mask = Array(repeating: false, count: depthMap.count)
        let threshold = 0.1  // Depth discontinuity threshold
        
        for i in 1..<depthMap.count {
            if abs(depthMap[i] - depthMap[i-1]) > threshold {
                mask[i] = true
                mask[i-1] = true
            }
        }
        
        return mask
    }
    
    /// Extract regions from occlusion mask
    private func extractRegions(from mask: [Bool]) -> [RegionData] {
        var regions: [RegionData] = []
        var currentRegion: [Int] = []
        
        for (index, isOccluded) in mask.enumerated() {
            if isOccluded {
                currentRegion.append(index)
            } else {
                if !currentRegion.isEmpty {
                    let bounds = (min: currentRegion.min()!, max: currentRegion.max()!)
                    regions.append(RegionData(bounds: bounds, confidence: 0.7))
                    currentRegion.removeAll()
                }
            }
        }
        
        // Handle region at end
        if !currentRegion.isEmpty {
            let bounds = (min: currentRegion.min()!, max: currentRegion.max()!)
            regions.append(RegionData(bounds: bounds, confidence: 0.7))
        }
        
        return regions
    }
    
    // MARK: - Queries
    
    /// Get occlusion regions
    public func getOcclusionRegions() -> [OcclusionRegion] {
        return occlusionRegions
    }
    
    // MARK: - Data Types
    
    /// Occlusion region
    public struct OcclusionRegion: Sendable {
        public let id: UUID
        public let bounds: (min: Int, max: Int)
        public let confidence: Double
        public let timestamp: Date
    }
    
    /// Region data
    private struct RegionData {
        let bounds: (min: Int, max: Int)
        let confidence: Double
    }
    
    /// Occlusion detection result
    public struct OcclusionDetectionResult: Sendable {
        public let regions: [OcclusionRegion]
        public let count: Int
    }
}
