//
// SamplingConstants.swift
// Aether3D
//
// Video sampling and frame selection constants.
//

import Foundation
import CoreGraphics

/// Video sampling and frame selection constants.
public enum SamplingConstants {
    
    /// 最短视频时长（秒）
    /// - 低于此值拒绝处理，提示用户"请拍摄至少2秒"
    public static let minVideoDurationSeconds: TimeInterval = 2.0
    
    /// 最长视频时长（秒）
    public static let maxVideoDurationSeconds: TimeInterval = 900  // 15分钟
    
    /// 最低帧数保障
    /// - 无论如何筛选，最终帧数不能低于此值
    public static let minFrameCount: Int = 30
    
    /// 最高帧数上限
    /// - 15分钟 × 2fps = 1800帧
    public static let maxFrameCount: Int = 1800
    
    /// 上传包大小上限（字节）
    /// - 1.08GB，永不降低质量
    public static let maxUploadSizeBytes: Int64 = 1_161_527_296
    
    /// JPEG 质量
    /// - 永不降低
    public static let jpegQuality: CGFloat = 0.85
    
    /// 分辨率长边（像素）
    /// - 永不降低
    public static let maxImageLongEdge: Int = 1920
    
    // MARK: - 动态采样策略阈值
    
    /// 短视频阈值（秒）
    /// - 2-5秒：全保留，只丢废帧
    public static let shortVideoDurationThreshold: TimeInterval = 5.0
    
    /// 中短视频阈值（秒）
    /// - 5-15秒：每秒10帧→选最好5帧
    public static let mediumShortVideoDurationThreshold: TimeInterval = 15.0
    
    /// 中视频阈值（秒）
    /// - 15-60秒：每秒6帧→选最好3帧
    public static let mediumVideoDurationThreshold: TimeInterval = 60.0
    
    /// 长视频阈值（秒）
    /// - 1-5分钟：每秒4帧→选最好2帧
    /// - 5-15分钟：每秒4帧→选最好2帧
    public static let longVideoDurationThreshold: TimeInterval = 300.0
    
    // MARK: - Specifications
    
    /// Specification for minVideoDurationSeconds
    public static let minVideoDurationSecondsSpec = ThresholdSpec(
        ssotId: "SamplingConstants.minVideoDurationSeconds",
        name: "Minimum Video Duration",
        unit: .seconds,
        category: .quality,
        min: 1.0,
        max: 10.0,
        defaultValue: minVideoDurationSeconds,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "低于2秒无法保证30帧最低要求"
    )
    
    /// Specification for maxVideoDurationSeconds
    public static let maxVideoDurationSecondsSpec = ThresholdSpec(
        ssotId: "SamplingConstants.maxVideoDurationSeconds",
        name: "Maximum Video Duration",
        unit: .seconds,
        category: .quality,
        min: 60.0,
        max: 1800.0,
        defaultValue: maxVideoDurationSeconds,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "15分钟上限，平衡质量与处理时间"
    )
    
    /// Specification for minFrameCount
    public static let minFrameCountSpec = MinLimitSpec(
        ssotId: "SamplingConstants.minFrameCount",
        name: "Minimum Frame Count",
        unit: .frames,
        minValue: minFrameCount,
        onUnderflow: .reject,
        documentation: "3DGS重建最低帧数要求"
    )
    
    /// Specification for maxFrameCount
    public static let maxFrameCountSpec = SystemConstantSpec(
        ssotId: "SamplingConstants.maxFrameCount",
        name: "Maximum Frame Count",
        unit: .frames,
        value: maxFrameCount,
        documentation: "15分钟×2fps，控制云端处理时间"
    )
    
    /// Specification for maxUploadSizeBytes
    /// Note: Int64 value converted to Int for SystemConstantSpec
    public static let maxUploadSizeBytesSpec = SystemConstantSpec(
        ssotId: "SamplingConstants.maxUploadSizeBytes",
        name: "Maximum Upload Size",
        unit: .bytes,
        value: Int(maxUploadSizeBytes),
        documentation: "1.08GB，1800帧×600KB最大估算"
    )
    
    /// Specification for jpegQuality
    public static let jpegQualitySpec = ThresholdSpec(
        ssotId: "SamplingConstants.jpegQuality",
        name: "JPEG Quality",
        unit: .ratio,
        category: .quality,
        min: 0.0,
        max: 1.0,
        defaultValue: Double(jpegQuality),
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "固定85%质量，永不降低"
    )
    
    /// Specification for maxImageLongEdge
    public static let maxImageLongEdgeSpec = SystemConstantSpec(
        ssotId: "SamplingConstants.maxImageLongEdge",
        name: "Maximum Image Long Edge",
        unit: .pixels,
        value: maxImageLongEdge,
        documentation: "1080p长边，永不降低"
    )
    
    /// All sampling constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(minVideoDurationSecondsSpec),
        .threshold(maxVideoDurationSecondsSpec),
        .minLimit(minFrameCountSpec),
        .systemConstant(maxFrameCountSpec),
        .systemConstant(maxUploadSizeBytesSpec),
        .threshold(jpegQualitySpec),
        .systemConstant(maxImageLongEdgeSpec)
    ]
}

