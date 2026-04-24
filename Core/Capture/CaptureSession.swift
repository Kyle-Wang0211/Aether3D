// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CaptureSession.swift
// Aether3D
//
// Actor-isolated hub for the capture pipeline. Replaces the pre-refactor
// pattern where frames flowed through `@MainActor` coordinators with
// nonisolated(unsafe) callback closures.
//
// LIFECYCLE
// ─────────
//   Init (no ARSession yet)
//       │
//       ▼
//   start()                ← caller provides ARSession + delegate bridge
//       │
//       ▼
//   ingest(arFrame: ...)   ← driven by nonisolated ARSessionBridge
//       │
//       ▼
//   broadcast(frame: ...)  ← per-observer rate gating, parallel dispatch
//       │
//       ▼
//   stop()                 ← tears down observers, clears state
//
// THREAD MODEL
// ────────────
// The actor serializes all state access. Observers are called FROM the
// actor (via `await observer.receive(...)`) — they are responsible for
// hopping off to their own queue if they have heavy work. Observers may
// also `await session.snapshot` to read the latest published state, or
// `await session.mutate(_:)` helpers to write.

import Foundation

#if canImport(simd)
import simd
#endif

#if canImport(CoreVideo)
import CoreVideo
#endif

public actor CaptureSession {

    // MARK: - Public snapshot (readable from anywhere via `await`)

    public private(set) var snapshot: CaptureSessionSnapshot = .init()

    // MARK: - Observer registry

    private struct ObserverSlot {
        weak var observer: CaptureFrameObserver?
        let observerID: String
        var preferredInterval: TimeInterval
        var lastDeliveredTimestamp: TimeInterval = -.infinity
    }
    private var slots: [ObserverSlot] = []

    private var isRunning: Bool = false

    public init() {}

    // MARK: - Lifecycle

    /// Mark session as running. The caller (typically the ViewModel)
    /// should have started ARSession and hooked up an ARSessionBridge
    /// before calling this; `start()` just notifies observers.
    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        for slot in slots {
            guard let obs = slot.observer else { continue }
            await obs.sessionDidStart(self)
        }
    }

    /// Graceful teardown. Observers get `sessionWillStop` so they can
    /// flush buffers (e.g. finalize AVAssetWriter).
    public func stop() async {
        guard isRunning else { return }
        isRunning = false
        for slot in slots {
            guard let obs = slot.observer else { continue }
            await obs.sessionWillStop(self)
        }
        // Observers are kept registered across start/stop cycles so the
        // ViewModel doesn't have to re-register every time. Call
        // `unregisterAll()` if you truly want a clean slate.
    }

    // MARK: - Observer management

    public func register(_ observer: CaptureFrameObserver) async {
        compactObservers()
        if slots.contains(where: { $0.observerID == observer.observerID }) {
            // Idempotent: re-registering the same ID is a no-op. Prevents
            // duplicate delivery if the ViewModel does init side-effect
            // registrations more than once.
            return
        }
        slots.append(
            ObserverSlot(
                observer: observer,
                observerID: observer.observerID,
                preferredInterval: max(0, observer.preferredInterval)
            )
        )
        if isRunning {
            await observer.sessionDidStart(self)
        }
    }

    public func unregister(observerID: String) async {
        guard let idx = slots.firstIndex(where: { $0.observerID == observerID }) else { return }
        let slot = slots[idx]
        slots.remove(at: idx)
        if isRunning, let obs = slot.observer {
            await obs.sessionWillStop(self)
        }
    }

    public func unregisterAll() async {
        let existing = slots
        slots.removeAll()
        guard isRunning else { return }
        for slot in existing {
            if let obs = slot.observer {
                await obs.sessionWillStop(self)
            }
        }
    }

    private func compactObservers() {
        slots.removeAll { $0.observer == nil }
    }

    // MARK: - Frame ingestion (called by nonisolated ARSessionBridge)

    /// Entry point from the ARSessionDelegate bridge. Updates pose-derived
    /// snapshot fields immediately, then broadcasts the frame to observers
    /// with per-observer rate gating applied.
    public func ingest(frame: CaptureFrame) async {
        guard isRunning else { return }

        // Fast-path snapshot updates that need per-frame freshness (pose
        // + tracking). Observers handle the rest at their own rates.
        snapshot.trackingOK = frame.trackingOK

        await broadcast(frame: frame)
    }

    private func broadcast(frame: CaptureFrame) async {
        compactObservers()
        // Iterate slots in registration order; each observer is awaited
        // before the next is notified so that observers that mutate the
        // snapshot (e.g. QualityAnalysisObserver → DomeUpdateObserver)
        // see consistent state. If this becomes a bottleneck, the
        // independence-preserving alternative is a TaskGroup — revisit
        // when there are enough observers that serialization matters.
        for i in slots.indices {
            let slot = slots[i]
            guard let obs = slot.observer else { continue }
            let elapsed = frame.timestamp - slot.lastDeliveredTimestamp
            if slot.preferredInterval > 0, elapsed < slot.preferredInterval {
                continue
            }
            slots[i].lastDeliveredTimestamp = frame.timestamp
            await obs.receive(frame, session: self)
        }
    }

    // MARK: - Snapshot mutation helpers (used by observers)

    public func mutateSnapshot(_ body: @Sendable (inout CaptureSessionSnapshot) -> Void) {
        body(&snapshot)
    }
}
