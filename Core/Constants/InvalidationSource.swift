// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// InvalidationSource.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Invalidation Source Enumeration
//
// This enum defines sources of record invalidation.
// CLOSED_SET: strictly fixed; any change requires RFC + major contract bump.
//

import Foundation

/// Invalidation source enumeration (CLOSED_SET).
///
/// **Rule ID:** AUDIT_INVALIDATION_001
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Strictly fixed; any change requires RFC + major contract bump
public enum InvalidationSource: String, Codable, CaseIterable {
    /// 用户手动撤销
    case userManual = "USER_MANUAL"
    
    /// 重投影误差过大
    case systemReprojError = "SYSTEM_REPROJ_ERROR"
    
    /// BA 优化后失效
    case systemBAUpdate = "SYSTEM_BA_UPDATE"
    
    /// 跨 epoch 迁移时 L3 重置
    case systemMigration = "SYSTEM_MIGRATION"
    
    /// 防作弊检测
    case systemAntiCheat = "SYSTEM_ANTI_CHEAT"
}

/// Invalidation effect enumeration.
///
/// **Rule ID:** AUDIT_INVALIDATION_001A (v1.1.1)
/// **Status:** IMMUTABLE
public enum InvalidationEffect: String, Codable, CaseIterable {
    /// Exclude from statistics
    case excludeFromStats = "exclude_from_stats"
    
    /// Replaced by newer version
    case replacedByNewer = "replaced_by_newer"
}
