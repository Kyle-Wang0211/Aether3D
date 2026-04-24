// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EmailSignInView.swift
// Aether3D
//
// Email + password sign-in / sign-up forms.

import Foundation
import Aether3DCore

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct EmailSignInView: View {

    @EnvironmentObject private var currentUser: CurrentUser
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var showForgotPasswordConfirmation: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            AuthField(title: "邮箱", text: $email, keyboard: .emailAddress, isSecure: false)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            AuthField(title: "密码", text: $password, keyboard: .default, isSecure: true)
                .textContentType(.password)

            Button {
                Task { await currentUser.signIn(.email(email: normalizedEmail, password: password)) }
            } label: {
                AuthPrimaryButtonLabel(
                    title: "登录",
                    isWorking: currentUser.isPerformingAuthAction
                )
            }
            .disabled(!canSubmit || currentUser.isPerformingAuthAction)
            .buttonStyle(.plain)

            Button("忘记密码？") {
                Task {
                    let ok = await currentUser.sendPasswordReset(email: normalizedEmail)
                    showForgotPasswordConfirmation = ok
                }
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.6))
            .disabled(normalizedEmail.isEmpty || currentUser.isPerformingAuthAction)
        }
        .alert("重置邮件已发送", isPresented: $showForgotPasswordConfirmation) {
            Button("好的", role: .cancel) {}
        } message: {
            Text("请查收 \(normalizedEmail) 的邮箱中的重置链接。")
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSubmit: Bool {
        !normalizedEmail.isEmpty && password.count >= 6
    }
}

struct EmailSignUpView: View {

    @EnvironmentObject private var currentUser: CurrentUser
    @State private var displayName: String = ""
    @State private var email: String = ""
    @State private var password: String = ""

    var body: some View {
        VStack(spacing: 16) {
            AuthField(title: "昵称（可选）", text: $displayName, keyboard: .default, isSecure: false)

            AuthField(title: "邮箱", text: $email, keyboard: .emailAddress, isSecure: false)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            AuthField(title: "设置密码（至少 8 位）", text: $password, keyboard: .default, isSecure: true)
                .textContentType(.newPassword)

            Button {
                Task {
                    await currentUser.signUp(
                        .email(
                            email: normalizedEmail,
                            password: password,
                            displayName: displayName.isEmpty ? nil : displayName
                        )
                    )
                }
            } label: {
                AuthPrimaryButtonLabel(
                    title: "注册",
                    isWorking: currentUser.isPerformingAuthAction
                )
            }
            .disabled(!canSubmit || currentUser.isPerformingAuthAction)
            .buttonStyle(.plain)

            Text("注册即表示你同意 Aether3D 的服务条款与隐私政策。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
    }

    private var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var canSubmit: Bool {
        !normalizedEmail.isEmpty && password.count >= 8
    }
}

#endif
