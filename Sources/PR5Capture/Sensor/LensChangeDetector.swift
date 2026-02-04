//
// LensChangeDetector.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 0: 传感器和相机管道
// 镜头切换检测，会话分段，内参监控
//

import Foundation

/// Lens change detector
///
/// Detects lens changes and segments sessions accordingly.
/// Monitors intrinsic parameters for changes.
public actor LensChangeDetector {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current lens identifier
    private var currentLensId: String?
    
    /// Lens change history
    private var lensChangeHistory: [(timestamp: Date, fromLens: String?, toLens: String)] = []
    
    /// Session segments (one per lens)
    private var sessionSegments: [SessionSegment] = []
    
    /// Intrinsics history per lens
    private var intrinsicsHistory: [String: [IntrinsicsDriftMonitor.CameraIntrinsics]] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Lens Detection
    
    /// Detect lens change from intrinsics
    ///
    /// Compares current intrinsics with baseline to detect lens changes
    public func detectLensChange(
        intrinsics: IntrinsicsDriftMonitor.CameraIntrinsics,
        deviceId: String
    ) -> LensChangeResult {
        // Generate lens identifier from intrinsics
        let lensId = generateLensId(intrinsics: intrinsics, deviceId: deviceId)
        
        if let current = currentLensId {
            if lensId != current {
                // Lens change detected
                let timestamp = Date()
                lensChangeHistory.append((
                    timestamp: timestamp,
                    fromLens: current,
                    toLens: lensId
                ))
                
                // End current segment
                if let lastSegment = sessionSegments.last {
                    var updatedSegment = lastSegment
                    updatedSegment.endTime = timestamp
                    sessionSegments[sessionSegments.count - 1] = updatedSegment
                }
                
                // Start new segment
                let newSegment = SessionSegment(
                    lensId: lensId,
                    startTime: timestamp,
                    endTime: nil
                )
                sessionSegments.append(newSegment)
                
                currentLensId = lensId
                
                return LensChangeResult(
                    changed: true,
                    fromLens: current,
                    toLens: lensId,
                    timestamp: timestamp
                )
            } else {
                // Same lens
                return LensChangeResult(
                    changed: false,
                    fromLens: current,
                    toLens: lensId,
                    timestamp: Date()
                )
            }
        } else {
            // First lens detection
            currentLensId = lensId
            let timestamp = Date()
            
            let segment = SessionSegment(
                lensId: lensId,
                startTime: timestamp,
                endTime: nil
            )
            sessionSegments.append(segment)
            
            return LensChangeResult(
                changed: false,
                fromLens: nil,
                toLens: lensId,
                timestamp: timestamp,
                isFirstLens: true
            )
        }
    }
    
    /// Generate lens identifier from intrinsics
    private func generateLensId(
        intrinsics: IntrinsicsDriftMonitor.CameraIntrinsics,
        deviceId: String
    ) -> String {
        // Create identifier from focal length and principal point
        // Round to avoid minor variations
        let focalRounded = round(intrinsics.focalLength * 100.0) / 100.0
        let pxRounded = round(intrinsics.principalPointX * 10.0) / 10.0
        let pyRounded = round(intrinsics.principalPointY * 10.0) / 10.0
        
        return "\(deviceId)-f\(focalRounded)-px\(pxRounded)-py\(pyRounded)"
    }
    
    /// Record intrinsics for monitoring
    public func recordIntrinsics(
        lensId: String,
        intrinsics: IntrinsicsDriftMonitor.CameraIntrinsics
    ) {
        if intrinsicsHistory[lensId] == nil {
            intrinsicsHistory[lensId] = []
        }
        
        intrinsicsHistory[lensId]?.append(intrinsics)
        
        // Keep only recent history (last 50 per lens)
        if let history = intrinsicsHistory[lensId], history.count > 50 {
            intrinsicsHistory[lensId] = Array(history.suffix(50))
        }
    }
    
    // MARK: - Queries
    
    /// Get current lens ID
    public func getCurrentLensId() -> String? {
        return currentLensId
    }
    
    /// Get lens change history
    public func getLensChangeHistory() -> [(timestamp: Date, fromLens: String?, toLens: String)] {
        return lensChangeHistory
    }
    
    /// Get session segments
    public func getSessionSegments() -> [SessionSegment] {
        return sessionSegments
    }
    
    /// Get intrinsics history for a lens
    public func getIntrinsicsHistory(for lensId: String) -> [IntrinsicsDriftMonitor.CameraIntrinsics]? {
        return intrinsicsHistory[lensId]
    }
    
    // MARK: - Data Types
    
    /// Session segment (one per lens)
    public struct SessionSegment: Sendable {
        public let lensId: String
        public let startTime: Date
        public var endTime: Date?
    }
    
    /// Lens change result
    public struct LensChangeResult: Sendable {
        public let changed: Bool
        public let fromLens: String?
        public let toLens: String
        public let timestamp: Date
        public let isFirstLens: Bool
        
        public init(
            changed: Bool,
            fromLens: String?,
            toLens: String,
            timestamp: Date,
            isFirstLens: Bool = false
        ) {
            self.changed = changed
            self.fromLens = fromLens
            self.toLens = toLens
            self.timestamp = timestamp
            self.isFirstLens = isFirstLens
        }
    }
}
