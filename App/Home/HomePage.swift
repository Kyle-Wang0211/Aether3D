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
    @StateObject private var viewModel = HomeViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FrameSamplingProfile.userDefaultsKey) private var selectedFrameSamplingProfileRaw = FrameSamplingProfile.full.rawValue
    @AppStorage(ProcessingBackendChoice.userDefaultsKey) private var selectedProcessingBackendRaw = ProcessingBackendChoice.cloud.rawValue
    @State private var navigateToScan = false
    @State private var scanDestinationFactory: (() -> AnyView)?
    @State private var selectedRecord: ScanRecord?
    @State private var showViewer = false
    @State private var hasResetLaunchPresentationState = false

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
        ProcessingBackendChoice(rawValue: selectedProcessingBackendRaw) ?? .cloud
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    heroSection

                    if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                        infoBanner(
                            title: "刚才没有成功",
                            detail: errorMessage,
                            tint: .red
                        )
                    }

                    if !viewModel.processingRecords.isEmpty {
                        sectionTitle("处理中")
                        recordGrid(viewModel.processingRecords)
                    }

                    if !viewModel.cancelledRecords.isEmpty {
                        sectionHeader(
                            title: "已取消，可重发",
                            detail: "这些任务已经停下来了，原始视频仍保留在手机里，随时可以按原处理方案重新发起。",
                            tint: .orange
                        )
                        recordGrid(viewModel.cancelledRecords)
                    }

                    if !viewModel.failedRecords.isEmpty {
                        sectionHeader(
                            title: "需要你处理",
                            detail: "这些任务没有拿到可用结果。你可以点开查看原因，再决定重试还是删除。",
                            tint: .red
                        )
                        recordGrid(viewModel.failedRecords)
                    }

                    if !viewModel.completedRecords.isEmpty {
                        sectionTitle("已完成作品")
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
                loadingOverlay(title: "正在加载作品", detail: "请稍候...")
            }

            if viewModel.isImportingVideo, let busyMessage = viewModel.busyMessage {
                loadingOverlay(title: busyMessage, detail: "这一步完成后会自动进入等待页。")
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
        .onAppear {
            if !hasResetLaunchPresentationState {
                hasResetLaunchPresentationState = true
                navigateToScan = false
                scanDestinationFactory = nil
                selectedRecord = nil
                showViewer = false
            }
            viewModel.loadRecords()
        }
        .onChange(of: scenePhase) { newPhase in
            guard newPhase == .active else { return }
            viewModel.loadRecords()
        }
        #if canImport(ARKit)
        .fullScreenCover(
            isPresented: $navigateToScan,
            onDismiss: {
                scanDestinationFactory = nil
                viewModel.loadRecords()
            }
        ) {
            if let scanDestinationFactory {
                scanDestinationFactory()
            } else {
                EmptyView()
            }
        }
        #endif
        #if canImport(UIKit) && canImport(Metal)
        .navigationDestination(isPresented: $showViewer) {
            if let record = selectedRecord {
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
        }
        #endif
        #if canImport(PhotosUI)
        .onChange(of: selectedVideoItem) { newValue in
            guard let newValue else { return }
            Task {
                await MainActor.run {
                    viewModel.errorMessage = nil
                    viewModel.busyMessage = "正在读取相册视频（大视频可能需要几分钟）..."
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
                        processingBackend: selectedProcessingBackend
                    ) else {
                        await MainActor.run {
                            if viewModel.errorMessage?.isEmpty != false {
                                viewModel.errorMessage = "相册视频已经选中，但没有成功进入上传流程，请再试一次。"
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
                        viewModel.errorMessage = "相册视频读取失败：\(Self.importErrorDescription(error))"
                        viewModel.busyMessage = nil
                        viewModel.isImportingVideo = false
                    }
                }
            }
        }
        #endif
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("极简白盒闭环")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.white)

            Text("从手机拍摄与审核开始，把视频送到丹麦 5090 训练，再把 3DGS 自动回传到本地查看。")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.72))

            HStack(spacing: 10) {
                tag("手机拍摄")
                tag("实时审核")
                tag("丹麦 5090")
                tag("3DGS 查看")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 24)
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.08), Color.white.opacity(0.03)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
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
                    relativeTime: viewModel.relativeTimeString(for: record.updatedAt)
                )
                .onTapGesture {
                    if record.canOpenStatusView {
                        selectedRecord = viewModel.refreshRecord(id: record.id) ?? record
                        showViewer = true
                    }
                }
                .contextMenu {
                    if record.isProcessing {
                        Button(role: .destructive) {
                            viewModel.cancelRemoteRecord(record)
                        } label: {
                            Label("取消远端任务", systemImage: "xmark.circle")
                        }
                    }

                    if record.status == .failed {
                        Button {
                            viewModel.retryRecord(record)
                        } label: {
                            Label(
                                record.resolvedProcessingBackend == .localPreview
                                    ? "重新运行本地快速预览"
                                    : "重试远端",
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }

                    if record.status == .cancelled {
                        Button {
                            viewModel.retryRecord(record)
                        } label: {
                            Label(
                                record.resolvedProcessingBackend == .localPreview
                                    ? "重新运行本地快速预览"
                                    : "重新发送到丹麦 5090",
                                systemImage: "arrow.clockwise"
                            )
                        }
                    }

                    Button(role: .destructive) {
                        viewModel.deleteRecord(record)
                    } label: {
                        Label("删除", systemImage: "trash")
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

            Text("尚无扫描作品")
                .font(.system(size: 17))
                .foregroundColor(.gray)

            Text("你可以直接拍摄，也可以先选一个已有视频，按云端高质量或本地快速预览两条方案处理。")
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
                    title: "远端任务正在进行",
                    detail: "处理中的作品可以随时点开查看等待页，也可以稍后回来继续。",
                    tint: .cyan
                )
            }

            processingBackendCard

            frameSamplingProfileCard

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

    private var primaryActionButton: some View {
        Button(action: {
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            #if canImport(ARKit)
            scanDestinationFactory = { AnyView(ScanView()) }
            #endif
            navigateToScan = true
        }) {
            Text("开始拍摄")
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
            Text("训练速度方案")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("全量保质量，半量和三分之一用更少的输入帧换更短的总耗时。拍摄和相册导入都会走这里的选择。")
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
            Text("处理方案")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
            Text("云端高质量会继续走当前成功链。本地快速预览现在支持直接拍摄和相册导入，优先给出单目 preview；复杂场景仍建议优先选云端。")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.60))

            HStack(spacing: 10) {
                ForEach(ProcessingBackendChoice.allCases, id: \.rawValue) { backend in
                    processingBackendButton(backend)
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

    private func processingBackendButton(_ backend: ProcessingBackendChoice) -> some View {
        let isSelected = selectedProcessingBackend == backend
        return Button {
            selectedProcessingBackendRaw = backend.rawValue
        } label: {
            VStack(spacing: 4) {
                Text(backend.title)
                    .font(.system(size: 15, weight: .bold))
                Text(backend.detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(isSelected ? Color.black.opacity(0.70) : Color.white.opacity(0.58))
            }
            .foregroundColor(isSelected ? .black : .white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(isSelected ? Color.white : Color.white.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.white : Color.white.opacity(0.08), lineWidth: 1)
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
                Text(profile.title)
                    .font(.system(size: 15, weight: .bold))
                Text(profile.detail)
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
        Group {
            #if canImport(PhotosUI)
            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                HStack(spacing: 8) {
                    Image(systemName: "film")
                    Text("选择视频")
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
            #else
            Button(action: {}) {
                HStack(spacing: 8) {
                    Image(systemName: "film")
                    Text("选择视频")
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

    private func tag(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06))
            .cornerRadius(999)
    }
}

private extension HomePage {
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
