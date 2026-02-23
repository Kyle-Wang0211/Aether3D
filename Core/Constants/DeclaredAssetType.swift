// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// DeclaredAssetType.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Declared Asset Type Enumeration
//
// This enum defines special asset type declarations.
// CLOSED_SET: strictly fixed; any change requires RFC + major contract bump.
//

import Foundation

/// Declared asset type enumeration (CLOSED_SET).
///
/// **Rule ID:** ASSET_DECLARED_TYPE_001
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Strictly fixed; any change requires RFC + major contract bump
/// - No additions without new schemaVersion
public enum DeclaredAssetType: String, Codable, CaseIterable {
    /// Default - normal gate logic
    case standard = "standard"
    
    /// Reflective material dominant
    case reflectiveDominant = "reflective_dominant"
    
    /// Transparent material dominant
    case transparentDominant = "transparent_dominant"
    
    /// Intended dynamic object
    case dynamicIntended = "dynamic_intended"
}

/// Declared asset type usage rules.
///
/// **Rule ID:** ASSET_DECLARED_TYPE_001
/// **Status:** IMMUTABLE
///
/// **使用规则:**
/// - 必须在 scan 开始前声明
/// - 声明后不可更改（防作弊）
/// - 非 standard 类型永远不能进入 S4(strict)
/// - 声明必须作为资产元数据永久保存
///
/// **Gate 放宽规则:**
///
/// | 声明类型 | 放宽的 gate | 最高可达 |
/// |----------|-------------|----------|
/// | reflective_dominant | specularRatio <= 0.80 | S4(warned) |
/// | transparent_dominant | seeThroughRatio <= 0.60 | S4(warned) |
/// | dynamic_intended | 允许 dynamicMotion=confirmed | S4(warned) |
