//
// HomePage.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Home Page
// Apple-platform only (SwiftUI)
//

import Foundation
import Aether3DCore

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(PhotosUI)
import PhotosUI
#endif
#if canImport(Photos)
import Photos
#endif
#if canImport(CoreTransferable)
import CoreTransferable
#endif

#if canImport(SwiftUI)
struct HomePage: View {
    private enum HomeLanguage: String {
        case zh
        case en
    }

    private enum HomeProcessingMode: String {
        case remote
        case remoteV2
        case local
    }

    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FrameSamplingProfile.userDefaultsKey) private var selectedFrameSamplingProfileRaw = FrameSamplingProfile.full.rawValue
    @AppStorage(ProcessingBackendChoice.userDefaultsKey) private var selectedProcessingBackendRaw = ProcessingBackendChoice.cloud.rawValue
    @AppStorage("aether.homeProcessingMode") private var homeProcessingModeRaw = HomeProcessingMode.remote.rawValue
    @AppStorage("aether.homeLanguage") private var homeLanguageRaw = HomeLanguage.zh.rawValue
    @State private var navigateToScan = false
    @State private var navigateToObjectModeV2 = false
    @State private var selectedRecord: ScanRecord?
    @State private var showViewer = false

    #if canImport(PhotosUI)
    @State private var selectedVideoItem: PhotosPickerItem?
    #endif

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var selectedFrameSamplingProfile: FrameSamplingProfile {
        FrameSamplingProfile(rawValue: selectedFrameSamplingProfileRaw) ?? .full
    }

    private var selectedProcessingBackend: ProcessingBackendChoice {
        switch selectedHomeProcessingMode {
        case .remote, .remoteV2:
            return .cloud
        case .local:
            return .localSubjectFirst
        }
    }

    private var effectiveSelectedProcessingBackend: ProcessingBackendChoice {
        selectedProcessingBackend
    }

    private var selectedHomeProcessingMode: HomeProcessingMode {
        HomeProcessingMode(rawValue: homeProcessingModeRaw) ?? .remote
    }

    private var homeLanguage: HomeLanguage {
        HomeLanguage(rawValue: homeLanguageRaw) ?? .zh
    }

    private var useEnglish: Bool {
        homeLanguage == .en
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                        infoBanner(
                            title: t("刚才没有成功", "That Just Failed"),
                            detail: errorMessage,
                            tint: .red
                        )
                    }

                    if !viewModel.processingRecords.isEmpty {
                        sectionTitle(t("处理中", "In Progress"))
                        recordGrid(viewModel.processingRecords)
                    }

                    if !viewModel.cancelledRecords.isEmpty {
                        sectionHeader(
                            title: t("已取消，可重发", "Cancelled, Ready to Resend"),
                            detail: t("这些任务已经停下来了，原始视频仍保留在手机里，随时可以按原处理方案重新发起。", "These jobs have stopped. The original videos are still on your phone, so you can resend them with the same processing setup at any time."),
                            tint: .orange
                        )
                        recordGrid(viewModel.cancelledRecords)
                    }

                    if !viewModel.failedRecords.isEmpty {
                        sectionHeader(
                            title: t("需要你处理", "Needs Attention"),
                            detail: t("这些任务没有拿到可用结果。你可以点开查看原因，再决定重试还是删除。", "These jobs did not produce a usable result. Open them to review the reason, then decide whether to retry or delete."),
                            tint: .red
                        )
                        recordGrid(viewModel.failedRecords)
                    }

                    if !viewModel.completedRecords.isEmpty {
                        sectionTitle(t("已完成作品", "Completed Results"))
                        recordGrid(viewModel.completedRecords)
                    }

                    if !viewModel.hasVisibleRecords && !viewModel.isLoading {
                        emptyStateView
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 120)
            }

            if viewModel.isLoading {
                loadingOverlay(title: t("正在加载作品", "Loading Results"), detail: t("请稍候...", "Please wait..."))
            }

            if viewModel.isImportingVideo, let busyMessage = viewModel.busyMessage {
                loadingOverlay(title: busyMessage, detail: t("这一步完成后会自动进入等待页。", "You will enter the waiting screen automatically after this step finishes."))
            }

            VStack {
                Spacer()
                actionBar
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .navigationTitle("Aether3D")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                languageToggleButton
            }
        }
        .onAppear {
            selectedProcessingBackendRaw = ProcessingBackendChoice.canonicalStoredSelectionRawValue(
                selectedProcessingBackendRaw
            )
            viewModel.loadRecords()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.loadRecords()
        }
        #if canImport(ARKit)
        .fullScreenCover(
            isPresented: $navigateToScan,
            onDismiss: {
                viewModel.loadRecords()
            }
        ) {
            ScanView(processingBackend: effectiveSelectedProcessingBackend)
        }
        .fullScreenCover(
            isPresented: $navigateToObjectModeV2,
            onDismiss: {
                viewModel.loadRecords()
            }
        ) {
            ObjectModeV2CaptureView()
        }
        #endif
        #if canImport(UIKit) && canImport(Metal)
        .fullScreenCover(
            isPresented: $showViewer,
            onDismiss: {
                viewModel.loadRecords()
                selectedRecord = nil
            }
        ) {
            if let record = selectedRecord {
                if record.isObjectFastPublishV1 {
                    ObjectFastPublishRecordViewer(
                        record: record,
                        homeViewModel: viewModel,
                        onDismiss: {
                            viewModel.loadRecords()
                            selectedRecord = nil
                            showViewer = false
                        }
                    )
                } else {
                    SplatViewerView(
                        record: record,
                        homeViewModel: viewModel,
                        onReturnHome: {
                            viewModel.loadRecords()
                            selectedRecord = nil
                            showViewer = false
                        }
                    )
                }
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView()
                        .tint(.white)
                }
            }
        }
        #endif
        #if canImport(PhotosUI)
        .onChange(of: selectedVideoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await MainActor.run {
                    viewModel.errorMessage = nil
                    viewModel.busyMessage = t("正在读取相册视频（大视频可能需要几分钟）...", "Reading the video from Photos (large files may take a few minutes)...")
                    viewModel.isImportingVideo = true
                    selectedRecord = nil
                    showViewer = false
                }

                defer {
                    Task { @MainActor in
                        selectedVideoItem = nil
                    }
                }

                do {
                    let movieURL = try await Self.loadPickedMovieURL(from: newValue) { message in
                        Task { @MainActor in
                            viewModel.busyMessage = message
                        }
                    }
                    guard let record = await viewModel.importVideo(
                        at: movieURL,
                        processingBackend: effectiveSelectedProcessingBackend
                    ) else {
                        await MainActor.run {
                            if viewModel.errorMessage?.isEmpty != false {
                                viewModel.errorMessage = t("相册视频已经选中，但没有成功进入上传流程，请再试一次。", "The video was selected, but it did not enter the upload flow successfully. Please try again.")
                            }
                        }
                        return
                    }

                    await MainActor.run {
                        selectedRecord = record
                        showViewer = false
                    }
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    await MainActor.run {
                        showViewer = true
                    }
                } catch {
                    await MainActor.run {
                        viewModel.errorMessage = "\(t("相册视频读取失败", "Failed to read the selected video")): \(Self.importErrorDescription(error))"
                        viewModel.busyMessage = nil
                        viewModel.isImportingVideo = false
                    }
                }
            }
        }
        #endif
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 18, weight: .semibold))
            .foregroundColor(.white)
    }

    private func sectionHeader(title: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(title)

            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
        }
    }

    private func recordGrid(_ records: [ScanRecord]) -> some View {
        LazyVGrid(columns: columns, spacing: 20) {
            ForEach(records) { record in
                ScanRecordCell(
                    record: record,
                    relativeTime: localizedRelativeTimeString(for: record.updatedAt),
                    useEnglish: useEnglish
                )
                .onTapGesture {
                    if record.canOpenStatusView {
                        selectedRecord = viewModel.refreshRecord(id: record.id) ?? record
                        showViewer = true
                    }
                }
                .contextMenu {
                    if record.isProcessing && record.resolvedProcessingBackend == .cloud {
                        Button(role: .destructive) {
                            viewModel.cancelRemoteRecord(record)
                        } label: {
                            Label(t("取消远端任务", "Cancel Remote Job"), systemImage: "xmark.circle")
                        }
                    }

                    if record.status == .failed {
                        Button {
                            viewModel.retryRecord(record)
                        } label: {
                            Label(
                                record.resolvedProcessingBackend.usesLocalPreviewPipeline
                                    ? t("重新运行本地处理", "Run Local Processing Again")
                                    : (record.isObjectFastPublishV1
                                        ? t("重试新远端", "Retry New Remote")
                                        : t("重试远端", "Retry Remote")),
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }

                    if record.status == .cancelled {
                        Button {
                            viewModel.retryRecord(record)
                        } label: {
                            Label(
                                record.resolvedProcessingBackend.usesLocalPreviewPipeline
                                    ? t("重新运行本地处理", "Run Local Processing Again")
                                    : (record.isObjectFastPublishV1
                                        ? t("重新发送到新远端", "Resend to New Remote")
                                        : t("重新发送到丹麦 5090", "Resend to Denmark 5090")),
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }

                    Button(role: .destructive) {
                        viewModel.deleteRecord(record)
                    } label: {
                        Label(t("删除", "Delete"), systemImage: "trash")
                    }
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "viewfinder.circle")
                .font(.system(size: 64))
                .foregroundColor(.gray)

            Text(t("尚无扫描作品", "No Scans Yet"))
                .font(.system(size: 17))
                .foregroundColor(.gray)

            Text(t("你可以直接拍摄，也可以先选一个已有视频，按远端高质量、新远端或本地处理三条方案处理。", "You can start recording right away, or choose an existing video and process it with remote high quality, new remote, or local processing."))
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.52))
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var actionBar: some View {
        VStack(spacing: 12) {
            if !viewModel.processingRecords.isEmpty {
                infoBanner(
                    title: processingBannerTitle,
                    detail: processingBannerDetail,
                    tint: .cyan
                )
            }

            processingBackendCard

            if effectiveSelectedProcessingBackend == .cloud {
                frameSamplingProfileCard
            }

            HStack(spacing: 12) {
                secondaryActionButton
                primaryActionButton
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .padding(.top, 12)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.0), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var hasLocalProcessingRecords: Bool {
        viewModel.processingRecords.contains { $0.resolvedProcessingBackend.usesLocalPreviewPipeline }
    }

    private var hasRemoteProcessingRecords: Bool {
        viewModel.processingRecords.contains { !$0.resolvedProcessingBackend.usesLocalPreviewPipeline }
    }

    private var processingBannerTitle: String {
        if hasLocalProcessingRecords && hasRemoteProcessingRecords {
            return t("任务正在处理中", "Jobs Are Running")
        }
        if hasLocalProcessingRecords {
            return t("本地任务正在处理", "Local Jobs Are Running")
        }
        return t("远端任务正在进行", "Remote Jobs Are Running")
    }

    private var processingBannerDetail: String {
        if hasLocalProcessingRecords && hasRemoteProcessingRecords {
            return t("有的作品在手机本地处理，有的作品在远端处理。你可以随时点开查看等待页，也可以先回主页稍后再看。", "Some results are processing on the phone and some are processing remotely. You can open any waiting screen at any time, or come back later.")
        }
        if hasLocalProcessingRecords {
            return t("本地方案会继续在手机上处理。你可以点开查看等待页，也可以先回主页稍后再看。", "The local pipeline will keep running on your phone. You can open the waiting screen now, or come back later.")
        }
        return t("远端方案会继续在后台处理。你可以点开查看等待页，也可以稍后回来继续。", "The remote pipeline will keep running in the background. You can open the waiting screen now, or come back later.")
    }

    private var primaryActionButton: some View {
        Button(action: {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            selectedRecord = nil
            showViewer = false
            if selectedHomeProcessingMode == .remoteV2 {
                navigateToObjectModeV2 = true
            } else {
                navigateToScan = true
            }
        }) {
            Text(t("开始拍摄", "Start Capture"))
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white)
                .cornerRadius(28)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var frameSamplingProfileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("训练速度方案", "Training Speed"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(t("全量保质量，半量和三分之一用更少的输入帧换更短的总耗时。拍摄和相册导入都会走这里的选择。", "Full keeps the highest quality. Half and one-third trade fewer input frames for shorter total runtime. Both capture and photo import use the selection here."))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.60))

            HStack(spacing: 10) {
                ForEach(FrameSamplingProfile.allCases, id: \.rawValue) { profile in
                    frameSamplingProfileButton(profile)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private var processingBackendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("处理方案", "Processing Mode"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text(t("这里先给你三条入口：远端高质量、新远端和本地处理。新远端是对象模式 V2 入口。", "There are three entry routes here: remote high quality, new remote, and local processing. New Remote is the Object Mode V2 entry."))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.60))

            HStack(spacing: 10) {
                processingModeButton(.remote)
                processingModeButton(.remoteV2)
                processingModeButton(.local)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func processingModeButton(_ mode: HomeProcessingMode) -> some View {
        let isSelected = selectedHomeProcessingMode == mode
        return Button {
            homeProcessingModeRaw = mode.rawValue
            selectedProcessingBackendRaw = canonicalBackend(for: mode).rawValue
        } label: {
            VStack(spacing: 5) {
                Image(systemName: processingModeIcon(mode))
                    .font(.system(size: 15, weight: .bold))

                Text(processingModeTitle(mode))
                    .font(.system(size: 15, weight: .bold))

                Text(processingModeDetail(mode))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? Color.black.opacity(0.70) : Color.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .foregroundColor(isSelected ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(processingModeBackground(mode: mode, isSelected: isSelected))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(processingModeStroke(mode: mode, isSelected: isSelected), lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func frameSamplingProfileButton(_ profile: FrameSamplingProfile) -> some View {
        let isSelected = selectedFrameSamplingProfile == profile
        return Button {
            selectedFrameSamplingProfileRaw = profile.rawValue
        } label: {
            VStack(spacing: 4) {
                Text(frameSamplingProfileTitle(profile))
                    .font(.system(size: 15, weight: .bold))
                Text(frameSamplingProfileDetail(profile))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? Color.black.opacity(0.70) : Color.white.opacity(0.58))
            }
            .foregroundColor(isSelected ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(isSelected ? Color.cyan : Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.cyan : Color.white.opacity(0.08), lineWidth: 1)
            )
            .cornerRadius(16)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var secondaryActionButton: some View {
        let useGuidedOnlyFlow = selectedHomeProcessingMode == .remoteV2
        let selectVideoTitle = useGuidedOnlyFlow
            ? (useEnglish ? "Guided Only" : "仅支持拍摄")
            : (useEnglish ? "Choose Video" : "选择视频")
        return Group {
            #if canImport(PhotosUI)
            if useGuidedOnlyFlow {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                    Text(selectVideoTitle)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.10), lineWidth: 1))
                .cornerRadius(28)
            } else {
                PhotosPicker(
                    selection: $selectedVideoItem,
                    matching: .videos,
                    photoLibrary: .shared()
                ) {
                    HStack(spacing: 8) {
                        Image(systemName: "film")
                        Text(selectVideoTitle)
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 28)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
                    .cornerRadius(28)
                }
            }
            #else
            Button(action: {}) {
                HStack(spacing: 8) {
                    Image(systemName: useGuidedOnlyFlow ? "viewfinder" : "film")
                    Text(selectVideoTitle)
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(Color.white.opacity(0.06))
                .cornerRadius(28)
            }
            .disabled(true)
            #endif
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func infoBanner(title: String, detail: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(tint)
                .frame(width: 10, height: 10)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.68))
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.06))
        )
    }

    private func loadingOverlay(title: String, detail: String) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.3)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white.opacity(0.65))
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color.white.opacity(0.08))
            )
        }
    }

}

private struct ObjectFastPublishRecordViewer: View {
    @Environment(\.scenePhase) private var scenePhase
    let record: ScanRecord
    @ObservedObject var homeViewModel: HomeViewModel
    let onDismiss: () -> Void

    @State private var currentRecord: ScanRecord
    @State private var refreshTask: Task<Void, Never>?
    @State private var showDefaultArtifact = false

    init(record: ScanRecord, homeViewModel: HomeViewModel, onDismiss: @escaping () -> Void) {
        self.record = record
        self.homeViewModel = homeViewModel
        self.onDismiss = onDismiss
        _currentRecord = State(initialValue: record)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let artifactURL, currentRecord.status == .completed {
                ObjectModeV2DefaultArtifactViewer(
                    url: artifactURL,
                    manifestURL: viewerManifestURL,
                    onDismiss: onDismiss
                )
            } else {
                ObjectModeV2ProcessingSurface(
                    snapshot: processingSnapshot,
                    onOpen: artifactURL != nil ? {
                        showDefaultArtifact = true
                    } : nil,
                    onClose: onDismiss
                )
            }
        }
        .fullScreenCover(isPresented: $showDefaultArtifact) {
            if let artifactURL {
                ObjectModeV2DefaultArtifactViewer(url: artifactURL, manifestURL: viewerManifestURL) {
                    showDefaultArtifact = false
                }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onAppear {
            forceRemoteRefresh()
            startRefreshLoop()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            forceRemoteRefresh()
        }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private var artifactURL: URL? {
        guard let relativePath = currentRecord.artifactPath, !relativePath.isEmpty else { return nil }
        return ScanRecordStore().baseDirectoryURL().appendingPathComponent(relativePath)
    }

    private var viewerManifestURL: URL? {
        guard let relativePath = currentRecord.runtimeMetrics?["local_viewer_manifest_path"],
              !relativePath.isEmpty else { return nil }
        return ScanRecordStore().baseDirectoryURL().appendingPathComponent(relativePath)
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("OBJECT MODE BETA")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.white.opacity(0.52))

            Text(currentRecord.displayStatusMessage)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(.white)

            Text(currentRecord.detailMessage ?? "新远端对象模式会先生成默认 surface 成品。")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.70))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contextCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                statusChip(title: "状态", value: currentRecord.status.rawValue.capitalized, tint: statusTint)
                statusChip(title: "进度", value: currentRecord.progressPercentText ?? "--", tint: .white.opacity(0.14))
            }

            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: min(max(currentRecord.displayProgressFraction, 0.02), currentRecord.status == .completed ? 1.0 : 0.99))
                    .tint(statusTint)

                HStack {
                    Text(currentRecord.remoteStageKey ?? "waiting")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                    Spacer()
                    if let eta = currentRecord.estimatedRemainingMinutes {
                        Text("约 \(eta) 分钟")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.white.opacity(0.60))
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func artifactReadyCard(artifactURL: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("默认 surface 已就绪")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(.white)

            Text("你可以先打开默认 surface 结果继续看。")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.68))

            HStack(spacing: 12) {
                Button(action: {
                    showDefaultArtifact = true
                }) {
                    Text("Open Default")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white)
                        .clipShape(Capsule())
                }

                ShareLink(item: artifactURL) {
                    Text("分享文件")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color(red: 0.10, green: 0.18, blue: 0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.green.opacity(0.30), lineWidth: 1)
                )
        )
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("任务详情")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)

            if let remoteJobId = currentRecord.remoteJobId, !remoteJobId.isEmpty {
                Text("Job ID: \(remoteJobId)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.55))
            }

            if let detail = currentRecord.detailMessage, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(Color.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 22)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func statusChip(title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var statusTint: Color {
        switch currentRecord.status {
        case .failed:
            return Color.red.opacity(0.22)
        case .completed:
            return Color.green.opacity(0.22)
        default:
            return Color.white.opacity(0.10)
        }
    }

    private var processingSnapshot: ObjectModeV2ProcessingSnapshot {
        let lockAccent = Color(red: 0.95, green: 0.79, blue: 0.12)
        #if canImport(UIKit)
        return ObjectModeV2ProcessingSnapshot(
            heroBadge: "OBJECT MODE BETA",
            heroTitle: processingHeroTitle,
            heroSubtitle: processingHeroSubtitle,
            heroImage: heroImage,
            canOpenArtifact: artifactURL != nil,
            isFailed: currentRecord.status == .failed,
            modeValue: "Guided",
            lockValue: "Open",
            lockAccent: lockAccent,
            stageCards: processingStageCards,
            stats: [
                .init(title: "Frames", value: acceptedFramesText),
                .init(title: "Orbit", value: orbitText),
                .init(title: "Status", value: processingStatusSummary)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。"
        )
        #else
        return ObjectModeV2ProcessingSnapshot(
            heroBadge: "OBJECT MODE BETA",
            heroTitle: processingHeroTitle,
            heroSubtitle: processingHeroSubtitle,
            canOpenArtifact: artifactURL != nil,
            isFailed: currentRecord.status == .failed,
            modeValue: "Guided",
            lockValue: "Open",
            lockAccent: lockAccent,
            stageCards: processingStageCards,
            stats: [
                .init(title: "Frames", value: acceptedFramesText),
                .init(title: "Orbit", value: orbitText),
                .init(title: "Status", value: processingStatusSummary)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。"
        )
        #endif
    }

    #if canImport(UIKit)
    private var heroImage: UIImage? {
        guard let relativePath = currentRecord.thumbnailPath, !relativePath.isEmpty else { return nil }
        let url = ScanRecordStore().baseDirectoryURL().appendingPathComponent(relativePath)
        return UIImage(contentsOfFile: url.path)
    }
    #endif

    private var acceptedFramesText: String {
        currentRecord.runtimeMetrics?["accepted_live_frames"] ?? "--"
    }

    private var orbitText: String {
        if let orbit = currentRecord.runtimeMetrics?["orbit_completion_percent"], !orbit.isEmpty {
            return "\(orbit)%"
        }
        return "--"
    }

    private var processingStatusSummary: String {
        switch currentRecord.status {
        case .failed:
            return "Failed"
        case .completed:
            return "Done"
        case .queued:
            return "Queued"
        default:
            return "Live"
        }
    }

    private var processingHeroTitle: String {
        switch currentRecord.status {
        case .failed:
            return "对象成品生成失败"
        case .completed:
            return "对象成品已完成"
        default:
            return "正在生成对象成品"
        }
    }

    private var processingHeroSubtitle: String {
        if let detail = currentRecord.detailMessage, !detail.isEmpty {
            return detail
        }
        if currentRecord.status == .failed {
            return currentRecord.failureReason ?? "远端任务失败。"
        }
        return "系统会先生成默认 surface 成品；下载完成后即可打开。"
    }

    private var processingStageCards: [ObjectModeV2StageCard] {
        [
            ObjectModeV2StageCard(
                id: .defaultStage,
                title: "Default",
                subtitle: "默认成品",
                state: defaultStageState
            ),
            ObjectModeV2StageCard(
                id: .hq,
                title: "HQ",
                subtitle: "高清成品",
                state: hqStageState
            )
        ]
    }

    private var defaultStageState: ObjectModeV2StageUIState {
        if currentRecord.status == .failed {
            return .failed(currentRecord.failureReason ?? currentRecord.detailMessage)
        }
        if artifactURL != nil || currentRecord.status == .completed {
            return .ready
        }
        return .processing(defaultStageProgress)
    }

    private var hqStageState: ObjectModeV2StageUIState {
        if currentRecord.status == .failed {
            return .idle
        }
        if currentRecord.status == .completed {
            return .ready
        }

        let stageKey = normalizedStageKey
        switch stageKey {
        default:
            return .idle
        }
    }

    private var defaultStageProgress: Double {
        let fraction = currentRecord.displayProgressFraction
        switch normalizedStageKey {
        case "queued":
            return max(fraction, 0.18)
        case "curate":
            return max(fraction, 0.22)
        case "slam3r_reconstruct":
            return max(fraction, 0.48)
        case "slam3r_scene_contract":
            return max(fraction, 0.58)
        case "sparse2dgs_surface":
            return max(fraction, 0.68)
        case "publish_default_surface":
            return max(fraction, 0.82)
        case "artifact_upload":
            return max(fraction, 0.90)
        default:
            return max(fraction, 0.12)
        }
    }

    private var normalizedStageKey: String {
        (currentRecord.remoteStageKey ?? currentRecord.runtimeMetrics?["remote_stage_key"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private func refreshCurrentRecord() {
        currentRecord = homeViewModel.refreshRecord(id: record.id) ?? currentRecord
    }

    private func forceRemoteRefresh() {
        refreshCurrentRecord()
        homeViewModel.resumeRemoteJobIfNeeded(currentRecord, force: true)
    }

    private func startRefreshLoop() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                refreshCurrentRecord()
                homeViewModel.resumeRemoteJobIfNeeded(currentRecord, force: false)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
}

private extension HomePage {
    var languageToggleButton: some View {
        Button {
            homeLanguageRaw = useEnglish ? HomeLanguage.zh.rawValue : HomeLanguage.en.rawValue
        } label: {
            Text("中/A")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(t("切换中英文", "Switch Language"))
    }

    func t(_ zh: String, _ en: String) -> String {
        useEnglish ? en : zh
    }

    func localizedRelativeTimeString(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: useEnglish ? "en_US" : "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    func frameSamplingProfileTitle(_ profile: FrameSamplingProfile) -> String {
        if !useEnglish {
            return profile.title
        }
        switch profile {
        case .full:
            return "Full"
        case .half:
            return "1/2"
        case .third:
            return "1/3"
        }
    }

    func frameSamplingProfileDetail(_ profile: FrameSamplingProfile) -> String {
        if !useEnglish {
            return profile.detail
        }
        switch profile {
        case .full:
            return "200 frames"
        case .half:
            return "100 frames"
        case .third:
            return "67 frames"
        }
    }

    private func canonicalBackend(for mode: HomeProcessingMode) -> ProcessingBackendChoice {
        switch mode {
        case .remote, .remoteV2:
            return .cloud
        case .local:
            return .localSubjectFirst
        }
    }

    private func processingModeTitle(_ mode: HomeProcessingMode) -> String {
        if !useEnglish {
            switch mode {
            case .remote:
                return "远端"
            case .remoteV2:
                return "新远端"
            case .local:
                return "本地"
            }
        }
        switch mode {
        case .remote:
            return "Remote"
        case .remoteV2:
            return "New Remote"
        case .local:
            return "Local"
        }
    }

    private func processingModeDetail(_ mode: HomeProcessingMode) -> String {
        if !useEnglish {
            switch mode {
            case .remote:
                return "高质量"
            case .remoteV2:
                return "对象模式 V2"
            case .local:
                return "本地处理"
            }
        }
        switch mode {
        case .remote:
            return "High Quality"
        case .remoteV2:
            return "Object Mode V2"
        case .local:
            return "Local Processing"
        }
    }

    private func processingModeIcon(_ mode: HomeProcessingMode) -> String {
        switch mode {
        case .remote:
            return "cloud.fill"
        case .remoteV2:
            return "sparkles"
        case .local:
            return "iphone.gen3"
        }
    }

    private func processingModeBackground(mode: HomeProcessingMode, isSelected: Bool) -> Color {
        guard isSelected else { return Color.white.opacity(0.06) }
        switch mode {
        case .remote:
            return .white
        case .remoteV2:
            return Color(red: 0.82, green: 0.94, blue: 0.55)
        case .local:
            return Color(red: 0.28, green: 0.83, blue: 0.58)
        }
    }

    private func processingModeStroke(mode: HomeProcessingMode, isSelected: Bool) -> Color {
        guard isSelected else { return Color.white.opacity(0.08) }
        switch mode {
        case .remote:
            return .white
        case .remoteV2:
            return Color(red: 0.82, green: 0.94, blue: 0.55)
        case .local:
            return Color(red: 0.28, green: 0.83, blue: 0.58)
        }
    }

    static func importErrorDescription(_ error: Error) -> String {
        let nsError = error as NSError
        let message = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || message == "The operation couldn’t be completed." {
            return "\(nsError.domain)(\(nsError.code))"
        }
        return message
    }

    static func loadPickedMovieURL(
        from item: PhotosPickerItem,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        var photoLibraryError: Error?
        #if canImport(Photos)
        if let itemIdentifier = item.itemIdentifier {
            progress("正在从相册导出原始视频...")
            do {
                if let url = try await loadMovieURLFromPhotoLibrary(
                    identifier: itemIdentifier,
                    progress: progress
                ) {
                    return url
                }
            } catch {
                photoLibraryError = error
            }
        }
        #endif

        progress("正在读取相册视频（大视频可能需要几分钟）...")
        if let movie = try await withTimeout(
            seconds: 180,
            timeoutMessage: "读取照片库超时，请保持当前页面打开，或稍后再试"
        , operation: {
            try await item.loadTransferable(type: PickedMovie.self)
        }) {
            return movie.url
        }

        if let photoLibraryError {
            throw photoLibraryError
        }

        throw NSError(
            domain: "Aether3D.PhotoImport",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "没有拿到可用的视频文件"]
        )
    }

    #if canImport(Photos)
    static func loadMovieURLFromPhotoLibrary(
        identifier: String,
        progress: @escaping @Sendable (String) -> Void
    ) async throws -> URL? {
        final class ResumeGate: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false

            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                guard resumed == false else { return false }
                resumed = true
                return true
            }
        }

        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil)
        guard let asset = fetchResult.firstObject else {
            return nil
        }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video || $0.type == .pairedVideo }) else {
            return nil
        }

        let tempDirectory = FileManager.default.temporaryDirectory
        let ext = (resource.originalFilename as NSString).pathExtension
        let targetURL = tempDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext.isEmpty ? "mov" : ext)

        if FileManager.default.fileExists(atPath: targetURL.path) {
            try FileManager.default.removeItem(at: targetURL)
        }
        let totalBytes = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { value in
            guard let totalBytes, totalBytes > 0 else {
                progress("正在从相册导出原始视频...")
                return
            }
            let uploaded = Int64(Double(totalBytes) * value)
            progress("正在从相册导出原始视频 \(formattedSize(uploaded)) / \(formattedSize(totalBytes))")
        }

        return try await withCheckedThrowingContinuation { continuation in
            let gate = ResumeGate()
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard gate.claim() else { return }
                try? FileManager.default.removeItem(at: targetURL)
                continuation.resume(
                    throwing: NSError(
                        domain: "Aether3D.PhotoImport",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "从相册导出原始视频超时，请保持当前页面打开，或稍后再试"]
                    )
                )
            }

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: targetURL,
                options: options,
                completionHandler: { error in
                    timeoutTask.cancel()
                    guard gate.claim() else { return }
                    if let error {
                        try? FileManager.default.removeItem(at: targetURL)
                        continuation.resume(throwing: error)
                        return
                    }

                    continuation.resume(returning: targetURL)
                }
            )
        }
    }
    #endif

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        timeoutMessage: String = "读取照片库超时，请换一个本地视频或稍后再试",
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let duration = UInt64(seconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: duration)
                throw NSError(
                    domain: "Aether3D.PhotoImport",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: timeoutMessage]
                )
            }

            let result = try await group.next()
            group.cancelAll()
            return try result.unwrap()
        }
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.includesCount = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes).replacingOccurrences(of: "Zero", with: "0")
    }
}

private extension Optional {
    func unwrap() throws -> Wrapped {
        guard let value = self else {
            throw NSError(
                domain: "Aether3D.PhotoImport",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "没有拿到可用的视频文件"]
            )
        }
        return value
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#if canImport(PhotosUI)
private struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let tempDirectory = FileManager.default.temporaryDirectory
            let targetURL = tempDirectory.appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(received.file.pathExtension)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                try FileManager.default.removeItem(at: targetURL)
            }
            try FileManager.default.copyItem(at: received.file, to: targetURL)
            return PickedMovie(url: targetURL)
        }
    }
}
#endif

#endif
