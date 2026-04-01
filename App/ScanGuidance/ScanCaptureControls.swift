//
// ScanCaptureControls.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan Capture Controls
// Apple-platform only (SwiftUI)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(SwiftUI)
public struct ScanCaptureControls: View {
    let isCapturing: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void

    public init(
        isCapturing: Bool = false,
        onStart: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onPause: @escaping () -> Void
    ) {
        self.isCapturing = isCapturing
        self.onStart = onStart
        self.onStop = onStop
        self.onPause = onPause
    }

    public var body: some View {
        VStack(spacing: 14) {
            if isCapturing {
                HStack(spacing: 14) {
                    secondaryButton(
                        title: "暂停",
                        systemImage: "pause.fill",
                        tint: .white.opacity(0.12),
                        action: onPause
                    )

                    mainCaptureButton(isCapturing: true, action: onStop)
                }
            } else {
                mainCaptureButton(isCapturing: false, action: onStart)
            }
        }
        .padding(.bottom, 42)
    }

    private func mainCaptureButton(isCapturing: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(0.80))
                    .frame(width: 74, height: 74)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 3)
                    )

                if isCapturing {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 24, height: 24)
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 24, height: 24)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func secondaryButton(
        title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 18)
            .frame(height: 48)
            .background(tint)
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
#endif
