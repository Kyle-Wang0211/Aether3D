//
// ComplianceConstants.swift
// Aether3D
//
// Compliance Constants - China National Standards (GB/T, CH/T, PIPL)
// 符合 PR1-02: Chinese National Standards Compliance Constants
//

import Foundation

/// Compliance Constants
///
/// Chinese National Standards compliance constants.
/// GB/T 35273-2020: Personal Information Protection Law (PIPL)
/// GB/T 45574-2025: Sensitive Personal Information Protection
/// CH/T 1001-2005: Surveying Standards
/// GB 37300-2018: Video Collection Standards
public enum ComplianceConstants {
    
    // MARK: - PIPL Compliance (GB/T 35273-2020)
    
    /// Biometric consent required (GB/T 35273-2020)
    /// Unit: boolean
    /// PIPL requires explicit consent for biometric data collection
    public static let cnPIPLBiometricConsentRequired: Bool = true
    
    /// Sensitive personal information retention period (days)
    /// Unit: days
    /// GB/T 35273-2020: Maximum retention period for sensitive PI
    public static let cnSensitivePIRetentionDays: Int = 180
    
    /// Sensitive personal information encryption required (GB/T 45574-2025)
    /// Unit: boolean
    /// GB/T 45574-2025: Sensitive PI must be encrypted
    public static let cnSensitivePIEncryptionRequired: Bool = true
    
    // MARK: - Photogrammetry Standards (CH/T 1001-2005)
    
    /// Photogrammetry accuracy requirement (mm/m)
    /// Unit: millimeters per meter
    /// CH/T 1001-2005: Surveying accuracy standard
    public static let cnPhotogrammetryAccuracyMmM: Double = 0.015
    
    // MARK: - Video Collection Standards (GB 37300-2018)
    
    /// Required metadata fields for video collection
    /// Unit: array of field names
    /// GB 37300-2018: Required metadata fields
    public static let cnVideoMetadataRequiredFields: [String] = [
        "location",
        "timestamp",
        "device_id",
        "operator_id"
    ]
    
    // MARK: - GDPR Compliance
    
    /// GDPR data retention period (days)
    /// Unit: days
    /// GDPR: Maximum retention period for personal data
    public static let gdprDataRetentionDays: Int = 365
    
    /// GDPR right to deletion enabled
    /// Unit: boolean
    /// GDPR: Users have right to request data deletion
    public static let gdprRightToDeletionEnabled: Bool = true
    
    // MARK: - eIDAS Compliance
    
    /// eIDAS qualified signature required
    /// Unit: boolean
    /// eIDAS: Qualified electronic signatures for legal validity
    public static let eidasQualifiedSignatureRequired: Bool = false // Optional for now
    
    // MARK: - Specifications
    
    /// Specification for cnPIPLBiometricConsentRequired
    public static let cnPIPLBiometricConsentRequiredSpec = ComplianceSpec(
        ssotId: "ComplianceConstants.cnPIPLBiometricConsentRequired",
        name: "PIPL Biometric Consent Required",
        standard: "GB/T 35273-2020",
        value: .bool(cnPIPLBiometricConsentRequired),
        documentation: "PIPL requires explicit consent for biometric data collection"
    )
    
    /// Specification for cnSensitivePIRetentionDays
    public static let cnSensitivePIRetentionDaysSpec = ComplianceSpec(
        ssotId: "ComplianceConstants.cnSensitivePIRetentionDays",
        name: "Sensitive PI Retention Period",
        standard: "GB/T 35273-2020",
        value: .int(cnSensitivePIRetentionDays),
        documentation: "Maximum retention period for sensitive personal information (GB/T 35273-2020)"
    )
    
    /// Specification for cnSensitivePIEncryptionRequired
    public static let cnSensitivePIEncryptionRequiredSpec = ComplianceSpec(
        ssotId: "ComplianceConstants.cnSensitivePIEncryptionRequired",
        name: "Sensitive PI Encryption Required",
        standard: "GB/T 45574-2025",
        value: .bool(cnSensitivePIEncryptionRequired),
        documentation: "Sensitive personal information must be encrypted (GB/T 45574-2025)"
    )
    
    /// Specification for cnPhotogrammetryAccuracyMmM
    public static let cnPhotogrammetryAccuracyMmMSpec = ComplianceSpec(
        ssotId: "ComplianceConstants.cnPhotogrammetryAccuracyMmM",
        name: "Photogrammetry Accuracy",
        standard: "CH/T 1001-2005",
        value: .double(cnPhotogrammetryAccuracyMmM),
        documentation: "Photogrammetry accuracy requirement (CH/T 1001-2005)"
    )
    
    /// All compliance constant specs
    public static let allSpecs: [ComplianceSpec] = [
        cnPIPLBiometricConsentRequiredSpec,
        cnSensitivePIRetentionDaysSpec,
        cnSensitivePIEncryptionRequiredSpec,
        cnPhotogrammetryAccuracyMmMSpec
    ]
}

// MARK: - Compliance Specification

/// Compliance specification
public struct ComplianceSpec: Codable, Sendable {
    public let ssotId: String
    public let name: String
    public let standard: String
    public let value: AnyComplianceValue
    public let documentation: String
}

/// Compliance value (supports Bool, Int, Double)
public enum AnyComplianceValue: Codable, Sendable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else {
            self = .double(try container.decode(Double.self))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        }
    }
}
