// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// RiskFlag.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Risk Flag Enumeration
//
// This enum defines all risk flags for anti-cheat and trust assessment.
// APPEND_ONLY_CLOSED_SET: may only append cases at the end, never delete/rename/reorder.
//

import Foundation

/// Risk flag enumeration (APPEND_ONLY_CLOSED_SET).
///
/// **Rule ID:** B3, AUDIT_ANTI_CHEAT_001
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Only legal change: append new cases to the end
/// - Any reorder/rename/delete must fail CI
/// - Each case must record firstIntroducedInFoundationVersion
public enum RiskFlag: String, Codable, CaseIterable {
    // MARK: - Data Source Risks
    
    /// 疑似 CGI/合成数据
    /// firstIntroducedInFoundationVersion: "1.1"
    case SYNTHETIC_SUSPECTED = "SYNTHETIC_SUSPECTED"
    
    /// 无原始帧数据
    /// firstIntroducedInFoundationVersion: "1.1"
    case NO_ORIGINAL_FRAMES = "NO_ORIGINAL_FRAMES"
    
    /// 外部 mesh 导入
    /// firstIntroducedInFoundationVersion: "1.1"
    case EXTERNAL_MESH_IMPORT = "EXTERNAL_MESH_IMPORT"
    
    // MARK: - Time Related Risks
    
    /// 时间戳异常
    /// firstIntroducedInFoundationVersion: "1.1"
    case TIMESTAMP_ANOMALY = "TIMESTAMP_ANOMALY"
    
    /// 疑似时钟篡改
    /// firstIntroducedInFoundationVersion: "1.1"
    case CLOCK_MANIPULATION = "CLOCK_MANIPULATION"
    
    // MARK: - Evidence Related Risks
    
    /// 疑似证据注入
    /// firstIntroducedInFoundationVersion: "1.1"
    case EVIDENCE_INJECTION = "EVIDENCE_INJECTION"
    
    /// observation 无对应帧
    /// firstIntroducedInFoundationVersion: "1.1"
    case OBSERVATION_WITHOUT_FRAME = "OBSERVATION_WITHOUT_FRAME"
    
    // MARK: - Device Related Risks
    
    /// 检测到模拟器
    /// firstIntroducedInFoundationVersion: "1.1"
    case EMULATOR_DETECTED = "EMULATOR_DETECTED"
    
    /// 检测到 root/越狱
    /// firstIntroducedInFoundationVersion: "1.1"
    case ROOT_JAILBREAK_DETECTED = "ROOT_JAILBREAK_DETECTED"
    
    // MARK: - Schema Metadata
    
    /// Schema identifier for logging/audit
    /// **Rule ID:** B3
    public static let schemaId = "RiskFlag_v1.1"
    
    /// Frozen case order hash (B3)
    /// **Rule ID:** B3
    /// **Status:** IMMUTABLE
    ///
    /// Computed from: case names (in declared order) joined with \n, SHA-256 hashed.
    /// Format: "caseName=rawValue\ncaseName=rawValue\n..."
    ///
    /// **WARNING:** Any change to this hash will fail CI.
    /// Only legal change: append new cases to the end and update this hash.
    public static let frozenCaseOrderHash = "44059b1fe1412b5e6923ec5cef94e8a2e03becfe993e3568c33c4496f858a763"
}
