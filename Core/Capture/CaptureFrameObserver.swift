// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CaptureFrameObserver.swift
// Aether3D
//
// Replaces the pre-refactor pattern of hanging a dozen `onXxx: ((...)->Void)?`
// closures on `ObjectModeV2ARDomeCoordinator`. Every downstream consumer
// (video writer, coverage map, quality analyzer, future real-time
// renderer UI) implements this protocol and registers with CaptureSession.
//
// CONCURRENCY CONTRACT
// ────────────────────
// * `receive(_:session:)` is invoked FROM the `CaptureSession` actor.
//   Blocking here blocks the whole session — do not do heavy work inline.
//   Instead, hop to your own queue (writer → writerQueue, analyzer →
//   analysisQueue, UI update → MainActor).
// * `preferredInterval` throttles at the session boundary. Setting 0
//   means every frame, `1.0/6.0` means up to 6 Hz, `.greatestFiniteMagnitude`
//   effectively disables receipt (useful for pause).
// * Observers are held weakly; keep a strong reference elsewhere or they
//   will be unregistered silently on the next sweep.

import Foundation

public protocol CaptureFrameObserver: AnyObject, Sendable {

    /// Used for de-duplicated registration and debug logging. Should be
    /// stable across instances of the same class (e.g. "DomeUpdate" not
    /// a UUID).
    var observerID: String { get }

    /// Desired delivery interval in seconds between consecutive `receive`
    /// calls. The session delivers at most once per interval; it never
    /// delivers faster than the AR session produces (~30Hz).
    ///
    /// Typical values:
    ///  * `0`         → every frame (video writer: needs every frame)
    ///  * `1.0 / 10`  → 10 Hz (quality analyzer)
    ///  * `1.0 / 6`   → 6 Hz (dome update)
    ///  * `1.0 / 15`  → 15 Hz (future real-time renderer)
    var preferredInterval: TimeInterval { get }

    /// Invoked for each frame that passes the observer's rate gate.
    /// The observer is responsible for hopping off the session actor if
    /// it needs to do heavy work — do NOT block inside this method.
    func receive(_ frame: CaptureFrame, session: CaptureSession) async

    /// Called once when the observer is attached to an actively-running
    /// session (or when the session transitions to running with the
    /// observer already attached). Default: no-op.
    func sessionDidStart(_ session: CaptureSession) async

    /// Called once when the session is about to stop or the observer is
    /// being detached. Observers should flush in-flight work here.
    /// Default: no-op.
    func sessionWillStop(_ session: CaptureSession) async
}

public extension CaptureFrameObserver {
    func sessionDidStart(_ session: CaptureSession) async {}
    func sessionWillStop(_ session: CaptureSession) async {}
}
