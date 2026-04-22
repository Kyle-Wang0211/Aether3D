import Foundation

#if canImport(SwiftUI)
import SwiftUI
#if canImport(UIKit)
import UIKit
#if canImport(QuickLook)
import QuickLook
#endif
#if canImport(WebKit)
import WebKit
#endif
#endif

struct ObjectModeV2CaptureView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: ObjectModeV2CaptureViewModel
    @State private var reticlePulse = false
    @State private var showLockFlash = false
    @State private var showLockBadge = false
    @State private var lockBadgePulse = false
    @State private var showRecordingCarryover = false
    @State private var showAcceptedFrameFlash = false
    private let onClose: (() -> Void)?

    private let maxFrames = 150

    init(onClose: (() -> Void)? = nil) {
        _viewModel = StateObject(wrappedValue: ObjectModeV2CaptureViewModel())
        self.onClose = onClose
    }

    var body: some View {
        ZStack {
            if viewModel.shouldShowProcessingOverlay {
                processingScreen
            } else {
                captureScreen
            }
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(false)
        .fullScreenCover(isPresented: $viewModel.isArtifactViewerPresented) {
            if let artifactURL = viewModel.downloadedArtifactURL {
                ObjectModeV2DefaultArtifactViewer(
                    url: artifactURL,
                    manifestURL: viewModel.manifestURL,
                    processingDurationLabel: viewModel.processingDurationLabelText
                ) {
                    viewModel.isArtifactViewerPresented = false
                }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            reticlePulse = true
            viewModel.onAppear()
        }
        .onDisappear {
            viewModel.onDisappear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.noteScenePhase(newPhase)
        }
        .onChange(of: viewModel.isTargetLocked) { _, isLocked in
            if isLocked {
                showLockBadge = true
                showLockFlash = true
                lockBadgePulse = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.48) {
                    withAnimation(.easeOut(duration: 0.24)) {
                        showLockFlash = false
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.92)) {
                        lockBadgePulse = false
                    }
                }
            } else {
                showLockFlash = false
                showLockBadge = false
                lockBadgePulse = false
            }
        }
        .onChange(of: captureHUDActive) { _, isActive in
            if isActive && viewModel.isTargetLocked {
                showRecordingCarryover = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    withAnimation(.easeOut(duration: 0.28)) {
                        showRecordingCarryover = false
                    }
                }
            } else if !isActive {
                showRecordingCarryover = false
            }
        }
        .onChange(of: viewModel.acceptedFrameFeedbackTick) { _, _ in
            withAnimation(.easeOut(duration: 0.08)) {
                showAcceptedFrameFlash = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.easeOut(duration: 0.22)) {
                    showAcceptedFrameFlash = false
                }
            }
        }
        .animation(.easeInOut(duration: 0.24), value: viewModel.shouldShowProcessingOverlay)
    }

    private var captureScreen: some View {
        ZStack {
            cameraLayer

            LinearGradient(
                colors: [
                    Color.black.opacity(0.32),
                    Color.black.opacity(0.06),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Spacer()
                centerPreview
                Spacer()
                bottomHud
            }
        }
    }

    private var processingScreen: some View {
        ObjectModeV2ProcessingSurface(
            snapshot: processingSnapshot,
            onOpen: viewModel.downloadedArtifactURL != nil ? { viewModel.openRecord() } : nil,
            onClose: {
                closeToHome()
            }
        )
    }

    private func closeToHome() {
        viewModel.prepareForDismiss()
        onClose?()
        dismiss()
    }

    @ViewBuilder
    private var cameraLayer: some View {
        #if canImport(UIKit) && canImport(AVFoundation)
        if viewModel.shouldShowProcessingOverlay {
            Color.black.ignoresSafeArea()
        } else {
            #if canImport(ARKit) && canImport(SwiftUI) && canImport(simd)
            // AR 路径:画面来自 ARSession(跟 dome 的 6DoF 共享同一个相机)
            ObjectModeV2ARKitPreview(
                session: viewModel.domeCoordinator.session,
                bridge: viewModel.previewBridge
            )
            .ignoresSafeArea()
            #else
            ObjectModeV2CameraPreview(session: viewModel.previewSession, bridge: viewModel.previewBridge)
                .ignoresSafeArea()
            #endif
        }
        #else
        Color.black.ignoresSafeArea()
        #endif
    }

    private var topBar: some View {
        ZStack {
            HStack {
                Spacer()
                Button(action: {
                    closeToHome()
                }) {
                    Circle()
                        .fill(Color.black.opacity(0.35))
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white.opacity(0.9))
                        )
                        .frame(width: 38, height: 38)
                }
            }

            VStack(spacing: 8) {
                Circle()
                    .fill(trackingIndicatorColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: trackingIndicatorColor.opacity(0.6), radius: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var centerPreview: some View {
        VStack(spacing: 18) {
            ZStack {
                if isPreCaptureUI {
                    preCaptureReticle
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .opacity
                        ))
                } else {
                    Color.clear
                        .frame(width: 1, height: 1)
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .opacity
                        ))
                }
            }
            .frame(width: isPreCaptureUI ? 268 : 1, height: isPreCaptureUI ? 322 : 1)

            if let cameraError = viewModel.cameraError {
                Text(cameraError)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color(red: 1.0, green: 0.83, blue: 0.40))
                    .clipShape(Capsule())
            }
        }
    }

    private var bottomHud: some View {
        VStack(spacing: 18) {
            if viewModel.manifestURL != nil {
                processingStatusCard
            }

            if isPreCaptureUI {
                preCaptureBottomHud
            } else {
                HStack(alignment: .bottom, spacing: 26) {
                    leftAnchor
                    captureButtonOrDome
                    trailingDock
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
    }

    private var processingOverlay: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.74),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
                .ignoresSafeArea()

            VStack(spacing: 18) {
                processingHero

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("OBJECT MODE BETA")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.55))
                            Text(processingHeroTitle)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                            Text(processingHeroSubtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.72))
                        }
                        Spacer()
                        if viewModel.downloadedArtifactURL != nil {
                            Button(action: {
                                viewModel.openRecord()
                            }) {
                                Text("Open")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                            }
                        } else if viewModel.processingFailureReason != nil {
                            Text("失败")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color(red: 1.0, green: 0.58, blue: 0.58))
                                .clipShape(Capsule())
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }

                    processingContextCard

                    stageProgressBand

                    HStack(spacing: 10) {
                        statChip(title: "Frames", value: "\(min(viewModel.acceptedFrames, maxFrames))")
                        statChip(title: "Orbit", value: "\(Int(viewModel.orbitCompletion * 100))%")
                        statChip(title: "Status", value: processingStatusSummary)
                    }

                    ForEach(viewModel.visibleStageCards) { card in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(stageColor(card.state))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(stageSubtitle(for: card))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.66))
                            }
                            Spacer()
                            stageTrailingLabel(for: card.state)
                        }
                        .padding(.vertical, 4)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                        Text("你可以留在这里等待，也可以稍后在作品列表里继续查看。")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 2)
                }
                .padding(18)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 24)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        closeToHome()
                    }) {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))
                            )
                            .frame(width: 38, height: 38)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Spacer()
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private var processingSnapshot: ObjectModeV2ProcessingSnapshot {
        let lockAccent = viewModel.isTargetLocked
            ? targetZoneAccentColor
            : Color(red: 0.95, green: 0.79, blue: 0.12)

        #if canImport(UIKit)
        return ObjectModeV2ProcessingSnapshot(
            heroBadge: "OBJECT MODE BETA",
            heroTitle: processingHeroTitle,
            heroSubtitle: processingHeroSubtitle,
            heroImage: viewModel.acceptedFrameThumbnails.last?.image,
            canOpenArtifact: viewModel.downloadedArtifactURL != nil,
            isFailed: viewModel.processingFailureReason != nil,
            isInspectionOnlyCandidate: viewModel.isInspectionOnlyCandidate,
            modeValue: "Guided",
            lockValue: viewModel.isTargetLocked ? "Confirmed" : "Open",
            lockAccent: lockAccent,
            stageCards: viewModel.visibleStageCards,
            stats: [
                .init(title: "Frames", value: "\(min(viewModel.acceptedFrames, maxFrames))"),
                .init(title: "Orbit", value: "\(Int(viewModel.orbitCompletion * 100))%"),
                .init(title: "Status", value: processingStatusSummary),
                .init(title: "Elapsed", value: viewModel.processingDurationShortText)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。",
            failedCardsSummary: nil
        )
        #else
        return ObjectModeV2ProcessingSnapshot(
            heroBadge: "OBJECT MODE BETA",
            heroTitle: processingHeroTitle,
            heroSubtitle: processingHeroSubtitle,
            canOpenArtifact: viewModel.downloadedArtifactURL != nil,
            isFailed: viewModel.processingFailureReason != nil,
            isInspectionOnlyCandidate: viewModel.isInspectionOnlyCandidate,
            modeValue: "Guided",
            lockValue: viewModel.isTargetLocked ? "Confirmed" : "Open",
            lockAccent: lockAccent,
            stageCards: viewModel.visibleStageCards,
            stats: [
                .init(title: "Frames", value: "\(min(viewModel.acceptedFrames, maxFrames))"),
                .init(title: "Orbit", value: "\(Int(viewModel.orbitCompletion * 100))%"),
                .init(title: "Status", value: processingStatusSummary),
                .init(title: "Elapsed", value: viewModel.processingDurationShortText)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。",
            failedCardsSummary: nil
        )
        #endif
    }

    private var processingHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 250, height: 250)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            #if canImport(UIKit)
            if let latest = viewModel.acceptedFrameThumbnails.last {
                ZStack(alignment: .bottom) {
                    Image(uiImage: latest.image)
                        .resizable()
                        .scaledToFill()
                        .saturation(0.12)
                        .frame(width: 210, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .opacity(0.82)

                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.18),
                            Color.black.opacity(0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 210, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Text("正在生成 HQ 成品")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.44))
                        .clipShape(Capsule())
                        .padding(.bottom, 14)
                }
            } else {
                DraftObjectPreview(
                    acceptedFrames: viewModel.acceptedFrames,
                    orbitCompletion: viewModel.orbitCompletion,
                    isRecording: false,
                    highlightFlash: false,
                    thumbnails: viewModel.acceptedFrameThumbnails
                )
                .frame(width: 210, height: 220)
            }
            #else
            DraftObjectPreview(
                acceptedFrames: viewModel.acceptedFrames,
                orbitCompletion: viewModel.orbitCompletion,
                isRecording: false,
                highlightFlash: false
            )
            .frame(width: 210, height: 220)
            #endif
        }
    }

    private var stageProgressBand: some View {
        HStack(spacing: 10) {
            ForEach(viewModel.visibleStageCards) { card in
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)

                    Capsule()
                        .fill(stageColor(card.state))
                        .frame(height: 6)

                    Text(stageBandDetail(for: card))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.46))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var processingContextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPTURE CONTEXT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.48))

            HStack(spacing: 10) {
                processingContextChip(
                    title: "Mode",
                    value: "Guided",
                    accent: .white
                )
                processingContextChip(
                    title: "Lock",
                    value: viewModel.isTargetLocked ? "Confirmed" : "Open",
                    accent: viewModel.isTargetLocked ? targetZoneAccentColor : Color(red: 0.95, green: 0.79, blue: 0.12)
                )
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func processingContextChip(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.44))
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var processingStatusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(processingCardTitle)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if viewModel.downloadedArtifactURL != nil {
                    Button(action: {
                        viewModel.openRecord()
                    }) {
                        Text("Open")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.white)
                            .clipShape(Capsule())
                    }
                } else {
                    Text(processingCardBadgeTitle)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 10) {
                ForEach(viewModel.visibleStageCards) { card in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(stageColor(card.state))
                            .frame(width: 8, height: 8)
                        Text(card.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Capsule())
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var captureBudgetDock: some View {
        VStack(spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ACCEPTED FRAMES")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.58))
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("\(min(viewModel.acceptedFrames, maxFrames))")
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(.white)
                        Text(captureReadinessLabel)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(captureReadinessColor)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(captureReadinessColor.opacity(0.16))
                            .clipShape(Capsule())
                    }
                }

                Spacer(minLength: 8)

                acceptedFrameStrip
            }

            VStack(spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(height: 6)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.95, green: 0.79, blue: 0.12),
                                    Color(red: 0.99, green: 0.92, blue: 0.55)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(frameBudgetProgress * 308, 8), height: 6)

                    HStack(spacing: 0) {
                        Circle()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: 8, height: 8)
                        Spacer()
                        Circle()
                            .fill(Color.white.opacity(0.14))
                            .frame(width: 8, height: 8)
                    }
                    .frame(width: 308)

                    VStack(spacing: 6) {
                        Text("\(min(viewModel.acceptedFrames, maxFrames))")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.white)
                            .clipShape(Capsule())

                        Circle()
                            .fill(Color(red: 0.95, green: 0.79, blue: 0.12))
                            .frame(width: 12, height: 12)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.72), lineWidth: 2)
                            )
                    }
                    .offset(x: min(max(frameBudgetProgress * 308 - 16, 0), 292), y: -22)
                }
                .frame(width: 308, height: 28)

                HStack {
                    Text("20 (MIN)")
                    Spacer()
                    Text("150 (MAX)")
                }
                .frame(width: 308)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    @ViewBuilder
    private var leftAnchor: some View {
        // 录制中弱化时间概念 —— 只留一个 72pt 占位保持 HStack 对齐。
        if viewModel.isRecording {
            Color.clear.frame(width: 72, height: 1)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("OBJECT")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.72))
                Text(String(format: "%02d:%02d", viewModel.recordingSeconds / 60, viewModel.recordingSeconds % 60))
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 72, alignment: .leading)
        }
    }

    private var preCaptureBottomHud: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                Spacer(minLength: 0)
                captureButton
                Spacer(minLength: 0)
            }
        }
    }

    private var targetModeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("GUIDED TARGET")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.white.opacity(0.52))
                    Text("Tell Guided whether you're framing one subject or a small group.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.58))
                }
                Spacer()
                if viewModel.isTargetLocked {
                    Text("LOCKED")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(targetZoneAccentColor)
                        .clipShape(Capsule())
                }
            }

            HStack(spacing: 10) {
                ForEach(ObjectModeV2TargetZoneMode.allCases, id: \.rawValue) { mode in
                    Button(action: {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
                            viewModel.setTargetZoneMode(mode)
                        }
                    }) {
                        VStack(spacing: 3) {
                            Text(mode.title)
                                .font(.system(size: 13, weight: .bold))
                            Text(mode.subtitle)
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(viewModel.targetZoneMode == mode ? .black : .white.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(viewModel.targetZoneMode == mode ? Color.white : Color.black.opacity(0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }

                if viewModel.isTargetLocked {
                    Button(action: {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
                            viewModel.resetTargetLock()
                        }
                    }) {
                        Text("Reset")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.36))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(14)
        .background(Color.black.opacity(0.30))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    /// 录制中显示 60-cell 球形 coverage dome,点击 = 结束拍摄;
    /// 未录制/处理中保持原白环快门。
    @ViewBuilder
    private var captureButtonOrDome: some View {
        #if canImport(ARKit) && canImport(SwiftUI) && canImport(simd) && canImport(UIKit)
        if viewModel.isRecording {
            // 关键:dome + 白环 两层都 allowsHitTesting(false),顶层一个透明 Color
            // 用 onTapGesture 捕获点击 —— 最稳可靠,不依赖 Button/UIView hit chain。
            ZStack {
                ObjectModeV2DomeContainerView(
                    coordinator: viewModel.domeCoordinator,
                    onTap: { }
                )
                .frame(width: 120, height: 120)
                .allowsHitTesting(false)

                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 120, height: 120)
                    .allowsHitTesting(false)

                Color.black.opacity(0.001)     // 几乎透明但能接收 tap
                    .frame(width: 140, height: 140)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        viewModel.toggleCapture()
                    }
            }
            .frame(width: 140, height: 140)
            .accessibilityLabel("结束采集并生成")
        } else {
            captureButton
        }
        #else
        captureButton
        #endif
    }

    private var captureButton: some View {
        Button(action: {
            viewModel.toggleCapture()
        }) {
            ZStack {
                Circle()
                    .stroke(Color.white, lineWidth: 4)
                    .frame(width: 110, height: 110)

                Circle()
                    .fill(Color.black.opacity(0.75))
                    .frame(width: 94, height: 94)

                if viewModel.isRunning {
                    ProgressView()
                        .tint(.white)
                } else if captureHUDActive {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 8, height: 24)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 8, height: 24)
                    }
                } else {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 28, height: 28)
                }
            }
        }
        .disabled(!(viewModel.canStartCapture || viewModel.canStopCapture))
        .accessibilityLabel(captureHUDActive ? "正在开始对象采集" : "开始对象采集")
    }

    private var trailingDock: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if viewModel.manifestURL != nil {
                Button(action: {
                    viewModel.openRecord()
                }) {
                    Text("Open")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 64, height: 30)
                        .background(Color.white.opacity(0.14))
                        .clipShape(Capsule())
                }
            } else if !viewModel.isRecording {
                // 录制中隐藏 —— 取代它的统计在球顶 HUD ("N 帧 · M 深绿")。
                acceptedFramesBadge
            }
        }
        .frame(width: 86, alignment: .trailing)
    }

    private var acceptedFramesBadge: some View {
        VStack(spacing: 8) {
            Text("有效关键帧")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.62))
            Text("\(viewModel.acceptedFrames)")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: 82)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.34))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(acceptedFramesBadgeStrokeColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var acceptedFramesBadgeStrokeColor: Color {
        if captureHUDActive && viewModel.acceptedFrames >= viewModel.minimumAcceptedFrames {
            return Color(red: 0.54, green: 0.96, blue: 0.62).opacity(0.62)
        }
        return Color.white.opacity(0.12)
    }

    @ViewBuilder
    private var draftPreviewView: some View {
        #if canImport(UIKit)
        DraftObjectPreview(
            acceptedFrames: viewModel.acceptedFrames,
            orbitCompletion: viewModel.orbitCompletion,
            isRecording: captureHUDActive,
            highlightFlash: showAcceptedFrameFlash,
            thumbnails: viewModel.acceptedFrameThumbnails
        )
        .frame(width: 234, height: 286)
        .overlay {
            if showRecordingCarryover && viewModel.isTargetLocked {
                recordingTargetCarryover
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        #else
        DraftObjectPreview(
            acceptedFrames: viewModel.acceptedFrames,
            orbitCompletion: viewModel.orbitCompletion,
            isRecording: captureHUDActive,
            highlightFlash: showAcceptedFrameFlash
        )
        .frame(width: 234, height: 286)
        .overlay {
            if showRecordingCarryover && viewModel.isTargetLocked {
                recordingTargetCarryover
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
        #endif
    }

    @ViewBuilder
    private var miniFrameStackView: some View {
        #if canImport(UIKit)
        MiniFrameStack(
            acceptedFrames: viewModel.acceptedFrames,
            thumbnails: viewModel.acceptedFrameThumbnails
        )
        #else
        MiniFrameStack(acceptedFrames: viewModel.acceptedFrames)
        #endif
    }

    private var frameBudgetProgress: CGFloat {
        CGFloat(min(Double(viewModel.acceptedFrames) / Double(maxFrames), 1.0))
    }

    private var captureReadinessLabel: String {
        if viewModel.acceptedFrames < viewModel.minimumAcceptedFrames {
            return "MORE"
        }
        if viewModel.acceptedFrames < 60 {
            return "GOOD"
        }
        return "RICH"
    }

    private var captureReadinessColor: Color {
        if viewModel.acceptedFrames < viewModel.minimumAcceptedFrames {
            return Color(red: 0.98, green: 0.76, blue: 0.24)
        }
        if viewModel.acceptedFrames < 60 {
            return Color(red: 0.67, green: 0.95, blue: 0.58)
        }
        return Color(red: 0.50, green: 0.84, blue: 1.0)
    }

    private var processingStatusSummary: String {
        if viewModel.isInspectionOnlyCandidate {
            return "Needs QA"
        }
        if viewModel.processingFailureReason != nil {
            return "Failed"
        }
        if viewModel.stageCards.allSatisfy({ if case .ready = $0.state { return true } else { return false } }) {
            return "Done"
        }
        if viewModel.stageCards.contains(where: { if case .processing = $0.state { return true } else { return false } }) {
            return "Live"
        }
        return "Queued"
    }

    private var trackingIndicatorColor: Color {
        if viewModel.cameraError != nil {
            return Color.red
        }
        if viewModel.isPreparingCamera {
            return Color.orange
        }
        return Color.green
    }

    private func stageColor(_ state: ObjectModeV2StageUIState) -> Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.35)
        case .processing:
            return Color(red: 0.95, green: 0.79, blue: 0.12)
        case .ready:
            return Color(red: 0.54, green: 0.96, blue: 0.62)
        case .failed:
            return Color(red: 1.0, green: 0.46, blue: 0.46)
        }
    }

    private func stageSubtitle(for card: ObjectModeV2StageCard) -> String {
        switch card.state {
        case .idle:
            return card.subtitle
        case .processing:
            return "正在生成 \(card.title) 资产"
        case .ready:
            return "\(card.title) 已可用于查看"
        case .failed(let reason):
            return reason ?? "\(card.title) 生成失败"
        }
    }

    @ViewBuilder
    private func stageTrailingLabel(for state: ObjectModeV2StageUIState) -> some View {
        switch state {
        case .idle:
            Text("等待中")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        case .processing(let progress):
            Text(progress.map { "\((Int($0 * 100)))%" } ?? "处理中")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.95, green: 0.79, blue: 0.12))
                .clipShape(Capsule())
        case .ready:
            Text("已完成")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.54, green: 0.96, blue: 0.62))
                .clipShape(Capsule())
        case .failed:
            Text("失败")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 1.0, green: 0.58, blue: 0.58))
                .clipShape(Capsule())
        }
    }

    private var acceptedFrameStrip: some View {
        VStack(alignment: .trailing, spacing: 6) {
            #if canImport(UIKit)
            AcceptedFrameStrip(
                thumbnails: viewModel.acceptedFrameThumbnails,
                pulseLatest: showAcceptedFrameFlash
            )
            #else
            AcceptedFrameStrip()
            #endif

            Text("系统自动挑选稳定关键帧")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.54))
        }
    }

    private func stageBandDetail(for card: ObjectModeV2StageCard) -> String {
        switch card.state {
        case .idle:
            return "等待"
        case .processing(let progress):
            if let progress {
                return "\(Int(progress * 100))%"
            }
            return "处理中"
        case .ready:
            return "完成"
        case .failed:
            return "失败"
        }
    }

    private var coverageOrb: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.14), lineWidth: 4)
                .frame(width: 56, height: 56)

            Circle()
                .trim(from: 0, to: max(min(viewModel.orbitCompletion, 1), 0.02))
                .stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 0.95, green: 0.79, blue: 0.12),
                            captureReadinessColor
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .frame(width: 56, height: 56)
                .rotationEffect(.degrees(-90))

            VStack(spacing: 2) {
                Text("\(Int(viewModel.orbitCompletion * 100))")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Text(stabilityLabel)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white.opacity(0.56))
            }
        }
    }

    private var modeTabs: some View {
        HStack(spacing: 18) {
            modeTab("SPACE", selected: false)
            modeTab("OBJECT", selected: true)
            HStack(spacing: 4) {
                modeTab("AI CAPTURE", selected: false)
                Text("AI")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .offset(y: -8)
            }
            modeTab("360", selected: false)
        }
        .padding(.top, 2)
    }

    private func modeTab(_ title: String, selected: Bool) -> some View {
        Text(title)
            .font(.system(size: 12, weight: selected ? .bold : .semibold))
            .foregroundColor(selected ? Color(red: 0.93, green: 0.84, blue: 0.46) : .white.opacity(0.62))
    }

    private var preCaptureReticle: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let anchor = CGPoint(
                x: size.width * viewModel.targetZoneAnchor.x,
                y: size.height * viewModel.targetZoneAnchor.y
            )
            let zoneSize = targetZoneSize(in: size)

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onEnded { value in
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                                    viewModel.lockTarget(at: value.location, in: size)
                                }
                            }
                    )

                if showLockFlash {
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(targetZoneAccentColor.opacity(0.95), lineWidth: 2)
                        .frame(width: zoneSize.width + 42, height: zoneSize.height + 42)
                        .position(anchor)
                        .scaleEffect(showLockFlash ? 1.08 : 0.94)
                        .opacity(showLockFlash ? 0 : 0.9)
                }

                targetPulse(size: zoneSize)
                    .position(anchor)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(targetZoneAccentColor.opacity(viewModel.isTargetLocked ? 0.10 : 0.03))
                    .frame(width: zoneSize.width, height: zoneSize.height)
                    .position(anchor)

                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(targetZoneAccentColor.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                    .frame(width: zoneSize.width + 18, height: zoneSize.height + 18)
                    .position(anchor)

                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(targetZoneAccentColor.opacity(viewModel.isTargetLocked ? 0.95 : 0.42), lineWidth: viewModel.isTargetLocked ? 2.2 : 1.2)
                    .frame(width: zoneSize.width, height: zoneSize.height)
                    .position(anchor)

                TargetZoneCornerMarks(color: targetZoneAccentColor.opacity(viewModel.isTargetLocked ? 0.95 : 0.46))
                    .frame(width: zoneSize.width + 10, height: zoneSize.height + 10)
                    .position(anchor)

                Circle()
                    .fill(targetZoneAccentColor)
                    .frame(width: 8, height: 8)
                    .position(anchor)

                if showLockBadge || viewModel.isTargetLocked {
                    targetLockBadge
                        .position(x: anchor.x, y: anchor.y - (zoneSize.height * 0.5) - 22)
                        .transition(.scale.combined(with: .opacity))
                }

                if viewModel.isTargetLocked {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(targetZoneAccentColor)
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.36))
                                .frame(width: 24, height: 24)
                        )
                        .position(x: anchor.x + zoneSize.width * 0.5 - 8, y: anchor.y - zoneSize.height * 0.5 + 8)
                }
            }
        }
    }

    private var isPreCaptureUI: Bool {
        !captureHUDActive && !viewModel.shouldShowProcessingOverlay && viewModel.manifestURL == nil && viewModel.acceptedFrames == 0
    }

    private var captureHUDActive: Bool {
        viewModel.isRecording
    }

    private var processingCardTitle: String {
        if viewModel.isInspectionOnlyCandidate {
            return "候选结果待质检"
        }
        if viewModel.processingFailureReason != nil {
            return "生成失败"
        }
        if viewModel.downloadedArtifactURL != nil || viewModel.visibleStageCards.allSatisfy({ if case .ready = $0.state { return true } else { return false } }) {
            return "生成完成"
        }
        return "正在生成 HQ 成品"
    }

    private var processingCardBadgeTitle: String {
        if viewModel.isInspectionOnlyCandidate {
            return "未达 HQ"
        }
        if viewModel.processingFailureReason != nil {
            return "失败"
        }
        return viewModel.downloadedArtifactURL != nil ? "可查看" : "请稍候"
    }

    private var processingHeroTitle: String {
        if viewModel.isInspectionOnlyCandidate {
            return "候选结果已生成"
        }
        return viewModel.processingFailureReason == nil ? "正在生成 HQ 成品" : "HQ 成品生成失败"
    }

    private var processingHeroSubtitle: String {
        if viewModel.isInspectionOnlyCandidate {
            return viewModel.statusText.isEmpty ? "未达 HQ，仅供质检。你可以先打开候选结果做人工判断。" : viewModel.statusText
        }
        if let failureReason = viewModel.processingFailureReason, !failureReason.isEmpty {
            return failureReason
        }
        return "系统会生成唯一的 HQ 3D 成品；下载完成后即可打开。"
    }

    private var stabilityLabel: String {
        if viewModel.stabilityScore < 0.4 {
            return "HOLD"
        }
        if viewModel.stabilityScore < 0.7 {
            return "OK"
        }
        return "GOOD"
    }

    private var recordingTargetCarryover: some View {
        let size = CGSize(width: 92, height: 92)

        return ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(targetZoneAccentColor.opacity(0.92), lineWidth: 2)
                .frame(width: size.width, height: size.height)
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(targetZoneAccentColor.opacity(0.24), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .frame(width: size.width + 16, height: size.height + 16)
        }
    }

    private func targetZoneSize(in size: CGSize) -> CGSize {
        CGSize(width: min(92, size.width * 0.34), height: min(92, size.height * 0.24))
    }

    private var targetZoneAccentColor: Color {
        viewModel.isTargetLocked ? Color(red: 0.54, green: 0.96, blue: 0.62) : .white
    }

    private func targetPulse(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
            .stroke(targetZoneAccentColor.opacity(viewModel.isTargetLocked ? 0.26 : 0.12), lineWidth: 1)
            .frame(width: size.width + 28, height: size.height + 28)
            .scaleEffect(reticlePulse ? 1.05 : 0.96)
            .opacity(reticlePulse ? (viewModel.isTargetLocked ? 0.36 : 0.30) : 0.10)
            .animation(
                .easeInOut(duration: 1.8).repeatForever(autoreverses: true),
                value: reticlePulse
            )
    }

    private var targetLockBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
                .font(.system(size: 11, weight: .bold))
            Text("OBJECT LOCKED")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(targetZoneAccentColor)
        .clipShape(Capsule())
        .shadow(color: Color.black.opacity(lockBadgePulse ? 0.26 : 0.16), radius: lockBadgePulse ? 14 : 8, y: 3)
        .scaleEffect(lockBadgePulse ? 1.08 : 1.0)
    }
}

