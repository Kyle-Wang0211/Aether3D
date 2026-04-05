//
// SplatViewerView.swift
// Aether3D
//
// Post-scan 3D Gaussian Splatting viewer.
// Pure black background with orbit camera (pan/pinch gestures).
// Wraps GaussianSplatViewController via UIViewControllerRepresentable.
// Apple-platform only (SwiftUI + Metal + UIKit)
//

import Foundation

#if canImport(SwiftUI) && canImport(UIKit) && canImport(Metal)
import SwiftUI
#if canImport(simd)
import simd
#endif

/// Post-scan 3D viewer: renders Gaussian splats on a black background.
///
/// Features:
///   - Orbit camera: pan to rotate, pinch to zoom
///   - Loads exported PLY from ScanRecord.artifactPath
///   - HUD: close button, share button, loading indicator, scan info
///
/// Uses GaussianSplatViewController internally (MTKView + Metal rendering).
struct SplatViewerView: View {
    let record: ScanRecord
    var scanViewModel: ScanViewModel? = nil
    var homeViewModel: HomeViewModel? = nil
    var onReturnHome: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var currentRecord: ScanRecord
    @State private var refreshTask: Task<Void, Never>?

    init(
        record: ScanRecord,
        scanViewModel: ScanViewModel? = nil,
        homeViewModel: HomeViewModel? = nil,
        onReturnHome: (() -> Void)? = nil
    ) {
        self.record = record
        self.scanViewModel = scanViewModel
        self.homeViewModel = homeViewModel
        self.onReturnHome = onReturnHome
        _currentRecord = State(initialValue: record)
    }

