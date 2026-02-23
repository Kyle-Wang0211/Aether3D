// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EdgeCaseType.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Edge Case Type Enumeration
//
// This enum defines all edge cases that can be triggered during processing.
// APPEND_ONLY_CLOSED_SET: may only append cases at the end, never delete/rename/reorder.
//

import Foundation

/// Edge case type enumeration (APPEND_ONLY_CLOSED_SET).
///
/// **Rule ID:** B3
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
/// - Each case must record firstIntroducedInFoundationVersion
///
/// **Frozen Order Hash:** Computed from case names (in declared order) joined with \n, SHA-256 hashed.
public enum EdgeCaseType: String, Codable, CaseIterable {
    // MARK: - Geometry Related
    
    /// A_total = 0
    /// firstIntroducedInFoundationVersion: "1.1"
    case EMPTY_GEOMETRY = "EMPTY_GEOMETRY"
    
    /// 退化三角形超限
    /// firstIntroducedInFoundationVersion: "1.1"
    case DEGENERATE_TRIANGLES = "DEGENERATE_TRIANGLES"
    
    /// 坐标超出 [-1000m, 1000m]
    /// firstIntroducedInFoundationVersion: "1.1"
    case COORDINATE_OUT_OF_RANGE = "COORDINATE_OUT_OF_RANGE"
    
    /// 检测到 NaN/Inf
    /// firstIntroducedInFoundationVersion: "1.1"
    case NAN_OR_INF_DETECTED = "NAN_OR_INF_DETECTED"
    
    // MARK: - Coverage Related
    
    /// 无任何 L2 合格 patch
    /// firstIntroducedInFoundationVersion: "1.1"
    case NO_L2_ELIGIBLE = "NO_L2_ELIGIBLE"
    
    /// PIZ 计算不适用
    /// firstIntroducedInFoundationVersion: "1.1"
    case PIZ_NOT_APPLICABLE = "PIZ_NOT_APPLICABLE"
    
    /// 所有 patch 被遮挡
    /// firstIntroducedInFoundationVersion: "1.1"
    case ALL_PATCHES_OCCLUDED = "ALL_PATCHES_OCCLUDED"
    
    // MARK: - Session Related
    
    /// 超时触发新 session
    /// firstIntroducedInFoundationVersion: "1.1"
    case SESSION_TIME_GAP = "SESSION_TIME_GAP"
    
    /// 后台触发新 session
    /// firstIntroducedInFoundationVersion: "1.1"
    case SESSION_APP_BACKGROUND = "SESSION_APP_BACKGROUND"
    
    /// 锚点帧不合格
    /// firstIntroducedInFoundationVersion: "1.1"
    case ANCHOR_FRAME_INVALID = "ANCHOR_FRAME_INVALID"
    
    // MARK: - Input Related
    
    /// Mesh 输入验证失败
    /// firstIntroducedInFoundationVersion: "1.1"
    case MESH_VALIDATION_FAILED = "MESH_VALIDATION_FAILED"
    
    /// 帧数超限
    /// firstIntroducedInFoundationVersion: "1.1"
    case FRAME_COUNT_OUT_OF_RANGE = "FRAME_COUNT_OUT_OF_RANGE"
    
    // MARK: - Risk Related
    
    /// 疑似合成数据
    /// firstIntroducedInFoundationVersion: "1.1"
    case SYNTHETIC_DATA_SUSPECTED = "SYNTHETIC_DATA_SUSPECTED"
    
    /// 时间戳异常
    /// firstIntroducedInFoundationVersion: "1.1"
    case TIMESTAMP_ANOMALY = "TIMESTAMP_ANOMALY"
    
    // MARK: - Math Safety Related (v1.1)
    
    /// 负数输入（面积/计数不应为负）
    /// firstIntroducedInFoundationVersion: "1.1"
    case NEGATIVE_INPUT = "NEGATIVE_INPUT"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    /// **Rule ID:** B3
    public static let schemaId = "EdgeCaseType_v1.1"
    
    /// Frozen case order hash (B3)
    /// **Rule ID:** B3
    /// **Status:** IMMUTABLE
    ///
    /// Computed from: case names (in declared order) joined with \n, SHA-256 hashed.
    /// Format: "caseName=rawValue\ncaseName=rawValue\n..."
    ///
    /// **WARNING:** Any change to this hash will fail CI.
    /// Only legal change: append new cases to the end and update this hash.
    public static let frozenCaseOrderHash = "f299aef016e1fb577202e382423d9aa4fb4b725916eebc30567d675b0661c8e0"
}
