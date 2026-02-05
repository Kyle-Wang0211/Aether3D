//
// LinearColorSpaceConverter.swift
// PR5Capture
//
// PR5 v1.8.1 - PART A: Raw 溯源和 ISP 真实性
// sRGB 到线性空间转换，颜色空间一致性保证
//

import Foundation

/// Linear color space converter
///
/// Converts sRGB to linear color space with consistency guarantees.
/// Ensures color space consistency across the pipeline.
public struct LinearColorSpaceConverter {
    
    // MARK: - sRGB to Linear Conversion
    
    /// Convert sRGB value to linear
    ///
    /// Applies gamma correction: linear = (sRGB / 255.0) ^ 2.2
    public static func sRGBToLinear(_ sRGB: Double) -> Double {
        guard sRGB >= 0.0 && sRGB <= 1.0 else {
            return sRGB  // Out of range, return as-is
        }
        
        if sRGB <= 0.04045 {
            return sRGB / 12.92
        } else {
            return pow((sRGB + 0.055) / 1.055, 2.4)
        }
    }
    
    /// Convert linear value to sRGB
    ///
    /// Inverse gamma correction: sRGB = (linear ^ (1/2.2)) * 255.0
    public static func linearToSRGB(_ linear: Double) -> Double {
        guard linear >= 0.0 && linear <= 1.0 else {
            return linear  // Out of range, return as-is
        }
        
        if linear <= 0.0031308 {
            return linear * 12.92
        } else {
            return 1.055 * pow(linear, 1.0 / 2.4) - 0.055
        }
    }
    
    /// Convert sRGB pixel array to linear
    public static func convertSRGBToLinear(_ pixels: [Double]) -> [Double] {
        return pixels.map { sRGBToLinear($0) }
    }
    
    /// Convert linear pixel array to sRGB
    public static func convertLinearToSRGB(_ pixels: [Double]) -> [Double] {
        return pixels.map { linearToSRGB($0) }
    }
    
    // MARK: - Consistency Verification
    
    /// Verify color space consistency
    ///
    /// Checks that conversion is reversible within acceptable error
    public static func verifyConsistency(_ original: Double, tolerance: Double = 0.001) -> Bool {
        let linear = sRGBToLinear(original)
        let convertedBack = linearToSRGB(linear)
        let error = abs(original - convertedBack)
        return error <= tolerance
    }
}
