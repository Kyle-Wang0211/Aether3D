//
// ScanView.swift
// Aether3D
//
// Minimal whitebox capture flow.
//

import Foundation
import Aether3DCore

#if canImport(SwiftUI) && canImport(ARKit)
import SwiftUI

struct ScanView: View {
    @StateObject private var viewModel = ScanViewModel()
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ProcessingBackendChoice.userDefaultsKey) private var selectedProcessingBackendRaw = ProcessingBackendChoice.cloud.rawValue

    @State private var completedRecord: ScanRecord?
    @State private var showViewer = false

    private var selectedProcessingBackend: ProcessingBackendChoice {
        ProcessingBackendChoice(rawValue: selectedProcessingBackendRaw) ?? .cloud
    }

    var body: some View {
        ZStack {
            ARCameraPreview(viewModel: viewModel)
                .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.34), Color.clear, Color.black.opacity(0.64)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar

                if viewModel.coordinatorNotReady {
                    inlineBanner(
                        title: "扫描引擎还在加载",
                        detail: "请再等几秒后再结束拍摄，避免拿不到可用结果。",
                        tint: .orange
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                Spacer()

                centerOverlay

                Spacer()

                ToastOverlay(presenter: viewModel.toastPresenter)

                if showsCaptureDashboard {
                    captureDashboard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }

                if showsCaptureControls {
                    ScanCaptureControls(
                        isCapturing: viewModel.scanState == .capturing,
                        onStart: { viewModel.startCapture(processingBackend: selectedProcessingBackend) },
                        onStop: { handleStop() },
                        onPause: { viewModel.pauseCapture() }
                    )
                } else {
                    Color.clear.frame(height: 24)
                }
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onDisappear {
            if !showViewer && viewModel.scanState != .completed {
                transitionToSafeTerminalState()
            }
        }
        .onAppear {
            viewModel.prepareCapture(processingBackend: selectedProcessingBackend)
        }
        #if canImport(UIKit) && canImport(Metal)
        .navigationDestination(isPresented: $showViewer) {
            if let record = completedRecord {
                SplatViewerView(
                    record: record,
                    scanViewModel: viewModel,
                    onReturnHome: {
                        completedRecord = nil
                        showViewer = false
                        dismiss()
                    }
                )
            } else {
                EmptyView()
            }
        }
        #endif
    }

    private var topBar: some View {
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
    }

    @ViewBuilder
    private var centerOverlay: some View {
        switch viewModel.scanState {
        case .initializing:
            statusPanel(
                title: "正在启动扫描环境",
                detail: "第一次进入会初始化相机和本地引擎，请保持手机稳定。"
            )
        case .ready:
            statusPanel(
                title: viewModel.liveGuidanceTitle,
                detail: viewModel.liveGuidanceDetail
            )
        case .paused:
            pausedPanel
        case .failed:
            failurePanel
        case .finishing:
            statusPanel(
                title: "正在整理这次拍摄",
                detail: "马上会进入等待页，并继续远端训练和回传。"
            )
        default:
            EmptyView()
        }
    }

    private var showsCaptureDashboard: Bool {
        viewModel.scanState == .capturing || viewModel.scanState == .ready
    }

    private var showsCaptureControls: Bool {
        switch viewModel.scanState {
        case .initializing, .failed, .finishing:
            return false
        case .ready, .capturing:
            return true
        case .paused:
            return false
        case .completed:
            return false
        }
    }

    private var captureDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.liveGuidanceTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                    Text(viewModel.liveGuidanceDetail)
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.68))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(Int(viewModel.coveragePercent * 100))%")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("覆盖率")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            ProgressView(value: Double(viewModel.coveragePercent))
                .tint(.cyan)

            HStack(spacing: 10) {
                signalChip(
                    title: viewModel.motionWarningActive ? "移动过快" : "速度正常",
                    subtitle: String(format: "%.2f m/s", viewModel.latestMotionSpeedMps),
                    tint: viewModel.motionWarningActive ? .orange : .green
                )
                signalChip(
                    title: viewModel.exposureWarningActive ? "光线异常" : "曝光正常",
                    subtitle: viewModel.latestAmbientIntensity > 0
                        ? String(format: "%.0f lux", viewModel.latestAmbientIntensity)
                        : "等待测光",
                    tint: viewModel.exposureWarningActive ? .orange : .green
                )
                signalChip(
                    title: viewModel.stabilityWarningActive ? "姿态不稳" : "稳定性正常",
                    subtitle: viewModel.stabilityWarningActive ? "请稍稳一点" : "可以继续",
                    tint: viewModel.stabilityWarningActive ? .orange : .green
                )
            }

            Text("当前方案：\(selectedProcessingBackend.displayLabel) · \(FrameSamplingProfile.currentSelection().displayLabel)。云端高质量会走当前成功链；本地快速预览会优先在手机上给出单目 preview。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.48))
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black.opacity(0.62))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private var pausedPanel: some View {
        VStack(spacing: 18) {
            statusPanel(
                title: "扫描已暂停",
                detail: viewModel.sessionPauseMessage ?? "你可以继续拍摄，也可以直接结束生成。"
            )

            HStack(spacing: 12) {
                overlayButton(
                    title: "继续拍摄",
                    systemImage: "play.fill",
                    style: .primary
                ) {
                    viewModel.resumeCapture()
                }

                overlayButton(
                    title: "结束生成",
                    systemImage: "stop.fill",
                    style: .secondary
                ) {
                    handleStop()
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private var failurePanel: some View {
        VStack(spacing: 18) {
            statusPanel(
                title: "扫描中断了",
                detail: viewModel.scanFailureMessage ?? "请返回主页重新开始一次拍摄。"
            )

            HStack(spacing: 12) {
                overlayButton(
                    title: "返回主页",
                    systemImage: "house.fill",
                    style: .primary
                ) {
                    dismiss()
                }

                overlayButton(
                    title: "重新准备",
                    systemImage: "arrow.clockwise",
                    style: .secondary
                ) {
                    viewModel.prepareCapture(processingBackend: selectedProcessingBackend)
                    viewModel.transition(to: .ready)
                }
            }
        }
        .padding(.horizontal, 20)
    }

    private func statusPanel(title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.68))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: 340)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black.opacity(0.64))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func inlineBanner(title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.66))
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.black.opacity(0.62))
        )
    }

    private func signalChip(title: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.58))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(tint.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(tint.opacity(0.28), lineWidth: 1)
                )
        )
    }

    private enum OverlayButtonStyle {
        case primary
        case secondary
    }

    private func overlayButton(
        title: String,
        systemImage: String,
        style: OverlayButtonStyle,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 15, weight: .bold))
            .foregroundColor(style == .primary ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(style == .primary ? Color.white : Color.white.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: 25)
                    .stroke(Color.white.opacity(style == .primary ? 0.0 : 0.16), lineWidth: 1)
            )
            .cornerRadius(25)
        }
        .buttonStyle(.plain)
    }

    private func handleDismiss() {
        if viewModel.scanState.canFinish {
            transitionToSafeTerminalState()
        }
        dismiss()
    }

    private func handleStop() {
        NSLog("[Aether3D] handleStop: IMMEDIATE navigation to viewer")

        viewModel.finishScanningOnly()

        let recordId = UUID()
        let frameSamplingProfile = FrameSamplingProfile.currentSelection()
        let record = ScanRecord(
            id: recordId,
            name: nil,
            createdAt: Date(),
            thumbnailPath: nil,
            artifactPath: nil,
            sourceVideoPath: nil,
            frameSamplingProfile: frameSamplingProfile.rawValue,
            captureIntent: nil,
            processingBackend: selectedProcessingBackend.rawValue,
            coveragePercentage: Double(viewModel.coveragePercent),
            triangleCount: 0,
            durationSeconds: viewModel.elapsedTime,
            status: .preparing,
            statusMessage: selectedProcessingBackend == .localPreview ? "正在准备本地快速预览" : "正在整理拍摄素材",
            detailMessage: selectedProcessingBackend == .localPreview
                ? "现在会进入等待页；手机会先用本地单目链路生成一个快速可看的 preview。"
                : "现在会进入黑色等待页。你可以留在这里，也可以返回主页稍后继续。",
            progressFraction: 0.01,
            estimatedRemainingMinutes: nil
        )

        ScanRecordStore().saveRecord(record)
        completedRecord = record

        if viewModel.scanState.allowedTransitions.contains(.finishing) {
            viewModel.transition(to: .finishing)
        }

        showViewer = true
        viewModel.signalViewerEntered()
        viewModel.startBackgroundExport(recordId: recordId, processingBackend: selectedProcessingBackend)
    }

    private func transitionToSafeTerminalState() {
        let plan = viewModel.scanState.actionPlan(for: .abort)
        viewModel.executeScanActionPlan(plan)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

#endif
