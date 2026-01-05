//
//  BuildMeta.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 构建元数据占位（PR12 引入）
/// Phase 1 所有字段为 UNKNOWN
struct BuildMeta: Codable, Sendable {
    let version: String
    let buildId: String
    let gitCommit: String
    let buildTime: String
    
    static let unknown = BuildMeta(
        version: "UNKNOWN",
        buildId: "UNKNOWN",
        gitCommit: "UNKNOWN",
        buildTime: "UNKNOWN"
    )
}

