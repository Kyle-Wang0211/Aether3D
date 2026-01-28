//
// PIZInputValidator.swift
// Aether3D
//
// PR1 PIZ Detection - Input Validation
//
// Validates heatmap inputs before detection logic executes.
// **Rule ID:** PIZ_INPUT_VALIDATION_001, PIZ_INPUT_VALIDATION_002, PIZ_FLOAT_CLASSIFICATION_001

import Foundation

// Import PIZConstants for canonical timestamp

/// Input validation result.
public enum InputValidationResult {
    case valid
    case invalid(reason: String)
}

/// PIZ Input Validator.
/// **Rule ID:** PIZ_INPUT_VALIDATION_001, PIZ_INPUT_VALIDATION_002
public struct PIZInputValidator {
    
    /// Validate heatmap input.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_002
    ///
    /// Validations:
    /// 1. Shape: Exactly 32×32 cells
    /// 2. Floating-point: No NaN, ±Inf, or subnormal values
    /// 3. Range: All values in [0.0, 1.0]
    ///
    /// - Parameter heatmap: The heatmap to validate
    /// - Returns: Validation result
    public static func validate(_ heatmap: [[Double]]) -> InputValidationResult {
        // 1. Shape validation
        guard heatmap.count == PIZThresholds.GRID_SIZE else {
            return .invalid(reason: "Heatmap must be exactly \(PIZThresholds.GRID_SIZE)×\(PIZThresholds.GRID_SIZE), got \(heatmap.count) rows")
        }
        
        for (rowIndex, row) in heatmap.enumerated() {
            guard row.count == PIZThresholds.GRID_SIZE else {
                return .invalid(reason: "Heatmap row \(rowIndex) must have exactly \(PIZThresholds.GRID_SIZE) columns, got \(row.count)")
            }
        }
        
        // 2. Floating-point validation and range validation
        for (rowIndex, row) in heatmap.enumerated() {
            for (colIndex, value) in row.enumerated() {
                // Check NaN
                if value.isNaN {
                    return .invalid(reason: "NaN value at [\(rowIndex)][\(colIndex)]")
                }
                
                // Check ±Inf
                if value.isInfinite {
                    return .invalid(reason: "Infinite value at [\(rowIndex)][\(colIndex)]")
                }
                
                // Check subnormal
                // **Rule ID:** PIZ_FLOAT_CLASSIFICATION_001
                if value.isSubnormal {
                    return .invalid(reason: "Subnormal value at [\(rowIndex)][\(colIndex)]")
                }
                
                // Zero is allowed (0.0 and -0.0)
                if value == 0.0 {
                    continue
                }
                
                // Check range [0.0, 1.0]
                if value < 0.0 || value > 1.0 {
                    return .invalid(reason: "Value out of range [0.0, 1.0] at [\(rowIndex)][\(colIndex)]: \(value)")
                }
            }
        }
        
        return .valid
    }
    
    /// Create INSUFFICIENT_DATA report for invalid input.
    /// **Rule ID:** PIZ_INPUT_VALIDATION_001
    ///
    /// - Parameter reason: Validation failure reason
    /// - Returns: PIZReport with INSUFFICIENT_DATA recommendation
    public static func createInsufficientDataReport(reason: String) -> PIZReport {
        return PIZReport(
            schemaVersion: PIZSchemaVersion.current,
            outputProfile: .fullExplainability,
            foundationVersion: "SSOT_FOUNDATION_v1.1",
            connectivityMode: ConnectivityMode.frozen.rawValue,
            gateRecommendation: .insufficientData,
            globalTrigger: false,
            localTriggerCount: 0,
            heatmap: Array(repeating: Array(repeating: 0.0, count: PIZThresholds.GRID_SIZE), count: PIZThresholds.GRID_SIZE),
            regions: [],
            recaptureSuggestion: RecaptureSuggestion(
                suggestedRegions: [],
                priority: .low,
                reason: "Invalid input: \(reason)"
            ),
            assetId: "",
            timestamp: {
                // Use fixed canonical timestamp for deterministic output
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: "1970-01-01T00:00:00Z")!
            }(),
            computePhase: .finalized
        )
    }
}
