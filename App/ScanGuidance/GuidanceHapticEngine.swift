//
// GuidanceHapticEngine.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Haptic Feedback Engine
// Apple-platform only (CoreHaptics)
// Phase 4: Full implementation
//

import Foundation

#if canImport(CoreHaptics)
import CoreHaptics
#endif

#if canImport(UIKit)
import UIKit
#endif

/// Haptic feedback patterns for scan guidance
public final class GuidanceHapticEngine {
    
    public enum HapticPattern: String, CaseIterable {
        case motionTooFast
        case blurDetected
        case exposureAbnormal
        case scanComplete
    }
    
    /// Last fire time per pattern (for debounce)
    private var lastFireTimes: [HapticPattern: TimeInterval] = [:]
    
    /// Recent fire timestamps (for rate limiting)
    private var recentFireTimestamps: [TimeInterval] = []
    
    #if canImport(CoreHaptics)
    /// CoreHaptics engine
    private var hapticEngine: CHHapticEngine?
    #endif
    
    public init() {
        #if canImport(CoreHaptics)
        initializeHapticEngine()
        #endif
    }
    
    #if canImport(CoreHaptics)
    /// Initialize CoreHaptics engine
    private func initializeHapticEngine() {
        do {
            hapticEngine = try CHHapticEngine()
            hapticEngine?.stoppedHandler = { [weak self] reason in
                // Engine stopped, try to restart
                if reason == .engineStopped {
                    self?.initializeHapticEngine()
                }
            }
            try hapticEngine?.start()
        } catch {
            // Haptic engine initialization failed, continue without haptics
            hapticEngine = nil
        }
    }
    #endif
    
    /// Fire haptic pattern with debounce and rate limiting
    ///
    /// - Parameters:
    ///   - pattern: Haptic pattern to fire
    ///   - timestamp: Current timestamp
    ///   - toastPresenter: Optional toast presenter for message display
    /// - Returns: true if haptic was fired, false if suppressed
    public func fire(
        pattern: HapticPattern,
        timestamp: TimeInterval,
        toastPresenter: GuidanceToastPresenter?
    ) -> Bool {
        guard shouldFire(pattern: pattern, at: timestamp) else {
            return false
        }
        
        // Update tracking
        lastFireTimes[pattern] = timestamp
        recentFireTimestamps.append(timestamp)
        recentFireTimestamps.removeAll { timestamp - $0 > 60.0 }
        
        // Fire haptic
        fireHapticPattern(pattern)
        
        // Show toast message
        toastPresenter?.show(message: toastMessage(for: pattern))
        
        return true
    }
    
    /// Fire completion haptic (scan complete)
    public func fireCompletion() {
        fireHapticPattern(.scanComplete)
    }
    
    /// Check if haptic should fire (debounce + rate limit)
    ///
    /// - Parameters:
    ///   - pattern: Pattern to check
    ///   - time: Current timestamp
    /// - Returns: true if haptic should fire
    internal func shouldFire(pattern: HapticPattern, at time: TimeInterval) -> Bool {
        // Check debounce (5 seconds per pattern)
        if let lastTime = lastFireTimes[pattern],
           time - lastTime < ScanGuidanceConstants.hapticDebounceS {
            return false
        }
        
        // Check rate limit (max 4 per minute)
        let recentCount = recentFireTimestamps.filter { time - $0 < 60.0 }.count
        if recentCount >= ScanGuidanceConstants.hapticMaxPerMinute {
            return false
        }
        
        return true
    }
    
    /// Get toast message for pattern
    private func toastMessage(for pattern: HapticPattern) -> String {
        switch pattern {
        case .motionTooFast:
            return "请您放慢移动速度"
        case .blurDetected:
            return "请您保持手机稳定"
        case .exposureAbnormal:
            return "请您调整光线环境"
        case .scanComplete:
            return "扫描完成！"
        }
    }
    
    /// Fire haptic pattern
    private func fireHapticPattern(_ pattern: HapticPattern) {
        #if canImport(CoreHaptics)
        guard let engine = hapticEngine else {
            // Fallback to UINotificationFeedbackGenerator if CoreHaptics unavailable
            #if os(iOS)
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            #endif
            return
        }
        
        do {
            let hapticPattern = createHapticPattern(for: pattern)
            let player = try engine.makePlayer(with: hapticPattern)
            try player.start(atTime: 0)
        } catch {
            // Haptic playback failed, continue silently
        }
        #else
        // No haptic support on this platform
        #endif
    }
    
    #if canImport(CoreHaptics)
    /// Create CHHapticPattern for pattern type
    private func createHapticPattern(for pattern: HapticPattern) -> CHHapticPattern {
        switch pattern {
        case .motionTooFast:
            // Sharp double tap
            let event1 = CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0)
            let event2 = CHHapticEvent(eventType: .hapticTransient, parameters: [], relativeTime: 0.1)
            return try! CHHapticPattern(events: [event1, event2], parameters: [])
            
        case .blurDetected:
            // Medium intensity single tap
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.7)
            let event = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity], relativeTime: 0)
            return try! CHHapticPattern(events: [event], parameters: [])
            
        case .exposureAbnormal:
            // Low intensity double tap
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.5)
            let event1 = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity], relativeTime: 0)
            let event2 = CHHapticEvent(eventType: .hapticTransient, parameters: [intensity], relativeTime: 0.15)
            return try! CHHapticPattern(events: [event1, event2], parameters: [])
            
        case .scanComplete:
            // Continuous haptic for completion
            let intensity = CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0)
            let sharpness = CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [intensity, sharpness],
                relativeTime: 0,
                duration: 0.3
            )
            return try! CHHapticPattern(events: [event], parameters: [])
        }
    }
    #endif
}
