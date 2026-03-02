//
// ScanView.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Scan View (Three-Layer AR Interface)
// Layer 1: AR Camera (ARSCNView)
// Layer 2: Metal mesh overlay (point cloud + splat stars via PointCloudOIRPipeline)
// Layer 3: HUD (Toast + Capture Controls + Close button + Timer)
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
///     Layer 2: Metal overlay (PointCloudOIRPipeline — point cloud stars on objects)
///     Layer 3: HUD overlay (SwiftUI)
///       - Top: Close button + elapsed time
///       - Middle: Toast overlay (guidance messages)
///       - Bottom: ScanCaptureControls
///   }
///
/// Point cloud "stars" are rendered via Metal overlay (Layer 2),
/// not as SwiftUI elements. They attach to 3D surfaces in world space.
struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Post-scan viewer navigation
    @State private var completedRecord: ScanRecord?
    @State private var showViewer = false

    var body: some View {
        ZStack {
            // Layer 1: AR Camera
            ARCameraPreview(viewModel: viewModel)
                .ignoresSafeArea()

            // Layer 2: Metal overlay renders point cloud "stars" on scanned surfaces
            // (handled inside ARCameraPreview coordinator — no separate SwiftUI layer)

            // Layer 3: HUD
            VStack(spacing: 0) {
                // ─── Top bar: Close + Timer ───
                HStack(alignment: .center) {
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

                // ─── Debug Overlay: Real-time pipeline stats ───
                // Always visible during development (screenshot for diagnostics)
                if viewModel.scanState.isActive || viewModel.scanState == .paused {
                    debugOverlayView
                        .padding(.top, 4)
                }

                Spacer()

                // Export progress overlay
                if viewModel.isExporting {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("正在导出...")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .padding(.bottom, 24)
                }

                // Toast overlay (guidance messages: move slower, too dark, etc.)
                ToastOverlay(presenter: viewModel.toastPresenter)

                // Bottom: Capture controls
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
        #if canImport(UIKit) && canImport(Metal)
        .navigationDestination(isPresented: $showViewer) {
            if let record = completedRecord {
                SplatViewerView(record: record)
            } else {
                // Defensive fallback: completedRecord should always be set before showViewer.
                // If we reach here, something went wrong in handleStop() ordering.
                SplatViewerView(record: ScanRecord(
                    id: UUID(), name: nil, createdAt: Date(),
                    thumbnailPath: nil, artifactPath: nil,
                    coveragePercentage: 0, triangleCount: 0,
                    durationSeconds: 0))
                .onAppear {
                    NSLog("[Aether3D] WARNING: navigationDestination fired but completedRecord is nil")
                }
            }
        }
        #endif
    }

    // MARK: - Actions

    /// Handle dismiss (X button)
    private func handleDismiss() {
        if viewModel.scanState.canFinish {
            transitionToSafeTerminalState()
        }
        dismiss()
    }

    /// Handle stop capture — navigate to 3D viewer IMMEDIATELY.
    /// User requirement: "拍摄结束后直接进入黑色3d空间"
    /// Export + training continue in background. Viewer loads when ready.
    private func handleStop() {
        NSLog("[Aether3D] handleStop: IMMEDIATE navigation to viewer")

        // 1. Signal pipeline to stop scanning (non-blocking)
        viewModel.finishScanningOnly()

        // 2. Create placeholder record immediately (no waiting for export)
        let recordId = UUID()
        let record = ScanRecord(
            id: recordId, name: nil, createdAt: Date(),
            thumbnailPath: nil, artifactPath: nil,
            coveragePercentage: Double(viewModel.coveragePercent),
            triangleCount: 0,
            durationSeconds: viewModel.elapsedTime)

        ScanRecordStore().saveRecord(record)
        completedRecord = record

        // 3. Transition states
        if viewModel.scanState != .completed {
            if viewModel.scanState.allowedTransitions.contains(.finishing) {
                viewModel.transition(to: .finishing)
            }
            if viewModel.scanState.allowedTransitions.contains(.completed) {
                viewModel.transition(to: .completed)
            }
        }

        // 4. Navigate to 3D viewer IMMEDIATELY (black space → progressive reveal)
        showViewer = true
        NSLog("[Aether3D] handleStop: showViewer=true — navigating NOW")

        // 5. Signal viewer entered → triggers fly-in animations for staged regions
        viewModel.signalViewerEntered()

        // 6. Export runs in background (viewer will pick up when ready)
        viewModel.startBackgroundExport(recordId: recordId)
    }

    /// Abort flow without assuming a specific transition edge is legal.
    private func transitionToSafeTerminalState() {
        let plan = viewModel.scanState.actionPlan(for: .abort)
        viewModel.executeScanActionPlan(plan)
    }

    // MARK: - Debug Overlay

    /// Semi-transparent debug HUD showing real-time pipeline stats.
    /// Always visible during development. Screenshot for diagnostics.
    private var debugOverlayView: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Bridge status (most important indicator)
            HStack(spacing: 4) {
                Circle()
                    .fill(viewModel.debugBridgeReady ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(viewModel.debugBridgeReady ? "Bridge: OK" : "Bridge: nil")
                    .foregroundColor(viewModel.debugBridgeReady ? .green : .red)
            }

            // Coordinator init time (shows loading progress)
            if !viewModel.debugBridgeReady {
                Text("Init: \(String(format: "%.1fs", viewModel.debugCoordinatorInitTime))")
                    .foregroundColor(.yellow)
            }

            // Frame counters
            Text("Frame: \(viewModel.debugFrameCount)  →C++: \(viewModel.debugPipelineFrameCount)")

            // Render data
            Text("Blk: \(viewModel.debugPointCloudCount)  OVL: \(viewModel.debugOverlayCount)  Splat: \(viewModel.debugSplatCount)")

            // Point cloud global alpha + encode stats
            Text("Alpha: \(String(format: "%.2f", viewModel.debugPointCloudAlpha))  Draw: \(viewModel.debugEncodeDrawCount)  Skip: \(viewModel.debugEncodeSkipCount)")

            // Training status (S6+ quality gate)
            HStack(spacing: 4) {
                // S6+ quality gate indicator
                let s6 = viewModel.debugHasS6Quality
                Text("S6+: \(s6 ? "✓" : "—")")
                    .foregroundColor(s6 ? .green : .orange)
                Text("Sel: \(viewModel.debugSelectedFrames)")
                    .foregroundColor(.white.opacity(0.7))
                if viewModel.debugTotalSteps > 0 {
                    let gpuTag = viewModel.debugIsGPUTraining ? "GPU" : "CPU"
                    Text("\(gpuTag) \(viewModel.debugTrainingStep)/\(viewModel.debugTotalSteps)  Loss: \(String(format: "%.4f", viewModel.debugLoss))")
                        .foregroundColor(viewModel.debugIsGPUTraining ? .cyan : .yellow)
                } else if !s6 {
                    Text("(scanning for quality)")
                        .foregroundColor(.orange)
                } else {
                    Text("(initializing...)")
                        .foregroundColor(.yellow)
                }
            }

            // Region training status (区域化训练)
            if viewModel.debugRegionTotal > 0 {
                HStack(spacing: 4) {
                    Text("Rgn: \(viewModel.debugRegionCompleted)/\(viewModel.debugRegionTotal)")
                        .foregroundColor(.cyan)
                    if viewModel.debugActiveRegionId >= 0 {
                        Text("R\(viewModel.debugActiveRegionId) \(Int(viewModel.debugActiveRegionProgress * 100))%")
                            .foregroundColor(.yellow)
                    }
                    if viewModel.debugStagedCount > 0 {
                        Text("Stg:\(viewModel.debugStagedCount)")
                            .foregroundColor(.green)
                    }
                }
            }

            // Memory usage (detect jetsam risk)
            let memMB = Self.currentMemoryMB()
            Text("Mem: \(memMB)MB")
                .foregroundColor(memMB > 1200 ? .red : (memMB > 800 ? .yellow : .white))
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.6))
        .cornerRadius(6)
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Memory Monitoring

    /// Current app memory footprint in MB (mach_task_basic_info)
    private static func currentMemoryMB() -> Int {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.resident_size / (1024 * 1024)) : 0
    }

    // MARK: - Formatting

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#endif