private struct TargetZoneCornerMarks: View {
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let h = proxy.size.height
            let l = min(w, h) * 0.16

            Path { path in
                path.move(to: CGPoint(x: 0, y: l))
                path.addLine(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: l, y: 0))

                path.move(to: CGPoint(x: w - l, y: 0))
                path.addLine(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: w, y: l))

                path.move(to: CGPoint(x: 0, y: h - l))
                path.addLine(to: CGPoint(x: 0, y: h))
                path.addLine(to: CGPoint(x: l, y: h))

                path.move(to: CGPoint(x: w - l, y: h))
                path.addLine(to: CGPoint(x: w, y: h))
                path.addLine(to: CGPoint(x: w, y: h - l))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct MiniFrameStack: View {
    let acceptedFrames: Int
    #if canImport(UIKit)
    let thumbnails: [ObjectModeV2AcceptedFrameThumbnail]
    #endif

    var body: some View {
        ZStack {
            #if canImport(UIKit)
            if !thumbnails.isEmpty {
                let recent = Array(thumbnails.suffix(3))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, thumbnail in
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 24, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.8)
                        )
                        .rotationEffect(.degrees(Double(index - 1) * 6))
                        .offset(x: CGFloat(index - 1) * 6, y: CGFloat(index - 1) * -1)
                }
            } else {
                placeholderStack
            }
            #else
            placeholderStack
            #endif

            VStack(spacing: 3) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.78))
                Text("\(acceptedFrames)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
        }
    }

    private var placeholderStack: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.08 + Double(index) * 0.04))
                    .frame(width: 24, height: 30)
                    .rotationEffect(.degrees(Double(index - 1) * 6))
                    .offset(x: CGFloat(index - 1) * 6, y: CGFloat(index - 1) * -1)
            }
        }
    }
}

