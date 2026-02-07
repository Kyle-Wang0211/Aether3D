//
// LiDARDepthProcessor.swift
// Aether3D
//
// LiDAR Depth Processor - LiDAR depth processing for depth-enhanced capture
// 符合 PR4-02: LiDAR + RGB Fusion
//

import Foundation
import AVFoundation

/// LiDAR Depth Processor
///
/// Processes LiDAR depth data synchronized with RGB frames.
/// 符合 PR4-02: LiDAR + RGB Fusion
public actor LiDARDepthProcessor {
    
    // MARK: - State
    
    private var depthFrames: [LiDARDepthFrame] = []
    private var isProcessing: Bool = false
    
    // MARK: - Processing
    
    /// Process depth frame synchronized with RGB frame
    /// 
    /// 符合 PR4-02: LiDAR depth synchronized with RGB frames
    /// - Parameters:
    ///   - depthMap: Depth map data
    ///   - confidenceMap: Confidence map (optional)
    ///   - timestamp: Frame timestamp
    public func processDepthFrame(depthMap: Data, confidenceMap: Data?, timestamp: Date) {
        let frame = LiDARDepthFrame(
            timestamp: timestamp,
            depthMap: depthMap,
            confidenceMap: confidenceMap
        )
        
        depthFrames.append(frame)
    }
    
    /// Get depth frames
    /// 
    /// - Returns: Array of depth frames
    public func getDepthFrames() -> [LiDARDepthFrame] {
        return depthFrames
    }
    
    /// Clear depth frames
    public func clearFrames() {
        depthFrames.removeAll()
    }
    
    /// Get depth frame for timestamp
    /// 
    /// - Parameter timestamp: Frame timestamp
    /// - Returns: Depth frame if found
    public func getDepthFrame(for timestamp: Date) -> LiDARDepthFrame? {
        // Find closest depth frame to timestamp
        let tolerance: TimeInterval = 0.033 // ~30fps tolerance
        
        return depthFrames.first { frame in
            abs(frame.timestamp.timeIntervalSince(timestamp)) <= tolerance
        }
    }
}
