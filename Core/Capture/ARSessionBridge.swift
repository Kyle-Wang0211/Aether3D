// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ARSessionBridge.swift
// Aether3D
//
// Nonisolated glue between `ARSessionDelegate` (runs on AR's private
// delegate queue) and the actor-isolated `CaptureSession`.
//
// WHY A SEPARATE CLASS
// ────────────────────
// ARSessionDelegate methods must be `nonisolated` (UIKit / ARKit calls
// them off any actor). Actors cannot conform to protocols with non-Sendable
// parameters like `ARFrame` without ceremony. This bridge holds a weak
// reference to the CaptureSession and copies the minimum data out of each
// ARFrame into a `CaptureFrame` struct before dispatching into the actor.
//
// "Minimum data" deliberately excludes the ARFrame itself — ARFrame has
// a hard 2-frame lifetime in ARKit's pool, so retaining it blocks ARKit
// from reusing the slot and stalls tracking. We copy pose + intrinsics +
// pixel buffer reference and release the frame immediately.

import Foundation

#if canImport(ARKit)
import ARKit

@preconcurrency import QuartzCore  // CACurrentMediaTime()

public final class ARSessionBridge: NSObject, ARSessionDelegate, @unchecked Sendable {

    /// Weakly held — the bridge must NOT keep the session alive.
    public weak var session: CaptureSession?

    public init(session: CaptureSession) {
        self.session = session
        super.init()
    }

    // MARK: - ARSessionDelegate

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Runs on AR delegate queue. Copy-out then release ARFrame.
        let trackingOK: Bool
        switch frame.camera.trackingState {
        case .normal: trackingOK = true
        default: trackingOK = false
        }
        let captureFrame = CaptureFrame(
            timestamp: frame.timestamp,
            cameraTransform: frame.camera.transform,
            cameraIntrinsics: frame.camera.intrinsics,
            trackingOK: trackingOK,
            pixelBuffer: frame.capturedImage
        )
        // Hop into the actor. We intentionally do NOT await here — the
        // AR delegate queue should return as soon as possible so ARKit
        // can move on to the next frame.
        if let target = self.session {
            Task { await target.ingest(frame: captureFrame) }
        }
    }

    public func session(_ session: ARSession, didFailWithError error: Error) {
        guard let target = self.session else { return }
        Task {
            await target.mutateSnapshot { snap in
                snap.trackingOK = false
                snap.hintText = "AR 会话异常,请重开扫描。"
            }
        }
    }

    public func sessionWasInterrupted(_ session: ARSession) {
        guard let target = self.session else { return }
        Task {
            await target.mutateSnapshot { snap in
                snap.trackingOK = false
                snap.hintText = "AR 会话被中断"
            }
        }
    }

    public func sessionInterruptionEnded(_ session: ARSession) {
        guard let target = self.session else { return }
        Task {
            await target.mutateSnapshot { snap in
                // Tracking will recover on next didUpdate; just clear the
                // user-visible hint so stale text doesn't linger.
                snap.hintText = ""
            }
        }
    }
}

#endif
