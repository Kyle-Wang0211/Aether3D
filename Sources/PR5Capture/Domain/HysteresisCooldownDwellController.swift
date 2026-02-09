// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// HysteresisCooldownDwellController.swift
// PR5Capture
//
// PR5 v1.8.1 - 五大核心方法论之一：滞后/冷却/最小驻留（Hysteresis/Cooldown/Minimum Dwell）
// 防止状态振荡
//

import Foundation

/// Generic hysteresis/cooldown/dwell controller
///
/// Prevents state oscillation through three mechanisms:
/// - **Hysteresis**: Different thresholds for entering vs exiting state
/// - **Cooldown**: Minimum time between state transitions
/// - **Minimum Dwell**: Minimum time state must be maintained before exit
///
/// **Pre-configured Controllers**:
/// - Low light
/// - High motion
/// - HDR
/// - Thermal
/// - Focus
public actor HysteresisCooldownDwellController {
    
    // MARK: - Configuration
    
    public struct ControllerConfig: Codable, Sendable {
        public let enterThreshold: Double
        public let exitThreshold: Double
        public let cooldownPeriodSeconds: TimeInterval
        public let minimumDwellSeconds: TimeInterval
        
        public init(
            enterThreshold: Double,
            exitThreshold: Double,
            cooldownPeriodSeconds: TimeInterval,
            minimumDwellSeconds: TimeInterval
        ) {
            self.enterThreshold = enterThreshold
            self.exitThreshold = exitThreshold
            self.cooldownPeriodSeconds = cooldownPeriodSeconds
            self.minimumDwellSeconds = minimumDwellSeconds
        }
    }
    
    private let config: ControllerConfig
    
    // MARK: - State
    
    /// Current state (true = active, false = inactive)
    private var isActive: Bool = false
    
    /// Time when state was last entered
    private var stateEnteredAt: Date?
    
    /// Time when last transition occurred
    private var lastTransitionAt: Date?
    
    // MARK: - Initialization
    
    public init(config: ControllerConfig) {
        self.config = config
    }
    
    // MARK: - State Evaluation
    
    /// Evaluate state based on input value
    ///
    /// Applies hysteresis, cooldown, and minimum dwell logic
    public func evaluate(_ value: Double) -> StateEvaluationResult {
        let now = Date()
        
        // Check cooldown period
        if let lastTransition = lastTransitionAt {
            let elapsed = now.timeIntervalSince(lastTransition)
            if elapsed < config.cooldownPeriodSeconds {
                return .cooldown(remaining: config.cooldownPeriodSeconds - elapsed)
            }
        }
        
        // Apply hysteresis logic
        if isActive {
            // Currently active - check exit threshold
            if value < config.exitThreshold {
                // Check minimum dwell requirement
                if let enteredAt = stateEnteredAt {
                    let dwellTime = now.timeIntervalSince(enteredAt)
                    if dwellTime >= config.minimumDwellSeconds {
                        // Can exit
                        isActive = false
                        lastTransitionAt = now
                        stateEnteredAt = nil
                        return .transitioned(to: false, reason: "Value \(value) below exit threshold \(config.exitThreshold)")
                    } else {
                        // Still in minimum dwell period
                        return .dwell(remaining: config.minimumDwellSeconds - dwellTime)
                    }
                } else {
                    // No entry time recorded (shouldn't happen, but handle gracefully)
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
            if value >= config.enterThreshold {
                // Can enter
                isActive = true
                lastTransitionAt = now
                stateEnteredAt = now
                return .transitioned(to: true, reason: "Value \(value) above enter threshold \(config.enterThreshold)")
            } else {
                // Still below enter threshold - remain inactive
                return .maintained(current: false, value: value)
            }
        }
    }
    
    // MARK: - State Queries
    
    /// Get current state
    public func getCurrentState() -> Bool {
        return isActive
    }
    
    /// Get time since state was entered
    public func getStateDwellTime() -> TimeInterval? {
        guard let enteredAt = stateEnteredAt else { return nil }
        return Date().timeIntervalSince(enteredAt)
    }
    
    /// Get time since last transition
    public func getTimeSinceLastTransition() -> TimeInterval? {
        guard let lastTransition = lastTransitionAt else { return nil }
        return Date().timeIntervalSince(lastTransition)
    }
    
    // MARK: - Result Types
    
    /// State evaluation result
    public enum StateEvaluationResult: Sendable {
        case transitioned(to: Bool, reason: String)
        case maintained(current: Bool, value: Double)
        case cooldown(remaining: TimeInterval)
        case dwell(remaining: TimeInterval)
    }
}

// MARK: - Pre-configured Controllers

extension HysteresisCooldownDwellController {
    
    /// Low light controller
    public static func lowLight(config: ExtremeProfile.StateMachineConfig) -> HysteresisCooldownDwellController {
        return HysteresisCooldownDwellController(
            config: ControllerConfig(
                enterThreshold: config.hysteresisEnterThreshold,
                exitThreshold: config.hysteresisExitThreshold,
                cooldownPeriodSeconds: config.cooldownPeriodSeconds,
                minimumDwellSeconds: config.cooldownPeriodSeconds * 2.0
            )
        )
    }
    
    /// High motion controller
    public static func highMotion(config: ExtremeProfile.StateMachineConfig) -> HysteresisCooldownDwellController {
        return HysteresisCooldownDwellController(
            config: ControllerConfig(
                enterThreshold: config.hysteresisEnterThreshold,
                exitThreshold: config.hysteresisExitThreshold,
                cooldownPeriodSeconds: config.cooldownPeriodSeconds,
                minimumDwellSeconds: config.cooldownPeriodSeconds * 1.5
            )
        )
    }
    
    /// HDR controller
    public static func hdr(config: ExtremeProfile.StateMachineConfig) -> HysteresisCooldownDwellController {
        return HysteresisCooldownDwellController(
            config: ControllerConfig(
                enterThreshold: config.hysteresisEnterThreshold,
                exitThreshold: config.hysteresisExitThreshold,
                cooldownPeriodSeconds: config.cooldownPeriodSeconds,
                minimumDwellSeconds: config.cooldownPeriodSeconds * 2.5
            )
        )
    }
    
    /// Thermal controller
    public static func thermal(config: ExtremeProfile.StateMachineConfig) -> HysteresisCooldownDwellController {
        return HysteresisCooldownDwellController(
            config: ControllerConfig(
                enterThreshold: config.hysteresisEnterThreshold,
                exitThreshold: config.hysteresisExitThreshold,
                cooldownPeriodSeconds: config.cooldownPeriodSeconds * 2.0,
                minimumDwellSeconds: config.cooldownPeriodSeconds * 3.0
            )
        )
    }
    
    /// Focus controller
    public static func focus(config: ExtremeProfile.StateMachineConfig) -> HysteresisCooldownDwellController {
        return HysteresisCooldownDwellController(
            config: ControllerConfig(
                enterThreshold: config.hysteresisEnterThreshold,
                exitThreshold: config.hysteresisExitThreshold,
                cooldownPeriodSeconds: config.cooldownPeriodSeconds * 0.5,
                minimumDwellSeconds: config.cooldownPeriodSeconds
            )
        )
    }
}
