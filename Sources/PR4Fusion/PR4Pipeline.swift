// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PR4Pipeline.swift
// PR4Fusion
//
// PR4 V10 - Main PR4 processing pipeline
//

import Foundation
import PR4Ownership
import PR4Health
import PR4Quality
import PR4Gate
import PR4Softmax

/// Main PR4 processing pipeline
public final class PR4Pipeline {
    
    private let session: SessionContext
    private let frameProcessor: FrameProcessor
    
    public init() {
        self.session = SessionContext()
        self.frameProcessor = FrameProcessor(session: session)
    }
    
    /// Process a single frame
    public func processFrame(
        depthSamples: [SourceDepthSamples],
        confidences: [SourceConfidence],
        timestamp: TimeInterval
    ) -> FrameResult {
        let context = FrameContextLegacy(
            sessionId: session.sessionId,
            depthSamples: depthSamples,
            confidences: confidences,
            timestamp: timestamp
        )
        
        let result = frameProcessor.processFrameLegacy(context)
        
        session.update(from: result)
        
        return result
    }
}
