//
// PIZCanonicalJSON.swift
// Aether3D
//
// PR1 PIZ Detection - Canonical JSON Encoder
//
// Implements canonical JSON encoding with fixed decimal formatting.
// **Rule ID:** PIZ_JSON_CANON_001, PIZ_NUMERIC_FORMAT_001

import Foundation

/// Canonical JSON encoder for PIZ reports.
/// **Rule ID:** PIZ_JSON_CANON_001
public enum PIZCanonicalJSON {
    
    /// Encode PIZReport to canonical JSON string.
    /// **Rule ID:** PIZ_JSON_CANON_001
    ///
    /// Format:
    /// - UTF-8 encoding
    /// - Lexicographic key ordering
    /// - Compact format (no pretty-print)
    /// - Fixed decimal formatting for floats (no scientific notation)
    /// - No trailing whitespace
    ///
    /// - Parameter report: The report to encode
    /// - Returns: Canonical JSON string (UTF-8)
    public static func encode(_ report: PIZReport) throws -> String {
        var parts: [String] = []
        
        // Sort keys lexicographically
        var keyValuePairs: [(String, String)] = []
        
        // Schema version
        keyValuePairs.append(("schemaVersion", encodeSchemaVersion(report.schemaVersion)))
        
        // Output profile
        keyValuePairs.append(("outputProfile", "\"\(report.outputProfile.rawValue)\""))
        
        // Gate recommendation
        keyValuePairs.append(("gateRecommendation", "\"\(report.gateRecommendation.rawValue)\""))
        
        // Global trigger
        keyValuePairs.append(("globalTrigger", report.globalTrigger ? "true" : "false"))
        
        // Local trigger count
        keyValuePairs.append(("localTriggerCount", String(report.localTriggerCount)))
        
        // Explainability fields (only for FullExplainability)
        if report.outputProfile == .fullExplainability {
            if let foundationVersion = report.foundationVersion.nonEmpty {
                keyValuePairs.append(("foundationVersion", escapeJSONString(foundationVersion)))
            }
            if let connectivityMode = report.connectivityMode.nonEmpty {
                keyValuePairs.append(("connectivityMode", escapeJSONString(connectivityMode)))
            }
            if let heatmap = report.heatmap {
                keyValuePairs.append(("heatmap", encodeHeatmap(heatmap)))
            }
            if let regions = report.regions {
                keyValuePairs.append(("regions", encodeRegions(regions)))
            }
            if let recaptureSuggestion = report.recaptureSuggestion {
                keyValuePairs.append(("recaptureSuggestion", encodeRecaptureSuggestion(recaptureSuggestion)))
            }
            if let assetId = report.assetId {
                keyValuePairs.append(("assetId", escapeJSONString(assetId)))
            }
            if let timestamp = report.timestamp {
                keyValuePairs.append(("timestamp", encodeTimestamp(timestamp)))
            }
            if let computePhase = report.computePhase {
                keyValuePairs.append(("computePhase", "\"\(computePhase.rawValue)\""))
            }
        }
        
        // Sort by key (lexicographic)
        keyValuePairs.sort { $0.0 < $1.0 }
        
        // Build JSON string
        parts.append("{")
        for (index, (key, value)) in keyValuePairs.enumerated() {
            if index > 0 {
                parts.append(",")
            }
            parts.append("\"\(escapeJSONString(key))\":\(value)")
        }
        parts.append("}")
        
        return parts.joined()
    }
    
    /// Encode schema version object.
    private static func encodeSchemaVersion(_ version: PIZSchemaVersion) -> String {
        return "{\"major\":\(version.major),\"minor\":\(version.minor),\"patch\":\(version.patch)}"
    }
    
    /// Encode heatmap array.
    private static func encodeHeatmap(_ heatmap: [[Double]]) -> String {
        let quantized = PIZFloatCanon.quantizeHeatmap(heatmap)
        let rows = quantized.map { row in
            "[" + row.map { formatFloat($0) }.joined(separator: ",") + "]"
        }
        return "[" + rows.joined(separator: ",") + "]"
    }
    
