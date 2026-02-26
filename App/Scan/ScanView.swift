//
// ScanView.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan View (Three-Layer AR Interface)
// Layer 1: AR Camera (ARSCNView)
// Layer 2: Metal mesh overlay (injected via ARSCNView delegate)
// Layer 3: HUD (Toast + Capture Controls + Close button)
// Apple-platform only (ARKit + SwiftUI)
//

import Foundation

#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI

/// Three-layer AR scanning interface
///
/// Architecture:
///   ZStack {
///     Layer 1: ARCameraPreview (ARSCNView via UIViewRepresentable)
///     Layer 2: Metal mesh overlay (handled inside ARSCNView delegate — no SwiftUI layer)
///     Layer 3: HUD overlay (SwiftUI)
///       - Top: Close button + elapsed time
///       - Middle: Toast overlay
///       - Bottom: ScanCaptureControls (reused component)
///   }
///
/// Navigation:
///   - X button → dismiss (with canFinish check)
///   - Stop → save record + dismiss
///   - onDisappear → cleanup
struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Layer 1: AR Camera
            ARCameraPreview(viewModel: viewModel)
                .ignoresSafeArea()

            // Layer 2: Metal mesh overlay is injected via ARSCNView delegate
            // (handled inside ARCameraPreview coordinator — no separate SwiftUI layer)

            // Layer 3: HUD
            VStack {
                // Top: Close button + elapsed time
                HStack {
                    Button(action: { handleDismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel("关闭")
                    .padding(.leading, 16)

                    Spacer()

                    if viewModel.scanState.isActive || viewModel.scanState == .paused {
                        Text(formatTime(viewModel.elapsedTime))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                            .padding(.trailing, 16)
                            .accessibilityLabel("扫描时长 \(formatTime(viewModel.elapsedTime))")
                    }
                }
                .padding(.top, 8)

                Spacer()

                // Toast overlay (reused component)
                ToastOverlay(presenter: viewModel.toastPresenter)

                // Bottom: Capture controls (reused component)
                ScanCaptureControls(
                    isCapturing: viewModel.scanState.isActive || viewModel.scanState == .paused,
                    onStart: { viewModel.startCapture() },
                    onStop: { handleStop() },
                    onPause: { viewModel.pauseCapture() }
                )
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            // Ensure ARKit session is cleaned up
            if viewModel.scanState != .completed {
                transitionToSafeTerminalState()
            }
        }
    }

    // MARK: - Actions

    /// Handle dismiss (X button)
    ///
    /// If scan is in progress, transition to failed (data discarded).
    /// Future: show confirmation dialog before discarding.
    private func handleDismiss() {
        if viewModel.scanState.canFinish {
            // TODO: Show confirmation dialog before discarding scan
            transitionToSafeTerminalState()
        }
        dismiss()
    }

    /// Handle stop capture
    ///
    /// Creates ScanRecord with metadata, saves to store, and dismisses.
    private func handleStop() {
        if let record = viewModel.stopCapture() {
            // Save record to persistent store
            ScanRecordStore().saveRecord(record)
        }
        dismiss()
    }

    /// Abort flow without assuming a specific transition edge is legal.
    /// Some runtime states (for example paused in older native policies)
    /// may reject .failed; fall back to .ready to avoid debug-time crashes.
    private func transitionToSafeTerminalState() {
        let plan = viewModel.scanState.actionPlan(for: .abort)
        viewModel.executeScanActionPlan(plan)
    }

    // MARK: - Formatting

    /// Format elapsed time as MM:SS
    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#endif
