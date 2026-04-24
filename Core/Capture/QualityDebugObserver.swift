// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityDebugObserver.swift
// Aether3D
//
// Observability for tuning `DomeCoverageMap.thresholds.minSharpness`.
// Registers on CaptureSession, polls `snapshot.lastQualityReport` at 2 Hz,
// and does two things:
//
//   1. `print(...)` to the Xcode console once per second of wall-clock
//      with current variance, rolling average, brightness and
//      approximate pass rate — useful when running with the cable
//      attached during dev.
//
//   2. Exposes the same numbers as a `QualityDebugStats` Sendable value
//      via the `onStats` callback so an on-device debug overlay can
//      render without reaching into the actor.
//
// THRESHOLD APPROXIMATION
// ───────────────────────
// The observer doesn't know whether the dome actually accepted any
// given frame (that happens downstream in `DomeCoverageMap.ingest`).
// For the pass-rate number we simply count frames where
// `laplacianVariance >= approxThreshold` — this matches the dome's
// gate to within motion / exposure scoring. Keep `approxThreshold` in
// sync with `DomeThresholds.minSharpness` when you tune it.

import Foundation

public struct QualityDebugStats: Sendable, Equatable {
    public let currentVariance: Double
    public let avgVariance: Double
    public let brightness: Double
    public let threshold: Double
    public let passRate: Double
    public let sampleCountInWindow: Int
    public let angularVelocity: Float      // rad/s, from gyroscope
    public let angularVelocityLimit: Float // current hard-reject threshold
    public let tiltDegrees: Float          // angle vs camera-up at lock time
    public let tiltDegreesLimit: Float     // current hard-reject threshold
    public let timestamp: TimeInterval

    public init(
        currentVariance: Double,
        avgVariance: Double,
        brightness: Double,
        threshold: Double,
        passRate: Double,
        sampleCountInWindow: Int,
        angularVelocity: Float = 0,
        angularVelocityLimit: Float = 2.0,
        tiltDegrees: Float = 0,
        tiltDegreesLimit: Float = 20.0,
        timestamp: TimeInterval
    ) {
        self.currentVariance = currentVariance
        self.avgVariance = avgVariance
        self.brightness = brightness
        self.threshold = threshold
        self.passRate = passRate
        self.sampleCountInWindow = sampleCountInWindow
        self.angularVelocity = angularVelocity
        self.angularVelocityLimit = angularVelocityLimit
        self.tiltDegrees = tiltDegrees
        self.tiltDegreesLimit = tiltDegreesLimit
        self.timestamp = timestamp
    }
}

public final class QualityDebugObserver: CaptureFrameObserver, @unchecked Sendable {

    public let observerID: String = "QualityDebug"

    /// 2 Hz is plenty for console-visible live tuning. Too fast and the
    /// log floods; too slow and you lose feedback loop snappiness.
    public let preferredInterval: TimeInterval = 0.5

    /// Matches `DomeCoverageMap.thresholds.minSharpness`. If you tune
    /// that on-device, update this so the "pass%" reading stays in sync.
    public var approxThreshold: Double = 500

    /// Matches the hard-reject angular velocity threshold in
    /// `ObjectModeV2ARDomeCoordinator.handleFrame` (currently 2.0 rad/s).
    /// Surfaced here so the HUD can color-code live omega against the
    /// active cutoff.
    public var angularVelocityLimit: Float = 2.0

    /// Matches `ObjectModeV2ARDomeCoordinator.maxTiltDegrees` (default
    /// 20.0°). Same sync obligation as `angularVelocityLimit`.
    public var tiltDegreesLimit: Float = 20.0

    /// Called with the latest stats. Callers are responsible for
    /// hopping to MainActor if they're driving SwiftUI. The callback is
    /// invoked on the session actor.
    public var onStats: (@Sendable (QualityDebugStats) -> Void)?

    /// When true, the observer also prints one line per second to stdout
    /// (Xcode console). Off by default so TestFlight doesn't fill its
    /// log ring with dev noise.
    public var consoleLogEnabled: Bool = false

    private let statsQueue = DispatchQueue(label: "com.aether3d.capture.qualitydebug.stats")

    // All of the below are serialized by `statsQueue`.
    private var passCount: Int = 0
    private var totalCount: Int = 0
    private var lastConsoleLogTime: TimeInterval = 0
    private let consoleLogInterval: TimeInterval = 1.0

    public init(consoleLogEnabled: Bool = false) {
        self.consoleLogEnabled = consoleLogEnabled
    }

    public func receive(_ frame: CaptureFrame, session: CaptureSession) async {
        let snap = await session.snapshot
        guard let report = snap.lastQualityReport else { return }
        let avg = snap.recentSharpnessAvg
        let omega = snap.currentAngularVelocity
        let tilt = snap.currentTiltDegrees

        let (shouldLog, snapshotPass, snapshotTotal) = statsQueue.sync { () -> (Bool, Int, Int) in
            totalCount += 1
            if report.laplacianVariance >= approxThreshold {
                passCount += 1
            }
            let now = CFAbsoluteTimeGetCurrent()
            let due = (now - lastConsoleLogTime) >= consoleLogInterval
            if due {
                lastConsoleLogTime = now
            }
            return (due, passCount, totalCount)
        }

        let passRate: Double = snapshotTotal > 0
            ? Double(snapshotPass) / Double(snapshotTotal)
            : 0

        if shouldLog && consoleLogEnabled {
            print(String(
                format: "[QualityDebug] variance=%.0f avg=%.0f brightness=%.0f omega=%.2f tilt=%.1f° threshold=%.0f omegaMax=%.1f tiltMax=%.0f° pass=%.0f%% (%d samples)",
                report.laplacianVariance,
                avg,
                report.meanBrightness,
                omega,
                tilt,
                approxThreshold,
                angularVelocityLimit,
                tiltDegreesLimit,
                passRate * 100,
                snapshotTotal
            ))
            // Reset the window after each log so each second is a clean
            // measurement rather than a cumulative total.
            statsQueue.sync {
                passCount = 0
                totalCount = 0
            }
        }

        let stats = QualityDebugStats(
            currentVariance: report.laplacianVariance,
            avgVariance: avg,
            brightness: report.meanBrightness,
            threshold: approxThreshold,
            passRate: passRate,
            sampleCountInWindow: snapshotTotal,
            angularVelocity: omega,
            angularVelocityLimit: angularVelocityLimit,
            tiltDegrees: tilt,
            tiltDegreesLimit: tiltDegreesLimit,
            timestamp: report.timestamp
        )
        onStats?(stats)
    }

    public func sessionWillStop(_ session: CaptureSession) async {
        statsQueue.sync {
            passCount = 0
            totalCount = 0
            lastConsoleLogTime = 0
        }
    }
}
