// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// QualityAnalysisObserver.swift
// Aether3D
//
// Runs FrameAnalyzer against incoming camera frames at ~10 Hz and
// publishes the result into `CaptureSessionSnapshot.lastQualityReport`
// so any other observer (e.g. DomeUpdateObserver) can gate ingestion on
// real image quality rather than the pre-refactor hardcoded sharpness.
//
// Replaces the pre-refactor comment in ObjectModeV2ARCaptureCoordinator:
//    // onVisualFrameSample 在 AR 路径下故意不喂 —— 老 GuidanceEngine 的
//    // "acceptedFrames" 统计由新球的 DomeCoverageMap 取代。如果将来想把两者
//    // 打通,可在这里做 Laplacian variance + signature 生成后喂回 sample。
// — "将来" is now.
//
// THREADING
// ─────────
// Analysis runs on a dedicated `analysisQueue` (`.userInitiated`, serial)
// so:
//   * It doesn't block the CaptureSession actor (which serializes all
//     observers).
//   * Multiple simultaneous frames are coalesced to the latest — we drop
//     queued work if analysis falls behind, preventing unbounded queue
//     growth if the device thermals drop performance.

import Foundation

#if canImport(CoreVideo)
import CoreVideo

public final class QualityAnalysisObserver: CaptureFrameObserver, @unchecked Sendable {

    public let observerID: String = "QualityAnalyzer"

    /// 10 Hz — a happy medium between "useful for gating" (we want at
    /// least 2 readings per dome tick at 6 Hz) and "cheap enough the
    /// device doesn't thermal" (128×128 Laplacian is ~1 ms on A17, so
    /// 10 Hz = 1% CPU).
    public let preferredInterval: TimeInterval = 1.0 / 10.0

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public let rollingWindowSize: Int

        public init(rollingWindowSize: Int = 30) {
            self.rollingWindowSize = rollingWindowSize
        }

        public static let `default` = Configuration()
    }

    // MARK: - State (guarded by analysisQueue)

    private let analysisQueue = DispatchQueue(label: "com.aether3d.capture.qualityanalyzer", qos: .userInitiated)
    private let analyzer = FrameAnalyzer()
    private let configuration: Configuration

    /// Atomic busy-flag to drop incoming frames if an analysis is still
    /// in flight. Prevents the actor from piling up Tasks during thermal
    /// throttling. We use a simple bool guarded by analysisQueue — no
    /// need for an actor here, all access is from receive → queue.
    nonisolated(unsafe) private var analysisInFlight: Bool = false

    nonisolated(unsafe) private var rolling: [Double] = []

    public init(configuration: Configuration = .default) {
        self.configuration = configuration
    }

    // MARK: - CaptureFrameObserver

    public func receive(_ frame: CaptureFrame, session: CaptureSession) async {
        guard let pixelBuffer = frame.pixelBuffer else { return }

        // Try to claim the in-flight slot. If another analysis hasn't
        // returned yet, drop this frame (next one comes in 100 ms).
        let shouldDispatch: Bool = analysisQueue.sync {
            if analysisInFlight { return false }
            analysisInFlight = true
            return true
        }
        guard shouldDispatch else { return }

        let timestamp = frame.timestamp
        // Capture the pixel buffer into the closure so it stays retained
        // until analysisQueue finishes with it.
        analysisQueue.async { [weak self] in
            defer {
                self?.analysisInFlight = false
            }
            guard let self else { return }
            guard let report = self.analyzer.analyze(pixelBuffer, timestamp: timestamp) else { return }

            self.rolling.append(report.laplacianVariance)
            if self.rolling.count > self.configuration.rollingWindowSize {
                self.rolling.removeFirst(self.rolling.count - self.configuration.rollingWindowSize)
            }
            let avg = self.rolling.reduce(0, +) / Double(self.rolling.count)

            Task { [weak session] in
                await session?.mutateSnapshot { snap in
                    snap.lastQualityReport = report
                    snap.recentSharpnessAvg = avg
                }
            }
        }
    }

    public func sessionWillStop(_ session: CaptureSession) async {
        // Drain state so a restart starts clean. No in-flight work to
        // cancel since the queue's work items are short-lived.
        analysisQueue.async { [weak self] in
            self?.rolling.removeAll()
            self?.analysisInFlight = false
        }
    }
}

#endif
