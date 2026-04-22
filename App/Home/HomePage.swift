//
// HomePage.swift
// Aether3D
//
// Figma-aligned home and capture flow
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

enum AetherChromePalette {
    static let canvas = Color(red: 0.96, green: 0.95, blue: 0.94)
    static let primary = Color(red: 0.12, green: 0.23, blue: 0.18)
    static let primarySoft = Color(red: 0.67, green: 0.71, blue: 0.64)
    static let danger = Color(red: 0.79, green: 0.29, blue: 0.23)
    static let warning = Color(red: 0.84, green: 0.63, blue: 0.22)
    static let info = Color(red: 0.29, green: 0.47, blue: 0.84)
    static let textPrimary = Color(red: 0.11, green: 0.11, blue: 0.10)
    static let textSecondary = Color(red: 0.38, green: 0.42, blue: 0.39)
    static let border = Color(red: 0.88, green: 0.86, blue: 0.82)
    static let white = Color.white
    static let shadow = Color.black.opacity(0.08)
}

enum AetherRootTab: String, CaseIterable, Identifiable {
    case home
    case tasks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home:
            return "首页"
        case .tasks:
            return "任务"
        }
    }

    var systemImage: String {
        switch self {
        case .home:
            return "house.fill"
        case .tasks:
            return "list.bullet.rectangle.portrait.fill"
        }
    }
}

enum AetherCaptureMode: String, CaseIterable, Identifiable, Hashable {
    case remoteLegacy
    case newRemote
    case local

    var id: String { rawValue }

    var title: String {
        switch self {
        case .remoteLegacy:
            return "远端方案"
        case .newRemote:
            return "新远端"
        case .local:
            return "本地方案"
        }
    }

    var subtitle: String {
        switch self {
        case .remoteLegacy:
            return "兼容旧版云端高质量链路，适合继续做远端样本对照。"
        case .newRemote:
            return "对象模式 Beta，优先面向现场拍摄，先回 Preview 再继续升级结果。"
        case .local:
            return "手机本地处理，适合快速验证、离线场景和保守导出。"
        }
    }

    var detailTitle: String {
        switch self {
        case .remoteLegacy:
            return "适合稳定复现旧远端流程"
        case .newRemote:
            return "适合作为新版主拍摄入口"
        case .local:
            return "适合网络不稳定时快速出结果"
        }
    }

    var detailBody: String {
        switch self {
        case .remoteLegacy:
            return "拍摄完成后会走远端上传、排队、预处理、训练和回传，反馈稳定但整体耗时更长。"
        case .newRemote:
            return "现场 Guided 拍摄后，系统会持续拉取新远端对象流程状态，并把默认结果与 HQ 状态回收到首页。"
        case .local:
            return "拍摄或导入后会在设备上继续跑本地处理链路，适合先验证数据可用性。"
        }
    }

    var shortBadge: String? {
        switch self {
        case .newRemote:
            return "推荐"
        case .remoteLegacy, .local:
            return nil
        }
    }

    var systemImage: String {
        switch self {
        case .remoteLegacy:
            return "cloud"
        case .newRemote:
            return "sparkles"
        case .local:
            return "iphone.gen3"
        }
    }

    var accentColor: Color {
        switch self {
        case .remoteLegacy:
            return AetherChromePalette.primarySoft
        case .newRemote:
            return AetherChromePalette.primary
        case .local:
            return AetherChromePalette.info
        }
    }

    var processingBackend: ProcessingBackendChoice {
        switch self {
        case .remoteLegacy, .newRemote:
            return .cloud
        case .local:
            return .localSubjectFirst
        }
    }

    var legacyHomeModeRawValue: String {
        switch self {
        case .remoteLegacy:
            return "remote"
        case .newRemote:
            return "remoteV2"
        case .local:
            return "local"
        }
    }

    var supportsVideoImport: Bool {
        self != .newRemote
    }
}

extension ScanRecord {
    var shellPreferredCaptureMode: AetherCaptureMode {
        if isObjectFastPublishV1 {
            return .newRemote
        }
        return resolvedProcessingBackend.usesLocalPreviewPipeline ? .local : .remoteLegacy
    }

    var shellModeTitle: String {
        shellPreferredCaptureMode.title
    }

    var shellStatusTitle: String {
        if isInspectionOnlyCandidate {
            return "待质检"
        }
        switch status {
        case .preparing:
            return "准备中"
        case .uploading:
            return "上传中"
        case .queued:
            return "排队中"
        case .reconstructing:
            return "处理中"
        case .training:
            return "训练中"
        case .packaging:
            return "导出中"
        case .downloading:
            return "回传中"
        case .localFallback:
            return "本地处理中"
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case .failed:
            return isObjectFastPublishV1 ? "训练失败" : "处理失败"
        }
    }

    var shellStatusColor: Color {
        if isInspectionOnlyCandidate {
            return AetherChromePalette.warning
        }
        switch status {
        case .completed:
            return AetherChromePalette.primary
        case .cancelled:
            return AetherChromePalette.warning
        case .failed:
            return AetherChromePalette.danger
        case .localFallback:
            return AetherChromePalette.warning
        case .uploading, .queued, .reconstructing, .training, .packaging, .downloading, .preparing:
            return AetherChromePalette.primary
        }
    }

    var shellStatusDetail: String {
        if let detailMessage, !detailMessage.isEmpty {
            return detailMessage
        }
        if let meta = galleryStatusMetaText, !meta.isEmpty {
            return meta
        }
        return displayStatusMessage
    }

    var shellStatusProgress: Double? {
        switch status {
        case .completed, .cancelled, .failed:
            return nil
        default:
            return min(max(displayProgressFraction, 0.02), 0.99)
        }
    }

    var shellNeedsAttention: Bool {
        status == .failed || status == .cancelled
    }

    var shellHasFinishedResult: Bool {
        artifactPath != nil || status == .completed
    }

    var shellCanRetry: Bool {
        status == .failed || status == .cancelled
    }

    var shellSupportsRemoteCancel: Bool {
        isProcessing && resolvedProcessingBackend == .cloud
    }
}

