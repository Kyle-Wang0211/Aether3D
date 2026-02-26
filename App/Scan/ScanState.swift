//
// ScanState.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Lifecycle State Machine
// Pure enum — Foundation only, no platform imports
//

import Foundation
#if canImport(CAetherNativeBridge)
import CAetherNativeBridge
#endif

public enum ScanOverlayDepthMode: Int32, Sendable {
    case less = 0
    case lessEqual = 1
}

public enum ScanActionReason: Int32, Sendable {
    case presentation
    case abort

    #if canImport(CAetherNativeBridge)
    fileprivate var nativeCode: Int32 {
        switch self {
        case .presentation: return Int32(AETHER_SCAN_ACTION_REASON_PRESENTATION)
        case .abort: return Int32(AETHER_SCAN_ACTION_REASON_ABORT)
        }
    }
    #endif
}

public struct ScanActionMask: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    #if canImport(CAetherNativeBridge)
    public static let setBlackBackground = ScanActionMask(
        rawValue: UInt32(AETHER_SCAN_ACTION_SET_BLACK_BACKGROUND)
    )
    public static let setOverlayOpaque = ScanActionMask(
        rawValue: UInt32(AETHER_SCAN_ACTION_SET_OVERLAY_OPAQUE)
    )
    public static let setBorderDepthLessEqual = ScanActionMask(
        rawValue: UInt32(AETHER_SCAN_ACTION_SET_BORDER_DEPTH_LESS_EQUAL)
    )
    public static let applyTransition = ScanActionMask(
        rawValue: UInt32(AETHER_SCAN_ACTION_APPLY_TRANSITION)
    )
    #else
    public static let setBlackBackground = ScanActionMask(rawValue: 1 << 0)
    public static let setOverlayOpaque = ScanActionMask(rawValue: 1 << 1)
    public static let setBorderDepthLessEqual = ScanActionMask(rawValue: 1 << 2)
    public static let applyTransition = ScanActionMask(rawValue: 1 << 3)
    #endif
}

public struct ScanRenderPresentationPolicy: Sendable {
    public let forceBlackBackground: Bool
    public let overlayOpaque: Bool
    public let overlayClearAlpha: Double
    public let borderDepthMode: ScanOverlayDepthMode

    public init(
        forceBlackBackground: Bool,
        overlayOpaque: Bool,
        overlayClearAlpha: Double,
        borderDepthMode: ScanOverlayDepthMode
    ) {
        self.forceBlackBackground = forceBlackBackground
        self.overlayOpaque = overlayOpaque
        self.overlayClearAlpha = max(0.0, min(1.0, overlayClearAlpha))
        self.borderDepthMode = borderDepthMode
    }

    public static func fallback(for state: ScanState) -> ScanRenderPresentationPolicy {
        let black = (state == .capturing || state == .paused || state == .finishing)
        return ScanRenderPresentationPolicy(
            forceBlackBackground: black,
            overlayOpaque: black,
            overlayClearAlpha: black ? 1.0 : 0.0,
            borderDepthMode: .lessEqual
        )
    }
}

public struct ScanActionPlan: Sendable {
    public let actionMask: ScanActionMask
    public let overlayClearAlpha: Double
    public let transitionTargetState: ScanState?

    public init(
        actionMask: ScanActionMask,
        overlayClearAlpha: Double = 0,
        transitionTargetState: ScanState? = nil
    ) {
        self.actionMask = actionMask
        self.overlayClearAlpha = max(0.0, min(1.0, overlayClearAlpha))
        self.transitionTargetState = transitionTargetState
    }

