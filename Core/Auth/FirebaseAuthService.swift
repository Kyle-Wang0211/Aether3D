// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// FirebaseAuthService.swift
// Aether3D
//
// Real AuthService backed by the Firebase iOS SDK. TestFlight / production
// variant: no separate backend; `InternalUserID.rawValue` IS the Firebase
// UID. If we ever add our own backend that mints stable internal ids, the
// change happens inside this file — business code stays on
// `AuthenticatedUser.id` and doesn't notice.
//
// The entire file is wrapped in `#if canImport(FirebaseAuth)` so the target
// still builds cleanly before the user has added the Firebase SPM package.

import Foundation

#if canImport(FirebaseAuth)
import FirebaseAuth
#if canImport(FirebaseCore)
import FirebaseCore
#endif

public final class FirebaseAuthService: AuthService, @unchecked Sendable {

    public init(assumeFirebaseConfigured: Bool = false) {
        if !assumeFirebaseConfigured {
            Self.bootstrapFirebaseIfNeeded()
        }
    }

    // MARK: - AuthService

    public func currentUser() async -> AuthenticatedUser? {
        guard let user = Auth.auth().currentUser else { return nil }
        return Self.toAuthenticatedUser(user)
    }

    public func signIn(_ request: SignInRequest) async throws -> AuthenticatedUser {
        let firebaseUser: User
        switch request {
        case .email(let email, let password):
            firebaseUser = try await mapFirebaseErrors {
                try await Auth.auth().signIn(withEmail: email, password: password).user
            }
        case .phone(_, let verificationID, let code):
            let credential = PhoneAuthProvider.provider().credential(
                withVerificationID: verificationID,
                verificationCode: code
            )
            firebaseUser = try await mapFirebaseErrors {
                try await Auth.auth().signIn(with: credential).user
            }
        }
        return Self.toAuthenticatedUser(firebaseUser)
    }

    public func signUp(_ request: SignUpRequest) async throws -> AuthenticatedUser {
        let firebaseUser: User
        let intendedName: String?
        switch request {
        case .email(let email, let password, let name):
            firebaseUser = try await mapFirebaseErrors {
                try await Auth.auth().createUser(withEmail: email, password: password).user
            }
            intendedName = name
        case .phone(_, let verificationID, let code, let name):
            let credential = PhoneAuthProvider.provider().credential(
                withVerificationID: verificationID,
                verificationCode: code
            )
            firebaseUser = try await mapFirebaseErrors {
                try await Auth.auth().signIn(with: credential).user
            }
            intendedName = name
        }
        if let name = intendedName, !name.isEmpty {
            let change = firebaseUser.createProfileChangeRequest()
            change.displayName = name
            try? await change.commitChanges()
        }
        return Self.toAuthenticatedUser(firebaseUser)
    }

    public func startPhoneVerification(phoneNumber: String) async throws -> PhoneVerificationChallenge {
        let verificationID = try await mapFirebaseErrors {
            try await PhoneAuthProvider.provider().verifyPhoneNumber(phoneNumber, uiDelegate: nil)
        }
        return PhoneVerificationChallenge(
            verificationID: verificationID,
            phoneNumber: phoneNumber,
            expiresAt: Date().addingTimeInterval(5 * 60)
        )
    }

    public func sendEmailVerification() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notSignedIn
        }
        try await mapFirebaseErrors {
            try await user.sendEmailVerification()
        }
    }

    public func sendPasswordReset(email: String) async throws {
        try await mapFirebaseErrors {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        }
    }

    public func signOut() async throws {
        try? Auth.auth().signOut()
    }

    public func deleteAccount() async throws {
        if let user = Auth.auth().currentUser {
            try await mapFirebaseErrors {
                try await user.delete()
            }
        }
    }

    // MARK: - Internals

    private static func toAuthenticatedUser(_ user: User) -> AuthenticatedUser {
        return AuthenticatedUser(
            id: InternalUserID(user.uid),
            email: user.email,
            phone: user.phoneNumber,
            displayName: user.displayName
        )
    }

    private func mapFirebaseErrors<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let error as NSError where error.domain == AuthErrorDomain {
            // Firebase Auth 10.x: `AuthErrorCode` is a struct wrapping the
            // raw Int enum `AuthErrorCode.Code`. Use the .Code form here.
            if let code = AuthErrorCode.Code(rawValue: error.code) {
                throw mapCode(code, underlying: error)
            }
            throw AuthError.unknown(detail: error.localizedDescription)
        } catch {
            throw AuthError.unknown(detail: error.localizedDescription)
        }
    }

    private func mapCode(_ code: AuthErrorCode.Code, underlying: NSError) -> AuthError {
        switch code {
        case .invalidEmail, .wrongPassword, .userNotFound, .invalidCredential:
            return .invalidCredentials
        case .emailAlreadyInUse, .credentialAlreadyInUse:
            return .accountAlreadyExists
        case .weakPassword:
            return .weakPassword
        case .tooManyRequests:
            return .rateLimited
        case .networkError:
            return .network(underlying: underlying.localizedDescription)
        case .invalidVerificationCode, .invalidVerificationID, .sessionExpired:
            return .invalidVerificationCode
        default:
            return .unknown(detail: "firebase_\(code.rawValue):\(underlying.localizedDescription)")
        }
    }

    private static func bootstrapFirebaseIfNeeded() {
        #if canImport(FirebaseCore)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        #endif
    }
}

#endif // canImport(FirebaseAuth)