struct AetherSectionHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundColor(AetherChromePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AetherRootTabBar: View {
    @Binding var selectedTab: AetherRootTab

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AetherRootTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 16, weight: .semibold))
                        Text(tab.title)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(selectedTab == tab ? .white : AetherChromePalette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 58)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(selectedTab == tab ? AetherChromePalette.primary : Color.clear)
                    )
                }
                .buttonStyle(AetherScaleButtonStyle())
            }
        }
        .padding(8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AetherChromePalette.border.opacity(0.7), lineWidth: 1)
        )
        .shadow(color: AetherChromePalette.shadow, radius: 18, y: 8)
    }
}

struct AetherPrimaryActionButton: View {
    let title: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            }
            Text(title)
                .font(.system(size: 16, weight: .semibold))
        }
        .foregroundColor(.white)
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .background(AetherChromePalette.primary)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct AetherSecondaryActionButton: View {
    let title: String
    var foreground: Color = AetherChromePalette.textPrimary
    var background: Color = AetherChromePalette.white
    var border: Color = AetherChromePalette.border

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
    }
}

struct AetherLoadingOverlay: View {
    let title: String
    let detail: String

    var body: some View {
        ZStack {
            AetherChromePalette.canvas.opacity(0.92).ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .tint(AetherChromePalette.primary)
                    .scaleEffect(1.2)
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AetherChromePalette.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .multilineTextAlignment(.center)
                    .foregroundColor(AetherChromePalette.textSecondary)
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AetherChromePalette.white)
            )
            .shadow(color: AetherChromePalette.shadow, radius: 18, y: 10)
        }
    }
}

private struct AetherLayoutMetrics {
    let width: CGFloat
    let safeBottom: CGFloat

    var isNarrowPhone: Bool { width < 390 }
    var isVeryNarrowPhone: Bool { width < 350 }
    var horizontalPadding: CGFloat { isNarrowPhone ? 12 : 16 }
    var gridSpacing: CGFloat { isNarrowPhone ? 12 : 16 }
    var topPadding: CGFloat { isNarrowPhone ? 18 : 22 }
    var contentBottomPadding: CGFloat { safeBottom > 0 ? 118 : 96 }
    var shellHorizontalPadding: CGFloat { isNarrowPhone ? 16 : 24 }
    var shellBottomPadding: CGFloat { safeBottom > 0 ? 8 : 12 }
    var fabSize: CGFloat { 56 }
    var compactCardLayout: Bool { isNarrowPhone }
    var usesSingleColumnGallery: Bool { width < 320 }
    var homeTitleSize: CGFloat { isNarrowPhone ? 27 : 30 }
    var heroTitleSize: CGFloat { isNarrowPhone ? 24 : 30 }
    var taskThumbnailWidth: CGFloat { isNarrowPhone ? 96 : 116 }
    var taskThumbnailHeight: CGFloat { isNarrowPhone ? 92 : 104 }
    var compactActionLayout: Bool { isNarrowPhone }
}

struct AetherScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct AetherAppShell: View {
    private struct CapturePlanRoute: Hashable, Identifiable {
        let id = UUID()
        let mode: AetherCaptureMode
    }

    @StateObject private var homeViewModel = HomeViewModel()
    @State private var selectedTab: AetherRootTab = .home
    @State private var route: CapturePlanRoute?
    @AppStorage("aether3d.home.captureMode") private var lastCaptureModeRawValue = AetherCaptureMode.newRemote.rawValue