private struct AcceptedFrameStrip: View {
    #if canImport(UIKit)
    var thumbnails: [ObjectModeV2AcceptedFrameThumbnail] = []
    var pulseLatest: Bool = false
    #endif

    var body: some View {
        HStack(spacing: 6) {
            #if canImport(UIKit)
            if !thumbnails.isEmpty {
                let recent = Array(thumbnails.suffix(5))
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, thumbnail in
                    let isLatest = index == recent.count - 1
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(
                                    Color.white.opacity(isLatest ? (pulseLatest ? 0.86 : 0.42) : 0.14),
                                    lineWidth: isLatest ? (pulseLatest ? 2.0 : 1.4) : 1
                                )
                        )
                        .shadow(
                            color: isLatest
                                ? Color.white.opacity(pulseLatest ? 0.34 : 0.0)
                                : Color.black.opacity(0),
                            radius: pulseLatest && isLatest ? 10 : 0,
                            y: 0
                        )
                        .shadow(color: Color.black.opacity(isLatest ? 0.24 : 0), radius: 6, y: 2)
                        .scaleEffect(isLatest && pulseLatest ? 1.08 : 1.0)
                }
            } else {
                placeholder
            }
            #else
            placeholder
            #endif
        }
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            ForEach(0..<5, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 30, height: 40)
            }
        }
    }
}

