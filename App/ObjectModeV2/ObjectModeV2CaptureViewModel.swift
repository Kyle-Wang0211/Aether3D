import Foundation

#if canImport(SwiftUI)
import SwiftUI
import Aether3DCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

enum ObjectModeV2StageUIState: Equatable {
    case idle
    case processing(Double?)
    case ready
    case failed(String?)
}

enum ObjectModeV2Stage: String, CaseIterable, Identifiable {
    case preview
    case defaultStage = "default"
    case hq

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .preview:
            return "预览"
        case .defaultStage:
            return "默认成品"
        case .hq:
            return "高清成品"
        }
    }
}

struct ObjectModeV2StageCard: Identifiable, Equatable {
    let id: ObjectModeV2Stage
    let title: String
    let subtitle: String
    var state: ObjectModeV2StageUIState
}

private struct ObjectModeV2PersistedViewerBundle {
    let defaultArtifactURL: URL
    let defaultArtifactRelativePath: String
    let localManifestURL: URL
    let localManifestRelativePath: String
    let comparisonArtifactRelativePath: String?
    let comparisonMetricsRelativePath: String?
    let hqArtifactRelativePath: String?
}

enum ObjectModeV2TargetZoneMode: String, CaseIterable {
    case subject
    case group

    var title: String {
        switch self {
        case .subject:
            return "Subject"
        case .group:
            return "Group"
        }
    }

    var subtitle: String {
        switch self {
        case .subject:
            return "单主体"
        case .group:
            return "小群组"
        }
    }
}

#if canImport(UIKit)
struct ObjectModeV2AcceptedFrameThumbnail: Identifiable, Equatable {
    let id: UUID
    let image: UIImage

    static func == (lhs: ObjectModeV2AcceptedFrameThumbnail, rhs: ObjectModeV2AcceptedFrameThumbnail) -> Bool {
        lhs.id == rhs.id
    }
}
#endif

@MainActor
final class ObjectModeV2CaptureViewModel: ObservableObject {
    private let guidanceEnabled = true
    private let store = ScanRecordStore()
    @Published var previewSession: AVCaptureSession?
    @Published var isPreparingCamera = true
    @Published var cameraError: String?
    @Published var isRecording = false
    @Published var acceptedFrames = 0
    @Published var orbitCompletion = 0.0
    @Published var stabilityScore = 1.0
    @Published var guidanceText = "将物体放在画面中央，开始后沿着对象缓慢绕一圈。"
    @Published var recordingSeconds = 0
    @Published var isRunning = false
    @Published var isProcessingOverlayPresented = false
    @Published var processingFailureReason: String?
    @Published var statusText = "旧版云端高质量不动，这里直接走新版对象模式 Beta。"
    @Published var manifestURL: URL?
    @Published var downloadedArtifactURL: URL?
    @Published var downloadedArtifactFormat: String?
    @Published var isArtifactViewerPresented = false
    @Published var batteryPercentageText = "100%"
    @Published var targetZoneMode: ObjectModeV2TargetZoneMode = .subject
    @Published var isTargetLocked = false
    @Published var targetZoneAnchor = CGPoint(x: 0.5, y: 0.64)
    @Published var acceptedFrameFeedbackTick = 0
    #if canImport(UIKit)
    @Published var acceptedFrameThumbnails: [ObjectModeV2AcceptedFrameThumbnail] = []
    #endif
    @Published var stageCards: [ObjectModeV2StageCard] = [
        .init(id: .preview, title: "Preview", subtitle: "流程预热", state: .idle),
        .init(id: .defaultStage, title: "Default", subtitle: "默认成品", state: .idle),
        .init(id: .hq, title: "HQ", subtitle: "高清成品", state: .idle)
    ]
    var visibleStageCards: [ObjectModeV2StageCard] {
        stageCards.filter { $0.id != .preview }
    }

    private let recorder = ObjectModeV2CaptureRecorder()
    private let guidanceEngine = ObjectModeV2GuidanceEngine()
    #if canImport(UIKit)
    let previewBridge = ObjectModeV2PreviewBridge()
    private var batteryObserver: NSObjectProtocol?
    #endif

    private var hasPreviewAttached = false
    private var prepareTask: Task<Void, Never>?
    private var durationTask: Task<Void, Never>?
    private var activeRecordId: UUID?
    private var lastRemoteJobId: String?
    private var acceptedFrameTimestampsSec: [TimeInterval] = []
    private var localViewerManifestRelativePath: String?
    private var localComparisonArtifactRelativePath: String?
    private var localComparisonMetricsRelativePath: String?
    private var localHQArtifactRelativePath: String?
    private let maxTransientPollFailures = 30

    init() {
        guidanceEngine.onUpdate = { [weak self] snapshot in
            guard let self else { return }
            let previousAcceptedFrames = self.acceptedFrames
            self.acceptedFrames = snapshot.acceptedFrames
            self.orbitCompletion = snapshot.orbitCompletion
            self.stabilityScore = snapshot.stabilityScore
            self.guidanceText = self.resolvedGuidanceText(for: snapshot)
            if snapshot.acceptedFrames > previousAcceptedFrames,
               let timestamp = snapshot.lastAcceptedTimestamp {
                self.acceptedFrameTimestampsSec.append(max(0, timestamp))
                if self.acceptedFrameTimestampsSec.count > 150 {
                    self.acceptedFrameTimestampsSec.removeFirst(self.acceptedFrameTimestampsSec.count - 150)
                }
            }
            #if canImport(UIKit)
            if snapshot.acceptedFrames > previousAcceptedFrames {
                self.captureAcceptedFrameThumbnail()
                self.registerAcceptedFrameFeedback()
            }
            #endif
        }
        recorder.onVisualFrameSample = { [weak self] sample in
            guard let self else { return }
            self.guidanceEngine.processVisualSample(
                sample,
                targetZoneAnchor: self.targetZoneAnchor,
                targetZoneMode: self.targetZoneMode
            )
        }
        #if canImport(UIKit)
        previewBridge.onPreviewAttached = { [weak self] in
            Task { @MainActor in
                self?.hasPreviewAttached = true
                self?.schedulePrepareIfNeeded()
            }
        }
        #endif
    }