    var body: some View {
        GeometryReader { proxy in
            let metrics = AetherLayoutMetrics(
                width: proxy.size.width,
                safeBottom: proxy.safeAreaInsets.bottom
            )

            ZStack {
                AetherChromePalette.canvas
                    .ignoresSafeArea()

                Group {
                    switch selectedTab {
                    case .home:
                        HomePage(viewModel: homeViewModel)
                    case .tasks:
                        TaskCenterPage(viewModel: homeViewModel)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomChrome(metrics: metrics)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .navigationDestination(item: $route) { route in
            CaptureModeSelectionPage(viewModel: homeViewModel, initialMode: route.mode)
        }
    }

    private func bottomChrome(metrics: AetherLayoutMetrics) -> some View {
        ZStack(alignment: .bottomTrailing) {
            AetherRootTabBar(selectedTab: $selectedTab)
                .padding(.trailing, metrics.fabSize + 18)

            Button(action: openCapturePlanFromLastSelection) {
                ZStack {
                    Circle()
                        .fill(AetherChromePalette.primary)
                        .frame(width: metrics.fabSize, height: metrics.fabSize)
                        .shadow(color: Color.black.opacity(0.14), radius: 16, y: 8)

                    Image(systemName: "camera")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(AetherScaleButtonStyle())
            .padding(.trailing, 12)
            .padding(.bottom, 28)
            .accessibilityLabel("进入拍摄方案选择页")
        }
        .padding(.horizontal, metrics.shellHorizontalPadding)
        .padding(.top, 8)
        .padding(.bottom, metrics.shellBottomPadding)
    }

    private func openCapturePlanFromLastSelection() {
        let mode = AetherCaptureMode(rawValue: lastCaptureModeRawValue) ?? .newRemote
        route = CapturePlanRoute(mode: mode)
    }
}

private struct AetherDebugGLBEntry: Identifiable {
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date
    var id: String { url.path }
    var displayName: String { url.lastPathComponent }
    var displaySize: String {
        let mb = Double(sizeBytes) / 1_048_576.0
        return mb >= 1.0 ? String(format: "%.1f MB", mb) : String(format: "%.0f KB", Double(sizeBytes) / 1024.0)
    }
}

struct HomePage: View {
    @ObservedObject private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedRecord: ScanRecord?
    @State private var showViewer = false
    @State private var captureModeRoute: AetherCaptureMode?
    @State private var showDebugGLBBrowser = false
    @State private var debugGLBEntries: [AetherDebugGLBEntry] = []
    @State private var debugViewerItem: AetherDebugGLBEntry?
    @AppStorage("aether3d.home.captureMode") private var lastCaptureModeRawValue = AetherCaptureMode.newRemote.rawValue

    init(viewModel: HomeViewModel = HomeViewModel()) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    private func loadDebugGLBList() {
        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        guard let docsURL else { debugGLBEntries = []; return }
        var results: [AetherDebugGLBEntry] = []
        if let items = try? FileManager.default.contentsOfDirectory(
            at: docsURL,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            for url in items where url.pathExtension.lowercased() == "glb" {
                let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                results.append(AetherDebugGLBEntry(
                    url: url,
                    sizeBytes: Int64((values?.fileSize) ?? 0),
                    modifiedAt: values?.contentModificationDate ?? Date.distantPast
                ))
            }
        }
        results.sort { $0.modifiedAt > $1.modifiedAt }
        debugGLBEntries = results
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = AetherLayoutMetrics(
                width: proxy.size.width,
                safeBottom: proxy.safeAreaInsets.bottom
            )

            ZStack(alignment: .bottomTrailing) {
                AetherChromePalette.canvas
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        header(metrics: metrics)
                        content(metrics: metrics)
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.contentBottomPadding)
                }

                floatingCaptureButton(metrics: metrics)
                    .padding(.trailing, metrics.horizontalPadding)
                    .padding(.bottom, metrics.safeBottom + 16)

                if viewModel.isLoading {
                    AetherLoadingOverlay(title: "正在加载作品", detail: "请稍候...")
                }

                if viewModel.isImportingVideo, let busyMessage = viewModel.busyMessage {
                    AetherLoadingOverlay(title: busyMessage, detail: "导入完成后结果会回到首页。")
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .navigationDestination(item: $captureModeRoute) { mode in
            CaptureModeSelectionPage(viewModel: viewModel, initialMode: mode)
        }
        .sheet(isPresented: $showDebugGLBBrowser) {
            debugGLBBrowserSheet()
        }
        .fullScreenCover(item: $debugViewerItem) { entry in
            ObjectModeV2DefaultArtifactViewer(
                url: entry.url,
                manifestURL: nil,
                processingDurationLabel: entry.displaySize
            ) {
                debugViewerItem = nil
            }
        }
        .onAppear {
            viewModel.loadRecords()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.loadRecords()
        }
        #if canImport(UIKit) && canImport(Metal)
        .fullScreenCover(
            isPresented: $showViewer,
            onDismiss: {
                viewModel.loadRecords()
                selectedRecord = nil
            }
        ) {
            if let record = selectedRecord {
                AetherRecordViewerScreen(
                    record: record,
                    homeViewModel: viewModel,
                    onDismiss: {
                        viewModel.loadRecords()
                        selectedRecord = nil
                        showViewer = false
                    }
                )
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        }
        #endif
    }

    private func header(metrics: AetherLayoutMetrics) -> some View {
        HStack {
            Spacer()

            Text("AETHER3D")
                .font(.system(size: metrics.homeTitleSize, weight: .bold))
                .foregroundColor(AetherChromePalette.primary)
                .tracking(-0.75)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.8) {
                    loadDebugGLBList()
                    showDebugGLBBrowser = true
                }

            Spacer()
        }
        .frame(height: metrics.isNarrowPhone ? 56 : 60)
        .padding(.bottom, 18)
    }

    @ViewBuilder
    private func debugGLBBrowserSheet() -> some View {
        NavigationStack {
            List {
                if debugGLBEntries.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Documents/ 目录里没有 .glb 文件").font(.subheadline)
                        Text("用 `xcrun devicectl device copy to` 推文件进 app 沙盒后再长按进入。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(debugGLBEntries) { entry in
                            Button {
                                showDebugGLBBrowser = false
                                debugViewerItem = entry
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.displayName)
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(.primary)
                                    HStack(spacing: 8) {
                                        Text(entry.displaySize)
                                        Text("·")
                                        Text(entry.modifiedAt, style: .relative)
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    } header: {
                        Text("本地 GLB (Documents/)")
                    } footer: {
                        Text("点击任意条目直接用 HQ 查看器打开。长按 AETHER3D 标题可重新打开此页。")
                            .font(.caption2)
                    }
                }
            }
            .navigationTitle("Debug: 本地 GLB")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("刷新") { loadDebugGLBList() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showDebugGLBBrowser = false }
                }
            }
        }
    }

    @ViewBuilder
    private func content(metrics: AetherLayoutMetrics) -> some View {
        if allVisibleRecords.isEmpty && !viewModel.isLoading {
            emptyState(metrics: metrics)
        } else {
            gallery(metrics: metrics)
        }
    }

    private func emptyState(metrics: AetherLayoutMetrics) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 120)

            ZStack {
                RoundedRectangle(cornerRadius: 32, style: .continuous)
                    .fill(AetherChromePalette.white)
                    .frame(width: 132, height: 132)
                    .shadow(color: Color.black.opacity(0.06), radius: 18, y: 10)

                Image(systemName: "cube.transparent")
                    .font(.system(size: 38, weight: .regular))
                    .foregroundColor(AetherChromePalette.primary)
            }

            Text("还没有第一件作品")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AetherChromePalette.textPrimary)

            Text("点击右下角进入拍摄方案选择页。先选远端方案、新远端或本地方案，确认后再正式进入对应拍摄流程。")
                .font(.system(size: 14))
                .foregroundColor(AetherChromePalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer(minLength: 120)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func gallery(metrics: AetherLayoutMetrics) -> some View {
        if metrics.usesSingleColumnGallery {
            VStack(spacing: metrics.gridSpacing) {
                ForEach(Array(allVisibleRecords.enumerated()), id: \.element.id) { entry in
                    let record = entry.element

                    Button {
                        openRecord(record)
                    } label: {
                        ScanRecordCell(
                            record: record,
                            relativeTime: galleryRelativeTime(for: record.updatedAt),
                            useEnglish: false,
                            imageHeight: singleColumnImageHeight(for: entry.offset),
                            compactLayout: metrics.compactCardLayout
                        )
                    }
                    .buttonStyle(AetherScaleButtonStyle())
                    .frame(maxWidth: .infinity)
                    .contextMenu {
                        recordContextMenu(record)
                    }
                }
            }
        } else {
            let columnWidth = gridColumnWidth(metrics: metrics)

            HStack(alignment: .top, spacing: metrics.gridSpacing) {
                recordColumn(records: leftColumnRecords, isLeft: true, metrics: metrics, width: columnWidth)
                recordColumn(records: rightColumnRecords, isLeft: false, metrics: metrics, width: columnWidth)
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    private func recordColumn(
        records: [ScanRecord],
        isLeft: Bool,
        metrics: AetherLayoutMetrics,
        width: CGFloat
    ) -> some View {
        VStack(spacing: metrics.gridSpacing) {
            ForEach(Array(records.enumerated()), id: \.element.id) { entry in
                let position = entry.offset
                let record = entry.element

                Button {
                    openRecord(record)
                } label: {
                    ScanRecordCell(
                        record: record,
                        relativeTime: galleryRelativeTime(for: record.updatedAt),
                        useEnglish: false,
                        imageHeight: imageHeight(for: position, isLeft: isLeft, metrics: metrics),
                        compactLayout: metrics.compactCardLayout
                    )
                }
                .buttonStyle(AetherScaleButtonStyle())
                .frame(width: width)
                .contextMenu {
                    recordContextMenu(record)
                }
            }
        }
        .frame(width: width, alignment: .top)
    }

    @ViewBuilder
    private func recordContextMenu(_ record: ScanRecord) -> some View {
        if record.shellSupportsRemoteCancel {
            Button(role: .destructive) {
                viewModel.cancelRemoteRecord(record)
            } label: {
                Label("取消远端任务", systemImage: "xmark.circle")
            }
        }

        if record.shellCanRetry {
            Button {
                viewModel.retryRecord(record)
            } label: {
                Label("重新尝试", systemImage: "arrow.clockwise")
            }
        }

        if viewModel.canReimportObjectFastPublishResult(record) {
            Button {
                viewModel.reimportObjectFastPublishResultAsNewRecord(record)
            } label: {
                Label("重新导入为新卡片", systemImage: "square.on.square")
            }
        }

        Button(role: .destructive) {
            viewModel.deleteRecord(record)
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    private var allVisibleRecords: [ScanRecord] {
        viewModel.scanRecords.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var leftColumnRecords: [ScanRecord] {
        allVisibleRecords.enumerated().compactMap { index, record in
            index.isMultiple(of: 2) ? record : nil
        }
    }

    private var rightColumnRecords: [ScanRecord] {
        allVisibleRecords.enumerated().compactMap { index, record in
            index.isMultiple(of: 2) ? nil : record
        }
    }

    private func imageHeight(for position: Int, isLeft: Bool, metrics: AetherLayoutMetrics) -> CGFloat {
        let leftHeights: [CGFloat] = metrics.isNarrowPhone ? [212, 252, 172, 232] : [256, 320, 192, 272]
        let rightHeights: [CGFloat] = metrics.isNarrowPhone ? [232, 212, 284, 228] : [288, 240, 384, 256]
        let pattern = isLeft ? leftHeights : rightHeights
        return pattern[position % pattern.count]
    }

    private func singleColumnImageHeight(for position: Int) -> CGFloat {
        let heights: [CGFloat] = [236, 280, 214, 248]
        return heights[position % heights.count]
    }

    private func gridColumnWidth(metrics: AetherLayoutMetrics) -> CGFloat {
        let availableWidth = metrics.width - (metrics.horizontalPadding * 2) - metrics.gridSpacing
        return floor(availableWidth / 2)
    }

    private func galleryRelativeTime(for date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        switch seconds {
        case ..<60:
            return "now"
        case ..<3600:
            return "\(max(1, seconds / 60))m ago"
        case ..<86_400:
            return "\(max(1, seconds / 3600))h ago"
        case ..<604_800:
            return "\(max(1, seconds / 86_400))d ago"
        default:
            return "\(max(1, seconds / 604_800))w ago"
        }
    }

    private func openRecord(_ record: ScanRecord) {
        guard record.canOpenStatusView else { return }
        selectedRecord = viewModel.refreshRecord(id: record.id) ?? record
        showViewer = true
    }

    private func openCapturePlan() {
        let mode = AetherCaptureMode(rawValue: lastCaptureModeRawValue) ?? .newRemote
        captureModeRoute = mode
    }

    private func floatingCaptureButton(metrics: AetherLayoutMetrics) -> some View {
        Button(action: openCapturePlan) {
            ZStack {
                Circle()
                    .fill(AetherChromePalette.primary)
                    .frame(width: metrics.fabSize, height: metrics.fabSize)
                    .shadow(color: Color.black.opacity(0.14), radius: 16, y: 8)

                Image(systemName: "camera")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .buttonStyle(AetherScaleButtonStyle())
        .accessibilityLabel("进入拍摄方案选择页")
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
                    .foregroundColor(AetherChromePalette.textPrimary)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(AetherChromePalette.textSecondary)
            }

            Spacer()
        }
        .padding(16)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }

}

struct TaskCenterPage: View {
    @ObservedObject private var viewModel: HomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedRecord: ScanRecord?
    @State private var showViewer = false

    init(viewModel: HomeViewModel = HomeViewModel()) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = AetherLayoutMetrics(
                width: proxy.size.width,
                safeBottom: proxy.safeAreaInsets.bottom
            )

            ZStack {
                AetherChromePalette.canvas
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        AetherSectionHeader(
                            title: "任务",
                            subtitle: "把失败、处理中和最近完成的结果集中在一个地方处理。"
                        )

                        summaryStrip(metrics: metrics)

                        if !attentionRecords.isEmpty {
                            taskSection(
                                title: "需要处理",
                                subtitle: "这些任务没有产出稳定结果，建议先查看原因，再决定是重试还是删除。",
                                records: attentionRecords,
                                metrics: metrics
                            )
                        }

                        if !viewModel.processingRecords.isEmpty {
                            taskSection(
                                title: "进行中",
                                subtitle: "高不确定性流程要持续反馈阶段、进度和当前说明，这里集中展示当前状态。",
                                records: viewModel.processingRecords,
                                metrics: metrics
                            )
                        }

                        taskSection(
                            title: "最近结果",
                            subtitle: viewModel.completedRecords.isEmpty ? "完成后的结果会在这里出现。" : "已经完成的结果可以直接从这里打开查看。",
                            records: viewModel.completedRecords,
                            metrics: metrics,
                            showsEmptyState: true
                        )
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.contentBottomPadding)
                }

                if viewModel.isLoading {
                    AetherLoadingOverlay(title: "正在整理任务状态", detail: "请稍候...")
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        .onAppear {
            viewModel.loadRecords()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            viewModel.loadRecords()
        }
        #if canImport(UIKit) && canImport(Metal)
        .fullScreenCover(
            isPresented: $showViewer,
            onDismiss: {
                viewModel.loadRecords()
                selectedRecord = nil
            }
        ) {
            if let record = selectedRecord {
                AetherRecordViewerScreen(
                    record: record,
                    homeViewModel: viewModel,
                    onDismiss: {
                        viewModel.loadRecords()
                        selectedRecord = nil
                        showViewer = false
                    }
                )
            } else {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ProgressView().tint(.white)
                }
            }
        }
        #endif
    }

    private var attentionRecords: [ScanRecord] {
        (viewModel.failedRecords + viewModel.cancelledRecords)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    @ViewBuilder
    private func summaryStrip(metrics: AetherLayoutMetrics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.gridSpacing) {
                summaryCard(title: "处理中", value: viewModel.processingRecords.count, tint: AetherChromePalette.primary)
                summaryCard(title: "待处理", value: attentionRecords.count, tint: AetherChromePalette.danger)
                summaryCard(title: "已完成", value: viewModel.completedRecords.count, tint: AetherChromePalette.primarySoft)
            }

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    summaryCard(title: "处理中", value: viewModel.processingRecords.count, tint: AetherChromePalette.primary)
                    summaryCard(title: "待处理", value: attentionRecords.count, tint: AetherChromePalette.danger)
                }
                summaryCard(title: "已完成", value: viewModel.completedRecords.count, tint: AetherChromePalette.primarySoft)
            }
        }
    }

    private func summaryCard(title: String, value: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(value)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AetherChromePalette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(tint.opacity(0.18), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func taskSection(
        title: String,
        subtitle: String,
        records: [ScanRecord],
        metrics: AetherLayoutMetrics,
        showsEmptyState: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AetherSectionHeader(title: title, subtitle: subtitle)

            if records.isEmpty, showsEmptyState {
                emptyTaskState
            } else {
                VStack(spacing: 14) {
                    ForEach(records) { record in
                        taskCard(record, metrics: metrics)
                    }
                }
            }
        }
    }

    private var emptyTaskState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(AetherChromePalette.primary)

            Text("还没有已完成结果")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(AetherChromePalette.textPrimary)

            Text("先从右下角进入拍摄方案选择页，完成一次采集后结果会自动出现在这里。")
                .font(.system(size: 13))
                .foregroundColor(AetherChromePalette.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AetherChromePalette.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func taskCard(_ record: ScanRecord, metrics: AetherLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if metrics.isVeryNarrowPhone {
                VStack(alignment: .leading, spacing: 14) {
                    taskThumbnail(record, metrics: metrics)
                    taskMeta(record)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    taskThumbnail(record, metrics: metrics)
                    taskMeta(record)
                }
            }

            if let progressValue = record.shellStatusProgress {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(record.liveStepTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AetherChromePalette.textPrimary)
                        Spacer()
                        Text("\(Int(progressValue * 100))%")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(AetherChromePalette.textSecondary)
                    }

                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(AetherChromePalette.border.opacity(0.8))
                            Capsule()
                                .fill(AetherChromePalette.primary)
                                .frame(width: proxy.size.width * progressValue)
                        }
                    }
                    .frame(height: 8)
                }
            }

            actionRow(for: record, metrics: metrics)
        }
        .padding(16)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(record.shellStatusColor.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: AetherChromePalette.shadow, radius: 12, y: 6)
        .contextMenu {
            if record.shellSupportsRemoteCancel {
                Button(role: .destructive) {
                    viewModel.cancelRemoteRecord(record)
                } label: {
                    Label("取消远端任务", systemImage: "xmark.circle")
                }
            }

            if record.shellCanRetry {
                Button {
                    viewModel.retryRecord(record)
                } label: {
                    Label("重新尝试", systemImage: "arrow.clockwise")
                }
            }

            if viewModel.canReimportObjectFastPublishResult(record) {
                Button {
                    viewModel.reimportObjectFastPublishResultAsNewRecord(record)
                } label: {
                    Label("重新导入为新卡片", systemImage: "square.on.square")
                }
            }

            Button(role: .destructive) {
                viewModel.deleteRecord(record)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private func taskMeta(_ record: ScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                statusChip(title: record.shellStatusTitle, color: record.shellStatusColor)
                modeChip(title: record.shellModeTitle)
            }

            Text(record.name)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Text(record.shellStatusDetail)
                .font(.system(size: 13))
                .foregroundColor(AetherChromePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You · \(viewModel.relativeTimeString(for: record.updatedAt))")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(AetherChromePalette.textSecondary)
        }
    }

    @ViewBuilder
    private func taskThumbnail(_ record: ScanRecord, metrics: AetherLayoutMetrics) -> some View {
        ZStack(alignment: .topTrailing) {
            if let image = taskThumbnailImage(record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: metrics.taskThumbnailWidth, height: metrics.taskThumbnailHeight)
                    .clipped()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.71, green: 0.82, blue: 0.94),
                        Color(red: 0.33, green: 0.58, blue: 0.84)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.82))
                }
                .frame(width: metrics.taskThumbnailWidth, height: metrics.taskThumbnailHeight)
            }

