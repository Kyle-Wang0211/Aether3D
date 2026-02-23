// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

// Clock.swift
// PR#8.5 / v0.0.1

import Foundation

/// 时间源，提供当前时间
/// Phase 1 直接使用 `Date()`
public enum WallClock {
    /// 返回当前时间
    public static func now() -> Date {
        return Date()
    }
}

