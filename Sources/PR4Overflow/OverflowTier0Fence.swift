//
// OverflowTier0Fence.swift
// PR4Overflow
//
// PR4 V10 - Pillar 18: Tier0 fields that MUST NOT overflow - fatal in STRICT mode
//

import Foundation


/// Tier0 overflow fence
///
/// V9 RULE: These fields are FATAL if they overflow.
/// Any overflow in Tier0 = system integrity compromised.
public enum OverflowTier0Fence {
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Tier0 Fields (FATAL on overflow)
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Fields that MUST NOT overflow
    public static let tier0Fields: Set<String> = [
        "gateQ",           // Gate state - overflow corrupts state machine
        "softQualityQ",    // Core output - overflow = wrong quality
        "fusedDepthQ",     // Fused depth - overflow = invalid output
        "healthQ",         // Health metric - overflow = bad decisions
        "consistencyGainQ", // Fusion weight - overflow = bad weights
        "coverageGainQ",
        "confidenceGainQ",
    ]
    
    /// Check if field is Tier0
    @inline(__always)
    public static func isTier0(_ fieldName: String) -> Bool {
        return tier0Fields.contains(fieldName)
    }
    
    // ═══════════════════════════════════════════════════════════════════════
    // MARK: - Overflow Handling
    // ═══════════════════════════════════════════════════════════════════════
    
    /// Handle potential Tier0 overflow
    ///
    /// STRICT: assertionFailure
    /// FAST: log + degrade + continue
    public static func handleOverflow(
        field: String,
        value: Int64,
        bound: Int64,
        direction: OverflowDirection
    ) -> Int64 {
        if isTier0(field) {
            #if DETERMINISM_STRICT
            assertionFailure("TIER0 OVERFLOW: \(field) = \(value), bound = \(bound)")
            #endif
            
            // Log fatal overflow
            Tier0OverflowLogger.shared.logFatal(
                field: field,
                value: value,
                bound: bound,
                direction: direction
            )
            
            // Return degraded value
            return direction == .above ? bound : -bound
        }
        
        // Non-Tier0: normal handling
        return direction == .above ? Swift.min(value, bound) : Swift.max(value, -bound)
    }
    
    public enum OverflowDirection {
        case above
        case below
    }
}

/// Logger for Tier0 overflows
public final class Tier0OverflowLogger {
    public static let shared = Tier0OverflowLogger()
    
    private var fatalOverflows: [(field: String, value: Int64, bound: Int64, time: Date)] = []
    private let lock = NSLock()
    
    private init() {}
    
    public func logFatal(field: String, value: Int64, bound: Int64, direction: OverflowTier0Fence.OverflowDirection) {
        lock.lock()
        defer { lock.unlock() }
        
        fatalOverflows.append((field, value, bound, Date()))
        print("🛑 TIER0 OVERFLOW: \(field) = \(value) (bound: \(bound))")
    }
    
    public var hasFatalOverflows: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !fatalOverflows.isEmpty
    }
    
    public func getRecords() -> [(field: String, value: Int64, bound: Int64, time: Date)] {
        lock.lock()
        defer { lock.unlock() }
        return fatalOverflows
    }
    
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        fatalOverflows.removeAll()
    }
}