            Text(record.shellStatusTitle)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(record.shellStatusColor)
                .clipShape(Capsule())
                .padding(8)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func taskThumbnailImage(_ record: ScanRecord) -> UIImage? {
        #if canImport(UIKit)
        if let thumbnailPath = record.thumbnailPath {
            let url = ScanRecordStore().thumbnailURL(for: thumbnailPath)
            return UIImage(contentsOfFile: url.path)
        }
        #endif
        return nil
    }

    @ViewBuilder
    private func actionRow(for record: ScanRecord, metrics: AetherLayoutMetrics) -> some View {
        if metrics.compactActionLayout {
            VStack(spacing: 10) {
                primaryAction(for: record)
                secondaryAction(for: record)
            }
        } else {
            HStack(spacing: 12) {
                secondaryAction(for: record)
                primaryAction(for: record)
            }
        }
    }

    private func primaryAction(for record: ScanRecord) -> some View {
        Group {
            if record.shellCanRetry {
                Button {
                    viewModel.retryRecord(record)
                } label: {
                    AetherPrimaryActionButton(title: "重新尝试", systemImage: "arrow.clockwise")
                }
            } else if record.shellSupportsRemoteCancel {
                Button {
                    viewModel.cancelRemoteRecord(record)
                } label: {
                    AetherPrimaryActionButton(title: "取消远端", systemImage: "xmark")
                }
            } else {
                Button {
                    openRecord(record)
                } label: {
                    AetherPrimaryActionButton(title: record.shellHasFinishedResult ? "打开结果" : "继续跟进", systemImage: "viewfinder")
                }
            }
        }
        .buttonStyle(AetherScaleButtonStyle())
    }

