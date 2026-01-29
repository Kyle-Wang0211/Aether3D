//
// SSOTTypes.swift
// Aether3D
//
// Core types and specifications for SSOT constants.
//

import Foundation

// MARK: - Units

/// Standard units for SSOT constants.
public enum SSOTUnit: String, Codable, CaseIterable {
    case frames
    case gaussians
    case ratio
    case db
    case pixels
    case bytes
    case seconds
    case milliseconds
    case dimensionless
    case count
    case degrees
    case degreesPerFrame
    case metersPerFrame
    case meters
    case variance
    case brightness
    case percent
    case degreesPerSecond
}

// MARK: - Categories

/// Category for threshold classification.
public enum ThresholdCategory: String, Codable, CaseIterable {
    case quality
    case performance
    case safety
    case resource
    case motion
    case photometric
}

/// Behavior when a value exceeds a threshold.
public enum ExceedBehavior: String, Codable, CaseIterable {
    case clamp
    case reject
    case warn
}

/// Behavior when a value underflows a minimum limit.
public enum UnderflowBehavior: String, Codable, CaseIterable {
    case clamp
    case reject
    case warn
}

// MARK: - Specifications

/// Specification for a threshold constant.
public struct ThresholdSpec: Codable, Equatable {
    /// Unique identifier (e.g., "QualityThresholds.sfmRegistrationMinRatio")
    public let ssotId: String
    
    /// Human-readable name
    public let name: String
    
    /// Unit of measurement
    public let unit: SSOTUnit
    
    /// Category
    public let category: ThresholdCategory
    
    /// Minimum allowed value (inclusive)
    public let min: Double
    
    /// Maximum allowed value (inclusive)
    public let max: Double
    
    /// Default/recommended value
    public let defaultValue: Double
    
    /// Behavior when exceeded
    public let onExceed: ExceedBehavior
    
    /// Behavior when underflowed
    public let onUnderflow: UnderflowBehavior
    
    /// Documentation string
    public let documentation: String
    
    public init(
        ssotId: String,
        name: String,
        unit: SSOTUnit,
        category: ThresholdCategory,
        min: Double,
        max: Double,
        defaultValue: Double,
        onExceed: ExceedBehavior,
        onUnderflow: UnderflowBehavior,
        documentation: String
    ) {
        self.ssotId = ssotId
        self.name = name
        self.unit = unit
        self.category = category
        self.min = min
        self.max = max
        self.defaultValue = defaultValue
        self.onExceed = onExceed
        self.onUnderflow = onUnderflow
        self.documentation = documentation
    }
}

/// Specification for a system constant (hard limit).
public struct SystemConstantSpec: Codable, Equatable {
    /// Unique identifier (e.g., "SystemConstants.maxFrames")
    public let ssotId: String
    
    /// Human-readable name
    public let name: String
    
    /// Unit of measurement
    public let unit: SSOTUnit
    
    /// The constant value
    public let value: Int
    
    /// Documentation string
    public let documentation: String
    
    public init(
        ssotId: String,
        name: String,
        unit: SSOTUnit,
        value: Int,
        documentation: String
    ) {
        self.ssotId = ssotId
        self.name = name
        self.unit = unit
        self.value = value
        self.documentation = documentation
    }
}

/// Specification for a minimum limit constant.
public struct MinLimitSpec: Codable, Equatable {
    /// Unique identifier (e.g., "SystemConstants.minFrames")
    public let ssotId: String
    
    /// Human-readable name
    public let name: String
    
    /// Unit of measurement
    public let unit: SSOTUnit
    
    /// The minimum value (inclusive)
    public let minValue: Int
    
    /// Behavior when underflowed
    public let onUnderflow: UnderflowBehavior
    
    /// Documentation string
    public let documentation: String
    
    public init(
        ssotId: String,
        name: String,
        unit: SSOTUnit,
        minValue: Int,
        onUnderflow: UnderflowBehavior,
        documentation: String
    ) {
        self.ssotId = ssotId
        self.name = name
        self.unit = unit
        self.minValue = minValue
        self.onUnderflow = onUnderflow
        self.documentation = documentation
    }
}

/// Specification for a fixed mathematical constant (immutable conversion factor).
public struct FixedConstantSpec: Codable, Equatable {
    /// Unique identifier (e.g., "ConversionConstants.bytesPerKB")
    public let ssotId: String
    
    /// Human-readable name
    public let name: String
    
    /// Unit of measurement
    public let unit: SSOTUnit
    
    /// The constant value (must be a literal)
    public let value: Int
    
    /// Documentation string
    public let documentation: String
    
    public init(
        ssotId: String,
        name: String,
        unit: SSOTUnit,
        value: Int,
        documentation: String
    ) {
        self.ssotId = ssotId
        self.name = name
        self.unit = unit
        self.value = value
        self.documentation = documentation
    }
}

/// Type-erased constant specification.
public enum AnyConstantSpec: Codable, Equatable {
    case threshold(ThresholdSpec)
    case systemConstant(SystemConstantSpec)
    case minLimit(MinLimitSpec)
    case fixedConstant(FixedConstantSpec)
    
    public var ssotId: String {
        switch self {
        case .threshold(let spec): return spec.ssotId
        case .systemConstant(let spec): return spec.ssotId
        case .minLimit(let spec): return spec.ssotId
        case .fixedConstant(let spec): return spec.ssotId
        }
    }
    
    public init(_ spec: ThresholdSpec) {
        self = .threshold(spec)
    }
    
    public init(_ spec: SystemConstantSpec) {
        self = .systemConstant(spec)
    }
    
    public init(_ spec: MinLimitSpec) {
        self = .minLimit(spec)
    }
    
    public init(_ spec: FixedConstantSpec) {
        self = .fixedConstant(spec)
    }
    
    // MARK: - Codable
    
    private enum CodingKeys: String, CodingKey {
        case type
        case spec
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "threshold":
            let spec = try container.decode(ThresholdSpec.self, forKey: .spec)
            self = .threshold(spec)
        case "systemConstant":
            let spec = try container.decode(SystemConstantSpec.self, forKey: .spec)
            self = .systemConstant(spec)
        case "minLimit":
            let spec = try container.decode(MinLimitSpec.self, forKey: .spec)
            self = .minLimit(spec)
        case "fixedConstant":
            let spec = try container.decode(FixedConstantSpec.self, forKey: .spec)
            self = .fixedConstant(spec)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown spec type: \(type)"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .threshold(let spec):
            try container.encode("threshold", forKey: .type)
            try container.encode(spec, forKey: .spec)
        case .systemConstant(let spec):
            try container.encode("systemConstant", forKey: .type)
            try container.encode(spec, forKey: .spec)
        case .minLimit(let spec):
            try container.encode("minLimit", forKey: .type)
            try container.encode(spec, forKey: .spec)
        case .fixedConstant(let spec):
            try container.encode("fixedConstant", forKey: .type)
            try container.encode(spec, forKey: .spec)
        }
    }
}

