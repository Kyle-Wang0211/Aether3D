//
// PIZConstants.swift
// Aether3D
//
// PR1 PIZ Detection - Additional Constants
//
// Constants for PIZ detection that don't belong in PIZThresholds.
// **Rule ID:** PIZ_SCHEMA_COMPAT_001

import Foundation

extension CodingUserInfoKey {
    /// User info key for schema version compatibility checking.
    /// **Rule ID:** PIZ_SCHEMA_COMPAT_001
    public static let pizSchemaVersion = CodingUserInfoKey(rawValue: "pizSchemaVersion")!
}
