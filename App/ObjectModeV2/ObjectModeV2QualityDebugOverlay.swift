// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// ObjectModeV2QualityDebugOverlay.swift
// Aether3D
//
// Small on-device HUD for tuning the dome's sharpness threshold without
// a Mac attached. Reads a `QualityDebugStats` value produced by
// `QualityDebugObserver` (in Core/Capture/) and shows it in the top-
// right corner of the capture view.
//
// Toggled by a long-press gesture on the capture-view host — see
// ObjectModeV2CaptureView.swift for the wiring. Default hidden so
// TestFlight users never see it.

import Foundation

#if canImport(SwiftUI) && canImport(Aether3DCore)
import SwiftUI
import Aether3DCore

struct ObjectModeV2QualityDebugOverlay: View {

    let stats: QualityDebugStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let s = stats {
                row(label: "variance", value: Int(s.currentVariance), color: varianceColor(s.currentVariance, threshold: s.threshold))
                row(label: "avg30f", value: Int(s.avgVariance), color: .white)
                row(label: "brightness", value: Int(s.brightness), color: brightnessColor(s.brightness))
                row(label: "threshold", value: Int(s.threshold), color: .white.opacity(0.5))
                row(label: "accept%", value: Int(s.passRate * 100), color: passRateColor(s.passRate))
                row(label: "samples", value: s.sampleCountInWindow, color: .white.opacity(0.5))
            } else {
                Text("waiting for analyzer…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .frame(minWidth: 150, alignment: .leading)
    }

    private func row(label: String, value: Int, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 4)
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    /// Green when comfortably above threshold, yellow borderline, red
    /// when below. The ±10 % band is wide enough that a typical
    /// handheld jitter doesn't oscillate wildly between green/yellow.
    private func varianceColor(_ v: Double, threshold: Double) -> Color {
        if v >= threshold * 1.1 { return .green }
        if v >= threshold * 0.9 { return .yellow }
        return .red
    }

    private func brightnessColor(_ b: Double) -> Color {
        if b < 30 { return .red }         // dark scene — Laplacian variance suppressed
        if b < 60 { return .yellow }       // dim but usable
        return .white
    }

    private func passRateColor(_ p: Double) -> Color {
        if p >= 0.6 { return .green }
        if p >= 0.3 { return .yellow }
        return .red
    }
}

#Preview {
    VStack(spacing: 16) {
        ObjectModeV2QualityDebugOverlay(stats: nil)
        ObjectModeV2QualityDebugOverlay(stats: QualityDebugStats(
            currentVariance: 1247,
            avgVariance: 1180,
            brightness: 92,
            threshold: 500,
            passRate: 0.73,
            sampleCountInWindow: 20,
            timestamp: 123.4
        ))
        ObjectModeV2QualityDebugOverlay(stats: QualityDebugStats(
            currentVariance: 120,   // blurry
            avgVariance: 180,
            brightness: 35,          // dim
            threshold: 500,
            passRate: 0.08,
            sampleCountInWindow: 20,
            timestamp: 124.0
        ))
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}

#endif
