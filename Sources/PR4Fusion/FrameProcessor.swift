// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FrameProcessor.swift
// PR4Fusion
//
// PR4 V10 - Frame processing with ownership semantics
//

import Foundation
import PR4Math
import PR4PathTrace
import PR4Ownership
import PR4Health
import PR4Quality
import PR4Gate
import PR4Softmax
import PR4Overflow
import PR4LUT
import PR4Quality

/// Frame processor that enforces ownership semantics
public final class FrameProcessor {
    
    private let session: SessionContext
    private let reentrancyGuard: ThreadingContract.ReentrancyGuard
    
    public init(session: SessionContext) {
        self.session = session
        self.reentrancyGuard = ThreadingContract.ReentrancyGuard(name: "FrameProcessor")
    }
    
    /// Process frame with consuming semantics
    public func processFrameLegacy(_ context: FrameContextLegacy) -> FrameResult {
        return reentrancyGuard.execute {
            context.assertValid()
            
            let snapshot = session.createFrameSnapshot()
            
            let result = doProcessFrameLegacy(context, snapshot: snapshot)
            
            context.consume()
            
            return result
        }
    }
    
    private func doProcessFrameLegacy(
        _ context: FrameContextLegacy,
        snapshot: SessionSnapshot
    ) -> FrameResult {
        context.pathTrace.record(.gateEnabled)
        
        // Compute health
        let healthInputs = HealthInputs(
            consistency: 0.8,
            coverage: 0.9,
            confidenceStability: 0.7,
            latencyOK: true
        )
        let health = HealthComputer.compute(healthInputs)
        
        // Compute quality (simplified)
        for source in context.depthSamples {
            let quality = SoftQualityComputer.compute(
                samples: source.samples.map { Double($0) },
                uncertainty: 0.1
            )
            context.computedQualities[source.sourceId] = quality
        }
        
        // Gate decisions
        for (sourceId, qualityAny) in context.computedQualities {
            if let quality = qualityAny as? QualityResult {
                let currentStateAny = snapshot.gateStates[sourceId]
                let currentState = (currentStateAny as? SoftGateState) ?? .disabled
                let decision = SoftGateMachine.transition(
                    currentState: currentState,
                    health: health,
                    quality: quality.value
                )
                context.gateDecisions[sourceId] = decision
            }
        }
        
        // Fusion (simplified)
        if !context.depthSamples.isEmpty {
            let firstSource = context.depthSamples[0]
            let avgDepth = firstSource.samples.reduce(0.0, +) / Double(firstSource.samples.count)
            context.fusionResult = FusionResult(
                fusedDepth: avgDepth,
                fusedConfidence: 0.8
            )
        }
        
        return FrameResult(
            frameId: context.frameId,
            sessionId: context.sessionId,
            qualities: context.computedQualities,
            gateDecisions: context.gateDecisions,
            fusion: context.fusionResult,
            overflows: context.overflowEvents,
            pathSignature: context.pathTrace.signature
        )
    }
}
