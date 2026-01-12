//
// ErrorDomain.swift
// Aether3D
//
// Error domain definitions and code range management.
//

import Foundation

/// Error domain with code range and naming conventions.
public struct ErrorDomain: Codable, Equatable, Hashable {
    /// Domain identifier (e.g., "SSOT", "Pipeline", "Audit")
    public let id: String
    
    /// Human-readable name
    public let name: String
    
    /// Code range (inclusive)
    public let codeRange: ClosedRange<Int>
    
    /// Expected prefix for stable names (e.g., "SSOT_", "PIPELINE_")
    public let stableNamePrefix: String
    
    /// Next available code in this domain
    public private(set) var nextAvailableCode: Int
    
    public init(
        id: String,
        name: String,
        codeRange: ClosedRange<Int>,
        stableNamePrefix: String
    ) {
        self.id = id
        self.name = name
        self.codeRange = codeRange
        self.stableNamePrefix = stableNamePrefix
        self.nextAvailableCode = codeRange.lowerBound
    }
    
    /// Advance the next available code counter.
    public mutating func advanceCode() {
        guard nextAvailableCode < codeRange.upperBound else {
            return
        }
        nextAvailableCode += 1
    }
}

/// Predefined error domains.
public enum ErrorDomains {
    /// SSOT system errors (1000-1999)
    public static let ssot = ErrorDomain(
        id: "SSOT",
        name: "SSOT System",
        codeRange: 1000...1999,
        stableNamePrefix: "SSOT_"
    )
    
    /// Capture errors (1000-1999, shared with SSOT but different prefix)
    public static let capture = ErrorDomain(
        id: "CAPTURE",
        name: "Capture",
        codeRange: 1000...1999,
        stableNamePrefix: "E_"
    )
    
    /// Storage errors (2000-2999)
    public static let storage = ErrorDomain(
        id: "STORAGE",
        name: "Storage",
        codeRange: 2000...2999,
        stableNamePrefix: "E_"
    )
    
    /// Network errors (3000-3999)
    public static let network = ErrorDomain(
        id: "NETWORK",
        name: "Network",
        codeRange: 3000...3999,
        stableNamePrefix: "E_"
    )
    
    /// Pipeline errors (4000-4999)
    public static let pipeline = ErrorDomain(
        id: "PIPELINE",
        name: "Pipeline",
        codeRange: 4000...4999,
        stableNamePrefix: "C_"
    )
    
    /// Quality errors (5000-5999)
    public static let quality = ErrorDomain(
        id: "QUALITY",
        name: "Quality",
        codeRange: 5000...5999,
        stableNamePrefix: "C_"
    )
    
    /// System errors (6000-6999)
    public static let system = ErrorDomain(
        id: "SYSTEM",
        name: "System",
        codeRange: 6000...6999,
        stableNamePrefix: "S_"
    )
    
    /// Audit errors (3000-3999, legacy - may conflict with network)
    public static let audit = ErrorDomain(
        id: "AUDIT",
        name: "Audit",
        codeRange: 3000...3999,
        stableNamePrefix: "AUDIT_"
    )
    
    /// All domains
    public static let all: [ErrorDomain] = [
        ssot,
        capture,
        storage,
        network,
        pipeline,
        quality,
        system,
        audit
    ]
}