private struct DraftObjectPreview: View {
    let acceptedFrames: Int
    let orbitCompletion: Double
    let isRecording: Bool
    let highlightFlash: Bool
    #if canImport(UIKit)
    let thumbnails: [ObjectModeV2AcceptedFrameThumbnail]
    #endif

    private var pointCount: Int {
        max(24, min(acceptedFrames * 3, 220))
    }

    private var shellOpacity: Double {
        min(0.32 + Double(acceptedFrames) / 240.0, 0.72)
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                supportBase(size: size)
                ghostComposite(size: size)
                coreObjectShell(size: size)
                pointCloudLayer(size: size)

                DraftGhostMaskShape()
                    .stroke(Color.white.opacity(0.07), lineWidth: 1)
                    .frame(width: size.width * 0.44, height: size.height * 0.74)
                    .offset(y: size.height * -0.02)

                DraftGhostMaskShape()
                    .fill(Color.white.opacity(0.03))
                    .frame(width: size.width * 0.40, height: size.height * 0.68)
                    .offset(y: size.height * -0.02)

                if highlightFlash {
                    DraftGhostMaskShape()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: size.width * 0.42, height: size.height * 0.70)
                        .offset(y: size.height * -0.02)
                }

                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.03), lineWidth: 1)
                    .frame(width: size.width * 0.30, height: size.height * 0.78)
                    .offset(y: size.height * -0.02)
            }
        }
    }

    @ViewBuilder
    private func supportBase(size: CGSize) -> some View {
        ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.28),
                            Color.white.opacity(0.11),
                            Color.white.opacity(0.02)
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: size.width * 0.42
                    )
                )
                .frame(width: size.width * 0.86, height: size.height * 0.22)
                .offset(y: size.height * 0.30)

            Ellipse()
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
                .frame(width: size.width * 0.70, height: size.height * 0.12)
                .offset(y: size.height * 0.29)

            if highlightFlash {
                Ellipse()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: size.width * 0.78, height: size.height * 0.14)
                    .offset(y: size.height * 0.29)
            }
        }
    }

    @ViewBuilder
    private func ghostComposite(size: CGSize) -> some View {
        #if canImport(UIKit)
        if !thumbnails.isEmpty {
            let recent = Array(thumbnails.suffix(4))
            ForEach(Array(recent.enumerated()), id: \.element.id) { index, thumbnail in
                Image(uiImage: thumbnail.image)
                    .resizable()
                    .scaledToFill()
                    .saturation(0.08)
                    .contrast(1.12)
                    .frame(
                        width: size.width * (0.31 + CGFloat(index) * 0.05),
                        height: size.height * (0.48 + CGFloat(index) * 0.055)
                    )
                    .clipShape(DraftGhostMaskShape())
                    .overlay(
                        DraftGhostMaskShape()
                            .stroke(Color.white.opacity(0.05), lineWidth: 1)
                    )
                    .blur(radius: CGFloat(max(0, 4 - index)))
                    .opacity(shellOpacity * (0.16 + Double(index) * 0.12))
                    .offset(
                        x: CGFloat(index - 1) * 8 + CGFloat(orbitCompletion - 0.5) * 18,
                        y: CGFloat(index - 1) * -6
                    )
            }
        }
        #endif
    }

    @ViewBuilder
    private func coreObjectShell(size: CGSize) -> some View {
        #if canImport(UIKit)
        if let latest = thumbnails.last {
            Image(uiImage: latest.image)
                .resizable()
                .scaledToFill()
                .saturation(0.18)
                .contrast(1.18)
                .frame(width: size.width * 0.32, height: size.height * 0.58)
                .clipShape(DraftGhostMaskShape())
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18),
                            Color.white.opacity(0.02),
                            Color.black.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(DraftGhostMaskShape())
                )
                .overlay(
                    DraftGhostMaskShape()
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .opacity(0.52 + shellOpacity * 0.18)
                .offset(y: size.height * -0.02)

            Capsule()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.26),
                            Color.white.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size.width * 0.05, height: size.height * 0.40)
                .blur(radius: 1.2)
                .offset(x: size.width * 0.04, y: size.height * -0.08)
        }
        #endif
    }

    @ViewBuilder
    private func pointCloudLayer(size: CGSize) -> some View {
        ForEach(0..<pointCount, id: \.self) { index in
            let point = point(for: index)
            Circle()
                .fill(point.color)
                .frame(width: point.size, height: point.size)
                .position(x: point.x * size.width, y: point.y * size.height)
                .opacity(point.opacity)
        }

        ForEach(0..<max(18, acceptedFrames / 2), id: \.self) { index in
            let seed = Double((index * 19) % 137) / 137.0
            Circle()
                .fill(Color.white.opacity(0.12 + seed * 0.18))
                .frame(width: 1.0 + seed * 1.6, height: 1.0 + seed * 1.6)
                .position(
                    x: size.width * (0.22 + CGFloat(seed) * 0.56),
                    y: size.height * (0.74 + CGFloat(sin(Double(index) * 0.5)) * 0.05)
                )
        }

        ForEach(0..<max(10, acceptedFrames / 3), id: \.self) { index in
            let progress = Double(index) / Double(max(10, acceptedFrames / 3))
            Capsule()
                .fill(Color.white.opacity(0.04 + progress * 0.06))
                .frame(width: 2, height: 8 + progress * 10)
                .rotationEffect(.degrees(progress * 24 - 12))
                .position(
                    x: size.width * (0.40 + CGFloat(progress) * 0.20),
                    y: size.height * (0.26 + CGFloat(progress) * 0.34)
                )
        }
    }

    private func point(for index: Int) -> (x: CGFloat, y: CGFloat, size: CGFloat, opacity: Double, color: Color) {
        let seed = Double((index * 37) % 251) / 251.0
        let swirl = Double(index) / Double(max(pointCount - 1, 1))
        let radius = 0.07 + seed * 0.16 + orbitCompletion * 0.08
        let angle = swirl * .pi * 6.4 + orbitCompletion * .pi * 2.0

        let columnBias = 0.5 + cos(angle) * radius * (0.42 + min(Double(acceptedFrames) / 120.0, 0.35))
        let heightProfile = 0.84 - swirl * 0.58 - abs(sin(angle * 0.6)) * 0.06
        let noiseX = sin(Double(index) * 0.9) * 0.01
        let noiseY = cos(Double(index) * 0.73) * 0.012

        let x = min(max(columnBias + noiseX, 0.1), 0.9)
        let y = min(max(heightProfile + noiseY, 0.14), 0.93)

        let size = CGFloat(1.1 + (seed * 1.8))
        let opacity = 0.28 + seed * 0.55 + (isRecording ? 0.06 : 0)
        let color = Color(
            red: 0.94,
            green: 0.96 - seed * 0.15,
            blue: 0.90 - seed * 0.22
        )
        return (CGFloat(x), CGFloat(y), size, opacity, color)
    }
}

