//
// HysteresisStateMachine.swift
// PR5Capture
//
// PR5 v1.8.1 - PART 1 + C: 状态机加固和增强
// 双阈值系统（进入/退出），冷却期管理，紧急转换覆盖
//

import Foundation

/// Hysteresis state machine
///
/// Implements dual-threshold system (enter/exit) with cooldown management.
/// Supports emergency transition override.
public actor HysteresisStateMachine {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Current state (true = active, false = inactive)
    private var isActive: Bool = false
    
    /// Time when state was last entered
    private var stateEnteredAt: Date?
    
    /// Time when last transition occurred
    private var lastTransitionAt: Date?
    
    /// Emergency transition count (for rate limiting)
    private var emergencyTransitionCount: Int = 0
    private var emergencyTransitionWindowStart: Date?
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - State Evaluation
    
    /// Evaluate state transition
    ///
    /// Applies hysteresis, cooldown, and minimum dwell logic
    public func evaluate(_ value: Double, forceEmergency: Bool = false) -> StateTransitionResult {
        let now = Date()
        
        // Check emergency transition override
        if forceEmergency {
            return handleEmergencyTransition(value: value, now: now)
        }
        
        // Check cooldown period
        if let lastTransition = lastTransitionAt {
            let elapsed = now.timeIntervalSince(lastTransition)
            let cooldown = config.stateMachine.cooldownPeriodSeconds
            
            if elapsed < cooldown {
                return .cooldown(remaining: cooldown - elapsed)
            }
        }
        
        // Apply hysteresis logic
        if isActive {
            // Currently active - check exit threshold
            if value < config.stateMachine.hysteresisExitThreshold {
                // Check minimum dwell requirement
                if let enteredAt = stateEnteredAt {
                    let dwellTime = now.timeIntervalSince(enteredAt)
                    let minDwellSeconds = Double(config.stateMachine.minimumDwellFrames) * 0.033  // Assume 30fps
                    
                    if dwellTime >= minDwellSeconds {
                        // Can exit
                        isActive = false
                        lastTransitionAt = now
                        stateEnteredAt = nil
                        return .transitioned(to: false, reason: "Value \(value) below exit threshold \(config.stateMachine.hysteresisExitThreshold)")
                    } else {
                        // Still in minimum dwell period
                        return .dwell(remaining: minDwellSeconds - dwellTime)
                    }
                } else {
                    // No entry time recorded
                    isActive = false
                    lastTransitionAt = now
                    return .transitioned(to: false, reason: "Exit threshold met")
                }
            } else {
                // Still above exit threshold - remain active
                return .maintained(current: true, value: value)
            }
        } else {
            // Currently inactive - check enter threshold
            if value >= config.stateMachine.hysteresisEnterThreshold {
                // Can enter
                isActive = true
                lastTransitionAt = now
                stateEnteredAt = now
                return .transitioned(to: true, reason: "Value \(value) above enter threshold \(config.stateMachine.hysteresisEnterThreshold)")
            } else {
                // Still below enter threshold - remain inactive
                return .maintained(current: false, value: value)
            }
        }
    }
    
    /// Handle emergency transition
    private func handleEmergencyTransition(value: Double, now: Date) -> StateTransitionResult {
        // Check emergency transition rate limit
        let rateLimit = config.stateMachine.emergencyTransitionRateLimit
        
        if let windowStart = emergencyTransitionWindowStart {
            let windowElapsed = now.timeIntervalSince(windowStart)
            if windowElapsed >= 1.0 {  // 1 second window
                // Reset window
                emergencyTransitionCount = 0
                emergencyTransitionWindowStart = now
            }
        } else {
            emergencyTransitionWindowStart = now
        }
        
        // Check rate limit
        if Double(emergencyTransitionCount) >= rateLimit {
            return .rateLimited(reason: "Emergency transition rate limit exceeded: \(rateLimit)/s")
        }
        
        // Allow emergency transition
        emergencyTransitionCount += 1
        
        let newState = value >= config.stateMachine.hysteresisEnterThreshold
        
        if newState != isActive {
            isActive = newState
            lastTransitionAt = now
            if newState {
                stateEnteredAt = now
            } else {
                stateEnteredAt = nil
            }
            
            return .transitioned(to: newState, reason: "Emergency transition", isEmergency: true)
        } else {
            return .maintained(current: isActive, value: value)
        }
    }
    
    // MARK: - Queries
    
    /// Get current state
    public func getCurrentState() -> Bool {
        return isActive
    }
    
    /// Get time since state was entered
    public func getStateDwellTime() -> TimeInterval? {
        guard let enteredAt = stateEnteredAt else { return nil }
        return Date().timeIntervalSince(enteredAt)
    }
    
    // MARK: - Result Types
    
    /// State transition result
    public enum StateTransitionResult: Sendable {
        case transitioned(to: Bool, reason: String, isEmergency: Bool = false)
        case maintained(current: Bool, value: Double)
        case cooldown(remaining: TimeInterval)
        case dwell(remaining: TimeInterval)
        case rateLimited(reason: String)
    }
}
