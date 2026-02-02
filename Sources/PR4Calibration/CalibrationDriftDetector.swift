//
// CalibrationDriftDetector.swift
// PR4Calibration
//
// PR4 V10 - Pillar 10: Stratified drift detection
//

import Foundation
import PR4Math

/// Calibration drift detector
///
/// V10 RULE: Detect drift per stratum (depth_bucket, confidence_bucket).
public enum CalibrationDriftDetector {
    
    /// Drift threshold (20% change)
    public static let driftThreshold: Double = 0.2
    
    /// Detect drift per stratum
    public static func detectDrift(
        currentSigma: Double,
        previousSigma: Double
    ) -> (drifted: Bool, driftAmount: Double) {
        guard previousSigma > 0 else {
            return (drifted: false, driftAmount: 0)
        }
        
        let relativeChange = abs(currentSigma - previousSigma) / previousSigma
        return (drifted: relativeChange > driftThreshold, driftAmount: relativeChange)
    }
    
    /// Stratum identifier
    public struct Stratum: Hashable {
        public let depthBucket: Int
        public let confidenceBucket: Int
        
        public init(depthBucket: Int, confidenceBucket: Int) {
            self.depthBucket = depthBucket
            self.confidenceBucket = confidenceBucket
        }
    }
    
    /// Track sigma per stratum
    public struct StratumTracker {
        private var sigmaHistory: [Stratum: [Double]] = [:]
        
        public mutating func recordSigma(stratum: Stratum, sigma: Double) {
            if sigmaHistory[stratum] == nil {
                sigmaHistory[stratum] = []
            }
            sigmaHistory[stratum]?.append(sigma)
            
            // Keep last 30 days
            if sigmaHistory[stratum]?.count ?? 0 > 30 {
                sigmaHistory[stratum]?.removeFirst()
            }
        }
        
        public func detectDrift(stratum: Stratum) -> Bool {
            guard let history = sigmaHistory[stratum], history.count >= 2 else {
                return false
            }
            
            let current = history.last!
            let previous = history[history.count - 2]
            
            let (drifted, _) = CalibrationDriftDetector.detectDrift(
                currentSigma: current,
                previousSigma: previous
            )
            
            return drifted
        }
    }
}