    private func secondaryAction(for record: ScanRecord) -> some View {
        Button {
            openRecord(record)
        } label: {
            AetherSecondaryActionButton(title: record.shellHasFinishedResult ? "查看结果" : "查看状态")
        }
        .buttonStyle(AetherScaleButtonStyle())
    }

    private func openRecord(_ record: ScanRecord) {
        guard record.canOpenStatusView else { return }
        selectedRecord = viewModel.refreshRecord(id: record.id) ?? record
        showViewer = true
    }

    private func statusChip(title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(color)
            .clipShape(Capsule())
    }

    private func modeChip(title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(AetherChromePalette.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AetherChromePalette.canvas)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(AetherChromePalette.border, lineWidth: 1)
            )
    }
}

struct CaptureModeSelectionPage: View {
    @ObservedObject private var viewModel: HomeViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMode: AetherCaptureMode
    @State private var showScanCapture = false
    @State private var showObjectModeCapture = false
    @State private var importErrorMessage: String?
    @AppStorage(FrameSamplingProfile.userDefaultsKey) private var selectedFrameSamplingProfileRaw = FrameSamplingProfile.full.rawValue
    @AppStorage(ProcessingBackendChoice.userDefaultsKey) private var selectedProcessingBackendRaw = ProcessingBackendChoice.cloud.rawValue
    @AppStorage("aether.homeProcessingMode") private var homeProcessingModeRaw = "remote"
    @AppStorage("aether3d.home.captureMode") private var lastCaptureModeRawValue = AetherCaptureMode.newRemote.rawValue

