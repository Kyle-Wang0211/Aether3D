// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CoreBlurThresholds.swift
// Aether3D
//
// CORE-PURE: Laplacian variance blur thresholds (SSOT)
//
// DUAL SEMANTICS (by design):
// - frameRejection (200): Strict. Discard frame if Laplacian var < this. Do not feed blur to SfM.
// - guidanceHaptic (120): Softer. Warn user / haptic when var < this. Earlier feedback loop.
//
// REF: PyImageSearch 100; TheAILearner 120; no universal value—tune per sensor/resolution.
// For 3D reconstruction: prefer conservative (stricter) to protect feature matching.
// 2024-2026: BAGS (arXiv 2403.04926), DeblurGS (arXiv 2509.26498) offer blur-aware 3D paths;
//             this threshold keeps traditional SfM reject strategy; blur-frame soft path optional.
//
// 突破极限: guidanceHaptic 120→100 = 更早触觉反馈，用户在帧被拒收前有更多时间调整
//

import Foundation

/// Core-pure blur thresholds. Single source for both frame rejection and guidance.
public enum CoreBlurThresholds {

    /// Frame rejection threshold (strict).
    /// Laplacian variance below this → discard frame, do not feed to SfM.
    /// Unit: variance of Laplacian (dimensionless, scale-dependent).
    /// Value: 200 = 2× PyImageSearch 100, conservative for 3D reconstruction.
    public static let frameRejection: Double = 200.0

    /// Guidance/haptic threshold (softer).
    /// Laplacian variance below this → warn user, trigger haptic.
    /// 100 = 更早触发，用户在帧拒收前有更多调整机会（突破极限 UX）
    public static let guidanceHaptic: Double = 100.0
}
