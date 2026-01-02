//
//  PipelineOutput.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

// Frame 类型已存在，直接使用
typealias FrameArtifact = Frame

// PluginResult 占位类型（Phase 1-3 允许为 nil）
enum PluginResult: Sendable {
    case success
    case failSoft(reason: String)
    case failed(errorDescription: String)
}

struct PipelineOutput: Sendable {
    let id: UUID
    let sourceVideoURL: URL
    let frames: [FrameArtifact]
    let buildPlan: BuildPlan                  // 反作弊关键
    let pluginResult: PluginResult?           // Phase 1-3 允许为 nil
    let state: OutputState
    let metadata: PipelineMetadata
    let createdAt: Date
}

enum OutputState: Equatable, Sendable {
    case success
    case failSoft(reason: String)
    case failed(errorDescription: String)
}