    var body: some View {
        let artifactURL = resolvedArtifactURL()

        ZStack {
            // Pure black background
            Color.black.ignoresSafeArea()

            // Metal 3DGS rendering view (when trained model exists)
            if let url = artifactURL {
                let _ = NSLog("[Aether3D] SplatViewerView: loading PLY from %@", url.path)
                SplatViewerRepresentable(
                    artifactURL: url,
                    captureGravityUpX: currentRecord.captureGravityUpX,
                    captureGravityUpY: currentRecord.captureGravityUpY,
                    captureGravityUpZ: currentRecord.captureGravityUpZ,
                    captureGravitySource: currentRecord.captureGravitySource,
                    captureGravityConfidence: currentRecord.captureGravityConfidence,
                    onLoaded: { isLoading = false }
                )
                .ignoresSafeArea()
            } else {
                waitingOrFallbackView
                    .onAppear { isLoading = false }
            }

            // HUD overlay
            VStack {
                // Top bar: close + share
                HStack {
                    Button(action: { closeExperience() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel("关闭")
                    .padding(.leading, 16)

                    Spacer()

                    if let url = artifactURL {
                        ShareLink(
                            item: url,
                            subject: Text(currentRecord.name),
                            message: Text("Aether3D 扫描")
                        ) {
                            Image(systemName: "square.and.arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white)
                                .shadow(radius: 2)
                        }
                        .padding(.trailing, 16)
                    }
                }
                .padding(.top, 8)

                Spacer()

                // Loading indicator (centered, only when loading 3DGS model)
                if isLoading, artifactURL != nil {
                    VStack(spacing: 8) {
                        ProgressView()
                            .tint(.white)
                        Text("渲染中...")
                            .font(.system(size: 14))
                            .foregroundColor(.gray)
                    }
                }

                Spacer()

                // Bottom bar: scan info
                HStack {
                    Text(currentRecord.name)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(formatDuration(currentRecord.durationSeconds))
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .navigationBarHidden(true)
        .statusBarHidden(true)
        .onAppear {
            startRefreshLoopIfNeeded()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    @ViewBuilder
    private var waitingOrFallbackView: some View {
        if currentRecord.status == .completed && hasUnreadyArtifactReference {
            terminalStateView(
                title: "结果文件暂不可用",
                detail: currentRecord.detailMessage ?? "结果路径已经生成，但文件还没真正落盘或仍是空文件。请稍等片刻自动刷新；如果一直这样，请回主页重试。"
            )
        } else {
            switch currentRecord.status {
            case .failed:
                terminalStateView(
                    title: currentRecord.workflowModeTitle,
                    detail: currentRecord.detailMessage ?? "这次处理没有拿到可用结果，请返回主页后再试一次。"
                )
            case .cancelled:
                terminalStateView(
                    title: currentRecord.workflowModeTitle,
                    detail: currentRecord.detailMessage ?? "这次处理已经停止。原始视频仍保留在手机里，可稍后重新发起。"
                )
            default:
                waitingStageView
            }
        }
    }

    private var hasUnreadyArtifactReference: Bool {
        currentRecord.artifactPath != nil && resolvedArtifactURL() == nil
    }

    private static func validatedArtifactURL(for record: ScanRecord) -> URL? {
        guard let relativePath = record.artifactPath else { return nil }
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        let url = documents
            .appendingPathComponent("Aether3D")
            .appendingPathComponent(relativePath)
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            guard fileSize > 0 else { return nil }
        } catch {
            return nil
        }
        return url
    }

    private func resolvedArtifactURL() -> URL? {
        Self.validatedArtifactURL(for: currentRecord)
    }

    private var waitingStageView: some View {
        VStack(spacing: 18) {
            Image(systemName: currentRecord.resolvedProcessingBackend == .localSubjectFirst ? "viewfinder.circle.fill" : "cube.transparent")
                .font(.system(size: 56))
                .foregroundColor(.white.opacity(0.30))

            VStack(spacing: 8) {
                Text(currentRecord.waitingHeadlineText)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                if let detail = currentRecord.workflowModeSummaryText ?? currentRecord.presentableDetailMessage {
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.62))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 340)

            VStack(spacing: 12) {
                if let percentText = currentRecord.workflowOverallPercentText {
                    Text(percentText)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }

                ProgressView(value: currentRecord.workflowOverallFraction)
                    .tint(.cyan)

                Text(currentRecord.workflowStatusSummaryLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.52))
                    .multilineTextAlignment(.center)

                if let eta = currentRecord.estimatedRemainingSummaryText {
                    metricCapsule(text: "预计剩余 \(eta)")
                }
            }
            .padding(18)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )

            workflowStepsCard
        }
        .padding(.horizontal, 20)
    }

    private func startRefreshLoopIfNeeded() {
        refreshTask?.cancel()
        refreshTask = nil

        let shouldPollForArtifact = currentRecord.artifactPath != nil && resolvedArtifactURL() == nil
        guard shouldPollForArtifact || currentRecord.isProcessing else {
            return
        }

        let recordID = currentRecord.id
        refreshTask = Task {
            let store = ScanRecordStore()
            let invalidArtifactDeadline = Date().addingTimeInterval(20)
            while !Task.isCancelled {
                guard let refreshed = store.record(id: recordID) else { break }
                await MainActor.run {
                    currentRecord = refreshed
                }
                let artifactReady = Self.validatedArtifactURL(for: refreshed) != nil
                let waitingOnArtifact = refreshed.artifactPath != nil
                if artifactReady {
                    break
                }
                if !refreshed.isProcessing && !waitingOnArtifact {
                    break
                }
                if !refreshed.isProcessing &&
                    waitingOnArtifact &&
                    Date() >= invalidArtifactDeadline {
                    break
                }
                try? await Task.sleep(nanoseconds: 900_000_000)
            }
        }
    }

    private func closeExperience() {
        if let onReturnHome {
            onReturnHome()
        } else {
            dismiss()
        }
    }

    private var workflowStepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(currentRecord.resolvedProcessingBackend == .localSubjectFirst ? "本地处理流程" : "远端处理流程")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                if let backend = currentRecord.galleryProcessingBackendLabelText {
                    metricCapsule(text: backend)
                }
            }

            ForEach(currentRecord.workflowStepProgresses) { step in
                workflowStepRow(step)
            }
        }
        .padding(18)
        .frame(maxWidth: 340, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.black.opacity(0.56))
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func workflowStepRow(_ step: WorkflowStepProgress) -> some View {
        let tint: Color
        let symbol: String
        switch step.state {
        case .pending:
            tint = .white.opacity(0.26)
            symbol = "circle"
        case .active:
            tint = .cyan
            symbol = "dot.scope"
        case .completed:
            tint = .green
            symbol = "checkmark.circle.fill"
        }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(tint)

                Text(step.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)

                Spacer()

                Text(step.progressText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            ProgressView(value: step.progressFraction)
                .tint(tint)

            if let detail = step.detailText, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.48))
            }
        }
    }

    private func metricCapsule(text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
            )
    }

    private func terminalStateView(title: String, detail: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: currentRecord.status == .failed ? "exclamationmark.triangle.fill" : "stop.circle.fill")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.32))

            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)

            Text(detail)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.60))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.horizontal, 20)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - Helpers

}

// MARK: - UIViewControllerRepresentable wrapper

/// Wraps GaussianSplatViewController for use in SwiftUI.
/// Configures the file URL and handles lifecycle.
struct SplatViewerRepresentable: UIViewControllerRepresentable {
    let artifactURL: URL
    let captureGravityUpX: Float?
    let captureGravityUpY: Float?
    let captureGravityUpZ: Float?
    let captureGravitySource: String?
    let captureGravityConfidence: Float?
    var onLoaded: (() -> Void)?

    func makeUIViewController(context: Context) -> GaussianSplatViewController {
        let vc = GaussianSplatViewController()
        vc.fileURL = artifactURL
        if let x = captureGravityUpX,
           let y = captureGravityUpY,
           let z = captureGravityUpZ {
            vc.preferredSceneUp = SIMD3<Float>(x, y, z)
            vc.preferredSceneUpSource = captureGravitySource
            vc.preferredSceneUpConfidence = captureGravityConfidence
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: GaussianSplatViewController, context: Context) {
        // GaussianSplatViewController loads fileURL in viewDidLoad automatically.
        // Notify loading complete after first draw cycle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            onLoaded?()
        }
    }
}

#endif
