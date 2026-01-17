//
//  WhiteCriticalMetrics.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 3
//  WhiteCriticalMetrics - critical metrics for Gray→White decisions
//

import Foundation

/// WhiteCriticalMetrics - critical metrics for Gray→White decisions
/// Only brightness + laplacian (PART 2.5)
/// Compile-time type safety prevents featureScore from being mixed in
public struct WhiteCriticalMetrics {
    /// Critical metric IDs
    public static let ids: [MetricId] = [.brightness, .laplacian]
    
    /// Create CriticalMetricBundle from MetricBundle
    /// Type-safe: only brightness + laplacian allowed
    public static func extract(from bundle: MetricBundle) -> CriticalMetricBundle? {
        guard let brightness = bundle.brightness,
              let laplacian = bundle.laplacian else {
            return nil
        }
        
        return CriticalMetricBundle(brightness: brightness, laplacian: laplacian)
    }
}

