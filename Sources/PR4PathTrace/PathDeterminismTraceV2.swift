//
// PathDeterminismTraceV2.swift
// PR4PathTrace
//
// PR4 V10 - Path Trace V2: Versioned with Token Whitelist
// Task 1.4: Foundation module with no dependencies
//

import Foundation

/// Branch token whitelist
///
/// V10 RULE: Only these tokens are valid. Unknown tokens = validation error.
public enum BranchToken: UInt8, CaseIterable, Codable {
    
    // Gate Decisions (0x01-0x0F)
    case gateEnabled = 0x01
    case gateDisabled = 0x02
    case gateDisablingConfirming = 0x03
    case gateEnablingConfirming = 0x04
    case gateNoChange = 0x05
    
    // Overflow Decisions (0x10-0x1F)
    case noOverflow = 0x10
    case overflowClamped = 0x11
    case overflowIsolated = 0x12
    case overflowFailed = 0x13
    case overflowDegraded = 0x14
    
    // Softmax Decisions (0x20-0x2F)
    case softmaxNormal = 0x20
    case softmaxUniform = 0x21
    case softmaxRemainderDistributed = 0x22
    case softmaxTieBreak = 0x23
    
    // Health Decisions (0x30-0x3F)
    case healthAboveThreshold = 0x30
    case healthBelowThreshold = 0x31
    case healthInHysteresis = 0x32
    
    // Calibration Decisions (0x40-0x4F)
    case calibrationEmpirical = 0x40
    case calibrationFallback = 0x41
    case calibrationDrift = 0x42
    
    // MAD State (0x50-0x5F)
    case madFrozen = 0x50
    case madUpdating = 0x51
    case madRecovery = 0x52
    
    // Frame Context (0x60-0x6F)
    case frameContextCreated = 0x60
    case frameContextConsumed = 0x61
    case sessionStateUpdated = 0x62
    case platformCheckPassed = 0x63
    case platformCheckFailed = 0x64
    
    // Unknown/Invalid
    case unknown = 0xFF
}

/// Path trace V2
public final class PathDeterminismTraceV2 {
    
    // MARK: - Version
    
    public static let currentVersion: UInt16 = 2
    public static let minSupportedVersion: UInt16 = 1
    
    // MARK: - State
    
    private var tokens: [BranchToken] = []
    private let maxTokens: Int = 256
    public let version: UInt16 = currentVersion
    
    public init() {}
    
    // MARK: - Recording
    
    @inline(__always)
    public func record(_ token: BranchToken) {
        guard token != .unknown else { return }
        
        if tokens.count < maxTokens {
            tokens.append(token)
        }
    }
    
    // MARK: - Signature
    
    public var signature: UInt64 {
        var hash: UInt64 = 14695981039346656037  // FNV-1a offset
        let prime: UInt64 = 1099511628211
        
        hash ^= UInt64(version)
        hash = hash &* prime
        
        for token in tokens {
            hash ^= UInt64(token.rawValue)
            hash = hash &* prime
        }
        
        return hash
    }
    
    public var path: [BranchToken] { tokens }
    
    public func reset() {
        tokens.removeAll(keepingCapacity: true)
    }
    
    // MARK: - Serialization
    
    public struct SerializedTrace: Codable, Equatable {
        public let version: UInt16
        public let tokens: [UInt8]
        public let signature: UInt64
        
        public func validate() -> [String] {
            var errors: [String] = []
            
            for (index, rawToken) in tokens.enumerated() {
                if BranchToken(rawValue: rawToken) == nil {
                    errors.append("Unknown token 0x\(String(rawToken, radix: 16)) at index \(index)")
                }
            }
            
            return errors
        }
    }
    
    public func serialize() -> SerializedTrace {
        return SerializedTrace(
            version: version,
            tokens: tokens.map { $0.rawValue },
            signature: signature
        )
    }
    
    public static func deserialize(_ serialized: SerializedTrace) -> PathDeterminismTraceV2? {
        guard serialized.version >= minSupportedVersion else { return nil }
        
        let trace = PathDeterminismTraceV2()
        
        for rawToken in serialized.tokens {
            if let token = BranchToken(rawValue: rawToken) {
                trace.tokens.append(token)
            } else {
                trace.tokens.append(.unknown)
            }
        }
        
        return trace
    }
}
