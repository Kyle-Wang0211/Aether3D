//
//  BuildResult.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

struct BuildResult: Sendable {
    let planSummary: String
    let artifact: PhotoSpaceArtifact
    let timings: Timings

    struct Timings: Sendable {
        let planMs: Int
        let extractMs: Int
        let buildMs: Int
        let totalMs: Int
    }
}

