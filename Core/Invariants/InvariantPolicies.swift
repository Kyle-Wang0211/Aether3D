//
//  InvariantPolicies.swift
//  Aether3D
//
//  PR#7: Phase 2a - Core/Invariants
//

import Foundation

/// Invariant Policy Definition
/// All policies must be pure data (constants), no runtime dependencies
public struct InvariantPolicies: Codable, Equatable {
    /// Build mode constraints
    public struct BuildModePolicy: Codable, Equatable {
        public let enterTimeoutMs: Int
        public let publishTimeoutMs: Int
        public let failSoftEnabled: Bool
        
        public init(enterTimeoutMs: Int, publishTimeoutMs: Int, failSoftEnabled: Bool) {
            self.enterTimeoutMs = enterTimeoutMs
            self.publishTimeoutMs = publishTimeoutMs
            self.failSoftEnabled = failSoftEnabled
        }
    }
    
    /// Device tier constraints
    public struct DeviceTierPolicy: Codable, Equatable {
        public let maxSplats: Int
        public let maxMemoryMB: Int
        public let shOrder: Int
        
        public init(maxSplats: Int, maxMemoryMB: Int, shOrder: Int) {
            self.maxSplats = maxSplats
            self.maxMemoryMB = maxMemoryMB
            self.shOrder = shOrder
        }
    }
    
    /// Router constraints
    public struct RouterPolicy: Codable, Equatable {
        public let minPhotoCount: Int
        public let minCoverage: Double
        public let maxTimeBudgetMs: Int
        
        public init(minPhotoCount: Int, minCoverage: Double, maxTimeBudgetMs: Int) {
            self.minPhotoCount = minPhotoCount
            self.minCoverage = minCoverage
            self.maxTimeBudgetMs = maxTimeBudgetMs
        }
    }
    
    public let version: String
    public let buildMode: BuildModePolicy
    public let deviceTierLow: DeviceTierPolicy
    public let deviceTierMedium: DeviceTierPolicy
    public let deviceTierHigh: DeviceTierPolicy
    public let router: RouterPolicy
    
    public init(
        version: String,
        buildMode: BuildModePolicy,
        deviceTierLow: DeviceTierPolicy,
        deviceTierMedium: DeviceTierPolicy,
        deviceTierHigh: DeviceTierPolicy,
        router: RouterPolicy
    ) {
        self.version = version
        self.buildMode = buildMode
        self.deviceTierLow = deviceTierLow
        self.deviceTierMedium = deviceTierMedium
        self.deviceTierHigh = deviceTierHigh
        self.router = router
    }
}

/// Default Invariant Policies
public extension InvariantPolicies {
    /// Default policy set (SSOT)
    static let `default` = InvariantPolicies(
        version: "1.3.10",
        buildMode: BuildModePolicy(
            enterTimeoutMs: 2000,
            publishTimeoutMs: 30000,
            failSoftEnabled: true
        ),
        deviceTierLow: DeviceTierPolicy(
            maxSplats: 100000,
            maxMemoryMB: 512,
            shOrder: 1
        ),
        deviceTierMedium: DeviceTierPolicy(
            maxSplats: 500000,
            maxMemoryMB: 2048,
            shOrder: 2
        ),
        deviceTierHigh: DeviceTierPolicy(
            maxSplats: 2000000,
            maxMemoryMB: 8192,
            shOrder: 3
        ),
        router: RouterPolicy(
            minPhotoCount: 10,
            minCoverage: 0.3,
            maxTimeBudgetMs: 180000
        )
    )
}

/// Stable JSON Encoder
/// Ensures deterministic JSON output with sorted keys
public struct StableJSONEncoder {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()
    
    /// Encode to stable JSON string
    public static func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: [],
                debugDescription: "Failed to convert data to UTF-8 string"
            ))
        }
        return string
    }
    
    /// Encode to Data
    public static func encodeToData<T: Encodable>(_ value: T) throws -> Data {
        return try encoder.encode(value)
    }
}