private struct DraftGhostMaskShape: Shape {
    func path(in rect: CGRect) -> Path {
        let width = rect.width
        let height = rect.height

        var path = Path()
        path.move(to: CGPoint(x: width * 0.35, y: height * 0.05))
        path.addQuadCurve(
            to: CGPoint(x: width * 0.65, y: height * 0.05),
            control: CGPoint(x: width * 0.5, y: height * -0.02)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.82, y: height * 0.36),
            control: CGPoint(x: width * 0.86, y: height * 0.13)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.74, y: height * 0.95),
            control: CGPoint(x: width * 0.88, y: height * 0.82)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.26, y: height * 0.95),
            control: CGPoint(x: width * 0.5, y: height * 1.02)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.18, y: height * 0.36),
            control: CGPoint(x: width * 0.12, y: height * 0.82)
        )
        path.addQuadCurve(
            to: CGPoint(x: width * 0.35, y: height * 0.05),
            control: CGPoint(x: width * 0.14, y: height * 0.13)
        )
        path.closeSubpath()
        return path
    }
}

#endif

#if canImport(SwiftUI) && canImport(UIKit) && canImport(QuickLook)

private struct ObjectModeV2ViewerAssetDescriptor: Decodable {
    let kind: String?
    let path: String
    let ready: Bool?

    enum CodingKeys: String, CodingKey {
        case kind
        case path
        case ready
    }
}

private struct ObjectModeV2ViewerManifestFile: Decodable {
    let defaultAsset: ObjectModeV2ViewerAssetDescriptor?
    let cleanedAsset: ObjectModeV2ViewerAssetDescriptor?
    let cleanupCompare: ObjectModeV2ViewerAssetDescriptor?
    let hqAsset: ObjectModeV2ViewerAssetDescriptor?
    let cameraPreset: ObjectModeV2ViewerCameraPreset?
    let productMode: String?
    let primaryProduct: String?
    let inspectionOnly: Bool?
    let hqPassed: Bool?
    let failedCards: [String]?

    enum CodingKeys: String, CodingKey {
        case defaultAsset = "default_asset"
        case cleanedAsset = "cleaned_asset"
        case cleanupCompare = "cleanup_compare"
        case hqAsset = "hq_asset"
        case cameraPreset = "camera_preset"
        case productMode = "product_mode"
        case primaryProduct = "primary_product"
        case inspectionOnly = "inspection_only"
        case hqPassed = "hq_passed"
        case failedCards = "failed_cards"
    }
}

private struct ObjectModeV2ViewerCameraPreset: Decodable {
    let pitchDegrees: Double?
    let yawDegrees: Double?
    let distanceScale: Double?
    let up: [Double]?

    enum CodingKeys: String, CodingKey {
        case pitchDegrees = "pitch_degrees"
        case yawDegrees = "yaw_degrees"
        case distanceScale = "distance_scale"
        case up
    }
}

private struct ObjectModeV2CleanupCompareSummary: Decodable {
    let rawPointCount: Int?
    let keptPointCount: Int?
    let removedPointCount: Int?
    let keptRatio: Double?
    let removedRatio: Double?

    enum CodingKeys: String, CodingKey {
        case rawPointCount = "raw_point_count"
        case keptPointCount = "kept_point_count"
        case removedPointCount = "removed_point_count"
        case keptRatio = "kept_ratio"
        case removedRatio = "removed_ratio"
    }
}

struct ObjectModeV2DefaultArtifactViewer: View {
    let url: URL
    let manifestURL: URL?
    let processingDurationLabel: String?
    let onDismiss: () -> Void

    @State private var displayMode: ViewerMode = .hq

    private enum ViewerMode: String {
        case hq = "HQ"
        case cleanup = "Cleanup"
    }

    init(
        url: URL,
        manifestURL: URL? = nil,
        processingDurationLabel: String? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.url = url
        self.manifestURL = manifestURL
        self.processingDurationLabel = processingDurationLabel
        self.onDismiss = onDismiss
    }

    private var isSplatArtifact: Bool {
        let suffix = activeArtifactURL.pathExtension.lowercased()
        return suffix == "ply" || suffix == "splat" || suffix == "spz"
    }

    private var isMeshArtifact: Bool {
        let suffix = activeArtifactURL.pathExtension.lowercased()
        return suffix == "glb" || suffix == "gltf"
    }

    private var parsedManifest: ObjectModeV2ViewerManifestFile? {
        guard let manifestURL,
              let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(ObjectModeV2ViewerManifestFile.self, from: data)
    }

    private var cleanupCompareSummary: ObjectModeV2CleanupCompareSummary? {
        guard let asset = parsedManifest?.cleanupCompare,
              let compareURL = resolvedURL(for: asset),
              let data = try? Data(contentsOf: compareURL) else { return nil }
        return try? JSONDecoder().decode(ObjectModeV2CleanupCompareSummary.self, from: data)
    }

    private var cleanedArtifactURL: URL? {
        guard let asset = parsedManifest?.cleanedAsset else { return nil }
        return resolvedURL(for: asset)
    }

    private var isInspectionOnlyCandidate: Bool {
        parsedManifest?.inspectionOnly ?? false
    }

    private var failedCardsSummaryText: String? {
        let labels = (parsedManifest?.failedCards ?? []).map(Self.hqFailedCardLabel)
        guard !labels.isEmpty else { return nil }
        return labels.joined(separator: "、")
    }

    private var availableModes: [ViewerMode] {
        var modes: [ViewerMode] = [.hq]
        if cleanedArtifactURL != nil {
            modes.append(.cleanup)
        }
        return modes
    }

    private var activeArtifactURL: URL {
        switch displayMode {
        case .cleanup:
            if let cleanedArtifactURL {
                return cleanedArtifactURL
            }
        case .hq:
            break
        }
        if let defaultAsset = parsedManifest?.defaultAsset,
           let resolvedDefaultURL = resolvedURL(for: defaultAsset) {
            return resolvedDefaultURL
        }
        return url
    }

    private var compareSummaryText: String? {
        guard let summary = cleanupCompareSummary else { return nil }
        if let removedRatio = summary.removedRatio {
            return String(format: "清理掉 %.0f%% 噪点", removedRatio * 100)
        }
        if let removedPointCount = summary.removedPointCount,
           let rawPointCount = summary.rawPointCount,
           rawPointCount > 0 {
            let ratio = (Double(removedPointCount) / Double(rawPointCount)) * 100
            return String(format: "清理掉 %.0f%% 噪点", ratio)
        }
        return nil
    }

    private func resolvedURL(for asset: ObjectModeV2ViewerAssetDescriptor) -> URL? {
        if asset.path.hasPrefix("/") {
            return URL(fileURLWithPath: asset.path)
        }
        if let manifestURL {
            return manifestURL.deletingLastPathComponent().appendingPathComponent(asset.path)
        }
        return nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if isSplatArtifact {
                SplatViewerRepresentable(artifactURL: activeArtifactURL)
                    .id(activeArtifactURL.path)
                    .ignoresSafeArea()
            } else if isMeshArtifact {
                ObjectModeV2GLBWebPreview(url: activeArtifactURL, cameraPreset: parsedManifest?.cameraPreset)
                    .id(activeArtifactURL.path)
                    .ignoresSafeArea()
            } else if QLPreviewController.canPreview(activeArtifactURL as NSURL) {
                ObjectModeV2QuickLookPreview(url: activeArtifactURL)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("\(displayMode.rawValue) 结果已下载")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                    Text(activeArtifactURL.lastPathComponent)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                    ShareLink(item: activeArtifactURL) {
                        Text("分享文件")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
            }

            HStack {
                if availableModes.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(availableModes, id: \.rawValue) { mode in
                            Button(action: {
                                displayMode = mode
                            }) {
                                Text(mode.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(displayMode == mode ? .black : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(displayMode == mode ? Color.white : Color.white.opacity(0.14))
                                    )
                            }
                        }
                    }
                }
                if isInspectionOnlyCandidate {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("未达 HQ")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.black)
                        Text(failedCardsSummaryText ?? "仅供质检")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black.opacity(0.72))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.96, green: 0.76, blue: 0.28))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                if let processingDurationLabel, !processingDurationLabel.isEmpty {
                    Label(processingDurationLabel, systemImage: "stopwatch")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.88))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.34))
                        .clipShape(Capsule())
                }
                if let compareSummaryText {
                    Text(compareSummaryText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.34))
                        .clipShape(Capsule())
                }
                Spacer()
                Button(action: onDismiss) {
                    Circle()
                        .fill(Color.black.opacity(0.38))
                        .overlay(
                            Image(systemName: "xmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(.white)
                        )
                        .frame(width: 38, height: 38)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }

    private static func hqFailedCardLabel(_ rawCard: String) -> String {
        switch rawCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "geometry_hq":
            return "几何"
        case "texture_hq":
            return "贴图"
        case "open_surface_hq":
            return "开放表面"
        case "hole_fill_hq":
            return "补洞克制"
        case "mesh_fidelity_hq":
            return "网格保真"
        default:
            return rawCard
        }
    }
}

#if canImport(WebKit)
private struct ObjectModeV2GLBWebPreview: UIViewRepresentable {
    let url: URL
    let cameraPreset: ObjectModeV2ViewerCameraPreset?