    var canStopCapture: Bool {
        isRecording
    }

    var canStartCapture: Bool {
        !isPreparingCamera && cameraError == nil && !isRecording && !shouldShowProcessingOverlay
    }

    var shouldShowProcessingOverlay: Bool {
        isProcessingOverlayPresented || isRunning
    }

    func onAppear() {
        debugLog("onAppear hasPreviewAttached=\(hasPreviewAttached) isRunning=\(isRunning) overlay=\(isProcessingOverlayPresented)")
        #if canImport(UIKit)
        startBatteryMonitoring()
        #endif
        schedulePrepareIfNeeded()
    }

    func onDisappear() {
        debugLog("onDisappear isRunning=\(isRunning) overlay=\(isProcessingOverlayPresented) jobId=\(lastRemoteJobId ?? "nil")")
        prepareTask?.cancel()
        prepareTask = nil
        durationTask?.cancel()
        if guidanceEnabled {
            guidanceEngine.stopMonitoring()
        }
        recorder.shutdown()
        #if canImport(UIKit)
        stopBatteryMonitoring()
        #endif
    }

    func prepareForDismiss() {
        debugLog("prepareForDismiss jobId=\(lastRemoteJobId ?? "nil")")
        if guidanceEnabled {
            guidanceEngine.stopMonitoring()
        }
        recorder.shutdown()
        previewSession = nil
        isPreparingCamera = false
        isProcessingOverlayPresented = false
        processingFailureReason = nil
    }

    func noteScenePhase(_ phase: ScenePhase) {
        debugLog("scenePhase=\(String(describing: phase)) isRunning=\(isRunning) overlay=\(isProcessingOverlayPresented) jobId=\(lastRemoteJobId ?? "nil")")
    }

    func toggleCapture() {
        if isRecording {
            stopCaptureAndGenerate()
        } else {
            startCapture()
        }
    }

    func setTargetZoneMode(_ mode: ObjectModeV2TargetZoneMode) {
        targetZoneMode = mode
        guard isTargetLocked else { return }
        guidanceText = "对象已锁定，开始后围绕这个目标缓慢移动。"
    }

    func lockTarget(at point: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        targetZoneAnchor = CGPoint(
            x: min(max(point.x / size.width, 0.18), 0.82),
            y: min(max(point.y / size.height, 0.18), 0.86)
        )
        isTargetLocked = true
        guidanceText = "对象已锁定，开始后围绕这个目标缓慢移动。"
    }

    func resetTargetLock() {
        isTargetLocked = false
        targetZoneAnchor = CGPoint(x: 0.5, y: 0.64)
        guidanceText = "将物体放在画面中央，开始后沿着对象缓慢绕一圈。"
    }

    func openRecord() {
        guard downloadedArtifactURL != nil else {
            statusText = "默认成品仍在下载或尚未准备好。"
            return
        }
        isArtifactViewerPresented = true
    }

    private func prepareCameraIfNeeded() async {
        if previewSession != nil || !isPreparingCamera || !hasPreviewAttached {
            return
        }

        do {
            try await recorder.prepare()
            if Task.isCancelled { return }
            previewSession = recorder.previewSession
            isPreparingCamera = false
            cameraError = nil
            statusText = "准备就绪。开始后系统会自动挑选有效关键帧，并先生成默认 surface 成品。"
        } catch {
            if Task.isCancelled { return }
            cameraError = error.localizedDescription
            isPreparingCamera = false
            statusText = "相机准备失败"
        }
    }

    private func schedulePrepareIfNeeded() {
        guard hasPreviewAttached else { return }
        guard prepareTask == nil else { return }
        prepareTask = Task { [weak self] in
            guard let self else { return }
            await self.prepareCameraIfNeeded()
            await MainActor.run {
                self.prepareTask = nil
            }
        }
    }

