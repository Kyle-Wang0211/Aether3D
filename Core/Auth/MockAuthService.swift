// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// MockAuthService.swift
// Aether3D
//
// In-memory AuthService for SwiftUI previews, unit tests, and the
// "Firebase SDK not linked yet" bring-up state.
//
// Never used in production: the factory in Aether3DApp only picks this when
// `canImport(FirebaseAuth)` is false.

import Foundation

public final class MockAuthService: AuthService, @unchecked Sendable {
    private let stateLock = NSLock()
    private var cached: AuthenticatedUser?

    public init(initial: AuthenticatedUser? = nil) {
        self.cached = initial
    }

    public func currentUser() async -> AuthenticatedUser? {
        readCached()
    }

    public func signIn(_ request: SignInRequest) async throws -> AuthenticatedUser {
        let user: AuthenticatedUser
        switch request {
        case .email(let e, _):
            user = AuthenticatedUser(
                id: InternalUserID("mock_\(Self.slug(e))"),
                email: e,
                phone: nil,
                displayName: nil
            )
        case .phone(let number, _, _):
            user = AuthenticatedUser(
                id: InternalUserID("mock_\(Self.slug(number))"),
                email: nil,
                phone: number,
                displayName: nil
            )
        }
        store(user)
        return user
    }

    public func signUp(_ request: SignUpRequest) async throws -> AuthenticatedUser {
        let user: AuthenticatedUser
        switch request {
        case .email(let e, _, let name):
            user = AuthenticatedUser(
                id: InternalUserID("mock_\(Self.slug(e))"),
                email: e,
                phone: nil,
                displayName: name
            )
        case .phone(let number, _, _, let name):
            user = AuthenticatedUser(
                id: InternalUserID("mock_\(Self.slug(number))"),
                email: nil,
                phone: number,
                displayName: name
            )
        }
        store(user)
        return user
    }

    public func startPhoneVerification(phoneNumber: String) async throws -> PhoneVerificationChallenge {
        return PhoneVerificationChallenge(
            verificationID: "mock_vid_\(Self.slug(phoneNumber))",
            phoneNumber: phoneNumber,
            expiresAt: Date().addingTimeInterval(300)
        )
    }

    public func sendEmailVerification() async throws { /* no-op */ }
    public func sendPasswordReset(email: String) async throws { /* no-op */ }

    public func signOut() async throws {
        clearCached()
    }

    public func deleteAccount() async throws {
        try await signOut()
    }

    // MARK: - Sync helpers
    //
    // Swift 6 strict concurrency forbids calling `NSLock.lock()` directly
    // from async contexts. We isolate the lock operations in non-async
    // helpers here so the protocol's async surface stays clean.

    private func readCached() -> AuthenticatedUser? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return cached
    }

    private func store(_ user: AuthenticatedUser) {
        stateLock.lock()
        cached = user
        stateLock.unlock()
    }

    private func clearCached() {
        stateLock.lock()
        cached = nil
        stateLock.unlock()
    }

    private static func slug(_ input: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = input.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "_"
        }
        return String(scalars).lowercased()
    }
}
