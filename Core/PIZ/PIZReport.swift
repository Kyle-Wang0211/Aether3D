//
// PIZReport.swift
// Aether3D
//
// PR1 PIZ Detection - Report Schema (v1)
//
// Versioned, closed-world schema for PIZ detection results.
// Rejects unknown fields during decoding.
// **Rule ID:** PIZ_SCHEMA_PROFILE_001, PIZ_SCHEMA_COMPAT_001

import Foundation

/// Output profile enum (closed set).
/// **Rule ID:** PIZ_OUTPUT_PROFILE_001, PIZ_SCHEMA_PROFILE_001
public enum OutputProfile: String, Codable {
    case decisionOnly = "DecisionOnly"
    case fullExplainability = "FullExplainability"
}

/// Schema version structure (semantic versioning).
/// **Rule ID:** PIZ_SCHEMA_COMPAT_001
public struct PIZSchemaVersion: Codable, Equatable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    
    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }
    
    /// Current schema version (v1.0.0).
    public static let current = PIZSchemaVersion(major: 1, minor: 0, patch: 0)
    
    /// Compare versions for compatibility checking.
    public func isCompatibleWith(_ other: PIZSchemaVersion) -> Bool {
        if major != other.major {
            return false // Major version mismatch = incompatible
        }
        if minor < other.minor {
            return true // Older minor can parse newer (open-set)
        }
        return true // Same or newer minor = compatible
    }
}

/// PIZ Detection Report (v1).
/// 
/// **Schema Version:** 1.0.0
/// **Connectivity Mode:** FOUR (frozen)
/// **Closed-World:** Unknown fields are rejected during decoding per schemaVersion and outputProfile.
/// **Rule ID:** PIZ_SCHEMA_PROFILE_001
public struct PIZReport: Codable {
    /// Schema version (semantic versioning).
    public let schemaVersion: PIZSchemaVersion
    
    /// Output profile (DecisionOnly or FullExplainability).
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    public let outputProfile: OutputProfile
    
    /// Foundation version string.
    public let foundationVersion: String
    
    /// Connectivity mode used (frozen to FOUR).
    public let connectivityMode: String
    
    /// Gate recommendation (closed set enum).
    public let gateRecommendation: GateRecommendation
    
    /// Global trigger fired flag.
    public let globalTrigger: Bool
    
    /// Number of regions passing local trigger.
    public let localTriggerCount: Int
    
    /// 32x32 heatmap grid (row-major, values 0.0-1.0).
    /// Required for FullExplainability profile only.
    public let heatmap: [[Double]]?
    
    /// List of detected PIZ regions.
    /// Required for FullExplainability profile only.
    public let regions: [PIZRegion]?
    
    /// Structured recapture suggestion.
    /// Required for FullExplainability profile only.
    public let recaptureSuggestion: RecaptureSuggestion?
    
    /// Asset ID.
    /// Required for FullExplainability profile only.
    public let assetId: String?
    
    /// Timestamp (for output only, not used in decision path).
    /// Required for FullExplainability profile only.
    public let timestamp: Date?
    
    /// Compute phase.
    /// Required for FullExplainability profile only.
    public let computePhase: ComputePhase?
    
