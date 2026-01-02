//
//  OutputManager.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

final class OutputManager {
    static let shared = OutputManager()
    private init() {}

    private(set) var outputs: [UUID: PipelineOutput] = [:]
    private(set) var lastOutputID: UUID?

    func save(_ output: PipelineOutput) {
        outputs[output.id] = output
        lastOutputID = output.id
    }

    func getOutput(id: UUID) -> PipelineOutput? {
        outputs[id]
    }

    func latestOutput() -> PipelineOutput? {
        guard let id = lastOutputID else { return nil }
        return outputs[id]
    }

    func clear() {
        outputs.removeAll()
        lastOutputID = nil
    }
}

