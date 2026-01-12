//
// SystemConstants.swift
// Aether3D
//
// System-level hard limits and constants.
//

import Foundation

/// System constants with hard limits.
public enum SystemConstants {
    /// Maximum number of frames (frames)
    /// 15分钟视频采样上限
    public static let maxFrames = 5000
    
    /// Minimum number of frames (frames)
    public static let minFrames = 10
    
    /// Maximum number of Gaussians (gaussians)
    public static let maxGaussians = 1000000
    
    // MARK: - Specifications
    
    /// Specification for maxFrames
    public static let maxFramesSpec = SystemConstantSpec(
        ssotId: "SystemConstants.maxFrames",
        name: "Maximum Frames",
        unit: .frames,
        value: maxFrames,
        documentation: "Hard limit on maximum number of frames in a capture sequence (15分钟视频采样上限)"
    )
    
    /// Specification for minFrames
    public static let minFramesSpec = MinLimitSpec(
        ssotId: "SystemConstants.minFrames",
        name: "Minimum Frames",
        unit: .frames,
        minValue: minFrames,
        onUnderflow: .reject,
        documentation: "Hard limit on minimum number of frames required for processing"
    )
    
    /// Specification for maxGaussians
    public static let maxGaussiansSpec = SystemConstantSpec(
        ssotId: "SystemConstants.maxGaussians",
        name: "Maximum Gaussians",
        unit: .gaussians,
        value: maxGaussians,
        documentation: "Hard limit on maximum number of Gaussian splats in a scene"
    )
    
    /// All system constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .systemConstant(maxFramesSpec),
        .minLimit(minFramesSpec),
        .systemConstant(maxGaussiansSpec)
    ]
    
    /// Validate relationships between constants
    public static func validateRelationships() -> [String] {
        var errors: [String] = []
        
        if minFrames >= maxFrames {
            errors.append("minFrames (\(minFrames)) >= maxFrames (\(maxFrames))")
        }
        
        return errors
    }
}

