// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuthSharedViews.swift
// Aether3D
//
// Small presentational helpers used by the Auth sub-views.

import Foundation

#if canImport(SwiftUI) && os(iOS)
import SwiftUI
import UIKit

struct AuthField: View {
    let title: String
    @Binding var text: String
    let keyboard: UIKeyboardType
    let isSecure: Bool

    var body: some View {
        Group {
            if isSecure {
                SecureField(title, text: $text)
            } else {
                TextField(title, text: $text)
                    .keyboardType(keyboard)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color.white.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

struct AuthPrimaryButtonLabel: View {
    let title: String
    let isWorking: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white)
                .frame(height: 48)

            if isWorking {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.black)
            } else {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
            }
        }
    }
}

#endif
