//
// ScanState.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Lifecycle State Machine
// Pure enum — Foundation only, no platform imports
//

import Foundation

/// Scan lifecycle state machine
///
/// State transitions:
///   initializing → ready → capturing ⇄ paused → finishing → completed
///   capturing → failed
///   paused → ready (cancel)
///   failed → ready (retry)
///
/// All transitions are validated via `allowedTransitions`.
/// ScanViewModel MUST use the validated `transition(to:)` method.
public enum ScanState: String, Sendable {
    case initializing   // ARKit session starting
    case ready          // Session ready, waiting for user tap
    case capturing      // Actively recording frames
    case paused         // User paused, can resume or stop
    case finishing      // Processing final data
    case completed      // Scan saved, ready to return home
    case failed         // Unrecoverable error

    /// Valid transitions from this state
    public var allowedTransitions: Set<ScanState> {
        switch self {
        case .initializing: return [.ready, .failed]
        case .ready:        return [.capturing, .failed]
        case .capturing:    return [.paused, .finishing, .failed]
        case .paused:       return [.capturing, .ready, .finishing]
        case .finishing:    return [.completed, .failed]
        case .completed:    return []  // Terminal
        case .failed:       return [.ready]  // Allow retry
        }
    }

    /// Whether scanning is actively in progress
    public var isActive: Bool {
        self == .capturing
    }

    /// Whether the scan can be saved
    public var canFinish: Bool {
        self == .capturing || self == .paused
    }
}
