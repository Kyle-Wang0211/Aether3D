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
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(UIKit)
import UIKit
#endif

struct ScanView: View {
    private let processingBackend: ProcessingBackendChoice
    @StateObject private var viewModel: ScanViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var completedRecord: ScanRecord?
    @State private var showViewer = false

    init(processingBackend: ProcessingBackendChoice = ProcessingBackendChoice.currentSelection()) {
        let normalizedBackend = processingBackend == .localPreview ? .localSubjectFirst : processingBackend
        self.processingBackend = normalizedBackend
        _viewModel = StateObject(
            wrappedValue: ScanViewModel(initialProcessingBackend: normalizedBackend)
        )
    }

    private var isSubjectFirstMode: Bool {
        processingBackend == .localSubjectFirst
    }

    var body: some View {
        ZStack {
            ARCameraPreview(
                viewModel: viewModel,
                prefersMinimalRuntime: viewModel.prefersMinimalARCaptureRuntime,
                shouldAcquireHeavyFrameInputs: viewModel.shouldAcquireHeavyARFrameInputs,
                shouldRequestSceneDepth: viewModel.shouldRequestSceneDepthDuringCapture,
                shouldProcessLiveFrames: viewModel.shouldProcessLiveARFrames,
                renderPresentationPolicy: viewModel.scanState.renderPresentationPolicy
            )
            .ignoresSafeArea()

#if canImport(UIKit) && canImport(MetalKit)
            if isSubjectFirstMode && viewModel.scanState == .capturing {
                LiveSparseDenseMapOverlayView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
#endif

            LinearGradient(
                colors: [Color.black.opacity(0.34), Color.clear, Color.black.opacity(0.64)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar

                if viewModel.coordinatorNotReady && !isSubjectFirstMode {
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

                if !isSubjectFirstMode {
                    ToastOverlay(presenter: viewModel.toastPresenter)
                }

                if showsCaptureDashboard {
                    captureDashboard
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }

                if showsCaptureControls {
                    ScanCaptureControls(
                        isCapturing: viewModel.scanState == .capturing,
                        modeTitle: isSubjectFirstMode ? nil : "标准扫描模式",
                        helperText: isSubjectFirstMode
                            ? nil
                            : "围绕场景缓慢移动，尽量补全主要视角。",
                        onStart: { viewModel.startCapture(processingBackend: processingBackend) },
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
            viewModel.prepareCapture(processingBackend: processingBackend)
        }
#if canImport(UIKit)
#if canImport(Metal)
        .fullScreenCover(isPresented: $showViewer) {
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
#endif
    }

#if canImport(UIKit) && canImport(MetalKit)
private struct LiveSparseDenseMapOverlayView: UIViewRepresentable {
    let viewModel: ScanViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> MTKView {
        let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 0)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        metalView.preferredFramesPerSecond = 20
        metalView.autoResizeDrawable = true
        context.coordinator.attach(metalView)
        return metalView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.attach(uiView)
    }

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        private let viewModel: ScanViewModel
        private var commandQueue: MTLCommandQueue?
        private weak var metalView: MTKView?

        init(viewModel: ScanViewModel) {
            self.viewModel = viewModel
        }

        func attach(_ view: MTKView) {
            guard metalView !== view else { return }
            metalView = view
            if commandQueue == nil, let device = view.device {
                commandQueue = device.makeCommandQueue()
            }
            view.delegate = self
        }

        func teardown() {
            metalView?.delegate = nil
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard viewModel.scanState == .capturing else { return }
            guard let pipeline = viewModel.currentRenderPipelineForOverlay(),
                  let commandQueue,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }

            pipeline.applySyncPoseToCurrentSlot()
            pipeline.encode(into: commandBuffer, renderPassDescriptor: renderPassDescriptor)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
#endif

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
            if isSubjectFirstMode {
                EmptyView()
            } else {
                statusPanel(
                    title: "正在启动扫描环境",
                    detail: "第一次进入会初始化相机和本地引擎，请保持手机稳定。"
                )
            }
        case .ready:
            if isSubjectFirstMode {
                EmptyView()
            } else {
                statusPanel(
                    title: viewModel.liveGuidanceTitle,
                    detail: viewModel.liveGuidanceDetail
                )
            }
        case .paused:
            pausedPanel
        case .failed:
            failurePanel
        case .finishing:
            statusPanel(
                title: isSubjectFirstMode ? "正在整理本地结果" : "正在整理这次拍摄",
                detail: isSubjectFirstMode
                    ? "接下来会在手机上继续做本地整理和预览导出。"
                    : "马上会进入等待页，并继续远端训练和回传。"
            )
        default:
            EmptyView()
        }
    }

    private var showsCaptureDashboard: Bool {
        return viewModel.scanState == .capturing || viewModel.scanState == .ready
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

    @ViewBuilder
    private var captureDashboard: some View {
        if isSubjectFirstMode {
            subjectFirstCaptureDashboard
        } else {
            standardCaptureDashboard
        }
    }

    private var standardCaptureDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.liveGuidanceTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text(viewModel.liveGuidanceDetail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.68))
            }

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

            Text(
                "当前方案：\(processingBackend.displayLabel) · \(FrameSamplingProfile.currentSelection().displayLabel)。云端高质量会走当前成功链；本地处理会优先在手机上给出单目预览。"
            )
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

    private var subjectFirstCaptureDashboard: some View {
        let progressTint: Color =
            viewModel.captureKeyframeProgressFraction >= 1.0 ? .green :
            (viewModel.captureKeyframeProgressFraction >= 0.6 ? .orange : .cyan)
        let acceptanceTint: Color =
            viewModel.captureKeyframeAcceptanceRatio >= 0.45 ? .green :
            (viewModel.captureKeyframeAcceptanceRatio >= 0.25 ? .orange : .red)
        let seedTint: Color =
            viewModel.captureSeedProgressFraction >= 1.0 ? .green :
            (viewModel.captureSeedProgressFraction >= 0.55 ? .orange : .red)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("有效关键帧")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                Text(viewModel.captureKeyframeHint)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.72))
            }

            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.debugSelectedFrames)")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("已收集")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.56))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Text("建议完成 \(viewModel.captureKeyframeRecommendedRangeText)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                }
            }

            keyframeProgressBar(tint: progressTint)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Seed 保底估计")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                    Spacer()
                    Text(viewModel.captureSeedMetricText)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.88))
                }

                seedProgressBar(tint: seedTint)

                Text(viewModel.captureSeedHint)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.56))
            }

            HStack(spacing: 10) {
                signalChip(
                    title: viewModel.captureKeyframeStatusTitle,
                    subtitle: viewModel.subjectCaptureBudgetAdvice,
                    tint: progressTint
                )
                signalChip(
                    title: viewModel.captureSeedStatusTitle,
                    subtitle: viewModel.captureSeedMetricText,
                    tint: seedTint
                )
                signalChip(
                    title: "通过率",
                    subtitle: viewModel.captureKeyframeAcceptanceRateText,
                    tint: acceptanceTint
                )
            }
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
                    viewModel.prepareCapture(processingBackend: processingBackend)
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

    private func keyframeProgressBar(tint: Color) -> some View {
        let maxCount = max(viewModel.captureKeyframeRecommendedMax, 1)
        let progressFraction = min(1.0, Double(viewModel.debugSelectedFrames) / Double(maxCount))
        let minMarker = min(1.0, Double(viewModel.captureKeyframeRecommendedMin) / Double(maxCount))
        let targetMarker = min(1.0, Double(viewModel.captureKeyframeRecommendedTarget) / Double(maxCount))

        return VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: width * CGFloat(targetMarker))
                    Capsule()
                        .fill(tint)
                        .frame(width: width * CGFloat(progressFraction))
                    Capsule()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, width * CGFloat(minMarker) - 1))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: 2, height: 14)
                        .offset(x: max(0, width * CGFloat(targetMarker) - 1))
                }
            }
            .frame(height: 14)

            HStack {
                Text("建议下限 \(viewModel.captureKeyframeRecommendedMin)")
                Spacer()
                Text("建议 \(viewModel.captureKeyframeRecommendedTarget)")
                Spacer()
                Text("建议上限 \(viewModel.captureKeyframeRecommendedMax)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.56))
        }
    }

    private func seedProgressBar(tint: Color) -> some View {
        let progressFraction = min(1.0, viewModel.captureSeedProgressFraction)

        return VStack(spacing: 8) {
            GeometryReader { proxy in
                let width = max(proxy.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                    Capsule()
                        .fill(tint)
                        .frame(width: width * CGFloat(progressFraction))
                }
            }
            .frame(height: 12)

            HStack {
                Text("当前估计 \(viewModel.captureSeedEstimatedCount)")
                Spacer()
                Text("保底目标 \(viewModel.captureSeedTargetCount)")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.56))
        }
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
            processingBackend: processingBackend.rawValue,
            coveragePercentage: Double(viewModel.coveragePercent),
            triangleCount: 0,
            durationSeconds: viewModel.elapsedTime,
            status: .preparing,
            statusMessage: stopStatusMessage,
            detailMessage: stopDetailMessage,
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
        viewModel.startBackgroundExport(recordId: recordId, processingBackend: processingBackend)
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

    private var stopStatusMessage: String {
        switch processingBackend {
        case .cloud:
            return "正在整理拍摄素材"
        case .localPreview, .localSubjectFirst:
            return "正在整理本地素材"
        }
    }

    private var stopDetailMessage: String {
        switch processingBackend {
        case .cloud:
            return "现在会进入黑色等待页。你可以留在这里，也可以返回主页稍后继续。"
        case .localPreview, .localSubjectFirst:
            return "现在会进入等待页；手机会先读取这段录制视频，再按深度先验 → 初始化高斯 → 本地 refine → cutout → cleanup 这条链路继续处理。"
        }
    }
}
#endif
