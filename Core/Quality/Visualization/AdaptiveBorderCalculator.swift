//
// AdaptiveBorderCalculator.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Adaptive Border Calculator
// Pure algorithm — Foundation only
//

import Foundation

/// Calculates adaptive border widths based on display value and triangle area
public final class AdaptiveBorderCalculator {
    
    public init() {}
    
    /// Calculate border widths for triangles based on display values and areas
    ///
    /// Formula: width = base × (displayWeight × (1-display) + areaWeight × sqrt(area/median))^gamma
    /// Then clamped to [borderMinWidthPx, borderMaxWidthPx]
    ///
    /// - Parameters:
    ///   - displayValues: Map of patch ID to display value [0, 1]
    ///   - triangles: Array of triangles (used to get patchId and area)
    ///   - medianArea: Median area for normalization
    /// - Returns: Array of border widths in pixels (same order as triangles)
    public func calculate(
        displayValues: [String: Double],
        triangles: [ScanTriangle],
        medianArea: Float
    ) -> [Float] {
        guard !triangles.isEmpty else {
            return []
        }
        
        var widths: [Float] = []
        
        for triangle in triangles {
            let display = displayValues[triangle.patchId] ?? 0.0
            let width = calculate(
                display: display,
                areaSqM: triangle.areaSqM,
                medianArea: medianArea
            )
            widths.append(width)
        }
        
        return widths
    }
    
    /// Calculate border width for a single triangle
    ///
    /// - Parameters:
    ///   - display: Display value [0, 1]
    ///   - areaSqM: Triangle area in square meters
    ///   - medianArea: Median area for normalization
    /// - Returns: Border width in pixels
    public func calculate(
        display: Double,
        areaSqM: Float,
        medianArea: Float
    ) -> Float {
        let base = Float(ScanGuidanceConstants.borderBaseWidthPx)
        let minWidth = Float(ScanGuidanceConstants.borderMinWidthPx)
        let maxWidth = Float(ScanGuidanceConstants.borderMaxWidthPx)
        let displayWeight = Float(ScanGuidanceConstants.borderDisplayWeight)
        let areaWeight = Float(ScanGuidanceConstants.borderAreaWeight)
        let gamma = Float(ScanGuidanceConstants.borderGamma)
        
        let clampedDisplay = min(max(display, 0.0), 1.0)
        
        // Calculate area factor
        let areaFactor = sqrt(areaSqM / max(medianArea, 1e-6))
        let clampedAreaFactor = min(max(areaFactor, 0.5), 2.0)
        
        // Dual-factor calculation
        let displayFactor = displayWeight * Float(1.0 - clampedDisplay)
        let areaFactorValue = areaWeight * clampedAreaFactor
        let combinedFactor = displayFactor + areaFactorValue
        
        // Apply gamma correction
        let gammaCorrected = pow(combinedFactor, gamma)
        
        // Calculate width
        let width = base * gammaCorrected
        
        // Clamp to [minWidth, maxWidth]
        return min(max(width, minWidth), maxWidth)
    }
}
