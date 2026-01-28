// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-3.0
// States: 8 | Transitions: 13 | FailureReasons: 17 | CancelReasons: 3
// ============================================================================

import Foundation

/// Cancel reason enumeration (3 reasons).
public enum CancelReason: String, Codable, CaseIterable {
    case userRequested = "user_requested"
    case appTerminated = "app_terminated"
    case systemTimeout = "system_timeout"    // NEW v3.0: Auto-cancel on prolonged inactivity
}

