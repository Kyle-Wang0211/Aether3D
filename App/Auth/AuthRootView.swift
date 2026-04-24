// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuthRootView.swift
// Aether3D
//
// Root of the sign-in flow. Owns the "Sign In ↔ Sign Up" × "Email ↔ Phone"
// selector state and forwards each sub-view to CurrentUser for the work.

import Foundation
import Aether3DCore

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct AuthRootView: View {

    enum Mode: String, Hashable, CaseIterable {
        case signIn = "登录"
        case signUp = "注册"
    }

    @EnvironmentObject private var currentUser: CurrentUser
    @State private var mode: Mode = .signIn

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 32) {
                header
                modePicker
                contentForCurrentMode
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 48)
        }
        .preferredColorScheme(.dark)
        .alert(
            "出错了",
            isPresented: .init(
                get: { currentUser.lastError != nil },
                set: { newValue in if !newValue { currentUser.lastError = nil } }
            ),
            presenting: currentUser.lastError
        ) { _ in
            Button("好的", role: .cancel) { currentUser.lastError = nil }
        } message: { err in
            Text(err.errorDescription ?? "未知错误")
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Text("Aether3D")
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(.white)
            Text(mode == .signIn ? "欢迎回来" : "创建你的账号")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
        }
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            ForEach(Mode.allCases, id: \.self) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .pickerStyle(.segmented)
    }

    // Phone sign-in is intentionally not surfaced here. The
    // PhoneSignInView + Firebase SDK plumbing stays in the project so we
    // can turn phone-based MFA back on later without re-scaffolding.
    @ViewBuilder
    private var contentForCurrentMode: some View {
        switch mode {
        case .signIn:
            EmailSignInView()
        case .signUp:
            EmailSignUpView()
        }
    }
}

#Preview {
    AuthRootView()
        .environmentObject(CurrentUser(service: MockAuthService()))
}

#endif
