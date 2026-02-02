//
// OverflowDetectionFramework.swift
// PR4Overflow
//
// PR4 V10 - Comprehensive overflow detection with structured reporting
// Pillar 27: Overflow detection framework
//

import Foundation
import PR4Math

/// Overflow detection framework with structured reporting
///
/// V10 DEFENSIVE: Every arithmetic operation on Q16 values is checked.
/// Overflows are detected, reported, and handled according to tier.
public enum OverflowDetectionFramework {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Event
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Detailed overflow event
    public struct OverflowEvent: Codable, Equatable {
        /// Field that overflowed
        public let field: String
        
        /// Operation that caused overflow
        public let operation: OverflowOperation
        
        /// Operands involved
        public let operands: [Int64]
        
        /// Result before clamping
        public let unclamped: Int64?
        
        /// Result after clamping
        public let clamped: Int64
        
        /// Tier of this field
        public let tier: OverflowTier
        
        /// Timestamp
        public let timestamp: Date
        
        /// Call stack (in DEBUG)
        public let callStack: String?
        
        /// Frame context
        public let frameId: UInt64?
    }
    
    /// Overflow operations
    public enum OverflowOperation: String, Codable {
        case add = "ADD"
        case subtract = "SUB"
        case multiply = "MUL"
        case divide = "DIV"
        case shift = "SHIFT"
        case accumulate = "ACC"
    }
    
    /// Overflow tier
    public enum OverflowTier: String, Codable {
        case tier0 = "TIER0"  // Fatal in STRICT
        case tier1 = "TIER1"  // Recoverable
        case tier2 = "TIER2"  // Diagnostic only
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Checked Operations
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Checked addition with overflow detection
    @inline(__always)
    public static func checkedAdd(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        let (result, overflow) = a.addingReportingOverflow(b)
        
        if overflow {
            let event = createOverflowEvent(
                field: field,
                operation: .add,
                operands: [a, b],
                unclamped: nil,
                clamped: result,
                tier: tier,
                frameId: frameId
            )
            
            handleOverflow(event)
            
            // Return clamped value
            let clamped = a > 0 ? Int64.max : Int64.min
            return (clamped, event)
        }
        
        return (result, nil)
    }
    
    /// Checked multiplication with overflow detection
    @inline(__always)
    public static func checkedMultiply(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        
        if overflow {
            let event = createOverflowEvent(
                field: field,
                operation: .multiply,
                operands: [a, b],
                unclamped: nil,
                clamped: result,
                tier: tier,
                frameId: frameId
            )
            
            handleOverflow(event)
            
            // Determine sign and clamp
            let sameSign = (a >= 0) == (b >= 0)
            let clamped = sameSign ? Int64.max : Int64.min
            return (clamped, event)
        }
        
        return (result, nil)
    }
    
    /// Checked Q16 multiplication (with proper scaling)
    @inline(__always)
    public static func checkedMultiplyQ16(
        _ a: Int64,
        _ b: Int64,
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflow: OverflowEvent?) {
        // Q16 multiplication: (a * b) >> 16
        // Use 128-bit intermediate to detect overflow
        let wide = Int128.multiply(a, b)
        let shifted = wide >> 16
        
        // Check if result fits in Int64
        if shifted.high != 0 && shifted.high != -1 {
            let clamped = shifted.high > 0 ? Int64.max : Int64.min
            
            let event = createOverflowEvent(
                field: field,
                operation: .multiply,
                operands: [a, b],
                unclamped: nil,
                clamped: clamped,
                tier: tier,
                frameId: frameId
            )
            
            handleOverflow(event)
            return (clamped, event)
        }
        
        return (shifted.toInt64Saturating(), nil)
    }
    
    /// Checked accumulation (for sums)
    public static func checkedAccumulate(
        _ values: [Int64],
        field: String,
        tier: OverflowTier,
        frameId: UInt64? = nil
    ) -> (result: Int64, overflows: [OverflowEvent]) {
        var sum: Int64 = 0
        var overflows: [OverflowEvent] = []
        
        for (index, value) in values.enumerated() {
            let (newSum, overflow) = checkedAdd(
                sum,
                value,
                field: "\(field)[\(index)]",
                tier: tier,
                frameId: frameId
            )
            
            sum = newSum
            if let event = overflow {
                overflows.append(event)
            }
        }
        
        return (sum, overflows)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Event Creation & Handling
    // ═══════════════════════════════════════════════════════════════════════
    
    private static func createOverflowEvent(
        field: String,
        operation: OverflowOperation,
        operands: [Int64],
        unclamped: Int64?,
        clamped: Int64,
        tier: OverflowTier,
        frameId: UInt64?
    ) -> OverflowEvent {
        #if DEBUG
        let callStack = Thread.callStackSymbols.joined(separator: "\n")
        #else
        let callStack: String? = nil
        #endif
        
        return OverflowEvent(
            field: field,
            operation: operation,
            operands: operands,
            unclamped: unclamped,
            clamped: clamped,
            tier: tier,
            timestamp: Date(),
            callStack: callStack,
            frameId: frameId
        )
    }
    
    private static func handleOverflow(_ event: OverflowEvent) {
        // Log to overflow reporter
        OverflowReporter.shared.report(event)
        
        // Handle based on tier and mode
        switch event.tier {
        case .tier0:
            #if DETERMINISM_STRICT
            assertionFailure("TIER0 overflow in \(event.field): \(event.operation)")
            #endif
            
        case .tier1:
            // Logged, computation continues with clamped value
            break
            
        case .tier2:
            // Diagnostic only, no action needed
            break
        }
    }
}