    public var renderPresentationPolicy: ScanRenderPresentationPolicy {
        let forceBlackBackground = actionMask.contains(.setBlackBackground)
        return ScanRenderPresentationPolicy(
            forceBlackBackground: forceBlackBackground,
            overlayOpaque: actionMask.contains(.setOverlayOpaque),
            overlayClearAlpha: overlayClearAlpha,
            borderDepthMode: actionMask.contains(.setBorderDepthLessEqual) ? .lessEqual : .less
        )
    }
}

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

    private static let allStates: [ScanState] = [
        .initializing, .ready, .capturing, .paused, .finishing, .completed, .failed
    ]

    private static func from(nativeCode: Int32) -> ScanState? {
        switch nativeCode {
        case Int32(AETHER_SCAN_STATE_INITIALIZING): return .initializing
        case Int32(AETHER_SCAN_STATE_READY): return .ready
        case Int32(AETHER_SCAN_STATE_CAPTURING): return .capturing
        case Int32(AETHER_SCAN_STATE_PAUSED): return .paused
        case Int32(AETHER_SCAN_STATE_FINISHING): return .finishing
        case Int32(AETHER_SCAN_STATE_COMPLETED): return .completed
        case Int32(AETHER_SCAN_STATE_FAILED): return .failed
        default: return nil
        }
    }

    private var nativeCode: Int32 {
        switch self {
        case .initializing: return Int32(AETHER_SCAN_STATE_INITIALIZING)
        case .ready: return Int32(AETHER_SCAN_STATE_READY)
        case .capturing: return Int32(AETHER_SCAN_STATE_CAPTURING)
        case .paused: return Int32(AETHER_SCAN_STATE_PAUSED)
        case .finishing: return Int32(AETHER_SCAN_STATE_FINISHING)
        case .completed: return Int32(AETHER_SCAN_STATE_COMPLETED)
        case .failed: return Int32(AETHER_SCAN_STATE_FAILED)
        }
    }

    /// Valid transitions from this state
    public var allowedTransitions: Set<ScanState> {
        #if canImport(CAetherNativeBridge)
        var result = Set<ScanState>()
        for target in Self.allStates {
            var allowed: Int32 = 0
            let rc = aether_scan_state_can_transition(nativeCode, target.nativeCode, &allowed)
            if rc == 0 && allowed != 0 {
                result.insert(target)
            }
        }
        return result
        #else
        return []
        #endif
    }

    /// Whether scanning is actively in progress
    public var isActive: Bool {
        #if canImport(CAetherNativeBridge)
        var active: Int32 = 0
        return aether_scan_state_is_active(nativeCode, &active) == 0 && active != 0
        #else
        return false
        #endif
    }

    /// Whether the scan can be saved
    public var canFinish: Bool {
        #if canImport(CAetherNativeBridge)
        var canFinish: Int32 = 0
        return aether_scan_state_can_finish(nativeCode, &canFinish) == 0 && canFinish != 0
        #else
        return false
        #endif
    }

    /// Core-owned abort fallback state used when session exits unexpectedly.
    public var recommendedAbortState: ScanState? {
        actionPlan(for: .abort).transitionTargetState
    }

    /// Core-owned render presentation policy for this scan state.
    public var renderPresentationPolicy: ScanRenderPresentationPolicy {
        actionPlan(for: .presentation).renderPresentationPolicy
    }

    /// Core-owned action plan (what to do); system layer executes bits (how to do).
    public func actionPlan(for reason: ScanActionReason) -> ScanActionPlan {
        #if canImport(CAetherNativeBridge)
        var plan = aether_scan_action_plan_t()
        let rc = aether_scan_state_action_plan(nativeCode, reason.nativeCode, &plan)
        if rc == 0 {
            return ScanActionPlan(
                actionMask: ScanActionMask(rawValue: plan.action_mask),
                overlayClearAlpha: Double(plan.overlay_clear_alpha),
                transitionTargetState: Self.from(nativeCode: plan.transition_target_state)
            )
        }
        #endif
        return Self.fallbackActionPlan(for: self, reason: reason)
    }

    private static func fallbackActionPlan(
        for state: ScanState,
        reason: ScanActionReason
    ) -> ScanActionPlan {
        switch reason {
        case .presentation:
            let shouldForceBlack = state == .capturing || state == .paused || state == .finishing
            var mask: ScanActionMask = [.setBorderDepthLessEqual]
            if shouldForceBlack {
                mask.formUnion([.setBlackBackground, .setOverlayOpaque])
            }
            return ScanActionPlan(
                actionMask: mask,
                overlayClearAlpha: shouldForceBlack ? 1.0 : 0.0
            )
        case .abort:
            return ScanActionPlan(actionMask: [])
        }
    }
}
