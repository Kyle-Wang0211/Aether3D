//
// FoundationVersioning.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Foundation Versioning Constants
//
// This file defines versioning constants for foundation and contract versions.
//

import Foundation

/// Foundation versioning constants.
///
/// **Rule ID:** FoundationVersioning, C89, C90
/// **Status:** IMMUTABLE
public enum FoundationVersioning {
    
    /// Foundation version string (major.minor format).
    /// **Rule ID:** C89
    /// **Status:** IMMUTABLE
    ///
    /// Format: "major.minor" (e.g., "1.1")
    /// Tests validate regex: ^\d+\.\d+$
    public static let FOUNDATION_VERSION = "1.1"
    
    /// Contract version integer (monotonically increasing).
    /// **Rule ID:** C90
    /// **Status:** IMMUTABLE
    ///
    /// Must be monotonically increasing; forbid manual decrement.
    /// Increments only on breaking output contract changes.
    public static let CONTRACT_VERSION: Int = 1
    
    /// Compatibility policy.
    /// **Rule ID:** CompatPolicy
    /// **Status:** IMMUTABLE
    public static let COMPAT_POLICY: CompatPolicy = .appendOnly
    
    // MARK: - Version Format Validation
    
    /// Validates foundation version format.
    /// **Rule ID:** C89
    /// **Status:** IMMUTABLE
    ///
    /// Format must be "major.minor" (e.g., "1.1")
    public static func isValidFoundationVersion(_ version: String) -> Bool {
        let pattern = #"^\d+\.\d+$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: version.utf16.count)
        return regex?.firstMatch(in: version, range: range) != nil
    }
}
