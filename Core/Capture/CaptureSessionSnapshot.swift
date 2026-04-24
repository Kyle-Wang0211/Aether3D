// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CaptureSessionSnapshot.swift
// Aether3D
//
// Single source of truth for everything a UI layer might want to know
// about the currently-running capture session. Replaces the pre-refactor
// pattern where state was scattered across:
//   * `ObjectModeV2ARDomeCoordinator.snapshot` (AR-side state)
//   * `ObjectModeV2ARDomeCoordinator.coverage` (cell-level state)
//   * `ObjectModeV2CaptureViewModel.acceptedFrames` (redundant counter)
//   * `ObjectModeV2CaptureViewModel.orbitCompletion` (always 0 in AR path)
//   * `ObjectModeV2CaptureViewModel.stabilityScore`   (always 0 in AR path)
//
// Observers write into this snapshot via CaptureSession; the ViewModel
// reads it (via Combine) and forwards to SwiftUI `@Published` fields.

import Foundation

public struct CaptureSessionSnapshot: Sendable, Equatable {

    // MARK: - Pose (updated every frame by the ARSessionBridge)

    /// Current camera azimuth (radians) relative to the locked world origin,
    /// if an origin has been locked; otherwise `0`.
    public var currentAzimuth: Float

    /// Current camera elevation (radians) relative to the locked world
    /// origin, if locked; otherwise `0`.
    public var currentElevation: Float

    /// ARKit `trackingState == .normal`. False during init / tracking limited.
    public var trackingOK: Bool

    // MARK: - Coverage (updated by DomeUpdateObserver @ ~6 Hz)

    /// Number of cells in the coverage dome that are saturated ("green").
    public var validatedCellCount: Int

    /// Total valid (= passed-gate) frames ingested since session start.
    /// Replaces `ViewModel.acceptedFrames`.
    public var validFrameCount: Int

    /// Estimated orbit completion [0, 1] — how much of the intended
    /// viewing hemisphere has been covered. Derived from
    /// `validatedCellCount / totalCellCount` by the DomeUpdateObserver.
    public var orbitCompletion: Float

    // MARK: - Quality (updated by QualityAnalysisObserver @ ~10 Hz)

    /// Most recent quality report. `nil` until the first frame has been
    /// analyzed.
    public var lastQualityReport: FrameQualityReport?

    /// Rolling average of the last 30 analyzed frames' `laplacianVariance`.
    /// Useful for stable UI display (vs the raw jittery per-frame value).
    public var recentSharpnessAvg: Double

    // MARK: - Motion (updated from CMDeviceMotion @ ~20 Hz)

    /// Magnitude of the gyroscope rotation rate in rad/s. Populated by
    /// whatever component owns CMMotionManager (ViewModel in this app).
    ///
    /// USE AS HARD GATE FOR `accept`:
    ///   * `< 2.0 rad/s` — safe for ingest, no rolling-shutter warping
    ///   * `2.0 – 4.0 rad/s` — reject (strong rolling-shutter distortion
    ///      even if image looks sharp; ARKit VIO drift starts mattering)
    ///   * `> 4.0 rad/s` — reject (definitely blurry, pose highly unreliable)
    ///
    /// Variance alone cannot catch rolling shutter because rolling-shutter
    /// warping leaves each row locally sharp — variance only sees blur
    /// *within* a row, not shear *across* rows.
    public var currentAngularVelocity: Float

    // MARK: - Orientation (updated per frame by DomeCoordinator)

    /// Angle in degrees between the phone's current "up" direction and
    /// whatever "up" it had at lock time. 0 = phone held exactly the way
    /// it was when the user tapped "lock center"; 90 = phone rotated
    /// sideways since; 180 = flipped upside down.
    ///
    /// Matters because:
    ///   * 3DGS reconstruction sees tilted frames as "scene is tilted";
    ///     pose encodes the tilt correctly BUT edge regions of the
    ///     object consistently land in lens-corner positions where
    ///     distortion + lens shading is worst → fuzzy reconstruction
    ///     boundaries.
    ///   * ARKit VIO yaw drift scales with off-axis rotation; tilted
    ///     frames have less reliable pose.
    ///
    /// Populated only after the user locks the world origin (at which
    /// point we capture the reference camera-up). Before lock: 0.
    public var currentTiltDegrees: Float

    // MARK: - Recording (updated by VideoWriterObserver)

    public var isRecording: Bool
    public var recordingDurationSec: TimeInterval

    // MARK: - Hint for UI

    /// Human-readable hint shown under the dome, e.g. "靠近物体" / "正在锁定".
    /// Updated by whichever observer has the most relevant info for the
    /// current failure mode.
    public var hintText: String

    public init(
        currentAzimuth: Float = 0,
        currentElevation: Float = 0,
        trackingOK: Bool = false,
        validatedCellCount: Int = 0,
        validFrameCount: Int = 0,
        orbitCompletion: Float = 0,
        lastQualityReport: FrameQualityReport? = nil,
        recentSharpnessAvg: Double = 0,
        currentAngularVelocity: Float = 0,
        currentTiltDegrees: Float = 0,
        isRecording: Bool = false,
        recordingDurationSec: TimeInterval = 0,
        hintText: String = ""
    ) {
        self.currentAzimuth = currentAzimuth
        self.currentElevation = currentElevation
        self.trackingOK = trackingOK
        self.validatedCellCount = validatedCellCount
        self.validFrameCount = validFrameCount
        self.orbitCompletion = orbitCompletion
        self.lastQualityReport = lastQualityReport
        self.recentSharpnessAvg = recentSharpnessAvg
        self.currentAngularVelocity = currentAngularVelocity
        self.currentTiltDegrees = currentTiltDegrees
        self.isRecording = isRecording
        self.recordingDurationSec = recordingDurationSec
        self.hintText = hintText
    }
}
