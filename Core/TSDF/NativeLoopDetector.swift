// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

struct NativeLoopCandidate: Sendable {
    var frameIndex: Int
    var overlapRatio: Float
    var score: Float
}

enum NativeLoopDetector {
    /// Detect loop closure by comparing current block set against keyframe history.
    /// Returns the best loop candidate, or nil if no loop detected.
    static func detect(
        currentBlocks: [UInt64],
        historyBlocks: [UInt64],
        historyOffsets: [UInt32],
        skipRecent: Int,
        overlapThreshold: Float,
        yawDeltas: [Float],
        timeDeltas: [Float]
    ) -> NativeLoopCandidate? {
        let historyFrameCount = historyOffsets.count - 1
        guard !currentBlocks.isEmpty,
              historyFrameCount > 0,
              yawDeltas.count == historyFrameCount,
              timeDeltas.count == historyFrameCount else {
            return nil
        }

        var candidate = aether_loop_candidate_t(
            frame_index: -1,
            overlap_ratio: 0,
            score: 0
        )

        let rc = currentBlocks.withUnsafeBufferPointer { curPtr in
            historyBlocks.withUnsafeBufferPointer { histPtr in
                historyOffsets.withUnsafeBufferPointer { offPtr in
                    yawDeltas.withUnsafeBufferPointer { yawPtr in
                        timeDeltas.withUnsafeBufferPointer { timePtr in
                            aether_loop_detect(
                                curPtr.baseAddress,
                                Int32(currentBlocks.count),
                                histPtr.baseAddress,
                                offPtr.baseAddress,
                                Int32(historyFrameCount),
                                Int32(skipRecent),
                                overlapThreshold,
                                0.5,   // yaw_sigma default
                                30.0,  // time_tau default
                                yawPtr.baseAddress,
                                timePtr.baseAddress,
                                &candidate
                            )
                        }
                    }
                }
            }
        }

        guard rc == 0, candidate.frame_index >= 0 else {
            return nil
        }

        return NativeLoopCandidate(
            frameIndex: Int(candidate.frame_index),
            overlapRatio: candidate.overlap_ratio,
            score: candidate.score
        )
    }
}
