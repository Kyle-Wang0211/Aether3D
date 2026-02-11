// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// StorageConstants.swift
// Aether3D
//
// Local storage management constants.
//

import Foundation

/// Local storage management constants.
public enum StorageConstants {
    
    /// 存储警告阈值（字节）
    /// - 低于此值提醒用户清理空间
    public static let lowStorageWarningBytes: Int64 = 1_610_612_736  // 1.5GB
    
    /// 素材/成品数量限制
    /// - .max 表示无限制
    public static let maxAssetCount: Int = .max
    
    /// 自动清理开关
    /// - false 表示不自动清理，用户自己管理
    public static let autoCleanupEnabled: Bool = false
    
    /// 成品保留策略
    public static let assetRetentionPolicy: String = "permanent_local"
    
    // MARK: - Specifications
    
    /// Specification for lowStorageWarningBytes
    /// Note: Int64 value converted to Int for SystemConstantSpec
    public static let lowStorageWarningBytesSpec = SystemConstantSpec(
        ssotId: "StorageConstants.lowStorageWarningBytes",
        name: "Low Storage Warning Threshold",
        unit: .bytes,
        value: Int(lowStorageWarningBytes),
        documentation: "1.5GB警告阈值，预留足够空间处理新素材"
    )
    
    /// Specification for maxAssetCount
    /// Note: .max is represented as Int.max for spec
    public static let maxAssetCountSpec = SystemConstantSpec(
        ssotId: "StorageConstants.maxAssetCount",
        name: "Maximum Asset Count",
        unit: .count,
        value: maxAssetCount,
        documentation: "不限制数量，用户自行管理"
    )
    
    /// Specification for autoCleanupEnabled
    /// Note: Bool represented as ThresholdSpec (0.0=false, 1.0=true) to allow 0 value
    public static let autoCleanupEnabledSpec = ThresholdSpec(
        ssotId: "StorageConstants.autoCleanupEnabled",
        name: "Auto Cleanup Enabled",
        unit: .dimensionless,
        category: .resource,
        min: 0.0,
        max: 1.0,
        defaultValue: autoCleanupEnabled ? 1.0 : 0.0,
        onExceed: .warn,
        onUnderflow: .warn,
        documentation: "不自动清理，避免误删用户数据"
    )
    
    /// All storage constant specs
    public static let allSpecs: [AnyConstantSpec] = [
        .systemConstant(lowStorageWarningBytesSpec),
        .systemConstant(maxAssetCountSpec),
        .threshold(autoCleanupEnabledSpec)
    ]
}

