//
// FrameQualityConstants.swift
// Aether3D
//
// Frame quality assessment and rejection thresholds.
//

import Foundation

/// Frame quality assessment and rejection thresholds.
public enum FrameQualityConstants {
    
    /// 模糊阈值（Laplacian 方差）
    /// - 低于此值判定为模糊，丢弃
    public static let blurThresholdLaplacian: Double = 200.0
    
    /// 暗部阈值（平均亮度 0-255）
    /// - 低于此值判定为太暗，丢弃
    public static let darkThresholdBrightness: Double = 60.0
    
    /// 亮部阈值（平均亮度 0-255）
    /// - 高于此值判定为太亮/过曝，丢弃
    public static let brightThresholdBrightness: Double = 200.0
    
    /// 帧间相似度上限
    /// - 高于此值判定为冗余帧，丢弃
    public static let maxFrameSimilarity: Double = 0.92
    
    /// 帧间相似度下限
    /// - 低于此值判定为跳帧，丢弃
    public static let minFrameSimilarity: Double = 0.50
    
    // MARK: - Specifications
    
    /// Specification for blurThresholdLaplacian
    public static let blurThresholdLaplacianSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.blurThresholdLaplacian",
        name: "Blur Threshold (Laplacian)",
        unit: .variance,
        category: .quality,
        min: 50.0,
        max: 500.0,
        defaultValue: blurThresholdLaplacian,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "比行业标准(100)严格2倍，宁可丢帧也要清晰"
    )
    
    /// Specification for darkThresholdBrightness
    public static let darkThresholdBrightnessSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.darkThresholdBrightness",
        name: "Dark Threshold (Brightness)",
        unit: .brightness,
        category: .quality,
        min: 0.0,
        max: 255.0,
        defaultValue: darkThresholdBrightness,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "暗部细节和深度估计都会失效"
    )
    
    /// Specification for brightThresholdBrightness
    public static let brightThresholdBrightnessSpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.brightThresholdBrightness",
        name: "Bright Threshold (Brightness)",
        unit: .brightness,
        category: .quality,
        min: 0.0,
        max: 255.0,
        defaultValue: brightThresholdBrightness,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "过曝区域完全没有纹理信息"
    )
    
    /// Specification for maxFrameSimilarity
    public static let maxFrameSimilaritySpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.maxFrameSimilarity",
        name: "Maximum Frame Similarity",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: maxFrameSimilarity,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "高于92%为冗余帧，减少无效数据"
    )
    
    /// Specification for minFrameSimilarity
    public static let minFrameSimilaritySpec = ThresholdSpec(
        ssotId: "FrameQualityConstants.minFrameSimilarity",
        name: "Minimum Frame Similarity",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: minFrameSimilarity,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "低于50%为跳帧，连续性断裂"
    )
    
    /// All frame quality constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(blurThresholdLaplacianSpec),
        .threshold(darkThresholdBrightnessSpec),
        .threshold(brightThresholdBrightnessSpec),
        .threshold(maxFrameSimilaritySpec),
        .threshold(minFrameSimilaritySpec)
    ]
}