    private func startCapture() {
        guard canStartCapture else { return }
        debugLog("startCapture acceptedFrames=\(acceptedFrames) orbit=\(orbitCompletion)")

        manifestURL = nil
        downloadedArtifactURL = nil
        downloadedArtifactFormat = nil
        isArtifactViewerPresented = false
        isProcessingOverlayPresented = false
        processingFailureReason = nil
        lastRemoteJobId = nil
        localViewerManifestRelativePath = nil
        localComparisonArtifactRelativePath = nil
        localComparisonMetricsRelativePath = nil
        localHQArtifactRelativePath = nil
        recordingSeconds = 0
        acceptedFrames = 0
        orbitCompletion = 0
        stabilityScore = 1
        acceptedFrameTimestampsSec = []
        guidanceText = isTargetLocked
            ? "对象已锁定，开始后围绕这个目标缓慢移动。"
            : "将物体放在画面中央，开始后沿着对象缓慢绕一圈。"
        #if canImport(UIKit)
        acceptedFrameThumbnails = []
        #endif
        stageCards = stageCards.map { .init(id: $0.id, title: $0.title, subtitle: $0.subtitle, state: .idle) }

        do {
            try recorder.startRecording()
            isRecording = true
            if guidanceEnabled {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard let self, self.isRecording else { return }
                    self.guidanceEngine.startMonitoring()
                    self.guidanceEngine.beginRecording()
                }
            }
            statusText = guidanceEnabled ? "正在采集对象素材…" : "正在录制基础素材…"
            startDurationTicker()
            debugLog("startCapture succeeded")
        } catch {
            cameraError = error.localizedDescription
            statusText = "开始录制失败"
            debugLog("startCapture failed error=\(error.localizedDescription)")
        }
    }

    private func stopCaptureAndGenerate() {
        guard isRecording else { return }
        debugLog("stopCaptureAndGenerate acceptedFrames=\(acceptedFrames) acceptedTimestamps=\(acceptedFrameTimestampsSec.count)")
        isRecording = false
        isProcessingOverlayPresented = true
        if guidanceEnabled {
            guidanceEngine.endRecording()
            guidanceEngine.stopMonitoring()
        }
        durationTask?.cancel()

        Task {
            do {
                let clip = try await recorder.stopRecording()
                debugLog("stopRecording succeeded duration=\(clip.duration) file=\(clip.fileURL.lastPathComponent)")
                releasePreviewForProcessing()
                await runPipeline(with: clip)
            } catch {
                statusText = "停止录制失败：\(error.localizedDescription)"
                debugLog("stopRecording failed error=\(error.localizedDescription)")
            }
        }
    }

    private func runPipeline(with clip: ObjectModeV2RecordedClip) async {
        isRunning = true
        isProcessingOverlayPresented = true
        processingFailureReason = nil
        manifestURL = nil
        downloadedArtifactURL = nil
        downloadedArtifactFormat = nil
        let broker = BackgroundUploadBrokerClient.shared
        debugLog("runPipeline start file=\(clip.fileURL.lastPathComponent) duration=\(clip.duration)")
        statusText = acceptedFrames < 20
            ? "素材偏少，仍会继续尝试生成默认成品。"
            : "素材已锁定，正在启动新版对象模式管线…"
        stageCards = stageCards.map { .init(id: $0.id, title: $0.title, subtitle: $0.subtitle, state: .idle) }

        do {
            let recordContext = try preparePersistentRecord(for: clip)
            debugLog("persistent record prepared recordId=\(recordContext.recordId.uuidString) upload=\(recordContext.uploadURL.lastPathComponent)")
            persistRecordState(
                recordId: recordContext.recordId,
                status: .uploading,
                statusMessage: "正在上传对象素材",
                detailMessage: "新远端对象模式正在上传素材，并准备默认成品。",
                progressFraction: 0.03,
                remoteJobId: nil,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "uploading",
                    detail: "uploading_source",
                    remoteJobId: nil
                )
            )
            let creation = try await broker.createJob(
                videoURL: recordContext.uploadURL,
                clientRecordId: recordContext.recordId,
                captureOrigin: "object_mode_v2",
                pipelineProfile: objectFastPublishPipelineProfile()
            )
            let jobId = creation.jobId
            lastRemoteJobId = jobId
            debugLog("remote job created jobId=\(jobId)")
            persistRecordState(
                recordId: recordContext.recordId,
                status: .uploading,
                statusMessage: "后台上传已接管",
                detailMessage: "远端任务已经创建，正在继续上传素材。",
                progressFraction: 0.05,
                remoteJobId: jobId,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "uploading",
                    detail: "upload_started",
                    remoteJobId: jobId
                )
            )

            _ = try await broker.startUpload(
                jobId: jobId,
                upload: creation.upload,
                sourceURL: recordContext.uploadURL,
                onProgress: { [weak self] progress in
                    await MainActor.run {
                        self?.applyUploadProgress(progress)
                    }
                }
            )
            debugLog("upload completed jobId=\(jobId)")

            persistRecordState(
                recordId: recordContext.recordId,
                status: .queued,
                statusMessage: "远端已接收任务",
                detailMessage: "默认成品正在排队并准备处理。",
                progressFraction: 0.18,
                remoteJobId: jobId,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "queued",
                    detail: "queued_for_worker",
                    remoteJobId: jobId
                )
            )

            var defaultReady = false
            var defaultDownloaded = false
            var transientPollFailures = 0
            var lastLoggedStageSignature: String?

            while true {
                let status: JobStatus
                do {
                    status = try await broker.pollStatus(jobId: jobId)
                    transientPollFailures = 0
                } catch {
                    transientPollFailures += 1
                    debugLog("pollStatus failed retry=\(transientPollFailures)/\(maxTransientPollFailures) jobId=\(jobId) error=\(error.localizedDescription)")
                    if transientPollFailures <= maxTransientPollFailures {
                        statusText = "网络波动，正在重新连接远端状态…"
                        persistRecordState(
                            recordId: recordContext.recordId,
                            status: .reconstructing,
                            statusMessage: "正在重新连接远端状态",
                            detailMessage: "网络短暂波动，系统正在继续拉取对象任务状态。",
                            progressFraction: max(currentProcessingProgress, 0.12),
                            remoteJobId: jobId,
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: "network_retry",
                                detail: "retrying_status_poll",
                                remoteJobId: jobId
                            )
                        )
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }
                    throw error
                }
                let stageSignature = status.debugSignature
                if stageSignature != lastLoggedStageSignature {
                    lastLoggedStageSignature = stageSignature
                    debugLog("pollStatus jobId=\(jobId) status=\(stageSignature)")
                }
                switch status {
                case .pending(let progress):
                    applyRemoteProgress(progress, defaultReady: defaultReady)
                    persistRemoteProgress(progress, recordId: recordContext.recordId, remoteJobId: jobId, defaultReady: defaultReady)
                case .processing(let progress):
                    applyRemoteProgress(progress, defaultReady: defaultReady)
                    persistRemoteProgress(progress, recordId: recordContext.recordId, remoteJobId: jobId, defaultReady: defaultReady)
                case .downloadReady(let progress):
                    defaultReady = true
                    debugLog("default artifact ready jobId=\(jobId)")
                    updateStage(.defaultStage, state: .ready)
                    applyRemoteProgress(progress, defaultReady: defaultReady)
                    persistRemoteProgress(progress, recordId: recordContext.recordId, remoteJobId: jobId, defaultReady: defaultReady)
                    if !defaultDownloaded {
                        let persistedBundle = try await downloadAndPersistViewerBundle(
                            broker: broker,
                            jobId: jobId,
                            recordId: recordContext.recordId
                        )
                        defaultDownloaded = true
                        statusText = "默认 surface 成品已下载，可先 Open 查看。"
                        persistRecordState(
                            recordId: recordContext.recordId,
                            status: .packaging,
                            statusMessage: progress.title ?? "默认 surface 成品已就绪",
                            detailMessage: "默认 surface 成品已下载，可先 Open 查看。",
                            progressFraction: max(progress.progressFraction ?? currentProcessingProgress, 0.82),
                            remoteJobId: jobId,
                            runtimeMetrics: objectFastPublishRuntimeMetrics(
                                stageKey: progress.stageKey ?? "publish_default_surface",
                                detail: progress.detail ?? "default_bundle_downloaded",
                                remoteJobId: jobId,
                                remoteProgress: progress,
                                localViewerManifestPath: persistedBundle.localManifestRelativePath,
                                localComparisonArtifactPath: persistedBundle.comparisonArtifactRelativePath,
                                localComparisonMetricsPath: persistedBundle.comparisonMetricsRelativePath,
                                localHQArtifactPath: persistedBundle.hqArtifactRelativePath
                            )
                        )
                        store.updateArtifactPath(recordId: recordContext.recordId, artifactPath: persistedBundle.defaultArtifactRelativePath)
                        debugLog("default viewer bundle downloaded raw=\(persistedBundle.defaultArtifactURL.lastPathComponent) manifest=\(persistedBundle.localManifestURL.lastPathComponent)")
                    }
                case .completed(let progress):
                    let persistedBundle = try await downloadAndPersistViewerBundle(
                        broker: broker,
                        jobId: jobId,
                        recordId: recordContext.recordId
                    )
                    defaultDownloaded = true
                    debugLog("completed viewer bundle refreshed jobId=\(jobId)")
                    if let artifactURL = downloadedArtifactURL {
                        let relativeArtifactPath = try persistDownloadedArtifact(
                            artifactURL,
                            recordId: recordContext.recordId
                        )
                        store.updateArtifactPath(recordId: recordContext.recordId, artifactPath: relativeArtifactPath)
                    }
                    updateStage(.preview, state: .ready)
                    updateStage(.defaultStage, state: .ready)
                    updateStage(.hq, state: .ready)
                    statusText = progress?.detail ?? "高清成品已完成"
                    persistRecordState(
                        recordId: recordContext.recordId,
                        status: .completed,
                        statusMessage: "对象成品已完成",
                        detailMessage: progress?.detail ?? "默认成品已完成下载，可从首页直接打开。",
                        progressFraction: 1.0,
                        remoteJobId: nil,
                        clearRemoteJobId: true,
                        runtimeMetrics: objectFastPublishRuntimeMetrics(
                            stageKey: "completed",
                            detail: progress?.detail,
                            remoteJobId: jobId,
                            localViewerManifestPath: localViewerManifestRelativePath,
                            localComparisonArtifactPath: localComparisonArtifactRelativePath,
                            localComparisonMetricsPath: localComparisonMetricsRelativePath,
                            localHQArtifactPath: persistedBundle.hqArtifactRelativePath
                        )
                    )
                    isRunning = false
                    debugLog("runPipeline completed jobId=\(jobId)")
                    return
                case .failed(let reason, _):
                    debugLog("remote job failed jobId=\(jobId) reason=\(reason)")
                    throw RemoteB1ClientError.jobFailed(reason)
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            if case RemoteB1ClientError.notConfigured = error {
                statusText = "新远端尚未配置，暂时回退到本地占位流程。"
                do {
                    let placeholderManifestURL = try makePlaceholderManifest(for: clip)
                    try await simulateStage(
                        .preview,
                        progressSteps: [0.32, 0.78],
                        stepDelayNs: 550_000_000
                    )
                    try await simulateStage(
                        .defaultStage,
                        progressSteps: [0.25, 0.56, 0.84],
                        stepDelayNs: 700_000_000
                    )
                    try await simulateStage(
                        .hq,
                        progressSteps: [0.18, 0.44, 0.72, 0.93],
                        stepDelayNs: 800_000_000
                    )
                    manifestURL = placeholderManifestURL
                    statusText = "高清成品已完成"
                    debugLog("fallback placeholder manifest ready")
                } catch {
                    statusText = "生成失败：\(error.localizedDescription)"
                    debugLog("fallback placeholder failed error=\(error.localizedDescription)")
                }
            } else {
                let failureMessage = userFacingFailureMessage(for: error)
                processingFailureReason = failureMessage
                statusText = "生成失败：\(failureMessage)"
                updateStage(.defaultStage, state: .failed(failureMessage))
                updateStage(.hq, state: .idle)
                debugLog("runPipeline failed error=\(error.localizedDescription) jobId=\(lastRemoteJobId ?? "nil")")
            }
            if let recordId = activeRecordId {
                let failureMessage = userFacingFailureMessage(for: error)
                persistRecordState(
                    recordId: recordId,
                    status: .failed,
                    statusMessage: "新远端生成失败",
                    detailMessage: failureMessage,
                    progressFraction: currentProcessingProgress,
                    remoteJobId: lastRemoteJobId,
                    runtimeMetrics: objectFastPublishRuntimeMetrics(
                        stageKey: "failed",
                        detail: failureMessage,
                        remoteJobId: lastRemoteJobId
                    ),
                    failureReason: normalizedFailureReason(for: error)
                )
            }
        }

        isRunning = false
        debugLog("runPipeline end isRunning=false overlay=\(isProcessingOverlayPresented) jobId=\(lastRemoteJobId ?? "nil")")
    }

    private func updateStage(_ stage: ObjectModeV2Stage, state: ObjectModeV2StageUIState) {
        stageCards = stageCards.map {
            guard $0.id == stage else { return $0 }
            return .init(id: $0.id, title: $0.title, subtitle: $0.subtitle, state: state)
        }
    }

    private func releasePreviewForProcessing() {
        debugLog("releasePreviewForProcessing")
        if guidanceEnabled {
            guidanceEngine.stopMonitoring()
        }
        recorder.suspendPreview()
        previewSession = nil
        isPreparingCamera = false
    }

    private func startDurationTicker() {
        durationTask?.cancel()
        durationTask = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRecording {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if self.isRecording {
                    self.recordingSeconds += 1
                }
            }
        }
    }

    #if canImport(UIKit)
    private func captureAcceptedFrameThumbnail() {
        guard isRecording else { return }
        guard let image = recorder.captureSnapshotImage() else { return }
        let thumbnail = ObjectModeV2AcceptedFrameThumbnail(id: UUID(), image: image)
        acceptedFrameThumbnails.append(thumbnail)
        if acceptedFrameThumbnails.count > 8 {
            acceptedFrameThumbnails.removeFirst(acceptedFrameThumbnails.count - 8)
        }
    }

    private func registerAcceptedFrameFeedback() {
        acceptedFrameFeedbackTick += 1
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred(intensity: 0.82)
    }

    private func startBatteryMonitoring() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        refreshBatteryPercentage()
        guard batteryObserver == nil else { return }
        batteryObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBatteryPercentage()
            }
        }
    }

    private func stopBatteryMonitoring() {
        if let batteryObserver {
            NotificationCenter.default.removeObserver(batteryObserver)
            self.batteryObserver = nil
        }
        UIDevice.current.isBatteryMonitoringEnabled = false
    }

    private func refreshBatteryPercentage() {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else {
            batteryPercentageText = "100%"
            return
        }
        batteryPercentageText = "\(max(1, Int(round(level * 100))))%"
    }
    #endif

    private func resolvedGuidanceText(for snapshot: ObjectModeV2GuidanceSnapshot) -> String {
        guard isTargetLocked else { return snapshot.hintText }

        if snapshot.stabilityScore < 0.28 {
            return "对象已锁定，先稳住手机，再继续围绕主体移动。"
        }

        if snapshot.orbitCompletion < 0.3 {
            return "对象已锁定，先补正面和侧面，保持目标在锁定框附近。"
        }

        if snapshot.acceptedFrames < 20 {
            return "对象已锁定，继续补新的角度，先把一圈拍完整。"
        }

        if snapshot.acceptedFrames < 60 {
            return "对象已锁定，质量已经不错，可以继续补顶部和边缘细节。"
        }

        return "对象已锁定，成品质量已经很好，可以结束或继续补更细节角度。"
    }

    private func simulateStage(
        _ stage: ObjectModeV2Stage,
        progressSteps: [Double],
        stepDelayNs: UInt64
    ) async throws {
        for progress in progressSteps {
            updateStage(stage, state: .processing(progress))
            statusText = "\(stage.displayName) 处理中…"
            try await Task.sleep(nanoseconds: stepDelayNs)
        }
        updateStage(stage, state: .ready)
        statusText = "\(stage.displayName) 已就绪"
    }

    private func objectFastPublishPipelineProfile() -> [String: String] {
        let maxSimilarity: Double = FrameQualityConstants.maxFrameSimilarity
        let acceptedTimestampsMs = acceptedFrameTimestampsSec
            .map { String(Int(($0 * 1000).rounded())) }
            .joined(separator: ",")
        return [
            "strategy": "object_slam3r_surface_v1",
            "capture_mode": "guided_object",
            "artifact_contract_version": "object_publish_v1",
            "first_result_kind": "sparse2dgs_surface",
            "hq_refine": "disabled",
            "optional_mesh_export": "disabled",
            "target_zone_mode": ObjectModeV2TargetZoneMode.subject.rawValue,
            "client_live_accepted_frames": "\(acceptedFrames)",
            "client_live_accepted_timestamps_ms": acceptedTimestampsMs,
            "client_live_selection_source": "visual_realtime",
            "client_live_orbit_completion": String(format: "%.4f", orbitCompletion),
            "visual_gate_version": "v1_visual_curated",
            "visual_blur_threshold_laplacian": String(format: "%.1f", FrameQualityConstants.blurThresholdLaplacian),
            "visual_dark_threshold_brightness": String(format: "%.1f", FrameQualityConstants.darkThresholdBrightness),
            "visual_bright_threshold_brightness": String(format: "%.1f", FrameQualityConstants.brightThresholdBrightness),
            "visual_max_frame_similarity": String(format: "%.4f", maxSimilarity),
            "visual_min_accept_interval_sec": "0.28"
        ]
    }

    private func applyUploadProgress(_ progress: RemoteUploadProgress) {
        let fraction = max(0.02, min(progress.fraction ?? 0.05, 0.18))
        updateStage(.preview, state: .processing(fraction))
        statusText = progress.isFinalizing
            ? "正在完成素材上传…"
            : "正在上传对象素材…"
        if let recordId = activeRecordId {
            persistRecordState(
                recordId: recordId,
                status: .uploading,
                statusMessage: progress.isFinalizing ? "正在完成素材上传" : "正在上传对象素材",
                detailMessage: progress.isFinalizing
                    ? "所有素材分片已发送，正在确认远端可见性。"
                    : "新远端对象模式正在上传素材。",
                progressFraction: fraction,
                remoteJobId: lastRemoteJobId,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: progress.isFinalizing ? "upload_finalizing" : "uploading",
                    detail: progress.isFinalizing ? "upload_finalizing" : "uploading_source",
                    remoteJobId: lastRemoteJobId
                ),
                uploadedBytes: progress.uploadedBytes,
                totalBytes: progress.totalBytes,
                uploadBytesPerSecond: nil
            )
        }
    }

    private func applyRemoteProgress(_ progress: RemoteJobProgress, defaultReady: Bool) {
        let stageKey = (progress.stageKey ?? "").lowercased()
        let fraction = progress.progressFraction
        if !defaultReady {
            updateStage(.preview, state: .ready)
        }

        switch stageKey {
        case "uploading", "queued":
            updateStage(.preview, state: .processing(progress.progressFraction ?? 0.18))
            if let detail = progress.detail, !detail.isEmpty {
                statusText = detail
            } else {
                statusText = "正在准备默认 surface 成品，下载完成后会出现 Open。"
            }
            return
        case "curate":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.22, 0.22)))
        case "slam3r_reconstruct":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.48, 0.48)))
        case "slam3r_scene_contract":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.58, 0.58)))
        case "sparse2dgs_surface":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.68, 0.68)))
        case "publish_default_surface":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.82, 0.82)))
        case "artifact_upload":
            updateStage(.defaultStage, state: .processing(max(fraction ?? 0.90, 0.90)))
            updateStage(.hq, state: .idle)
        default:
            updateStage(.defaultStage, state: .processing(fraction ?? 0.42))
        }

        if let detail = progress.detail, !detail.isEmpty {
            statusText = detail
        } else if let title = progress.title, !title.isEmpty {
            statusText = title
        }
    }

    private var currentProcessingProgress: Double {
        for card in stageCards.reversed() {
            switch card.state {
            case .processing(let progress):
                if let progress { return progress }
            case .ready:
                return 1.0
            case .failed:
                return 1.0
            case .idle:
                continue
            }
        }
        return 0
    }

    private func preparePersistentRecord(for clip: ObjectModeV2RecordedClip) throws -> (recordId: UUID, uploadURL: URL, relativeSourcePath: String) {
        let recordId = activeRecordId ?? UUID()
        activeRecordId = recordId

        let importsDirectory = store.baseDirectoryURL().appendingPathComponent("imports", isDirectory: true)
        try FileManager.default.createDirectory(at: importsDirectory, withIntermediateDirectories: true)
        let fileExtension = clip.fileURL.pathExtension.isEmpty ? "mov" : clip.fileURL.pathExtension
        let persistedSourceURL = importsDirectory.appendingPathComponent("\(recordId.uuidString).\(fileExtension)")
        if persistedSourceURL.standardizedFileURL.path != clip.fileURL.standardizedFileURL.path {
            if FileManager.default.fileExists(atPath: persistedSourceURL.path) {
                try FileManager.default.removeItem(at: persistedSourceURL)
            }
            try FileManager.default.copyItem(at: clip.fileURL, to: persistedSourceURL)
        }
        let relativeSourcePath = "imports/\(persistedSourceURL.lastPathComponent)"

        if store.record(id: recordId) == nil {
            let thumbnailPath = persistLatestThumbnail(for: recordId)
            let record = ScanRecord(
                id: recordId,
                thumbnailPath: thumbnailPath,
                artifactPath: nil,
                sourceVideoPath: relativeSourcePath,
                remoteJobId: nil,
                frameSamplingProfile: FrameSamplingProfile.currentSelection().rawValue,
                captureIntent: ScanCaptureIntent.object.rawValue,
                processingBackend: ProcessingBackendChoice.cloud.rawValue,
                coveragePercentage: orbitCompletion,
                triangleCount: 0,
                durationSeconds: clip.duration,
                status: .uploading,
                statusMessage: "正在上传对象素材",
                detailMessage: "新远端对象模式正在准备默认成品。",
                progressFraction: 0.03,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "preparing",
                    detail: "capture_saved",
                    remoteJobId: nil
                )
            )
            store.saveRecord(record)
        } else {
            store.updateProcessingState(
                recordId: recordId,
                status: .uploading,
                statusMessage: "正在上传对象素材",
                detailMessage: "新远端对象模式正在准备默认成品。",
                progressFraction: 0.03,
                runtimeMetrics: objectFastPublishRuntimeMetrics(
                    stageKey: "preparing",
                    detail: "capture_saved",
                    remoteJobId: nil
                ),
                sourceVideoPath: relativeSourcePath,
                frameSamplingProfile: FrameSamplingProfile.currentSelection().rawValue,
            )
            #if canImport(UIKit)
            if let thumbnailPath = persistLatestThumbnail(for: recordId) {
                store.updateThumbnailPath(recordId: recordId, thumbnailPath: thumbnailPath)
            }
            #endif
        }

        return (recordId, persistedSourceURL, relativeSourcePath)
    }

    #if canImport(UIKit)
    private func persistLatestThumbnail(for recordId: UUID) -> String? {
        guard let image = acceptedFrameThumbnails.last?.image ?? recorder.captureSnapshotImage(),
              let data = image.jpegData(compressionQuality: 0.82) else {
            return nil
        }
        return store.saveThumbnail(data, for: recordId)
    }
    #endif

    private func persistRecordState(
        recordId: UUID,
        status: ScanRecordStatus,
        statusMessage: String,
        detailMessage: String,
        progressFraction: Double?,
        remoteJobId: String?,
        clearRemoteJobId: Bool = false,
        runtimeMetrics: [String: String],
        uploadedBytes: Int64? = nil,
        totalBytes: Int64? = nil,
        uploadBytesPerSecond: Double? = nil,
        failureReason: String? = nil
    ) {
        store.updateProcessingState(
            recordId: recordId,
            status: status,
            statusMessage: statusMessage,
            detailMessage: detailMessage,
            progressFraction: progressFraction,
            remoteStageKey: runtimeMetrics["remote_stage_key"],
            runtimeMetrics: runtimeMetrics,
            uploadedBytes: uploadedBytes,
            totalBytes: totalBytes,
            uploadBytesPerSecond: uploadBytesPerSecond,
            sourceVideoPath: store.record(id: recordId)?.sourceVideoPath,
            frameSamplingProfile: FrameSamplingProfile.currentSelection().rawValue,
            remoteJobId: remoteJobId,
            clearRemoteJobId: clearRemoteJobId,
            failureReason: failureReason
        )
    }

    private func persistRemoteProgress(
        _ progress: RemoteJobProgress,
        recordId: UUID,
        remoteJobId: String,
        defaultReady: Bool
    ) {
        let stageKey = (progress.stageKey ?? "").lowercased()
        let status: ScanRecordStatus
        switch stageKey {
        case "queued":
            status = .queued
        case "curate", "slam3r_reconstruct", "slam3r_scene_contract", "sparse2dgs_surface":
            status = .reconstructing
        case "publish_default_surface", "artifact_upload":
            status = .packaging
        default:
            status = defaultReady ? .packaging : .reconstructing
        }

        let detail = progress.detail ?? progress.title ?? (defaultReady
            ? "默认 surface 成品已就绪，可直接打开。"
            : "新远端对象模式正在生成默认 surface 成品。")
        persistRecordState(
            recordId: recordId,
            status: status,
            statusMessage: progress.title ?? detail,
            detailMessage: detail,
            progressFraction: progress.progressFraction ?? currentProcessingProgress,
            remoteJobId: remoteJobId,
            runtimeMetrics: objectFastPublishRuntimeMetrics(
                stageKey: stageKey,
                detail: detail,
                remoteJobId: remoteJobId,
                remoteProgress: progress
            )
        )
    }

    private func objectFastPublishRuntimeMetrics(
        stageKey: String,
        detail: String?,
        remoteJobId: String?,
        remoteProgress: RemoteJobProgress? = nil,
        localViewerManifestPath: String? = nil,
        localComparisonArtifactPath: String? = nil,
        localComparisonMetricsPath: String? = nil,
        localHQArtifactPath: String? = nil
    ) -> [String: String] {
        let resolvedLocalViewerManifestPath = localViewerManifestPath ?? self.localViewerManifestRelativePath
        let resolvedLocalComparisonArtifactPath = localComparisonArtifactPath ?? self.localComparisonArtifactRelativePath
        let resolvedLocalComparisonMetricsPath = localComparisonMetricsPath ?? self.localComparisonMetricsRelativePath
        let resolvedLocalHQArtifactPath = localHQArtifactPath ?? self.localHQArtifactRelativePath
        var metrics: [String: String] = [
            "pipeline_strategy": "object_slam3r_surface_v1",
            "artifact_contract_version": "object_publish_v1",
            "first_result_kind": "sparse2dgs_surface",
            "hq_refine": "disabled",
            "optional_mesh_export": "disabled",
            "target_zone_mode": "subject",
            "accepted_live_frames": "\(acceptedFrames)",
            "orbit_completion_percent": "\(Int((orbitCompletion * 100).rounded()))",
            "remote_stage_key": stageKey,
        ]
        if let detail, !detail.isEmpty {
            metrics["stage_detail"] = detail
        }
        if let remoteJobId, !remoteJobId.isEmpty {
            metrics["remote_job_id"] = remoteJobId
        }
        if let resolvedLocalViewerManifestPath, !resolvedLocalViewerManifestPath.isEmpty {
            metrics["local_viewer_manifest_path"] = resolvedLocalViewerManifestPath
        }
        if let resolvedLocalComparisonArtifactPath, !resolvedLocalComparisonArtifactPath.isEmpty {
            metrics["local_comparison_asset_path"] = resolvedLocalComparisonArtifactPath
        }
        if let resolvedLocalComparisonMetricsPath, !resolvedLocalComparisonMetricsPath.isEmpty {
            metrics["local_comparison_metrics_path"] = resolvedLocalComparisonMetricsPath
        }
        if let resolvedLocalHQArtifactPath, !resolvedLocalHQArtifactPath.isEmpty {
            metrics["local_hq_asset_path"] = resolvedLocalHQArtifactPath
        }
        if let remoteProgress {
            if let phaseName = remoteProgress.phaseName, !phaseName.isEmpty {
                metrics["remote_phase_name"] = phaseName
            }
            if let progressBasis = remoteProgress.progressBasis, !progressBasis.isEmpty {
                metrics["progress_basis"] = progressBasis
            }
            if let title = remoteProgress.title, !title.isEmpty {
                metrics["runtime_title"] = title
            }
            if let detail = remoteProgress.detail, !detail.isEmpty {
                metrics["runtime_detail"] = detail
            }
            for (key, value) in remoteProgress.runtimeMetrics {
                metrics[key] = value
            }
        }
        return metrics
    }

    private func persistDownloadedArtifact(_ sourceURL: URL, recordId: UUID) throws -> String {
        let exportsDirectory = store.baseDirectoryURL().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        let fileExtension = sourceURL.pathExtension.isEmpty ? "glb" : sourceURL.pathExtension
        let destinationURL = exportsDirectory.appendingPathComponent("\(recordId.uuidString).\(fileExtension)")
        if sourceURL.standardizedFileURL.path == destinationURL.standardizedFileURL.path {
            return "exports/\(destinationURL.lastPathComponent)"
        }
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return "exports/\(destinationURL.lastPathComponent)"
    }

    private func downloadAndPersistViewerBundle(
        broker: BackgroundUploadBrokerClient,
        jobId: String,
        recordId: UUID
    ) async throws -> ObjectModeV2PersistedViewerBundle {
        let bundle = try await broker.downloadObjectModeViewerBundle(jobId: jobId)
        let persistedBundle = try persistDownloadedViewerBundle(bundle, recordId: recordId)
        downloadedArtifactURL = persistedBundle.defaultArtifactURL
        downloadedArtifactFormat = bundle.defaultArtifact.format
        manifestURL = persistedBundle.localManifestURL
        localViewerManifestRelativePath = persistedBundle.localManifestRelativePath
        localComparisonArtifactRelativePath = persistedBundle.comparisonArtifactRelativePath
        localComparisonMetricsRelativePath = persistedBundle.comparisonMetricsRelativePath
        localHQArtifactRelativePath = persistedBundle.hqArtifactRelativePath
        return persistedBundle
    }

    private func persistDownloadedViewerBundle(
        _ bundle: BrokerDownloadedObjectModeViewerBundle,
        recordId: UUID
    ) throws -> ObjectModeV2PersistedViewerBundle {
        let exportsDirectory = store.baseDirectoryURL().appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)

        func copyArtifact(_ sourceURL: URL, fileName: String) throws -> URL {
            let destinationURL = exportsDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            return destinationURL
        }

        let defaultExtension = bundle.defaultArtifact.localURL.pathExtension.isEmpty ? "ply" : bundle.defaultArtifact.localURL.pathExtension.lowercased()
        let defaultDestinationURL = try copyArtifact(
            bundle.defaultArtifact.localURL,
            fileName: "\(recordId.uuidString).\(defaultExtension)"
        )

        var cleanedRelativePath: String?
        if let comparisonArtifact = bundle.comparisonArtifact {
            let cleanedExtension = comparisonArtifact.localURL.pathExtension.isEmpty ? "ply" : comparisonArtifact.localURL.pathExtension.lowercased()
            let cleanedURL = try copyArtifact(
                comparisonArtifact.localURL,
                fileName: "\(recordId.uuidString).cleanup.\(cleanedExtension)"
            )
            cleanedRelativePath = "exports/\(cleanedURL.lastPathComponent)"
        }

        var compareMetricsRelativePath: String?
        if let comparisonMetrics = bundle.comparisonMetrics {
            let compareExtension = comparisonMetrics.localURL.pathExtension.isEmpty ? "json" : comparisonMetrics.localURL.pathExtension.lowercased()
            let compareURL = try copyArtifact(
                comparisonMetrics.localURL,
                fileName: "\(recordId.uuidString).cleanup_compare.\(compareExtension)"
            )
            compareMetricsRelativePath = "exports/\(compareURL.lastPathComponent)"
        }

        var hqRelativePath: String?
        if let hqArtifact = bundle.hqArtifact {
            let hqExtension = hqArtifact.localURL.pathExtension.isEmpty ? "splat" : hqArtifact.localURL.pathExtension.lowercased()
            let hqURL = try copyArtifact(
                hqArtifact.localURL,
                fileName: "\(recordId.uuidString).hq.\(hqExtension)"
            )
            hqRelativePath = "exports/\(hqURL.lastPathComponent)"
        }

        var remoteManifestPayload: [String: Any] = [:]
        if let remoteManifest = bundle.viewerManifest,
           let data = try? Data(contentsOf: remoteManifest.localURL),
           let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            remoteManifestPayload = payload
        }

        var localManifestPayload: [String: Any] = [
            "version": remoteManifestPayload["version"] ?? "object_publish_v1",
            "default_asset": [
                "kind": bundle.defaultArtifact.format,
                "path": defaultDestinationURL.lastPathComponent,
                "ready": true,
            ],
        ]
        if let cleanedRelativePath {
            localManifestPayload["cleaned_asset"] = [
                "kind": bundle.comparisonArtifact?.format ?? "ply",
                "path": URL(fileURLWithPath: cleanedRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let compareMetricsRelativePath {
            localManifestPayload["cleanup_compare"] = [
                "kind": "json",
                "path": URL(fileURLWithPath: compareMetricsRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let hqRelativePath {
            localManifestPayload["hq_asset"] = [
                "kind": bundle.hqArtifact?.format ?? "splat",
                "path": URL(fileURLWithPath: hqRelativePath).lastPathComponent,
                "ready": true,
            ]
        }
        if let cameraPreset = remoteManifestPayload["camera_preset"] {
            localManifestPayload["camera_preset"] = cameraPreset
        }
        if let supportPatchBounds = remoteManifestPayload["support_patch_bounds"] {
            localManifestPayload["support_patch_bounds"] = supportPatchBounds
        }

        let localManifestURL = exportsDirectory.appendingPathComponent("\(recordId.uuidString).viewer_manifest.json")
        if FileManager.default.fileExists(atPath: localManifestURL.path) {
            try FileManager.default.removeItem(at: localManifestURL)
        }
        let manifestData = try JSONSerialization.data(withJSONObject: localManifestPayload, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: localManifestURL, options: .atomic)

        return ObjectModeV2PersistedViewerBundle(
            defaultArtifactURL: defaultDestinationURL,
            defaultArtifactRelativePath: "exports/\(defaultDestinationURL.lastPathComponent)",
            localManifestURL: localManifestURL,
            localManifestRelativePath: "exports/\(localManifestURL.lastPathComponent)",
            comparisonArtifactRelativePath: cleanedRelativePath,
            comparisonMetricsRelativePath: compareMetricsRelativePath,
            hqArtifactRelativePath: hqRelativePath
        )
    }

    private func makePlaceholderManifest(for clip: ObjectModeV2RecordedClip, remoteJobId: String? = nil) throws -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let base = documents
            .appendingPathComponent("Aether3D")
            .appendingPathComponent("ObjectModeV2StagedRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let sessionDirectory = base.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let manifestURL = sessionDirectory.appendingPathComponent("manifest.json")
        let payload: [String: Any] = [
            "display_name": "对象模式 Beta",
            "created_at": ISO8601DateFormatter().string(from: Date()),
            "source_video_path": clip.fileURL.path,
            "remote_job_id": remoteJobId as Any,
            "accepted_frames": acceptedFrames,
            "orbit_completion": orbitCompletion,
            "stages": [
                ["id": "default", "title": "Default"],
                ["id": "hq", "title": "HQ"]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: manifestURL, options: .atomic)
        return manifestURL
    }

    private func debugLog(_ message: String) {
        let recordLabel = activeRecordId?.uuidString.prefix(8) ?? "no-record"
        print("[Aether3D][ObjectModeV2][\(recordLabel)] \(message)")
    }

    private func userFacingFailureMessage(for error: Error) -> String {
        if case RemoteB1ClientError.jobFailed(let reason) = error {
            switch reason {
            case "curate_frames_insufficient_client_selected_frames":
                return "端上选中的有效关键帧命中不足，远端没法继续生成默认成品。"
            case "object_surface_failed":
                return "新远端在 surface 默认成品阶段失败了。"
            default:
                return reason
            }
        }
        return error.localizedDescription
    }

    private func normalizedFailureReason(for error: Error) -> String {
        if case RemoteB1ClientError.jobFailed(let reason) = error {
            return reason
        }
        return "object_surface_failed"
    }
}

private extension JobStatus {
    var debugSignature: String {
        switch self {
        case .pending(let progress):
            return "pending:\(progress.stageKey ?? "nil"):\(progress.progressFraction.map { String(format: "%.3f", $0) } ?? "nil")"
        case .processing(let progress):
            return "processing:\(progress.stageKey ?? "nil"):\(progress.progressFraction.map { String(format: "%.3f", $0) } ?? "nil")"
        case .downloadReady(let progress):
            return "downloadReady:\(progress.stageKey ?? "nil"):\(progress.progressFraction.map { String(format: "%.3f", $0) } ?? "nil")"
        case .completed(let progress):
            return "completed:\(progress?.stageKey ?? "nil"):\(progress?.progressFraction.map { String(format: "%.3f", $0) } ?? "nil")"
        case .failed(let reason, let progress):
            return "failed:\(progress?.stageKey ?? "nil"):\(reason)"
        }
    }
}

#endif
