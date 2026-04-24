// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PhoneSignInView.swift
// Aether3D
//
// Phone number + SMS OTP. Two-step flow:
//   1) Enter phone → provider issues a verificationID.
//   2) Enter the 6-digit code → sign in / sign up.

import Foundation
import Aether3DCore

#if canImport(SwiftUI) && os(iOS)
import SwiftUI

struct PhoneSignInView: View {

    enum Intent {
        case signIn
        case signUp
    }

    @EnvironmentObject private var currentUser: CurrentUser
    let intent: Intent

    @State private var countryCode: String = "+1"
    @State private var nationalNumber: String = ""
    @State private var displayName: String = ""
    @State private var challenge: PhoneVerificationChallenge?
    @State private var code: String = ""

    var body: some View {
        VStack(spacing: 16) {
            if let challenge {
                codeEntryStep(for: challenge)
            } else {
                phoneEntryStep
            }
        }
    }

    // MARK: - Step 1: phone entry

    private var phoneEntryStep: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                TextField("+1", text: $countryCode)
                    .keyboardType(.phonePad)
                    .frame(width: 70)
                    .padding(12)
                    .background(Color.white.opacity(0.08))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                AuthField(
                    title: "手机号（不含国际区号）",
                    text: $nationalNumber,
                    keyboard: .phonePad,
                    isSecure: false
                )
                .textContentType(.telephoneNumber)
            }

            if intent == .signUp {
                AuthField(title: "昵称（可选）", text: $displayName, keyboard: .default, isSecure: false)
            }

            Button {
                Task { await startVerification() }
            } label: {
                AuthPrimaryButtonLabel(
                    title: "发送验证码",
                    isWorking: currentUser.isPerformingAuthAction
                )
            }
            .disabled(!canStartVerification || currentUser.isPerformingAuthAction)
            .buttonStyle(.plain)

            Text("我们会发送一次性验证码到 \(e164PhoneNumber.isEmpty ? "你的手机号" : e164PhoneNumber)。标准短信费可能适用。")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Step 2: code entry

    private func codeEntryStep(for challenge: PhoneVerificationChallenge) -> some View {
        VStack(spacing: 16) {
            Text("验证码已发送到 \(challenge.phoneNumber)")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)

            AuthField(title: "6 位验证码", text: $code, keyboard: .numberPad, isSecure: false)
                .textContentType(.oneTimeCode)

            Button {
                Task { await submitCode(for: challenge) }
            } label: {
                AuthPrimaryButtonLabel(
                    title: intent == .signIn ? "登录" : "完成注册",
                    isWorking: currentUser.isPerformingAuthAction
                )
            }
            .disabled(code.count < 6 || currentUser.isPerformingAuthAction)
            .buttonStyle(.plain)

            Button("换个手机号") {
                self.challenge = nil
                self.code = ""
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.6))
            .disabled(currentUser.isPerformingAuthAction)
        }
    }

    // MARK: - Derived values

    private var e164PhoneNumber: String {
        let cc = countryCode.trimmingCharacters(in: CharacterSet(charactersIn: "+ ").union(.whitespaces))
        let number = nationalNumber.filter { $0.isNumber }
        if cc.isEmpty || number.isEmpty { return "" }
        return "+\(cc)\(number)"
    }

    private var canStartVerification: Bool {
        !e164PhoneNumber.isEmpty && nationalNumber.filter({ $0.isNumber }).count >= 6
    }

    // MARK: - Actions

    private func startVerification() async {
        let result = await currentUser.startPhoneVerification(phoneNumber: e164PhoneNumber)
        challenge = result
    }

    private func submitCode(for challenge: PhoneVerificationChallenge) async {
        switch intent {
        case .signIn:
            await currentUser.signIn(
                .phone(
                    phoneNumber: challenge.phoneNumber,
                    verificationID: challenge.verificationID,
                    code: code
                )
            )
        case .signUp:
            await currentUser.signUp(
                .phone(
                    phoneNumber: challenge.phoneNumber,
                    verificationID: challenge.verificationID,
                    code: code,
                    displayName: displayName.isEmpty ? nil : displayName
                )
            )
        }
    }
}

#endif
