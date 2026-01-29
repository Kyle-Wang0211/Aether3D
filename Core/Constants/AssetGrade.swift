//
// AssetGrade.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Asset Grade Enumeration
//
// This enum defines asset quality grades.
// CLOSED_SET: strictly fixed; any change requires RFC + major contract bump.
//

import Foundation

/// Asset grade enumeration (CLOSED_SET).
///
/// **Rule ID:** ASSET_GRADE_001
/// **Status:** IMMUTABLE
///
/// **Governance:**
/// - Strictly fixed; any change requires RFC + major contract bump
/// - No additions without new schemaVersion
public enum AssetGrade: String, Codable, CaseIterable {
    /// Premium - 完整资产级承诺
    case S = "premium"
    
    /// Standard - 标准质量
    case A = "standard"
    
    /// Acceptable - 有限制但可用
    case B = "acceptable"
    
    /// Limited - 仅供参考
    case C = "limited"
    
    /// Experimental - 实验性/特殊用途
    case X = "experimental"
}

/// Grade determination rules (CLOSED_SET).
///
/// **Rule ID:** ASSET_GRADE_001
/// **Status:** IMMUTABLE
///
/// | Grade | S_state | unreliableRatio | 其他条件 |
/// |-------|---------|-----------------|----------|
/// | S | S4(strict) | <= 0.10 | 无 riskFlag 阻断 |
/// | A | S4(strict) | <= 0.30 | - |
/// | B | S4(warned) | <= 0.50 | - |
/// | C | S3 或 S4(warned) | <= 0.80 | - |
/// | X | 其他 | 任意 | 含 dynamic_intended 等特殊声明 |
///
/// **注意:** Grade 判定使用 Guaranteed 字段。
/// 判定逻辑必须在所有平台一致。
public enum AssetGradeDetermination {
    // Grade determination logic is defined in documentation only.
    // Implementation belongs to PR#6.
}
