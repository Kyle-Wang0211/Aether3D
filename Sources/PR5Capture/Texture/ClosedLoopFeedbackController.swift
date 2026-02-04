//
// ClosedLoopFeedbackController.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 5 + G: 纹理响应和闭环
// 闭环反馈控制，自适应调整，反馈循环
//

import Foundation

/// Closed-loop feedback controller
///
/// Implements closed-loop feedback control with adaptive adjustment.
/// Manages feedback loops for quality improvement.
public actor ClosedLoopFeedbackController {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Feedback history
    private var feedbackHistory: [(timestamp: Date, input: Double, output: Double, error: Double)] = []
    
    /// Control parameters
    private var kp: Double = 1.0  // Proportional gain
    private var ki: Double = 0.1   // Integral gain
    private var kd: Double = 0.01  // Derivative gain
    
    /// Integral accumulator
    private var integral: Double = 0.0
    private var lastError: Double = 0.0
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - Feedback Control
    
    /// Process feedback and compute control output
    ///
    /// PID controller implementation
    public func processFeedback(currentValue: Double, targetValue: Double) -> ControlOutput {
        let error = targetValue - currentValue
        
        // Proportional term
        let pTerm = kp * error
        
        // Integral term
        integral += error
        let iTerm = ki * integral
        
        // Derivative term
        let dTerm = kd * (error - lastError)
        lastError = error
        
        // Compute output
        let output = pTerm + iTerm + dTerm
        
        // Record feedback
        feedbackHistory.append((timestamp: Date(), input: currentValue, output: output, error: error))
        
        // Keep only recent history (last 100)
        if feedbackHistory.count > 100 {
            feedbackHistory.removeFirst()
        }
        
        return ControlOutput(
            output: output,
            error: error,
            pTerm: pTerm,
            iTerm: iTerm,
            dTerm: dTerm
        )
    }
    
    /// Reset controller
    public func reset() {
        integral = 0.0
        lastError = 0.0
    }
    
    /// Set PID gains
    public func setGains(kp: Double, ki: Double, kd: Double) {
        self.kp = kp
        self.ki = ki
        self.kd = kd
    }
    
    // MARK: - Result Types
    
    /// Control output
    public struct ControlOutput: Sendable {
        public let output: Double
        public let error: Double
        public let pTerm: Double
        public let iTerm: Double
        public let dTerm: Double
    }
}
