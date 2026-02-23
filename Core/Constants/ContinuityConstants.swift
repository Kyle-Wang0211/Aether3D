// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ContinuityConstants.swift
// Aether3D
//
// Continuity protection constants for motion tracking.
//

import Foundation

/// Continuity protection constants for motion tracking.
public enum ContinuityConstants {
    
    /// 角度突变阈值（度/帧）
    /// - 超过此值触发冻结窗口
    public static let maxDeltaThetaDegPerFrame: Double = 30.0
    
    /// 位移突变阈值（米/帧）
    /// - 超过此值触发冻结窗口
    public static let maxDeltaTranslationMPerFrame: Double = 0.25
    
    /// 冻结窗口（帧数）
    /// - 约 0.67 秒 @30fps
    public static let freezeWindowFrames: Int = 20
    
    /// 恢复稳定帧数
    /// - 约 0.5 秒 @30fps，需要连续稳定才能恢复
    public static let recoveryStableFrames: Int = 15
    
    /// 恢复阈值（度/帧）
    /// - 恢复时需要更严格的稳定性
    public static let recoveryMaxDeltaThetaDegPerFrame: Double = 15.0
    
    // MARK: - Specifications
    
    /// Specification for maxDeltaThetaDegPerFrame
    public static let maxDeltaThetaDegPerFrameSpec = ThresholdSpec(
        ssotId: "ContinuityConstants.maxDeltaThetaDegPerFrame",
        name: "Maximum Delta Theta (Degrees per Frame)",
        unit: .degreesPerFrame,
        category: .quality,
        min: 5.0,
        max: 90.0,
        defaultValue: maxDeltaThetaDegPerFrame,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "30°/帧已是快速转动，正常扫描约10-20°/帧"
    )
    
    /// Specification for maxDeltaTranslationMPerFrame
    public static let maxDeltaTranslationMPerFrameSpec = ThresholdSpec(
        ssotId: "ContinuityConstants.maxDeltaTranslationMPerFrame",
        name: "Maximum Delta Translation (Meters per Frame)",
        unit: .metersPerFrame,
        category: .quality,
        min: 0.01,
        max: 1.0,
        defaultValue: maxDeltaTranslationMPerFrame,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "0.25m/帧已是快速移动，正常扫描更慢"
    )
    
    /// Specification for freezeWindowFrames
    public static let freezeWindowFramesSpec = SystemConstantSpec(
        ssotId: "ContinuityConstants.freezeWindowFrames",
        name: "Freeze Window Frames",
        unit: .frames,
        value: freezeWindowFrames,
        documentation: "约0.67秒@30fps，给用户足够缓冲时间"
    )
    
    /// Specification for recoveryStableFrames
    public static let recoveryStableFramesSpec = SystemConstantSpec(
        ssotId: "ContinuityConstants.recoveryStableFrames",
        name: "Recovery Stable Frames",
        unit: .frames,
        value: recoveryStableFrames,
        documentation: "约0.5秒@30fps，确保真正稳定后才恢复"
    )
    
    /// Specification for recoveryMaxDeltaThetaDegPerFrame
    public static let recoveryMaxDeltaThetaDegPerFrameSpec = ThresholdSpec(
        ssotId: "ContinuityConstants.recoveryMaxDeltaThetaDegPerFrame",
        name: "Recovery Maximum Delta Theta (Degrees per Frame)",
        unit: .degreesPerFrame,
        category: .quality,
        min: 1.0,
        max: 45.0,
        defaultValue: recoveryMaxDeltaThetaDegPerFrame,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "恢复时比正常阈值更严格"
    )
    
    /// All continuity constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(maxDeltaThetaDegPerFrameSpec),
        .threshold(maxDeltaTranslationMPerFrameSpec),
        .systemConstant(freezeWindowFramesSpec),
        .systemConstant(recoveryStableFramesSpec),
        .threshold(recoveryMaxDeltaThetaDegPerFrameSpec)
    ]
}

