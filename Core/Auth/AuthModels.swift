// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuthModels.swift
// Aether3D
//
// Value types the rest of the app uses to talk about identity.
//
// Architectural rule: business code references `AuthenticatedUser.id` and
// NOTHING else from the auth layer. Provider-specific identifiers (e.g.
// firebase_uid) stay inside FirebaseAuthService.swift and never reach this
// surface. That is what lets us swap auth providers later without touching
// business code.

import Foundation

/// Strongly-typed wrapper so `String` user IDs don't get confused with other
/// strings (job IDs, record IDs, etc.) at call sites. This is the ONLY
/// identifier the app is allowed to persist or reference long-term.
///
/// Today the raw value IS the Firebase UID, but callers must never assume
/// that. If we ever add our own backend that mints internal IDs, switching
/// will be a one-line change in FirebaseAuthService — call sites stay intact.
public struct InternalUserID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// The authenticated user as the app sees them.
///
/// Intentionally minimal: anything we don't show in UI or use for scoping
/// (provider tokens, internal timestamps, etc.) lives in the auth provider
/// and is only exposed through AuthService if genuinely needed.
public struct AuthenticatedUser: Equatable, Sendable, Codable {
    public let id: InternalUserID
    public let email: String?
    public let phone: String?
    public let displayName: String?

    public init(
        id: InternalUserID,
        email: String?,
        phone: String?,
        displayName: String?
    ) {
        self.id = id
        self.email = email
        self.phone = phone
        self.displayName = displayName
    }
}

/// UserDefaults keys the auth layer persists so that other modules can
/// read the current user synchronously without awaiting the CurrentUser
/// actor. `currentUserID` in particular exists so that the ~16 call
/// sites of `ScanRecordStore()` scattered around the app can resolve
/// "who is logged in right now?" at allocation time — without threading
/// the user through every view model. CurrentUser writes it on sign-in
/// and bootstrap success, clears it on sign-out. UserDefaults is
/// thread-safe and persists across cold launches, so a newly-launched
/// app can still render the right user's scans before Firebase finishes
/// bootstrapping.
public enum AuthPersistenceKeys {
    public static let currentUserID = "Aether3D.auth.currentUserID"
}
