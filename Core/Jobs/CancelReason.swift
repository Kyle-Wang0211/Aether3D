// ============================================================================
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR2-JSM-2.5
// States: 8 | Transitions: 13 | FailureReasons: 14 | CancelReasons: 2
// ============================================================================

import Foundation

/// Cancel reason enumeration (2 reasons).
public enum CancelReason: String, Codable, CaseIterable {
    case userRequested = "user_requested"
    case appTerminated = "app_terminated"
}

