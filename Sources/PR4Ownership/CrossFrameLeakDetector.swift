// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CrossFrameLeakDetector.swift
// PR4Ownership
//
// PR4 V10 - Pillar 2: Cross-frame leak detection (Hard-13)
//

import Foundation
import PR4Math
import PR4PathTrace

/// Leak detector for cross-frame state access
///
/// V10 RULE: Any access to state from a different frame is a leak.
public enum CrossFrameLeakDetector {
    
    /// Current frame being processed (thread-local)
    @TaskLocal
    public static var currentFrameId: FrameID?
    
    /// Assert we're in expected frame
    @inline(__always)
    public static func assertInFrame(_ expectedFrameId: FrameID, caller: String = #function) {
        guard let current = currentFrameId else {
            #if DETERMINISM_STRICT
            assertionFailure("No frame context set when accessing \(caller)")
            #endif
            return
        }
        
        if current != expectedFrameId {
            #if DETERMINISM_STRICT
            assertionFailure(
                "Cross-frame leak: \(caller) accessed from frame \(current), " +
                "but belongs to frame \(expectedFrameId)"
            )
            #else
            FrameLeakLogger.shared.log(
                expectedFrame: expectedFrameId,
                actualFrame: current,
                caller: caller
            )
            #endif
        }
    }
}
