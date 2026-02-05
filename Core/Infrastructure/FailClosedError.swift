//
// FailClosedError.swift
// Aether3D
//
// PR1 v2.4 Addendum - Fail-Closed Error Standardization
//
// Single error type for contract violations (v2.4+)
//

import Foundation

/// Fail-closed error for contract violations (v2.4+)
/// 
/// **P0 Contract:**
/// - All v2.4+ violations must throw FailClosedError with one of the closed-world codes
/// - Codes are allocated in closed-world enum
public struct FailClosedError: Error {
    /// Error code (closed-world, UInt16)
    public let code: UInt16
    
    /// Context (static string for compile-time safety)
    public let context: StaticString
    
    /// Internal contract violation constructor
    public static func internalContractViolation(code: UInt16, context: StaticString) -> FailClosedError {
        return FailClosedError(code: code, context: context)
    }
    
    private init(code: UInt16, context: StaticString) {
        self.code = code
        self.context = context
    }
}

/// Fail-closed error codes (closed-world)
/// 
/// **P0 Contract:**
/// - Codes are allocated sequentially starting from 0x2401
/// - Unknown codes => fail-closed
public enum FailClosedErrorCode: UInt16 {
    /// Presence tag violation (0x2401)
    case presenceTagViolation = 0x2401
    
    /// Flow counter count mismatch (0x2402)
    case flowCounterCountMismatch = 0x2402
    
    /// Unknown layout version (0x2403)
    case unknownLayoutVersion = 0x2403
    
    /// UUID canonicalization error (0x2404)
    case uuidCanonicalizationError = 0x2404
    
    /// Policy epoch rollback (0x2405)
    case policyEpochRollback = 0x2405
    
    /// Limiter arithmetic overflow (0x2406)
    case limiterArithOverflow = 0x2406
    
    /// Canonical length mismatch (0x2407)
    case canonicalLengthMismatch = 0x2407
    
    /// Crypto implementation mismatch (0x2408)
    case cryptoImplementationMismatch = 0x2408
}
