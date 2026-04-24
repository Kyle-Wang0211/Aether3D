// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObjectModeV2DomeUpdateObserver.swift
// Aether3D
//
// Owns the ObjectModeV2 coverage dome's state in the refactored capture
// pipeline. Replaces the responsibilities that used to live scattered
// across:
//   * `ObjectModeV2ARDomeCoordinator.handleFrame(_:)` — computed az/el
//     and called `coverage.ingest` with a hardcoded sharpness.
//   * `ObjectModeV2ARDomeCoordinator.coverage` / `.snapshot` — owned the
//     coverage state + published to SwiftUI.
//   * `ObjectModeV2CaptureViewModel.acceptedFrameTimestampsSec` — kept a
//     parallel list of accepted timestamps that shadowed the dome's own
//     `validFrameCount`.
//
// Now those three jobs live here, all gated on `CaptureFrame` input and
// publishing to `CaptureSessionSnapshot` as the single source of truth.

import Foundation

#if canImport(ARKit) && canImport(simd) && canImport(Aether3DCore)
import Aether3DCore
import simd

/// Observer that maintains the 36-cell coverage dome. Runs at ~6 Hz.
final class ObjectModeV2DomeUpdateObserver: CaptureFrameObserver, @unchecked Sendable {

    let observerID: String = "ObjectModeV2.Dome"
    let preferredInterval: TimeInterval = 1.0 / 6.0  // 6 Hz

    // MARK: - Inputs

    private let coverage: DomeCoverageMap

    /// Used to derive a motion score per frame. Filled by whatever the
    /// ViewModel plugs in (currently a CoreMotion-backed gyro integrator).
    /// `nil` → we default `motionScore` to 0.5 which is a neutral value
    /// in the coverage grader.
    var motionScoreProvider: (@Sendable () -> Float)?

    // MARK: - Outputs (for ViewModel audit trail)

    /// Most recent cell index a frame was ingested into (if any).
    /// Useful for UI vibrations / cell-landed feedback.
    private(set) var lastIngestedCell: DomeCellIndex?

    // MARK: - Init

    init(coverage: DomeCoverageMap) {
        self.coverage = coverage
    }

    // MARK: - CaptureFrameObserver

    func receive(_ frame: CaptureFrame, session: CaptureSession) async {
        guard frame.trackingOK else {
            // Tracking bad this tick; just refresh the published
            // snapshot's pose/tracking flag so the UI can render "限定
            // 模式" / hint.
            await session.mutateSnapshot { snap in
                snap.trackingOK = false
            }
            return
        }
        guard let origin = coverage.worldOrigin else {
            // Origin not locked yet; nothing to ingest. Keep publishing
            // the current pose so the dome can still preview motion.
            await publishPose(from: frame, in: session)
            return
        }

        // Pose relative to locked origin.
        let transform = frame.cameraTransform
        let camPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let rel = camPos - origin
        let horizDist = sqrt(rel.x * rel.x + rel.z * rel.z)
        let az = atan2(rel.z, rel.x) - coverage.worldYaw
        let el = atan2(rel.y, max(horizDist, 0.001))

        // Pull the latest quality report off the session snapshot. It
        // was produced by the QualityAnalysisObserver at ~10 Hz, so the
        // lag between analysis and ingest is at most ~100 ms — well
        // under the time a user takes to noticeably change pose.
        let snap = await session.snapshot
        let quality = snap.lastQualityReport
        let sharpness = Float(quality?.laplacianVariance ?? 0)
        let exposureScore = Float((quality?.meanBrightness ?? 128) / 255.0)
        let motion = motionScoreProvider?() ?? 0.5

        let extrinsicFlat: [Float] = [
            transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
            transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
            transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
            transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w,
        ]
        let intrinsics = frame.cameraIntrinsics
        let intrinsicsFxFyCxCy: [Float] = [
            intrinsics.columns.0.x,
            intrinsics.columns.1.y,
            intrinsics.columns.2.x,
            intrinsics.columns.2.y,
        ]

        let sample = CapturedFrameSample(
            timestamp: frame.timestamp,
            azimuth: az,
            elevation: el,
            sharpness: sharpness,
            motionScore: motion,
            exposureScore: exposureScore,
            frameID: UUID(),
            cameraExtrinsic4x4: extrinsicFlat,
            cameraIntrinsicFxFyCxCy: intrinsicsFxFyCxCy
        )
        let ingestResult = coverage.ingest(sample: sample)
        lastIngestedCell = ingestResult

        let counts = coverage.cellCounts()
        await session.mutateSnapshot { [weak self] snap in
            snap.currentAzimuth = az
            snap.currentElevation = el
            snap.trackingOK = true
            snap.validFrameCount = self?.coverage.validFrameCount ?? snap.validFrameCount
            snap.validatedCellCount = counts.excellent + counts.ok
            // Orbit completion is 36 cells, weight excellent fully and
            // ok at half. Matches the intuition that "fully green" is
            // only excellent cells.
            let weighted = Float(counts.excellent) + 0.5 * Float(counts.ok)
            snap.orbitCompletion = min(1, weighted / Float(36))
        }
    }

    // MARK: - Helpers

    private func publishPose(from frame: CaptureFrame, in session: CaptureSession) async {
        let transform = frame.cameraTransform
        let camPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let az = atan2(camPos.z, camPos.x)
        let el = atan2(camPos.y, max(sqrt(camPos.x * camPos.x + camPos.z * camPos.z), 0.001))
        await session.mutateSnapshot { snap in
            snap.currentAzimuth = az
            snap.currentElevation = el
            snap.trackingOK = frame.trackingOK
        }
    }
}

#endif
