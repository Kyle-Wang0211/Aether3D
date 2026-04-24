// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CurrentUser.swift
// Aether3D
//
// ObservableObject between AuthService and SwiftUI.
//
// Views never depend on AuthService directly. They observe `CurrentUser`,
// which publishes three states:
//   .bootstrapping — we haven't yet checked the persisted session
//   .signedIn(AuthenticatedUser) — show the app
//   .signedOut — show the sign-in flow

import Foundation

#if canImport(SwiftUI)
import SwiftUI

@MainActor
public final class CurrentUser: ObservableObject {

    public enum State: Equatable {
        case bootstrapping
        case signedIn(AuthenticatedUser)
        case signedOut
    }

    /// A session is force-signed-out if the app hasn't seen activity in this
    /// many seconds. "Activity" = successful sign-in, successful bootstrap,
    /// or the scene becoming active while already signed-in.
    ///
    /// We do this locally (UserDefaults timestamp) rather than through
    /// Firebase because Firebase iOS tokens don't expire by default — we
    /// want a hard lockout the user controls even when offline.
    public static let idleSignOutInterval: TimeInterval = 30 * 24 * 60 * 60

    private static let idleTimestampKey = "Aether3D.auth.lastActivityAt"

    @Published public private(set) var state: State = .bootstrapping

    /// Inline-display auth failures (e.g. "wrong password"). Cleared on the
    /// next successful transition.
    @Published public var lastError: AuthError?

    /// Suppresses the "re-entrant sign-in" race when the user taps a button
    /// multiple times.
    @Published public private(set) var isPerformingAuthAction: Bool = false

    private let service: AuthService

    public init(service: AuthService) {
        self.service = service
    }

    /// Called once at app launch (from the App's `.task`). Reads whatever
    /// persisted session the provider tracks and jumps to `.signedIn` or
    /// `.signedOut`. Force-signs-out if the session has been idle past the
    /// policy window.
    public func bootstrap() async {
        guard let user = await service.currentUser() else {
            Self.clearPersistedUserID()
            state = .signedOut
            return
        }
        if isIdleExpired() {
            try? await service.signOut()
            clearIdleTimestamp()
            Self.clearPersistedUserID()
            state = .signedOut
            return
        }
        touchIdleTimestamp()
        Self.persistUserID(user.id.rawValue)
        state = .signedIn(user)
    }

    /// Called by UI on scene-become-active transitions. If the session has
    /// exceeded the idle window we drop the user to the sign-in gate
    /// immediately; otherwise we refresh the "last active" stamp.
    public func refreshIdleSession() async {
        guard case .signedIn = state else { return }
        if isIdleExpired() {
            await signOut()
            return
        }
        touchIdleTimestamp()
    }

    private func isIdleExpired() -> Bool {
        let last = UserDefaults.standard.double(forKey: Self.idleTimestampKey)
        guard last > 0 else { return false }
        let elapsed = Date().timeIntervalSince1970 - last
        return elapsed > Self.idleSignOutInterval
    }

    private func touchIdleTimestamp() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.idleTimestampKey)
    }

    private func clearIdleTimestamp() {
        UserDefaults.standard.removeObject(forKey: Self.idleTimestampKey)
    }

    public func signIn(_ request: SignInRequest) async {
        await runAuthAction { [service] in
            try await service.signIn(request)
        }
    }

    public func signUp(_ request: SignUpRequest) async {
        await runAuthAction { [service] in
            try await service.signUp(request)
        }
    }

    public func startPhoneVerification(phoneNumber: String) async -> PhoneVerificationChallenge? {
        isPerformingAuthAction = true
        defer { isPerformingAuthAction = false }
        do {
            return try await service.startPhoneVerification(phoneNumber: phoneNumber)
        } catch let err as AuthError {
            lastError = err
            return nil
        } catch {
            lastError = .unknown(detail: error.localizedDescription)
            return nil
        }
    }

    public func sendPasswordReset(email: String) async -> Bool {
        isPerformingAuthAction = true
        defer { isPerformingAuthAction = false }
        do {
            try await service.sendPasswordReset(email: email)
            return true
        } catch let err as AuthError {
            lastError = err
            return false
        } catch {
            lastError = .unknown(detail: error.localizedDescription)
            return false
        }
    }

    public func signOut() async {
        do {
            try await service.signOut()
        } catch {
            // Signing out locally is best-effort; network failures shouldn't
            // keep the user stuck in an authed UI.
        }
        clearIdleTimestamp()
        Self.clearPersistedUserID()
        state = .signedOut
        lastError = nil
    }

    public func deleteAccount() async -> Bool {
        isPerformingAuthAction = true
        defer { isPerformingAuthAction = false }
        do {
            try await service.deleteAccount()
            clearIdleTimestamp()
            Self.clearPersistedUserID()
            state = .signedOut
            lastError = nil
            return true
        } catch let err as AuthError {
            lastError = err
            return false
        } catch {
            lastError = .unknown(detail: error.localizedDescription)
            return false
        }
    }

    // MARK: - Private helpers

    private func runAuthAction(_ action: @escaping @Sendable () async throws -> AuthenticatedUser) async {
        isPerformingAuthAction = true
        defer { isPerformingAuthAction = false }
        lastError = nil
        do {
            let user = try await action()
            touchIdleTimestamp()
            Self.persistUserID(user.id.rawValue)
            state = .signedIn(user)
        } catch let err as AuthError {
            lastError = err
        } catch {
            lastError = .unknown(detail: error.localizedDescription)
        }
    }

    // MARK: - currentUserID persistence
    //
    // The key is read (synchronously) by non-auth modules like
    // ScanRecordStore so they can scope their per-user data without
    // having to await the CurrentUser actor on every allocation. See
    // AuthPersistenceKeys.currentUserID for the rationale.

    private static func persistUserID(_ uid: String) {
        UserDefaults.standard.set(uid, forKey: AuthPersistenceKeys.currentUserID)
    }

    private static func clearPersistedUserID() {
        UserDefaults.standard.removeObject(forKey: AuthPersistenceKeys.currentUserID)
    }
}

#endif // canImport(SwiftUI)
