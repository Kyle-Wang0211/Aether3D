// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  SamplingPolicy.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 采样策略
/// Phase 1 仅支持 100% 采样
enum SamplingPolicy {
    case all
    
    var shouldSample: Bool {
        switch self {
        case .all:
            return true
        }
    }
}

