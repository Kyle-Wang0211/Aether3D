//
// FrameDropPredictor.swift
// PR5Capture
//
// PR5 v1.8.1 - PART L: 性能预算
// 掉帧预测，提前降级触发
//

import Foundation

/// Frame drop predictor
///
/// Predicts frame drops and triggers early degradation.
/// Prevents frame drops through proactive measures.
public actor FrameDropPredictor {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Frame time history
    private var frameTimes: [TimeInterval] = []
    
    /// Drop predictions
    private var predictions: [(timestamp: Date, probability: Double)] = []
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Prediction
    
    /// Predict frame drop probability
    public func predictDrop(frameTime: TimeInterval, targetTime: TimeInterval = 0.01667) -> PredictionResult {
        frameTimes.append(frameTime)
        
        // Keep only recent history (last 50)
        if frameTimes.count > 50 {
            frameTimes.removeFirst()
        }
        
        // Compute drop probability based on trend
        let probability = computeDropProbability(frameTime: frameTime, targetTime: targetTime)
        
        // Record prediction
        predictions.append((timestamp: Date(), probability: probability))
        
        // Keep only recent predictions (last 50)
        if predictions.count > 50 {
            predictions.removeFirst()
        }
        
        // Determine action
        let action: Action
        if probability > 0.7 {
            action = .aggressiveDegrade
        } else if probability > 0.4 {
            action = .moderateDegrade
        } else {
            action = .monitor
        }
        
        return PredictionResult(
            probability: probability,
            action: action,
            frameTime: frameTime
        )
    }
    
    /// Compute drop probability
    private func computeDropProbability(frameTime: TimeInterval, targetTime: TimeInterval) -> Double {
        guard !frameTimes.isEmpty else { return 0.0 }
        
        // Check if frame time exceeds target
        if frameTime > targetTime {
            return 0.8  // High probability
        }
        
        // Check trend
        if frameTimes.count >= 3 {
            let recent = Array(frameTimes.suffix(3))
            let trend = recent.last! - recent.first!
            if trend > 0 {
                return min(0.6, trend / targetTime)  // Increasing trend
            }
        }
        
        return 0.2  // Low probability
    }
    
    // MARK: - Result Types
    
    /// Action
    public enum Action: String, Sendable {
        case monitor
        case moderateDegrade
        case aggressiveDegrade
    }
    
    /// Prediction result
    public struct PredictionResult: Sendable {
        public let probability: Double
        public let action: Action
        public let frameTime: TimeInterval
    }
}
