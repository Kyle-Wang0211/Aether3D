//
// PolicyEpochRegistry.swift
// Aether3D
//
// PR1 v2.4 Addendum - PolicyEpoch Governance Registry
//
// Process-local, concurrency-safe actor for tracking policyEpoch monotonicity per tierId
//

import Foundation

/// PolicyEpochRegistry: Process-local registry for policyEpoch monotonicity enforcement
/// 
/// **P0 Contract:**
/// - Actor (concurrency-safe, single-writer semantics)
/// - Process-local (not persisted across app installs)
/// - Tracks maximum policyEpoch seen per tierId
/// - v2.4+ enforcement: policyEpoch rollback => fail-closed
public actor PolicyEpochRegistry {
    /// Shared instance (process-local)
    public static let shared = PolicyEpochRegistry()
    
    /// Maximum policyEpoch seen per tierId
    private var maxEpochPerTier: [UInt16: UInt32] = [:]
    
    /// Internal initializer for singleton and testing
    ///
    /// **Note:** Use `PolicyEpochRegistry.shared` for production code.
    /// Direct initialization is allowed for testing purposes only.
    internal init() {
        // Initializer for singleton and testing
    }
    
    /// Validate and update policyEpoch for a tierId
    /// 
    /// **Rules:**
    /// - If tierId not seen before: accept any policyEpoch, record it
    /// - If tierId seen before: currentEpoch must >= maxSeenEpoch[tierId]
    /// - v2.4+: rollback => fail-closed
    /// 
    /// **Fail-closed:** Throws FailClosedError.policyEpochRollback if rollback detected (v2.4+)
    public func validateAndUpdate(
        tierId: UInt16,
        policyEpoch: UInt32,
        schemaVersion: UInt16
    ) throws {
        // v2.4+ enforcement
        if schemaVersion >= 0x0204 {
            if let maxSeen = maxEpochPerTier[tierId] {
                guard policyEpoch >= maxSeen else {
                    // Rollback detected => fail-closed
                    throw FailClosedError.internalContractViolation(
                        code: FailClosedErrorCode.policyEpochRollback.rawValue,
                        context: "PolicyEpoch rollback detected"
                    )
                }
            }
        }
        
        // Update max seen epoch
        if let currentMax = maxEpochPerTier[tierId] {
            if policyEpoch > currentMax {
                maxEpochPerTier[tierId] = policyEpoch
            }
        } else {
            maxEpochPerTier[tierId] = policyEpoch
        }
    }
    
    /// Get maximum policyEpoch seen for a tierId (for testing/debugging)
    public func maxEpoch(for tierId: UInt16) -> UInt32? {
        return maxEpochPerTier[tierId]
    }
    
    /// Reset registry (for testing only)
    public func reset() {
        maxEpochPerTier.removeAll()
    }
}
