//
//  PipelineState.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

enum PipelineState: Equatable, Sendable {
    case idle
    case planning
    case extractingFrames(progress: Double)
    case buildingArtifact(progress: Double)
    case finished
    case failed(message: String)
}

