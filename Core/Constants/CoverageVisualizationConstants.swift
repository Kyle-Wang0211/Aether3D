// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoverageVisualizationConstants.swift
// Aether3D
//
// Coverage visualization constants (black-gray-white-native color states).
//

import Foundation


/// Coverage visualization constants (black-gray-white-native color states).
public enum CoverageVisualizationConstants {
    
    // MARK: - 状态颜色定义
    
    /// S0: 未知状态 - 黑色 RGB
    public static let s0BlackColor: (r: UInt8, g: UInt8, b: UInt8) = (0, 0, 0)
    
    /// S0: 未知状态边框 - 白色 RGB
    public static let s0BorderColor: (r: UInt8, g: UInt8, b: UInt8) = (255, 255, 255)
    
    /// S0: 边框宽度（像素）
    /// - 用户刚打开相机时，全屏黑色 + 每个三角形有1px白色边框
    public static let s0BorderWidthPx: Double = 1.0
    
    /// S1: 弱证据 - 深灰色 RGB
    public static let s1DarkGrayColor: (r: UInt8, g: UInt8, b: UInt8) = (64, 64, 64)
    
    /// S2: 中证据 - 灰色 RGB
    public static let s2GrayColor: (r: UInt8, g: UInt8, b: UInt8) = (128, 128, 128)
    
    /// S3: 强证据 - 浅灰/近白 RGB
    /// - 仍是证据态，非承诺态
    public static let s3LightGrayColor: (r: UInt8, g: UInt8, b: UInt8) = (200, 200, 200)
    
    /// S4+: 资产级 - 显示物体本色（使用真实纹理，无固定颜色）
    
    // MARK: - S4 达标条件
    
    /// 视角跨度最小值（度）
    public static let s4MinThetaSpanDeg: Double = 16.0
    
    /// 有效视角数最小值
    /// - 每个视角与之前差至少 5°
    public static let s4MinL2PlusCount: Int = 7
    
    /// 高质量视角数最小值
    /// - 每个视角与之前差至少 10°
    public static let s4MinL3Count: Int = 3
    
    /// 重投影误差上限（像素）
    public static let s4MaxReprojRmsPx: Double = 1.0
    
    /// 边缘抖动上限（像素）
    public static let s4MaxEdgeRmsPx: Double = 0.5
    
    // MARK: - 观测等级阈值
    
    /// L1 最小角度差（度）
    public static let l1MinDeltaThetaDeg: Double = 1.5
    
    /// L2 最小角度差（度）
    public static let l2MinDeltaThetaDeg: Double = 5.0
    
    /// L3 最小角度差（度）
    public static let l3MinDeltaThetaDeg: Double = 10.0
    
    // MARK: - Mesh 三角形动态尺寸
    
    /// 最小 Patch 边长（米）
    public static let patchSizeMinM: Double = 0.005  // 0.5cm
    
    /// 最大 Patch 边长（米）
    public static let patchSizeMaxM: Double = 0.5    // 50cm
    
    /// 默认 Patch 边长（米）
    public static let patchSizeFallbackM: Double = 0.05  // 5cm
    
    /// Patch 尺寸平滑变化最大比例
    public static let patchSizeSmoothMaxChangeRatio: Double = 0.10
    
    /// 重叠允许比例
    public static let overlapAllowRatio: Double = 0.30
    
    // MARK: - Specifications
    
    /// Specification for s0BorderWidthPx
    public static let s0BorderWidthPxSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.s0BorderWidthPx",
        name: "S0 Border Width",
        unit: .pixels,
        category: .quality,
        min: 0.5,
        max: 3.0,
        defaultValue: s0BorderWidthPx,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "1px白线分割三角形，让用户知道这里有东西要扫"
    )
    
    /// Specification for s4MinThetaSpanDeg
    public static let s4MinThetaSpanDegSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.s4MinThetaSpanDeg",
        name: "S4 Minimum Theta Span",
        unit: .degrees,
        category: .quality,
        min: 5.0,
        max: 90.0,
        defaultValue: s4MinThetaSpanDeg,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "视角跨度至少16°才能保证多视角重建质量"
    )
    
    /// Specification for s4MinL2PlusCount
    public static let s4MinL2PlusCountSpec = SystemConstantSpec(
        ssotId: "CoverageVisualizationConstants.s4MinL2PlusCount",
        name: "S4 Minimum L2+ Count",
        unit: .count,
        value: s4MinL2PlusCount,
        documentation: "至少7个有效视角（每个差5°以上）"
    )
    
    /// Specification for s4MinL3Count
    public static let s4MinL3CountSpec = SystemConstantSpec(
        ssotId: "CoverageVisualizationConstants.s4MinL3Count",
        name: "S4 Minimum L3 Count",
        unit: .count,
        value: s4MinL3Count,
        documentation: "至少3个高质量视角（每个差10°以上）"
    )
    
    /// Specification for s4MaxReprojRmsPx
    public static let s4MaxReprojRmsPxSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.s4MaxReprojRmsPx",
        name: "S4 Maximum Reprojection RMS",
        unit: .pixels,
        category: .quality,
        min: 0.1,
        max: 5.0,
        defaultValue: s4MaxReprojRmsPx,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "重投影误差<1px保证几何精度"
    )
    
    /// Specification for s4MaxEdgeRmsPx
    public static let s4MaxEdgeRmsPxSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.s4MaxEdgeRmsPx",
        name: "S4 Maximum Edge RMS",
        unit: .pixels,
        category: .quality,
        min: 0.1,
        max: 2.0,
        defaultValue: s4MaxEdgeRmsPx,
        onExceed: .reject,
        onUnderflow: .warn,
        documentation: "边缘抖动<0.5px保证边界稳定"
    )
    
    /// Specification for patchSizeMinM
    public static let patchSizeMinMSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.patchSizeMinM",
        name: "Patch Size Minimum",
        unit: .meters,
        category: .quality,
        min: 0.001,
        max: 0.1,
        defaultValue: patchSizeMinM,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "0.5cm最小Patch，捕捉细节"
    )
    
    /// Specification for patchSizeMaxM
    public static let patchSizeMaxMSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.patchSizeMaxM",
        name: "Patch Size Maximum",
        unit: .meters,
        category: .quality,
        min: 0.1,
        max: 2.0,
        defaultValue: patchSizeMaxM,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "50cm最大Patch，覆盖大平面"
    )
    
    /// Specification for patchSizeFallbackM
    public static let patchSizeFallbackMSpec = ThresholdSpec(
        ssotId: "CoverageVisualizationConstants.patchSizeFallbackM",
        name: "Patch Size Fallback",
        unit: .meters,
        category: .quality,
        min: 0.01,
        max: 0.2,
        defaultValue: patchSizeFallbackM,
        onExceed: .warn,
        onUnderflow: .reject,
        documentation: "5cm默认Patch，适合大多数场景"
    )
    
    /// All coverage visualization constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .threshold(s0BorderWidthPxSpec),
        .threshold(s4MinThetaSpanDegSpec),
        .systemConstant(s4MinL2PlusCountSpec),
        .systemConstant(s4MinL3CountSpec),
        .threshold(s4MaxReprojRmsPxSpec),
        .threshold(s4MaxEdgeRmsPxSpec),
        .threshold(patchSizeMinMSpec),
        .threshold(patchSizeMaxMSpec),
        .threshold(patchSizeFallbackMSpec)
    ]
}