    /// Encode regions array.
    private static func encodeRegions(_ regions: [PIZRegion]) -> String {
        let quantized = regions.map { PIZFloatCanon.quantizeRegion($0) }
        let regionStrings = quantized.map { encodeRegion($0) }
        return "[" + regionStrings.joined(separator: ",") + "]"
    }
    
    /// Encode a single region.
    private static func encodeRegion(_ region: PIZRegion) -> String {
        var pairs: [(String, String)] = []
        pairs.append(("areaRatio", formatFloat(region.areaRatio)))
        pairs.append(("bbox", encodeBoundingBox(region.bbox)))
        pairs.append(("centroid", encodePoint(region.centroid)))
        pairs.append(("id", escapeJSONString(region.id)))
        pairs.append(("pixelCount", String(region.pixelCount)))
        pairs.append(("principalDirection", encodeVector(region.principalDirection)))
        pairs.append(("severityScore", formatFloat(region.severityScore)))
        
        pairs.sort { $0.0 < $1.0 }
        
        let parts = pairs.map { "\"\($0.0)\":\($0.1)" }
        return "{" + parts.joined(separator: ",") + "}"
    }
    
    /// Encode bounding box.
    private static func encodeBoundingBox(_ bbox: BoundingBox) -> String {
        return "{\"maxCol\":\(bbox.maxCol),\"maxRow\":\(bbox.maxRow),\"minCol\":\(bbox.minCol),\"minRow\":\(bbox.minRow)}"
    }
    
    /// Encode point.
    private static func encodePoint(_ point: Point) -> String {
        return "{\"col\":\(formatFloat(point.col)),\"row\":\(formatFloat(point.row))}"
    }
    
    /// Encode vector.
    private static func encodeVector(_ vector: Vector) -> String {
        return "{\"dx\":\(formatFloat(vector.dx)),\"dy\":\(formatFloat(vector.dy))}"
    }
    
    /// Encode recapture suggestion.
    private static func encodeRecaptureSuggestion(_ suggestion: RecaptureSuggestion) -> String {
        var pairs: [(String, String)] = []
        pairs.append(("priority", "\"\(suggestion.priority.rawValue)\""))
        pairs.append(("reason", escapeJSONString(suggestion.reason)))
        pairs.append(("suggestedRegions", encodeStringArray(suggestion.suggestedRegions)))
        
        pairs.sort { $0.0 < $1.0 }
        
        let parts = pairs.map { "\"\($0.0)\":\($0.1)" }
        return "{" + parts.joined(separator: ",") + "}"
    }
    
    /// Encode string array.
    private static func encodeStringArray(_ array: [String]) -> String {
        let escaped = array.map { escapeJSONString($0) }
        return "[" + escaped.map { "\"\($0)\"" }.joined(separator: ",") + "]"
    }
    
    /// Encode timestamp (ISO 8601).
    private static func encodeTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return escapeJSONString(formatter.string(from: date))
    }
    
    /// Format floating-point value with fixed decimal places.
    /// **Rule ID:** PIZ_NUMERIC_FORMAT_001
    ///
    /// - Exactly JSON_CANON_DECIMAL_PLACES digits after decimal point
    /// - No scientific notation
    /// - Fixed-point format
    private static func formatFloat(_ value: Double) -> String {
        let decimalPlaces = PIZThresholds.JSON_CANON_DECIMAL_PLACES
        let quantized = PIZFloatCanon.quantize(value)
        
        // Format with fixed decimal places
        let formatted = String(format: "%.\(decimalPlaces)f", quantized)
        
        // Verify no scientific notation (defensive check)
        assert(!formatted.contains("e") && !formatted.contains("E"), "Scientific notation forbidden in canonical JSON")
        
        return formatted
    }
    
    /// Escape JSON string.
    private static func escapeJSONString(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        
        for char in string {
            switch char {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if let scalar = char.unicodeScalars.first {
                    let value = scalar.value
                    if value < 0x20 || value == 0x7F {
                        result += String(format: "\\u%04X", value)
                    } else {
                        result.append(char)
                    }
                } else {
                    result.append(char)
                }
            }
        }
        
        return result
    }
}

extension String {
    var nonEmpty: String? {
        return isEmpty ? nil : self
    }
}
