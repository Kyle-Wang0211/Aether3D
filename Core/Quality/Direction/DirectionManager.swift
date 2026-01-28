//
//  DirectionManager.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 4
//  DirectionManager - direction window lifecycle management (PART 5)
//

import Foundation

/// DirectionId - direction identifier (30° yaw bucket + 20° pitch bucket)
public typealias DirectionId = String

/// DirectionManager - manages direction window lifecycle
public class DirectionManager {
    private var currentDirectionId: DirectionId?
    private var directionStartTime: Int64?
    private var lastWhiteProgressTime: Int64?
    
    public init() {}
    
    /// Generate direction ID from yaw and pitch
    /// 30° yaw bucket + 20° pitch bucket
    public static func generateDirectionId(yaw: Double, pitch: Double) -> DirectionId {
        let yawBucket = Int(yaw / 30.0)
        let pitchBucket = Int(pitch / 20.0)
        return "\(yawBucket)_\(pitchBucket)"
    }
    
    /// Check if should enter new direction
    /// Condition: stable time ≥ DIR_ENTER_STABLE_MS
    public func shouldEnterDirection(directionId: DirectionId, stableTimeMs: Int64) -> Bool {
        return stableTimeMs >= QualityPreCheckConstants.DIR_ENTER_STABLE_MS
    }
    
    /// Enter direction
    public func enterDirection(_ directionId: DirectionId) {
        currentDirectionId = directionId
        let now = MonotonicClock.nowMs()
        directionStartTime = now
        lastWhiteProgressTime = now
    }
    
    /// Check if should exit direction
    /// Condition: no white progress ≥ DIR_NO_PROGRESS_MS
    public func shouldExitDirection() -> Bool {
        guard let lastProgress = lastWhiteProgressTime else {
            return false
        }
        
        let now = MonotonicClock.nowMs()
        let noProgressDuration = now - lastProgress
        
        return noProgressDuration >= QualityPreCheckConstants.DIR_NO_PROGRESS_MS
    }
    
    /// Update white progress timestamp
    public func updateWhiteProgress() {
        lastWhiteProgressTime = MonotonicClock.nowMs()
    }
    
    /// Get current direction ID
    public func getCurrentDirectionId() -> DirectionId? {
        return currentDirectionId
    }
}

