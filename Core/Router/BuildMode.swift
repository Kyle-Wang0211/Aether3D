// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  BuildMode.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 构建模式
public enum BuildMode: String, Codable, CaseIterable, Sendable {
    /// Enter 模式：快速进入，T+1-2s 内显示可漫游结果
    case enter
    
    /// Publish 模式：高质量输出，10-30s 范围按 tier
    case publish
    
    /// Fail-soft 模式：降级输出照片空间
    case failSoft
    
    // MARK: - PR1 C-Class Capacity Control Modes
    
    /// Normal mode: standard admission behavior
    case NORMAL
    
    /// Damping mode: SOFT_LIMIT triggered, more selective admission
    case DAMPING
    
    /// Saturated mode: HARD_LIMIT triggered, all admissions rejected
    case SATURATED
}

