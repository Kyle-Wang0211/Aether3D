//
//  PipelineError.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

enum PipelineError: Error, Sendable {
    case invalidInput
    case extractFramesFailed
    case pluginFailed
    case cancelled
    case internalInconsistency
}

