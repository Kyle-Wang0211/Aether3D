// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuthError.swift
// Aether3D
//
// Errors surfaced by the AuthService protocol.
//
// Deliberately provider-agnostic: FirebaseAuthService maps Firebase errors
// into these cases so UI code never has to `switch on NSError.code`.

import Foundation

public enum AuthError: Error, LocalizedError, Equatable {
    /// Invalid email / phone / password.
    case invalidCredentials

    /// Requested email/phone already has an account.
    case accountAlreadyExists

    /// SMS verification code didn't match or expired.
    case invalidVerificationCode

    /// Password too weak for provider policy.
    case weakPassword

    /// Provider rate-limited the request (too many attempts).
    case rateLimited

    /// Network transport error; user can retry.
    case network(underlying: String)

    /// Provider backend not reachable or misconfigured.
    case providerUnavailable(detail: String)

    /// Action requires a signed-in user but there was none.
    case notSignedIn

    /// Catch-all for anything we don't explicitly model.
    case unknown(detail: String)

    public var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "账号或密码不正确"
        case .accountAlreadyExists:
            return "该账号已注册，请直接登录"
        case .invalidVerificationCode:
            return "验证码错误或已过期"
        case .weakPassword:
            return "密码强度不足（至少 6 位）"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .network:
            return "网络连接失败，请检查网络后重试"
        case .providerUnavailable:
            return "登录服务暂时不可用"
        case .notSignedIn:
            return "请先登录"
        case .unknown:
            return "登录失败，请重试"
        }
    }
}