    func makeCoordinator() -> Coordinator {
        Coordinator(assetURL: url, cameraPreset: cameraPreset)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.setURLSchemeHandler(
            context.coordinator.schemeHandler,
            forURLScheme: ObjectModeV2MeshPreviewSchemeHandler.scheme
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        load(url: url, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedURL?.standardizedFileURL != url.standardizedFileURL else { return }
        load(url: url, in: webView, coordinator: context.coordinator)
    }

    private func load(url: URL, in webView: WKWebView, coordinator: Coordinator) {
        guard ObjectModeV2MeshPreviewSchemeHandler.hasRequiredResources else {
            coordinator.loadedURL = url
            webView.loadHTMLString(
                """
                <html><body style="margin:0;background:#000;color:#fff;display:flex;align-items:center;justify-content:center;font:600 15px -apple-system,sans-serif;">HQ viewer 资源缺失。</body></html>
                """,
                baseURL: nil
            )
            return
        }
        coordinator.loadedURL = url
        coordinator.schemeHandler.update(assetURL: url, cameraPreset: cameraPreset)
        webView.load(URLRequest(url: ObjectModeV2MeshPreviewSchemeHandler.viewerURL))
    }

    final class Coordinator {
        var loadedURL: URL?
        let schemeHandler: ObjectModeV2MeshPreviewSchemeHandler

        init(assetURL: URL, cameraPreset: ObjectModeV2ViewerCameraPreset?) {
            self.schemeHandler = ObjectModeV2MeshPreviewSchemeHandler(assetURL: assetURL, cameraPreset: cameraPreset)
        }
    }
}

private final class ObjectModeV2MeshPreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "aethermesh"
    static let host = "local"
    static let viewerURL = URL(string: "\(scheme)://\(host)/viewer.html")!

    static var hasRequiredResources: Bool {
        Bundle.main.url(forResource: "babylon", withExtension: "js") != nil &&
        Bundle.main.url(forResource: "babylonjs.loaders.min", withExtension: "js") != nil
    }

    private let lock = NSLock()
    private var assetURL: URL
    private var cameraPreset: ObjectModeV2ViewerCameraPreset?

    init(assetURL: URL, cameraPreset: ObjectModeV2ViewerCameraPreset?) {
        self.assetURL = assetURL
        self.cameraPreset = cameraPreset
    }

    func update(assetURL url: URL, cameraPreset: ObjectModeV2ViewerCameraPreset?) {
        lock.lock()
        assetURL = url
        self.cameraPreset = cameraPreset
        lock.unlock()
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(NSError(domain: "Aether3DMeshViewer", code: -1))
            return
        }
        do {
            let payload = try payload(for: url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": payload.mimeType,
                    "Cache-Control": "no-store",
                    "Access-Control-Allow-Origin": "*",
                    "Content-Length": "\(payload.data.count)",
                ]
            ) ?? URLResponse(
                url: url,
                mimeType: payload.mimeType,
                expectedContentLength: payload.data.count,
                textEncodingName: payload.textEncoding
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(payload.data)
            urlSchemeTask.didFinish()
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}

    private func payload(for url: URL) throws -> (data: Data, mimeType: String, textEncoding: String?) {
        switch url.path {
        case "/viewer.html":
            return (
                data: Data(viewerHTML().utf8),
                mimeType: "text/html",
                textEncoding: "utf-8"
            )
        case "/babylon.js":
            return try bundledResourcePayload(resource: "babylon", ext: "js", mimeType: "application/javascript")
        case "/babylonjs.loaders.min.js":
            return try bundledResourcePayload(resource: "babylonjs.loaders.min", ext: "js", mimeType: "application/javascript")
        default:
            if url.path.hasPrefix("/files/") {
                return try assetPayload(path: url.path)
            }
            throw NSError(domain: "Aether3DMeshViewer", code: 404)
        }
    }

    private func bundledResourcePayload(resource: String, ext: String, mimeType: String) throws -> (data: Data, mimeType: String, textEncoding: String?) {
        guard let fileURL = Bundle.main.url(forResource: resource, withExtension: ext) else {
            throw NSError(domain: "Aether3DMeshViewer", code: 404)
        }
        return (try Data(contentsOf: fileURL), mimeType, "utf-8")
    }

    private func assetPayload(path: String) throws -> (data: Data, mimeType: String, textEncoding: String?) {
        let requestedName = String(path.dropFirst("/files/".count)).removingPercentEncoding ?? ""
        let currentAssetURL = lockedAssetURL()
        let assetDirectory = currentAssetURL.deletingLastPathComponent()
        let resolvedURL = assetDirectory.appendingPathComponent(requestedName)
        let standardizedDirectory = assetDirectory.standardizedFileURL.path
        let standardizedResolved = resolvedURL.standardizedFileURL.path
        guard standardizedResolved.hasPrefix(standardizedDirectory) else {
            throw NSError(domain: "Aether3DMeshViewer", code: 403)
        }
        guard FileManager.default.fileExists(atPath: standardizedResolved) else {
            throw NSError(domain: "Aether3DMeshViewer", code: 404)
        }
        return (
            data: try Data(contentsOf: resolvedURL),
            mimeType: mimeType(for: resolvedURL.pathExtension),
            textEncoding: nil
        )
    }

    private func lockedAssetURL() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return assetURL
    }

    private func lockedCameraPreset() -> ObjectModeV2ViewerCameraPreset? {
        lock.lock()
        defer { lock.unlock() }
        return cameraPreset
    }

