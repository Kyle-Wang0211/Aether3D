// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// IdentityLayerArchitecture.swift
// Aether3D
//
// PR#1 SSOT Foundation v1.1 - Identity Layer Architecture Constants (A1)
//
// This file defines the hybrid methodology layer architecture.
//

import Foundation

/// Identity layer architecture constants (A1 - IMMUTABLE).
///
/// **Rule ID:** A1
/// **Status:** IMMUTABLE
///
/// **混合方法论:** Layer 0-3 严格分层，单向依赖
public enum IdentityLayerArchitecture {
    
    // MARK: - Layer Definitions
    
    /// Layer 0: Continuous Reality (B)
    /// - Floating-point geometry
    /// - Raw camera poses
    /// - Continuous depth/color
    /// - **NEVER participates in identity hashing**
    public static let LAYER_0_NAME = "Continuous Reality"
    public static let LAYER_0_PARTICIPATES_IN_IDENTITY = false
    
    /// Layer 1: Patch Evidence Layer (B + C)
    /// - patchId (epoch-local, high precision)
    /// - Detailed coverage / evidence / L3 evaluation
    /// - Valid only within one mesh epoch
    public static let LAYER_1_NAME = "Patch Evidence Layer"
    public static let LAYER_1_PARTICIPATES_IN_IDENTITY = true
    
    /// Layer 2: Geometry Identity Layer (A + C)
    /// - geomId (cross-epoch stable)
    /// - Used for inheritance and asset continuity
    public static let LAYER_2_NAME = "Geometry Identity Layer"
    public static let LAYER_2_PARTICIPATES_IN_IDENTITY = true
    
    /// Layer 3: Asset Trust Layer (A)
    /// - S-state, AssetGrade
    /// - Pricing / licensing / publication
    public static let LAYER_3_NAME = "Asset Trust Layer"
    public static let LAYER_3_PARTICIPATES_IN_IDENTITY = true
    
    // MARK: - Dependency Direction Constraints
    
    /// **非协商约束:**
    /// - 身份永远不依赖连续值
    /// - 依赖方向严格 bottom → top
    /// - 任何反向依赖被禁止
    
    /// Dependency direction: strictly bottom → top.
    /// **Rule ID:** A1
    /// **Status:** IMMUTABLE
    public static let DEPENDENCY_DIRECTION = "bottom_to_top"
    
    /// Reverse dependencies are forbidden.
    /// **Rule ID:** A1
    /// **Status:** IMMUTABLE
    public static let REVERSE_DEPENDENCIES_FORBIDDEN = true
}
