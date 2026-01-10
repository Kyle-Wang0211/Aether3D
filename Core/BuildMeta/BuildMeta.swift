// BuildMeta.swift
// PR#8.5 / v0.0.1

import Foundation

/// 构建元数据占位（PR12 引入）
/// Phase 1 所有字段为 UNKNOWN
public struct BuildMeta: Codable, Sendable, Equatable {
    public let version: String
    public let buildId: String
    public let gitCommit: String
    public let buildTime: String
    
    public init(version: String, buildId: String, gitCommit: String, buildTime: String) {
        self.version = version
        self.buildId = buildId
        self.gitCommit = gitCommit
        self.buildTime = buildTime
    }
    
    public static let unknown = BuildMeta(
        version: "UNKNOWN",
        buildId: "UNKNOWN",
        gitCommit: "UNKNOWN",
        buildTime: "UNKNOWN"
    )
}

