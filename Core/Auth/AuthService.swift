// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuthService.swift
// Aether3D
//
// The ONE place in the app that knows how to sign a user in/out.
//
// Concrete implementations (FirebaseAuthService, MockAuthService) plug in
// here. Every UI screen, every persistence path goes through this protocol
// — so the day we replace Firebase with something else, there is a single
// file to swap.

import Foundation

/// Intent passed to `signIn` so UI code doesn't pick between overloaded
/// methods. New sign-in methods land as new cases.
public enum SignInRequest: Sendable {
    /// Email + password.
    case email(email: String, password: String)

    /// Phone (E.164) + OTP previously issued via `startPhoneVerification`.
    case phone(phoneNumber: String, verificationID: String, code: String)
}

public enum SignUpRequest: Sendable {
    case email(email: String, password: String, displayName: String?)
    case phone(phoneNumber: String, verificationID: String, code: String, displayName: String?)
}

/// Implemented by every auth backend.
public protocol AuthService: AnyObject, Sendable {
    /// Currently signed-in user, or nil if signed out.
    func currentUser() async -> AuthenticatedUser?

    /// Sign in with an existing account.
    func signIn(_ request: SignInRequest) async throws -> AuthenticatedUser

    /// Create a new account.
    func signUp(_ request: SignUpRequest) async throws -> AuthenticatedUser

    /// Send an OTP to a phone number. Returns a `verificationID` to pass
    /// into `signIn(.phone(...))` or `signUp(.phone(...))`.
    func startPhoneVerification(phoneNumber: String) async throws -> PhoneVerificationChallenge

    /// Resend an email verification link to the currently-signed-in user.
    func sendEmailVerification() async throws

    /// Start the password-reset email flow for a given email.
    func sendPasswordReset(email: String) async throws

    /// Drop the current session locally and in the provider.
    func signOut() async throws

    /// Delete the user's account at the provider AND clear local state.
    /// Irreversible.
    func deleteAccount() async throws
}

/// Opaque handle returned from `startPhoneVerification`. Provider-defined.
public struct PhoneVerificationChallenge: Equatable, Sendable {
    public let verificationID: String
    public let phoneNumber: String
    public let expiresAt: Date?

    public init(verificationID: String, phoneNumber: String, expiresAt: Date?) {
        self.verificationID = verificationID
        self.phoneNumber = phoneNumber
        self.expiresAt = expiresAt
    }
}