    private func mimeType(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "glb":
            return "model/gltf-binary"
        case "gltf":
            return "model/gltf+json"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "bin":
            return "application/octet-stream"
        default:
            return "application/octet-stream"
        }
    }

    private func encodeCameraPresetJSON(_ preset: ObjectModeV2ViewerCameraPreset?) -> String {
        guard let preset else {
            return "null"
        }
        var payload: [String: Any] = [:]
        if let pitch = preset.pitchDegrees {
            payload["pitchDegrees"] = pitch
        }
        if let yaw = preset.yawDegrees {
            payload["yawDegrees"] = yaw
        }
        if let distanceScale = preset.distanceScale {
            payload["distanceScale"] = distanceScale
        }
        if let up = preset.up {
            payload["up"] = up
        }
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return string
    }

    private func viewerHTML() -> String {
        let assetName = lockedAssetURL().lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? lockedAssetURL().lastPathComponent
        let assetURL = "\(Self.scheme)://\(Self.host)/files/\(assetName)"
        let cameraPresetJSON = encodeCameraPresetJSON(lockedCameraPreset())
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no">
          <script src="\(Self.scheme)://\(Self.host)/babylon.js"></script>
          <script src="\(Self.scheme)://\(Self.host)/babylonjs.loaders.min.js"></script>
          <style>
            html, body {
              margin: 0;
              width: 100%;
              height: 100%;
              overflow: hidden;
              background: #000;
            }
            canvas {
              width: 100%;
              height: 100%;
              background: radial-gradient(circle at top, #171717 0%, #050505 55%, #000000 100%);
              touch-action: none;
            }
            .fallback {
              position: absolute;
              inset: 0;
              display: flex;
              flex-direction: column;
              align-items: center;
              justify-content: center;
              color: rgba(255,255,255,0.72);
              font: 600 15px -apple-system, BlinkMacSystemFont, sans-serif;
              letter-spacing: 0.01em;
              pointer-events: none;
              gap: 10px;
              text-align: center;
              padding: 0 24px;
            }
            .fallback-percent {
              font-size: 28px;
              font-weight: 700;
              color: rgba(255,255,255,0.94);
              letter-spacing: -0.03em;
            }
            .fallback-label {
              line-height: 1.35;
              max-width: min(320px, 80vw);
              word-break: break-word;
            }
            .fallback-bar {
              width: min(240px, 58vw);
              height: 5px;
              border-radius: 999px;
              background: rgba(255,255,255,0.14);
              overflow: hidden;
            }
            .fallback-bar-fill {
              width: 0%;
              height: 100%;
              border-radius: inherit;
              background: linear-gradient(90deg, rgba(255,255,255,0.92), rgba(255,255,255,0.68));
              transition: width 160ms ease;
            }
            .gravity-badge {
              position: absolute;
              left: 16px;
              bottom: 18px;
              display: inline-flex;
              align-items: center;
              gap: 8px;
              padding: 10px 12px;
              border-radius: 999px;
              background: rgba(6, 6, 6, 0.52);
              border: 1px solid rgba(255,255,255,0.1);
              font: 700 11px -apple-system, BlinkMacSystemFont, sans-serif;
              color: rgba(255,255,255,0.82);
              letter-spacing: 0.01em;
              pointer-events: none;
              backdrop-filter: blur(12px);
            }
            .gravity-arrow {
              font-size: 14px;
              color: rgba(120,255,145,0.96);
            }
          </style>
        </head>
        <body>
          <canvas id="mesh-canvas"></canvas>
          <div class="fallback">
            <div class="fallback-percent">0%</div>
            <div class="fallback-label">正在打开 HQ 成品...</div>
            <div class="fallback-bar"><div class="fallback-bar-fill"></div></div>
          </div>
          <div class="gravity-badge">
            <span class="gravity-arrow">↑</span>
            <span>Up</span>
          </div>
          <script>
            const assetURL = "\(assetURL)";
            const cameraPreset = \(cameraPresetJSON);
            const canvas = document.getElementById('mesh-canvas');
            const fallback = document.querySelector('.fallback');
            const percentLabel = document.querySelector('.fallback-percent');
            const textLabel = document.querySelector('.fallback-label');
            const barFill = document.querySelector('.fallback-bar-fill');
            let currentProgress = 0;
            let targetProgress = 0;
            let viewerReady = false;
            let stagePulse = null;
            let stallTimeout = null;
            let firstFrameShown = false;
            const setProgress = (value) => {
              const clamped = Math.max(0, Math.min(100, value));
              currentProgress = clamped;
              targetProgress = clamped;
              if (percentLabel) {
                percentLabel.textContent = `${clamped}%`;
              }
              if (barFill) {
                barFill.style.width = `${clamped}%`;
              }
            };
            const animateProgress = (value) => {
              targetProgress = Math.max(currentProgress, Math.min(99, value));
            };
            const show = (text) => {
              if (fallback) {
                fallback.style.display = 'flex';
              }
              if (textLabel) {
                textLabel.textContent = text;
              }
            };
            const hide = () => {
              if (fallback) {
                fallback.style.display = 'none';
              }
            };
            const fail = (message) => {
              window.clearTimeout(stallTimeout);
              if (stagePulse) {
                window.clearInterval(stagePulse);
                stagePulse = null;
              }
              setProgress(100);
              show(message);
            };
            const startPulse = (cap) => {
              if (stagePulse) {
                window.clearInterval(stagePulse);
              }
              stagePulse = window.setInterval(() => {
                if (viewerReady) {
                  return;
                }
                if (targetProgress < cap) {
                  targetProgress = Math.min(cap, targetProgress + 1);
                }
              }, 450);
            };
            const shortError = (error) => {
              const raw = String(error && (error.message || error) || '未知错误');
              return raw.length > 120 ? `${raw.slice(0, 117)}...` : raw;
            };
            window.addEventListener('error', (event) => {
              console.error(event.error || event.message);
            });
            const presetYaw = (cameraPreset && typeof cameraPreset.yawDegrees === 'number') ? (cameraPreset.yawDegrees * Math.PI / 180.0) : (-Math.PI / 2.1);
            const presetPitch = (cameraPreset && typeof cameraPreset.pitchDegrees === 'number') ? (Math.PI / 2 - (cameraPreset.pitchDegrees * Math.PI / 180.0)) : (Math.PI / 2.5);
            const presetDistanceScale = (cameraPreset && typeof cameraPreset.distanceScale === 'number') ? Math.max(0.75, cameraPreset.distanceScale) : 2.4;
            const presetUp = (cameraPreset && Array.isArray(cameraPreset.up) && cameraPreset.up.length === 3)
              ? new BABYLON.Vector3(cameraPreset.up[0], cameraPreset.up[1], cameraPreset.up[2]).normalize()
              : new BABYLON.Vector3(0, 1, 0);
            const fitCameraToScene = (camera, scene) => {
              const meshes = scene.meshes.filter(mesh => mesh && mesh.getTotalVertices && mesh.getTotalVertices() > 0);
              if (!meshes.length) {
                return;
              }
              let min = new BABYLON.Vector3(Number.POSITIVE_INFINITY, Number.POSITIVE_INFINITY, Number.POSITIVE_INFINITY);
              let max = new BABYLON.Vector3(Number.NEGATIVE_INFINITY, Number.NEGATIVE_INFINITY, Number.NEGATIVE_INFINITY);
              for (const mesh of meshes) {
                mesh.computeWorldMatrix(true);
                const bounds = mesh.getHierarchyBoundingVectors(true);
                min = BABYLON.Vector3.Minimize(min, bounds.min);
                max = BABYLON.Vector3.Maximize(max, bounds.max);
              }
              const center = min.add(max).scale(0.5);
              const extent = max.subtract(min);
              const radius = Math.max(extent.x, extent.y, extent.z) * presetDistanceScale || 1.0;
              camera.setTarget(center);
              camera.alpha = presetYaw;
              camera.beta = presetPitch;
              camera.radius = radius;
              camera.lowerRadiusLimit = radius * 0.18;
              camera.upperRadiusLimit = radius * 8.0;
              camera.minZ = Math.max(radius / 500, 0.01);
              camera.maxZ = Math.max(radius * 40, 200);
            };
            const configureTouchViewerControls = (canvas, camera) => {
              const activePointers = new Map();
              let singleGesture = null;
              let multiGesture = null;
              const clamp = (value, min, max) => Math.min(max, Math.max(min, value));
              const normalizeAngleDelta = (angle) => {
                while (angle > Math.PI) angle -= Math.PI * 2;
                while (angle < -Math.PI) angle += Math.PI * 2;
                return angle;
              };
              const forwardVector = () => {
                const forward = camera.target.subtract(camera.position);
                if (forward.lengthSquared() < 1e-8) {
                  return new BABYLON.Vector3(0, 0, -1);
                }
                return forward.normalize();
              };
              const orbitRight = () => {
                let right = BABYLON.Vector3.Cross(forwardVector(), camera.upVector);
                if (right.lengthSquared() < 1e-8) {
                  right = new BABYLON.Vector3(1, 0, 0);
                }
                return right.normalize();
              };
              const orbitUp = () => {
                let up = BABYLON.Vector3.Cross(orbitRight(), forwardVector());
                if (up.lengthSquared() < 1e-8) {
                  up = new BABYLON.Vector3(0, 1, 0);
                }
                return up.normalize();
              };
              const panTarget = (deltaX, deltaY) => {
                const panScale = Math.max(camera.radius, 0.5) * 0.0016;
                const right = orbitRight();
                const up = orbitUp();
                camera.target = camera.target
                  .subtract(right.scale(deltaX * panScale))
                  .add(up.scale(deltaY * panScale));
              };
              const updateSingleGesture = (pointer) => {
                if (!singleGesture) {
                  return;
                }
                const deltaX = pointer.x - singleGesture.lastX;
                const deltaY = pointer.y - singleGesture.lastY;
                singleGesture.lastX = pointer.x;
                singleGesture.lastY = pointer.y;
                camera.alpha += deltaX * 0.0085;
                camera.beta = clamp(camera.beta - deltaY * 0.0085, 0.045, Math.PI - 0.045);
              };
              const measureMultiPointer = () => {
                const pointers = Array.from(activePointers.values()).slice(0, 2);
                const first = pointers[0];
                const second = pointers[1];
                const center = {
                  x: (first.x + second.x) * 0.5,
                  y: (first.y + second.y) * 0.5,
                };
                const dx = second.x - first.x;
                const dy = second.y - first.y;
                return {
                  center,
                  distance: Math.max(Math.hypot(dx, dy), 1),
                  angle: Math.atan2(dy, dx),
                };
              };
              const beginMultiGesture = () => {
                const measurement = measureMultiPointer();
                multiGesture = {
                  lastCenter: measurement.center,
                  lastDistance: measurement.distance,
                  lastAngle: measurement.angle,
                };
                singleGesture = null;
              };
              const updateMultiGesture = () => {
                if (activePointers.size < 2) {
                  multiGesture = null;
                  return;
                }
                if (!multiGesture) {
                  beginMultiGesture();
                  return;
                }
                const measurement = measureMultiPointer();
                const centerDeltaX = measurement.center.x - multiGesture.lastCenter.x;
                const centerDeltaY = measurement.center.y - multiGesture.lastCenter.y;
                const zoomRatio = measurement.distance / Math.max(multiGesture.lastDistance, 1);
                const twistDelta = normalizeAngleDelta(measurement.angle - multiGesture.lastAngle);

                if (Math.abs(centerDeltaX) > 0.1 || Math.abs(centerDeltaY) > 0.1) {
                  panTarget(centerDeltaX, centerDeltaY);
                }
                if (Math.abs(zoomRatio - 1.0) > 0.001) {
                  camera.radius = clamp(
                    camera.radius / zoomRatio,
                    camera.lowerRadiusLimit,
                    camera.upperRadiusLimit
                  );
                }
                if (Math.abs(twistDelta) > 0.0005) {
                  camera.alpha += twistDelta;
                }

                multiGesture.lastCenter = measurement.center;
                multiGesture.lastDistance = measurement.distance;
                multiGesture.lastAngle = measurement.angle;
              };

              canvas.addEventListener('pointerdown', (event) => {
                canvas.setPointerCapture(event.pointerId);
                activePointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
                if (activePointers.size === 1) {
                  singleGesture = { lastX: event.clientX, lastY: event.clientY };
                  multiGesture = null;
                } else if (activePointers.size >= 2) {
                  beginMultiGesture();
                }
              });

              canvas.addEventListener('pointermove', (event) => {
                if (!activePointers.has(event.pointerId)) {
                  return;
                }
                activePointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
                if (activePointers.size >= 2) {
                  updateMultiGesture();
                } else if (activePointers.size === 1) {
                  updateSingleGesture({ x: event.clientX, y: event.clientY });
                }
              });

              const endPointer = (pointerId) => {
                activePointers.delete(pointerId);
                if (activePointers.size === 1) {
                  const remaining = Array.from(activePointers.values())[0];
                  singleGesture = { lastX: remaining.x, lastY: remaining.y };
                  multiGesture = null;
                } else if (activePointers.size === 0) {
                  singleGesture = null;
                  multiGesture = null;
                }
              };
              canvas.addEventListener('pointerup', (event) => endPointer(event.pointerId));
              canvas.addEventListener('pointercancel', (event) => endPointer(event.pointerId));
              canvas.addEventListener('pointerout', (event) => endPointer(event.pointerId));
              canvas.addEventListener('wheel', (event) => {
                event.preventDefault();
                const zoomScale = event.deltaY > 0 ? 1.08 : 0.92;
                camera.radius = clamp(
                  camera.radius * zoomScale,
                  camera.lowerRadiusLimit,
                  camera.upperRadiusLimit
                );
              }, { passive: false });
            };
              const finalizeScene = (scene) => {
                for (const material of scene.materials || []) {
                  if (material) {
                    // 强制 non-metallic —— glTF 里 metallicFactor 未写时默认 1.0(金属),
                    // 导致平视视角反射环境光变银灰。这里按产品语义(真实物体,非金属)兜底。
                    if ('metallic' in material) {
                      try { material.metallic = 0.0; } catch (_) {}
                    }
                    if ('metallicF0Factor' in material) {
                      try { material.metallicF0Factor = 0.0; } catch (_) {}
                    }
                    if ('roughness' in material && (material.roughness == null || material.roughness < 0.6)) {
                      try { material.roughness = 0.85; } catch (_) {}
                    }
                    const tex = material.albedoTexture || material.diffuseTexture || material.baseTexture;
                    if (tex && 'anisotropicFilteringLevel' in tex) {
                      try { tex.anisotropicFilteringLevel = 16; } catch (_) {}
                    }
                  }
                  if (material && typeof material.freeze === 'function') {
                    try { material.freeze(); } catch (_) {}
                  }
              }
              for (const mesh of scene.meshes || []) {
                if (mesh && typeof mesh.freezeWorldMatrix === 'function') {
                  try { mesh.freezeWorldMatrix(); } catch (_) {}
                }
              }
              try { scene.freezeActiveMeshes(true); } catch (_) {}
            };
            const tickProgress = () => {
              if (currentProgress >= targetProgress) {
                window.requestAnimationFrame(tickProgress);
                return;
              }
              currentProgress = Math.min(targetProgress, currentProgress + Math.max(1, Math.ceil((targetProgress - currentProgress) * 0.12)));
              if (percentLabel) {
                percentLabel.textContent = `${currentProgress}%`;
              }
              if (barFill) {
                barFill.style.width = `${currentProgress}%`;
              }
              window.requestAnimationFrame(tickProgress);
            };
            tickProgress();
            if (canvas && window.BABYLON) {
              setProgress(0);
              show('正在准备 mesh 查看器...');
              stallTimeout = window.setTimeout(() => {
                if (!viewerReady) {
                  fail('HQ 成品打开超时，请稍后重试。');
                }
              }, 45000);
              const engine = new BABYLON.Engine(canvas, true, {
                preserveDrawingBuffer: false,
                stencil: false,
                antialias: true,
                powerPreference: 'high-performance',
              });
              engine.setHardwareScalingLevel(1.0);
              const scene = new BABYLON.Scene(engine);
              scene.clearColor = new BABYLON.Color4(0, 0, 0, 1);
              scene.skipPointerMovePicking = true;
              scene.imageProcessingConfiguration.contrast = 1.15;
              scene.imageProcessingConfiguration.exposure = 1.1;
              const camera = new BABYLON.ArcRotateCamera('camera', -Math.PI / 2, Math.PI / 2.4, 4, BABYLON.Vector3.Zero(), scene);
              camera.upVector = presetUp;
              camera.lowerBetaLimit = 0.045;
              camera.upperBetaLimit = Math.PI - 0.045;
              camera.inertia = 0.42;
              camera.panningInertia = 0.55;
              camera.allowUpsideDown = false;
              camera.useAutoRotationBehavior = false;
              camera.inputs.clear();
              configureTouchViewerControls(canvas, camera);
              const hemi = new BABYLON.HemisphericLight('hemi', new BABYLON.Vector3(0.1, 1, 0.15), scene);
              hemi.intensity = 1.8;
              const fill = new BABYLON.DirectionalLight('fill', new BABYLON.Vector3(-0.35, -1, 0.2), scene);
              fill.intensity = 0.9;
              const rim = new BABYLON.DirectionalLight('rim', new BABYLON.Vector3(0.45, -0.4, -0.25), scene);
              rim.intensity = 0.45;
              engine.runRenderLoop(() => {
                scene.render();
                if (viewerReady && !firstFrameShown) {
                  firstFrameShown = true;
                  setProgress(100);
                  hide();
                }
              });
              window.addEventListener('resize', () => engine.resize());
              const load = async () => {
                try {
                  animateProgress(10);
                  show('正在读取 HQ 文件...');
                  startPulse(24);
                  const response = await fetch(assetURL, { cache: 'no-store' });
                  if (!response.ok) {
                    throw new Error(`HTTP ${response.status}`);
                  }
                  const buffer = await response.arrayBuffer();
                  animateProgress(34);
                  show('正在解析 glTF / GLB 结构...');
                  startPulse(62);
                  const blob = new Blob([buffer], { type: 'model/gltf-binary' });
                  const blobURL = URL.createObjectURL(blob);
                  try {
                    await BABYLON.SceneLoader.AppendAsync('', blobURL, scene, undefined, '.glb');
                  } finally {
                    URL.revokeObjectURL(blobURL);
                  }
                  animateProgress(76);
                  show('正在拟合默认视角...');
                  fitCameraToScene(camera, scene);
                  animateProgress(90);
                  show('正在完成 mesh 初始化...');
                  finalizeScene(scene);
                  viewerReady = true;
                  window.clearTimeout(stallTimeout);
                  if (stagePulse) {
                    window.clearInterval(stagePulse);
                    stagePulse = null;
                  }
                } catch (error) {
                  console.error(error);
                  fail(`HQ 成品打开失败：${shortError(error)}`);
                }
              };
              load();
            } else {
              fail('HQ viewer 初始化失败。');
            }
          </script>
        </body>
        </html>
        """
    }
}
#endif

private struct ObjectModeV2QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {}

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}

struct ObjectModeV2ProcessingStat: Identifiable {
    let id = UUID()
    let title: String
    let value: String
}

struct ObjectModeV2ProcessingSnapshot {
    let heroBadge: String
    let heroTitle: String
    let heroSubtitle: String
    #if canImport(UIKit)
    let heroImage: UIImage?
    #endif
    let canOpenArtifact: Bool
    let isFailed: Bool
    let isInspectionOnlyCandidate: Bool
    let modeValue: String
    let lockValue: String
    let lockAccent: Color
    let stageCards: [ObjectModeV2StageCard]
    let stats: [ObjectModeV2ProcessingStat]
    let footerText: String
    let failedCardsSummary: String?
}

struct ObjectModeV2ProcessingSurface: View {
    let snapshot: ObjectModeV2ProcessingSnapshot
    let onOpen: (() -> Void)?
    let onClose: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.82),
                    Color.black.opacity(0.74),
                    Color.black.opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                processingHero

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.heroBadge)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.55))
                            Text(snapshot.heroTitle)
                                .font(.system(size: 22, weight: .bold))
                                .foregroundColor(.white)
                            Text(snapshot.heroSubtitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.72))
                        }
                        Spacer()
                        if let onOpen {
                            Button(action: onOpen) {
                                Text("Open")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                            }
                        } else if snapshot.isFailed {
                            Text(snapshot.isInspectionOnlyCandidate ? "质检" : "失败")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.black)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(
                                    snapshot.isInspectionOnlyCandidate
                                        ? Color(red: 0.96, green: 0.76, blue: 0.28)
                                        : Color(red: 1.0, green: 0.58, blue: 0.58)
                                )
                                .clipShape(Capsule())
                        } else {
                            ProgressView()
                                .tint(.white)
                        }
                    }

                    if snapshot.isInspectionOnlyCandidate {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 11, weight: .bold))
                            Text(snapshot.failedCardsSummary.map { "未通过：\($0)" } ?? "未达 HQ，仅供质检")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(red: 0.96, green: 0.76, blue: 0.28))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }

                    processingContextCard
                    stageProgressBand

                    HStack(spacing: 10) {
                        ForEach(snapshot.stats) { stat in
                            statChip(title: stat.title, value: stat.value)
                        }
                    }

                    ForEach(snapshot.stageCards) { card in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(stageColor(card.state))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(card.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                                Text(stageSubtitle(for: card))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(.white.opacity(0.66))
                            }
                            Spacer()
                            stageTrailingLabel(for: card.state)
                        }
                        .padding(.vertical, 4)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.75))
                        Text(snapshot.footerText)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                    }
                    .padding(.top, 2)
                }
                .padding(18)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.horizontal, 24)
            }

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Circle()
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                Image(systemName: "xmark")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundColor(.white.opacity(0.9))
                            )
                            .frame(width: 38, height: 38)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Spacer()
            }
        }
    }

    private var processingHero: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 250, height: 250)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )

            #if canImport(UIKit)
            if let image = snapshot.heroImage {
                ZStack(alignment: .bottom) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .saturation(0.12)
                        .frame(width: 210, height: 210)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .opacity(0.82)

                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color.black.opacity(0.18),
                            Color.black.opacity(0.42)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: 210, height: 210)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

                    Text(snapshot.canOpenArtifact ? "HQ 成品已就绪" : "正在生成 HQ 成品")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.44))
                        .clipShape(Capsule())
                        .padding(.bottom, 14)
                }
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 210, height: 210)
                    .overlay(
                        Image(systemName: snapshot.isFailed ? "xmark.octagon.fill" : "square.stack.3d.up.fill")
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundColor(snapshot.isFailed ? Color.red.opacity(0.8) : Color.white.opacity(0.65))
                    )
            }
            #else
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.05))
                .frame(width: 210, height: 210)
            #endif
        }
    }

    private var processingContextCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CAPTURE CONTEXT")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.48))

            HStack(spacing: 10) {
                processingContextChip(
                    title: "Mode",
                    value: snapshot.modeValue,
                    accent: .white
                )
                processingContextChip(
                    title: "Lock",
                    value: snapshot.lockValue,
                    accent: snapshot.lockAccent
                )
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func processingContextChip(title: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white.opacity(0.44))
            HStack(spacing: 6) {
                Circle()
                    .fill(accent)
                    .frame(width: 7, height: 7)
                Text(value)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var stageProgressBand: some View {
        HStack(spacing: 10) {
            ForEach(snapshot.stageCards) { card in
                VStack(alignment: .leading, spacing: 6) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)

                    Capsule()
                        .fill(stageColor(card.state))
                        .frame(height: 6)

                    Text(stageBandDetail(for: card))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.58))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
    }

    private func statChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(.white.opacity(0.46))
            Text(value)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stageColor(_ state: ObjectModeV2StageUIState) -> Color {
        switch state {
        case .idle:
            return Color.white.opacity(0.35)
        case .processing:
            return Color(red: 0.95, green: 0.79, blue: 0.12)
        case .ready:
            return Color(red: 0.54, green: 0.96, blue: 0.62)
        case .failed:
            return Color(red: 1.0, green: 0.46, blue: 0.46)
        }
    }

    private func stageSubtitle(for card: ObjectModeV2StageCard) -> String {
        switch card.state {
        case .idle:
            return card.subtitle
        case .processing:
            return "正在生成 \(card.title) 资产"
        case .ready:
            return "\(card.title) 已可用于查看"
        case .failed(let reason):
            return reason ?? "\(card.title) 生成失败"
        }
    }

    @ViewBuilder
    private func stageTrailingLabel(for state: ObjectModeV2StageUIState) -> some View {
        switch state {
        case .idle:
            Text("等待中")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
        case .processing(let progress):
            Text(progress.map { "\((Int($0 * 100)))%" } ?? "处理中")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.95, green: 0.79, blue: 0.12))
                .clipShape(Capsule())
        case .ready:
            Text("已完成")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 0.54, green: 0.96, blue: 0.62))
                .clipShape(Capsule())
        case .failed:
            Text("失败")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(red: 1.0, green: 0.58, blue: 0.58))
                .clipShape(Capsule())
        }
    }

    private func stageBandDetail(for card: ObjectModeV2StageCard) -> String {
        switch card.state {
        case .idle:
            return "等待"
        case .processing(let progress):
            if let progress {
                return "\(Int(progress * 100))%"
            }
            return "处理中"
        case .ready:
            return "完成"
        case .failed:
            return "失败"
        }
    }
}

#endif
