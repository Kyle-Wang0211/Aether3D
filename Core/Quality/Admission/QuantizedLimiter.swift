//
// QuantizedLimiter.swift
// Aether3D
//
// PR1 v2.4 Addendum - Quantized Limiter with Exact Semantics + Overflow Rules
//
// Window semantics: [startTick, startTick + windowTicks) left-closed right-open
// Request order: advanceTo(nowTick) THEN consume()
// Attempts counted BEFORE token consume
// Overflow => HardFuse LIMITER_ARITH_OVERFLOW + TERMINAL
//

import Foundation

/// Quantized limiter with exact window semantics and overflow handling
/// 
/// **P0 Contract:**
/// - Window: [startTick, startTick + windowTicks) left-closed right-open
/// - Request order: advanceTo(nowTick) THEN consume()
/// - attemptsInWindow increments BEFORE token consume
/// - Refill computed in one step with overflow checks
/// - attemptsInWindow saturating increment to UInt32.max
/// - Arithmetic overflow => HardFuse LIMITER_ARITH_OVERFLOW + TERMINAL
public struct QuantizedLimiter {
    /// Window start tick
    private var windowStartTick: UInt64
    
    /// Window duration (ticks)
    private let windowTicks: UInt64
    
    /// Last tick processed
    private var lastTick: UInt64
    
    /// Tokens available
    private var tokens: UInt32
    
    /// Maximum tokens (burst capacity)
    private let maxTokens: UInt32
    
    /// Refill rate per tick
    private let refillRatePerTick: UInt64
    
    /// Attempts in current window
    private var attemptsInWindow: UInt32
    
    /// Initialize quantized limiter
    /// 
    /// **Parameters:**
    /// - windowTicks: Window duration in ticks
    /// - maxTokens: Maximum tokens (burst capacity)
    /// - refillRatePerTick: Tokens refilled per tick
    /// - initialTick: Initial tick value
    public init(
        windowTicks: UInt64,
        maxTokens: UInt32,
        refillRatePerTick: UInt64,
        initialTick: UInt64 = 0
    ) {
        self.windowTicks = windowTicks
        self.maxTokens = maxTokens
        self.refillRatePerTick = refillRatePerTick
        self.windowStartTick = initialTick
        self.lastTick = initialTick
        self.tokens = maxTokens
        self.attemptsInWindow = 0
    }
    
    /// Advance to current tick and update internal state
    /// 
    /// **Semantics:**
    /// - Updates window if needed (sliding window)
    /// - Refills tokens based on elapsed ticks
    /// - Computes refill in one step: delta * refillRatePerTick
    /// 
    /// **Fail-closed:** Throws FailClosedError on arithmetic overflow
    public mutating func advanceTo(_ nowTick: UInt64) throws {
        // Check for tick rollback (should not happen, but fail-closed)
        guard nowTick >= lastTick else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.limiterArithOverflow.rawValue,
                context: "Tick rollback detected"
            )
        }
        
        // Slide window if needed (left-closed right-open: [startTick, startTick + windowTicks))
        // Window includes startTick but excludes startTick + windowTicks
        if nowTick >= windowStartTick + windowTicks {
            // Window has moved: reset attempts and start new window
            windowStartTick = nowTick
            attemptsInWindow = 0
        }
        
        // Compute refill: delta * refillRatePerTick (one step, with overflow check)
        let delta = nowTick - lastTick
        
        // Check for multiplication overflow
        let (refill, overflow) = delta.multipliedReportingOverflow(by: refillRatePerTick)
        guard !overflow else {
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.limiterArithOverflow.rawValue,
                context: "Refill multiplication overflow"
            )
        }
        
        // Add refill to tokens (saturating add to maxTokens)
        let newTokens = tokens.addingReportingOverflow(UInt32(min(refill, UInt64(UInt32.max))))
        if newTokens.overflow || newTokens.partialValue > maxTokens {
            tokens = maxTokens
        } else {
            tokens = newTokens.partialValue
        }
        
        lastTick = nowTick
    }
    
    /// Consume a token (must call advanceTo first)
    /// 
    /// **Semantics:**
    /// - attemptsInWindow increments BEFORE token consume
    /// - Then consumes token if available
    /// 
    /// **Returns:** true if token consumed, false if rate limited
    /// 
    /// **Fail-closed:** Throws FailClosedError on attemptsInWindow saturation (retry storm)
    public mutating func consume() throws -> Bool {
        // Increment attempts BEFORE consume (P0 requirement)
        let (newAttempts, overflow) = attemptsInWindow.addingReportingOverflow(1)
        
        if overflow || newAttempts == UInt32.max {
            // Saturation reached => retry storm equivalent => HardFuse + TERMINAL
            throw FailClosedError.internalContractViolation(
                code: FailClosedErrorCode.limiterArithOverflow.rawValue,
                context: "Attempts saturation (retry storm)"
            )
        }
        
        attemptsInWindow = newAttempts
        
        // Consume token if available
        if tokens > 0 {
            tokens -= 1
            return true
        } else {
            return false
        }
    }
    
    /// Get current attempts in window
    public var currentAttempts: UInt32 {
        return attemptsInWindow
    }
    
    /// Get current tokens available
    public var currentTokens: UInt32 {
        return tokens
    }
    
    /// Get window start tick
    public var currentWindowStart: UInt64 {
        return windowStartTick
    }
}