    #if canImport(PhotosUI)
    @State private var selectedVideoItem: PhotosPickerItem?
    #endif

    init(viewModel: HomeViewModel, initialMode: AetherCaptureMode = .newRemote) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _selectedMode = State(initialValue: initialMode)
    }

    var body: some View {
        GeometryReader { proxy in
            let metrics = AetherLayoutMetrics(
                width: proxy.size.width,
                safeBottom: proxy.safeAreaInsets.bottom
            )

            ZStack {
                AetherChromePalette.canvas
                    .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        topBar
                        hero(metrics: metrics)

                        if let importErrorMessage, !importErrorMessage.isEmpty {
                            AetherSectionHeader(title: "刚才没有成功", subtitle: importErrorMessage)
                                .padding(16)
                                .background(AetherChromePalette.white)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                                        .stroke(AetherChromePalette.danger.opacity(0.18), lineWidth: 1)
                                )
                        }

                        stepStrip(metrics: metrics)
                        modeCards
                        detailCard

                        if selectedMode == .remoteLegacy {
                            samplingProfileCard
                        } else if selectedMode == .newRemote {
                            guidedOnlyCard
                        }
                    }
                    .padding(.horizontal, metrics.horizontalPadding)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.contentBottomPadding)
                }

                if viewModel.isImportingVideo, let busyMessage = viewModel.busyMessage {
                    AetherLoadingOverlay(title: busyMessage, detail: "导入完成后会自动回到作品页。")
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar(metrics: metrics)
            }

        }
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.light)
        #if canImport(ARKit)
        .fullScreenCover(
            isPresented: $showScanCapture,
            onDismiss: {
                viewModel.loadRecords()
            }
        ) {
            ScanView(processingBackend: selectedMode.processingBackend)
        }
        .fullScreenCover(
            isPresented: $showObjectModeCapture,
            onDismiss: {
                viewModel.loadRecords()
            }
        ) {
            ObjectModeV2CaptureView(
                onClose: {
                    showObjectModeCapture = false
                }
            )
        }
        #endif
        #if canImport(PhotosUI)
        .onChange(of: selectedVideoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                await importPickedVideo(newValue)
            }
        }
        #endif
    }

    private var topBar: some View {
        HStack {
            Button(action: { dismiss() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AetherChromePalette.textPrimary)
                    .frame(width: 40, height: 40)
                    .background(AetherChromePalette.white)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(AetherChromePalette.border, lineWidth: 1))
            }
            .buttonStyle(AetherScaleButtonStyle())

            Spacer()

            Text("拍摄方案")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            Spacer()

            Color.clear.frame(width: 40, height: 40)
        }
    }

    private func hero(metrics: AetherLayoutMetrics) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("先决定这次走哪条采集链路")
                .font(.system(size: metrics.heroTitleSize, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            Text("新版首页不再直接暴露方案按钮。用户从右下角进入这里，选定方案并确认后，才正式进入对应拍摄流程。")
                .font(.system(size: 14))
                .foregroundColor(AetherChromePalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .shadow(color: AetherChromePalette.shadow, radius: 16, y: 8)
    }

    @ViewBuilder
    private func stepStrip(metrics: AetherLayoutMetrics) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.gridSpacing) {
                captureStep(index: "1", title: "选方案", isActive: true)
                captureStep(index: "2", title: "确认入口", isActive: true)
                captureStep(index: "3", title: "开始拍摄", isActive: false)
            }

            VStack(spacing: 10) {
                captureStep(index: "1", title: "选方案", isActive: true)
                captureStep(index: "2", title: "确认入口", isActive: true)
                captureStep(index: "3", title: "开始拍摄", isActive: false)
            }
        }
    }

    private var modeCards: some View {
        VStack(spacing: 14) {
            ForEach(AetherCaptureMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    modeCard(mode)
                }
                .buttonStyle(AetherScaleButtonStyle())
            }
        }
    }

    private func modeCard(_ mode: AetherCaptureMode) -> some View {
        let isSelected = selectedMode == mode

        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? mode.accentColor : AetherChromePalette.canvas)
                        .frame(width: 46, height: 46)

                    Image(systemName: mode.systemImage)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(isSelected ? .white : mode.accentColor)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(mode.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(AetherChromePalette.textPrimary)

                        if let shortBadge = mode.shortBadge {
                            Text(shortBadge)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AetherChromePalette.primary)
                                .clipShape(Capsule())
                        }
                    }

                    Text(mode.subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(AetherChromePalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Circle()
                    .strokeBorder(isSelected ? AetherChromePalette.primary : AetherChromePalette.border, lineWidth: 2)
                    .background(
                        Circle()
                            .fill(isSelected ? AetherChromePalette.primary : Color.clear)
                            .padding(4)
                    )
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(mode.detailTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AetherChromePalette.textPrimary)

                Text(mode.detailBody)
                    .font(.system(size: 13))
                    .foregroundColor(AetherChromePalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? mode.accentColor.opacity(0.10) : AetherChromePalette.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(18)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(isSelected ? AetherChromePalette.primary : AetherChromePalette.border, lineWidth: isSelected ? 2 : 1)
        )
        .shadow(color: AetherChromePalette.shadow.opacity(isSelected ? 1.0 : 0.5), radius: 14, y: 8)
    }

    private var detailCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认后会发生什么")
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            detailRow(title: "当前选择", body: selectedMode.title)
            detailRow(title: "进入页面", body: selectedMode == .newRemote ? "对象模式 Beta 拍摄页" : "扫描拍摄页")
            detailRow(title: "状态反馈", body: selectedMode == .newRemote ? "拍摄后会持续拉新远端状态，并把候选结果与 HQ 状态同步回首页。" : "拍摄或导入后会在首页持续显示上传、处理、回传与失败状态。")
        }
        .padding(22)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AetherChromePalette.border, lineWidth: 1)
        )
    }

    private var samplingProfileCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("训练速度方案")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            Text("远端方案会沿用这里的采样档位。全量保质量，半量和三分之一会用更少输入帧换更短总耗时。")
                .font(.system(size: 13))
                .foregroundColor(AetherChromePalette.textSecondary)

            HStack(spacing: 10) {
                ForEach(FrameSamplingProfile.allCases, id: \.rawValue) { profile in
                    frameSamplingProfileButton(profile)
                }
            }
        }
        .padding(18)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AetherChromePalette.border, lineWidth: 1)
        )
    }

    private var guidedOnlyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Guided Only")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(AetherChromePalette.textPrimary)

            Text("新远端目前只支持现场 Guided 拍摄，不支持直接从相册导入历史视频。")
                .font(.system(size: 13))
                .foregroundColor(AetherChromePalette.textSecondary)
        }
        .padding(18)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(AetherChromePalette.border, lineWidth: 1)
        )
    }

    private func bottomActionBar(metrics: AetherLayoutMetrics) -> some View {
        VStack(spacing: 12) {
            Button(action: confirmSelection) {
                AetherPrimaryActionButton(title: "确认进入拍摄", systemImage: "arrow.right")
            }
            .buttonStyle(AetherScaleButtonStyle())

            importActionButton
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .padding(.top, 16)
        .padding(.bottom, metrics.safeBottom > 0 ? 8 : 14)
        .background(
            LinearGradient(
                colors: [
                    AetherChromePalette.canvas.opacity(0.08),
                    AetherChromePalette.canvas,
                    AetherChromePalette.canvas
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }

    @ViewBuilder
    private var importActionButton: some View {
        if selectedMode.supportsVideoImport {
            #if canImport(PhotosUI)
            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos,
                photoLibrary: .shared()
            ) {
                AetherSecondaryActionButton(
                    title: "从相册导入已有视频",
                    foreground: AetherChromePalette.textPrimary
                )
            }
            .buttonStyle(AetherScaleButtonStyle())
            #else
            AetherSecondaryActionButton(
                title: "当前平台暂不支持相册导入",
                foreground: AetherChromePalette.textSecondary
            )
            #endif
        } else {
            AetherSecondaryActionButton(
                title: "Guided Only",
                foreground: AetherChromePalette.textSecondary,
                background: AetherChromePalette.white.opacity(0.68)
            )
        }
    }

    private func captureStep(index: String, title: String, isActive: Bool) -> some View {
        HStack(spacing: 10) {
            Text(index)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(isActive ? .white : AetherChromePalette.textSecondary)
                .frame(width: 24, height: 24)
                .background(isActive ? AetherChromePalette.primary : AetherChromePalette.border)
                .clipShape(Circle())

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(AetherChromePalette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(AetherChromePalette.white)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AetherChromePalette.border, lineWidth: 1)
        )
    }

    private func detailRow(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AetherChromePalette.textSecondary)
            Text(body)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(AetherChromePalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                    .foregroundColor(isSelected ? Color.black.opacity(0.70) : AetherChromePalette.textSecondary)
            }
            .foregroundColor(isSelected ? .black : AetherChromePalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(isSelected ? Color(red: 0.70, green: 0.90, blue: 1.0) : AetherChromePalette.canvas)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? AetherChromePalette.info : AetherChromePalette.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(AetherScaleButtonStyle())
    }

    private var selectedFrameSamplingProfile: FrameSamplingProfile {
        FrameSamplingProfile(rawValue: selectedFrameSamplingProfileRaw) ?? .full
    }

    private func confirmSelection() {
        lastCaptureModeRawValue = selectedMode.rawValue
        homeProcessingModeRaw = selectedMode.legacyHomeModeRawValue
        selectedProcessingBackendRaw = selectedMode.processingBackend.rawValue
        importErrorMessage = nil

        if selectedMode == .newRemote {
            showObjectModeCapture = true
        } else {
            showScanCapture = true
        }
    }

    #if canImport(PhotosUI)
    private func importPickedVideo(_ item: PhotosPickerItem) async {
        await MainActor.run {
            importErrorMessage = nil
            homeProcessingModeRaw = selectedMode.legacyHomeModeRawValue
            selectedProcessingBackendRaw = selectedMode.processingBackend.rawValue
            viewModel.errorMessage = nil
            viewModel.busyMessage = "正在读取相册视频（大视频可能需要几分钟）..."
            viewModel.isImportingVideo = true
        }

        defer {
            Task { @MainActor in
                selectedVideoItem = nil
            }
        }

        do {
            let movieURL = try await Self.loadPickedMovieURL(from: item) { message in
                Task { @MainActor in
                    viewModel.busyMessage = message
                }
            }

            guard let _ = await viewModel.importVideo(
                at: movieURL,
                processingBackend: selectedMode.processingBackend
            ) else {
                await MainActor.run {
                    importErrorMessage = viewModel.errorMessage?.isEmpty == false
                        ? viewModel.errorMessage
                        : "相册视频已经选中，但没有成功进入处理流程，请再试一次。"
                }
                return
            }

            await MainActor.run {
                viewModel.loadRecords(scheduleRemoteResume: false)
                dismiss()
            }
        } catch {
            await MainActor.run {
                importErrorMessage = "相册视频读取失败: \(Self.importErrorDescription(error))"
                viewModel.busyMessage = nil
                viewModel.isImportingVideo = false
            }
        }
    }
    #endif
}

#if canImport(UIKit) && canImport(Metal)
private struct AetherRecordViewerScreen: View {
    let record: ScanRecord
    @ObservedObject var homeViewModel: HomeViewModel
    let onDismiss: () -> Void

    var body: some View {
        if record.isObjectFastPublishV1 {
            ObjectFastPublishRecordViewer(record: record, homeViewModel: homeViewModel, onDismiss: onDismiss)
        } else {
            SplatViewerView(
                record: record,
                homeViewModel: homeViewModel,
                onReturnHome: onDismiss
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
                    processingDurationLabel: currentRecord.galleryProcessingDurationLabelText,
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
                ObjectModeV2DefaultArtifactViewer(
                    url: artifactURL,
                    manifestURL: viewerManifestURL,
                    processingDurationLabel: currentRecord.galleryProcessingDurationLabelText
                ) {
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

    private var statusTint: Color {
        if currentRecord.isInspectionOnlyCandidate {
            return Color.orange.opacity(0.22)
        }
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
            isInspectionOnlyCandidate: currentRecord.isInspectionOnlyCandidate,
            modeValue: "Guided",
            lockValue: "Open",
            lockAccent: lockAccent,
            stageCards: processingStageCards,
            stats: [
                .init(title: "Frames", value: acceptedFramesText),
                .init(title: "Orbit", value: orbitText),
                .init(title: "Status", value: processingStatusSummary),
                .init(title: "Elapsed", value: processingDurationCompactText)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。",
            failedCardsSummary: currentRecord.inspectionFailedCardsSummaryText
        )
        #else
        return ObjectModeV2ProcessingSnapshot(
            heroBadge: "OBJECT MODE BETA",
            heroTitle: processingHeroTitle,
            heroSubtitle: processingHeroSubtitle,
            canOpenArtifact: artifactURL != nil,
            isFailed: currentRecord.status == .failed,
            isInspectionOnlyCandidate: currentRecord.isInspectionOnlyCandidate,
            modeValue: "Guided",
            lockValue: "Open",
            lockAccent: lockAccent,
            stageCards: processingStageCards,
            stats: [
                .init(title: "Frames", value: acceptedFramesText),
                .init(title: "Orbit", value: orbitText),
                .init(title: "Status", value: processingStatusSummary),
                .init(title: "Elapsed", value: processingDurationCompactText)
            ],
            footerText: "你可以留在这里等待，也可以稍后在作品列表里继续查看。",
            failedCardsSummary: currentRecord.inspectionFailedCardsSummaryText
        )
        #endif
    }

    private var processingDurationCompactText: String {
        if let label = currentRecord.galleryProcessingDurationLabelText,
           let value = label.split(separator: " ").last,
           !value.isEmpty {
            return String(value)
        }
        return "--:--"
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
        if currentRecord.isInspectionOnlyCandidate {
            return "Needs QA"
        }
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
        if currentRecord.isInspectionOnlyCandidate {
            return "候选结果已生成"
        }
        switch currentRecord.status {
        case .failed:
            return "HQ 成品生成失败"
        case .completed:
            return "HQ 成品已完成"
        default:
            return "正在生成 HQ 成品"
        }
    }

    private var processingHeroSubtitle: String {
        if currentRecord.isInspectionOnlyCandidate {
            if let detail = currentRecord.detailMessage, !detail.isEmpty {
                return detail
            }
            return "未达 HQ，仅供质检。你可以打开候选结果做人工判断。"
        }
        if let detail = currentRecord.detailMessage, !detail.isEmpty {
            return detail
        }
        if currentRecord.status == .failed {
            return currentRecord.failureReason ?? "远端任务失败。"
        }
        return "系统会生成唯一的 HQ 3D 成品；下载完成后即可打开。"
    }

    private var processingStageCards: [ObjectModeV2StageCard] {
        [
            ObjectModeV2StageCard(
                id: .defaultStage,
                title: "HQ",
                subtitle: "高质量成品",
                state: defaultStageState
            )
        ]
    }

    private var defaultStageState: ObjectModeV2StageUIState {
        if currentRecord.isInspectionOnlyCandidate {
            return .failed("未达 HQ，仅供质检")
        }
        if currentRecord.status == .failed {
            return .failed(currentRecord.failureReason ?? currentRecord.detailMessage)
        }
        if artifactURL != nil || currentRecord.status == .completed {
            return .ready
        }
        return .processing(defaultStageProgress)
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
        case "matcha_mesh_extract":
            return max(fraction, 0.82)
        case "optimize_default_mesh":
            return max(fraction, 0.88)
        case "bake_default_texture":
            return max(fraction, 0.94)
        case "publish_default_mesh":
            return max(fraction, 0.97)
        case "artifact_upload":
            return max(fraction, 0.99)
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
#endif

private extension String? {
    var orEmpty: String { self ?? "" }
}

private extension CaptureModeSelectionPage {
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
                if let url = try await loadMovieURLFromPhotoLibrary(identifier: itemIdentifier, progress: progress) {
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
            timeoutMessage: "读取照片库超时，请保持当前页面打开，或稍后再试",
            operation: {
                try await item.loadTransferable(type: PickedMovie.self)
            }
        ) {
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
                options: options
            ) { error in
                timeoutTask.cancel()
                guard gate.claim() else { return }
                if let error {
                    try? FileManager.default.removeItem(at: targetURL)
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: targetURL)
            }
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