    /// Initialize DecisionOnly profile report.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    public init(
        schemaVersion: PIZSchemaVersion,
        outputProfile: OutputProfile,
        gateRecommendation: GateRecommendation,
        globalTrigger: Bool,
        localTriggerCount: Int
    ) {
        self.schemaVersion = schemaVersion
        self.outputProfile = outputProfile
        self.foundationVersion = ""
        self.connectivityMode = ""
        self.gateRecommendation = gateRecommendation
        self.globalTrigger = globalTrigger
        self.localTriggerCount = localTriggerCount
        self.heatmap = nil
        self.regions = nil
        self.recaptureSuggestion = nil
        self.assetId = nil
        self.timestamp = nil
        self.computePhase = nil
    }
    
    /// Initialize FullExplainability profile report.
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001
    public init(
        schemaVersion: PIZSchemaVersion,
        outputProfile: OutputProfile,
        foundationVersion: String,
        connectivityMode: String,
        gateRecommendation: GateRecommendation,
        globalTrigger: Bool,
        localTriggerCount: Int,
        heatmap: [[Double]],
        regions: [PIZRegion],
        recaptureSuggestion: RecaptureSuggestion,
        assetId: String,
        timestamp: Date,
        computePhase: ComputePhase
    ) {
        self.schemaVersion = schemaVersion
        self.outputProfile = outputProfile
        self.foundationVersion = foundationVersion
        self.connectivityMode = connectivityMode
        self.gateRecommendation = gateRecommendation
        self.globalTrigger = globalTrigger
        self.localTriggerCount = localTriggerCount
        self.heatmap = heatmap
        self.regions = regions
        self.recaptureSuggestion = recaptureSuggestion
        self.assetId = assetId
        self.timestamp = timestamp
        self.computePhase = computePhase
    }
    
    /// Custom decoding to enforce closed-world (reject unknown fields).
    /// **Rule ID:** PIZ_SCHEMA_PROFILE_001, PIZ_SCHEMA_COMPAT_001
    public init(from decoder: Decoder) throws {
        // First, get all keys from the raw container to check for unknown fields
        let rawContainer = try decoder.container(keyedBy: PIZDynamicCodingKey.self)
        let allRawKeys = Set(rawContainer.allKeys.map { $0.stringValue })
        
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Decode schemaVersion first (needed for compatibility checking)
        let schemaVersionValue = try container.decode(PIZSchemaVersion.self, forKey: .schemaVersion)
        self.schemaVersion = schemaVersionValue
        
        // Decode outputProfile (needed for profile-gated field sets)
        self.outputProfile = try container.decode(OutputProfile.self, forKey: .outputProfile)
        
        // Decode decision fields (always required)
        self.gateRecommendation = try container.decode(GateRecommendation.self, forKey: .gateRecommendation)
        self.globalTrigger = try container.decode(Bool.self, forKey: .globalTrigger)
        self.localTriggerCount = try container.decode(Int.self, forKey: .localTriggerCount)
        
        // Profile-gated decoding
        switch outputProfile {
        case .decisionOnly:
            // DecisionOnly: reject explainability fields (strictness)
            if container.contains(.heatmap) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'heatmap' is forbidden"
                    )
                )
            }
            if container.contains(.regions) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'regions' is forbidden"
                    )
                )
            }
            if container.contains(.recaptureSuggestion) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'recaptureSuggestion' is forbidden"
                    )
                )
            }
            if container.contains(.assetId) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'assetId' is forbidden"
                    )
                )
            }
            if container.contains(.timestamp) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'timestamp' is forbidden"
                    )
                )
            }
            if container.contains(.computePhase) {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "DecisionOnly profile: explainability field 'computePhase' is forbidden"
                    )
                )
            }
            
            // Set explainability fields to nil
            self.heatmap = nil
            self.regions = nil
            self.recaptureSuggestion = nil
            self.assetId = nil
            self.timestamp = nil
            self.computePhase = nil
            self.foundationVersion = ""
            self.connectivityMode = ""
            
        case .fullExplainability:
            // FullExplainability: require all fields
            self.foundationVersion = try container.decode(String.self, forKey: .foundationVersion)
            self.connectivityMode = try container.decode(String.self, forKey: .connectivityMode)
            self.heatmap = try container.decode([[Double]].self, forKey: .heatmap)
            self.regions = try container.decode([PIZRegion].self, forKey: .regions)
            self.recaptureSuggestion = try container.decode(RecaptureSuggestion.self, forKey: .recaptureSuggestion)
            self.assetId = try container.decode(String.self, forKey: .assetId)
            self.timestamp = try container.decode(Date.self, forKey: .timestamp)
            self.computePhase = try container.decode(ComputePhase.self, forKey: .computePhase)
        }
        
        // Closed-world: check for unknown fields
        // Same schemaVersion: strict closed-set (unknown fields rejected)
        // Older schemaVersion parsing newer minor: open-set (unknown fields ignored)
        // **Rule ID:** PIZ_SCHEMA_COMPAT_001
        let decoderSchemaVersion = decoder.userInfo[.pizSchemaVersion] as? PIZSchemaVersion ?? schemaVersionValue
        let isSameVersion = decoderSchemaVersion.major == schemaVersionValue.major && decoderSchemaVersion.minor == schemaVersionValue.minor
        let _ = decoderSchemaVersion.major == schemaVersionValue.major && decoderSchemaVersion.minor < schemaVersionValue.minor // isOlderMinor (for future use)
        
        if isSameVersion {
            // Same version: strict closed-set
            // Use raw keys from the raw container to detect unknown fields
            let knownKeys = Set(CodingKeys.allCases.map { $0.stringValue })
            let unknownKeys = allRawKeys.subtracting(knownKeys)
            
            if !unknownKeys.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown fields found: \(unknownKeys.joined(separator: ", "))"
                    )
                )
            }
        }
        // Older minor version parsing newer: unknown fields are ignored (open-set)
        // This is handled implicitly by not checking unknownKeys when isOlderMinor is true
    }
    
    /// Coding keys enum (explicit, closed set).
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case outputProfile
        case foundationVersion
        case connectivityMode
        case gateRecommendation
        case globalTrigger
        case localTriggerCount
        case heatmap
        case regions
        case recaptureSuggestion
        case assetId
        case timestamp
        case computePhase
    }
}

/// Dynamic coding key for checking all keys in JSON (including unknown ones).
private struct PIZDynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    
    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// Note: CodingUserInfoKey extension moved to Core/Constants/PIZConstants.swift to avoid scattered constants

/// Compute phase enum.
public enum ComputePhase: String, Codable {
    case realtimeEstimate = "realtime_estimate"
    case delayedRefinement = "delayed_refinement"
    case finalized = "finalized"
}
