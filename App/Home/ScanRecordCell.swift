//
// ScanRecordCell.swift
// Aether3D
//
// Figma-aligned gallery card for the light home shell
// Apple-platform only (SwiftUI)
//

import Foundation

#if canImport(SwiftUI)
import SwiftUI
#endif

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(UIKit) && canImport(AVFoundation)
private func makeSourceVideoThumbnailJPEGData(for url: URL) async -> Data? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 960)
    do {
        let cgImage = try await generateThumbnailImage(generator: generator, time: .zero)
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
    } catch {
        return nil
    }
}
#endif

#if canImport(UIKit) && canImport(AVFoundation)
private func generateThumbnailImage(
    generator: AVAssetImageGenerator,
    time: CMTime
) async throws -> CGImage {
    try await withCheckedThrowingContinuation { continuation in
        generator.generateCGImageAsynchronously(for: time) { image, _, error in
            if let image {
                continuation.resume(returning: image)
            } else {
                continuation.resume(throwing: error ?? NSError(domain: "Aether3D.Thumbnail", code: -1))
            }
        }
    }
}
#endif

#if canImport(SwiftUI)
struct ScanRecordCell: View {
    let record: ScanRecord
    let relativeTime: String
    let useEnglish: Bool
    let imageHeight: CGFloat
    let compactLayout: Bool

    init(
        record: ScanRecord,
        relativeTime: String,
        useEnglish: Bool,
        imageHeight: CGFloat = 256,
        compactLayout: Bool = false
    ) {
        self.record = record
        self.relativeTime = relativeTime
        self.useEnglish = useEnglish
        self.imageHeight = imageHeight
        self.compactLayout = compactLayout
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compactLayout ? 10 : 12) {
            thumbnailCard

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(size: compactLayout ? 15 : 16, weight: .semibold))
                    .foregroundColor(textPrimaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                    .fixedSize(horizontal: false, vertical: true)

                Text("You · \(relativeTime)")
                    .font(.system(size: compactLayout ? 11 : 12))
                    .foregroundColor(textSecondaryColor)
            }
            .padding(.horizontal, compactLayout ? 2 : 4)
            .padding(.bottom, 2)
        }
        .padding(compactLayout ? 10 : 12)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(cardBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
        .shadow(color: Color.black.opacity(0.05), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name)，\(localizedStatusMessage)，\(relativeTime)")
    }

    private var thumbnailCard: some View {
        thumbnailContent
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .background(thumbnailBackground)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if showsStatusBadge {
                    statusBadge
                        .padding(compactLayout ? 10 : 12)
                }
            }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnailPath = record.thumbnailPath {
            #if canImport(UIKit)
            if let image = persistedThumbnailImage(for: thumbnailPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let sourceVideoPath = record.sourceVideoPath {
                SourceVideoThumbnailView(
                    recordId: record.id,
                    sourceVideoPath: sourceVideoPath,
                    height: imageHeight,
                    placeholder: thumbnailPlaceholder
                )
            } else {
                thumbnailPlaceholder
            }
            #else
            let store = ScanRecordStore()
            let url = store.thumbnailURL(for: thumbnailPath)
            AsyncImage(url: url) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                thumbnailPlaceholder
            }
            #endif
        } else if let sourceVideoPath = record.sourceVideoPath {
            SourceVideoThumbnailView(
                recordId: record.id,
                sourceVideoPath: sourceVideoPath,
                height: imageHeight,
                placeholder: thumbnailPlaceholder
            )
        } else {
            thumbnailPlaceholder
        }
    }

    #if canImport(UIKit)
    private func persistedThumbnailImage(for thumbnailPath: String) -> UIImage? {
        let store = ScanRecordStore()
        let url = store.thumbnailURL(for: thumbnailPath)
        return UIImage(contentsOfFile: url.path)
    }
    #endif

    private var thumbnailBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.72, green: 0.83, blue: 0.95),
                Color(red: 0.33, green: 0.58, blue: 0.85)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var thumbnailPlaceholder: some View {
        ZStack {
            thumbnailBackground
            Image(systemName: placeholderSymbolName)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.white.opacity(0.86))
        }
    }

    private var placeholderSymbolName: String {
        if record.isInspectionOnlyCandidate {
            return "eye.fill"
        }
        switch record.status {
        case .completed:
            return "cube.transparent"
        case .cancelled:
            return "stop.circle"
        case .failed:
            return "exclamationmark.triangle"
        default:
            return "hourglass"
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 0) {
            Text(statusTitle)
                .font(.system(size: compactLayout ? 10 : 11, weight: .semibold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, compactLayout ? 8 : 10)
        .padding(.vertical, compactLayout ? 6 : 7)
        .background(statusColor)
        .clipShape(Capsule())
    }

    private var processingBackendBadge: some View {
        Text(processingBackendBadgeTitle)
            .font(.system(size: compactLayout ? 10 : 11, weight: .semibold))
            .foregroundColor(textPrimaryColor)
            .padding(.horizontal, compactLayout ? 8 : 10)
            .padding(.vertical, compactLayout ? 6 : 7)
            .background(processingBackendBadgeColor)
            .clipShape(Capsule())
    }

    private var statusTitle: String {
        if record.isInspectionOnlyCandidate {
            return useEnglish ? "Needs QA" : "未达HQ"
        }
        let workflowStatus = record.displayWorkflowStatus
        if useEnglish {
            switch workflowStatus {
            case .completed:
                return "Done"
            case .cancelled:
                return "Cancelled"
            case .failed:
                return "Failed"
            case .localFallback:
                return "On Device"
            case .uploading:
                return "Uploading"
            case .queued:
                return "Queued"
            case .reconstructing:
                return "Rebuild"
            case .training:
                return "Training"
            case .packaging:
                return "Processing"
            case .downloading:
                return "Downloading"
            case .preparing:
                return "Preparing"
            }
        }
        switch workflowStatus {
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case .failed:
            return record.isObjectFastPublishV1 ? "训练失败" : "失败"
        case .localFallback:
            return "本地处理"
        case .uploading:
            return "上传中"
        case .queued:
            return "排队中"
        case .reconstructing:
            return "重建中"
        case .training:
            return "训练中"
        case .packaging:
            return "处理中"
        case .downloading:
            return "回传中"
        case .preparing:
            return "准备中"
        }
    }

    private var localizedStatusMessage: String {
        guard useEnglish else { return record.displayStatusMessage }
        let message = record.displayStatusMessage
        let fallback = ScanRecord.defaultStatusMessage(for: record.displayWorkflowStatus)
        if message == fallback {
            return englishDefaultStatusMessage(for: record.displayWorkflowStatus)
        }
        return message
    }

    private func englishDefaultStatusMessage(for status: ScanRecordStatus) -> String {
        switch status {
        case .preparing:
            return "Organizing captured footage"
        case .uploading:
            return "Uploading to object storage"
        case .queued:
            return "Queued in the backend, waiting for GPU"
        case .reconstructing:
            return "Remote preprocessing and reconstruction setup"
        case .training:
            return "Remote training is building the 3D model"
        case .packaging:
            return "Processing the HQ 3D result"
        case .downloading:
            return "Returning the 3DGS to your phone"
        case .localFallback:
            return "Remote unavailable, continuing with on-device processing"
        case .completed:
            return "Result is ready to open"
        case .cancelled:
            return "You cancelled this remote job"
        case .failed:
            return "This generation failed"
        }
    }

    private var statusColor: Color {
        if record.isInspectionOnlyCandidate {
            return Color(red: 0.73, green: 0.53, blue: 0.16)
        }
        switch record.displayWorkflowStatus {
        case .completed:
            return Color(red: 0.12, green: 0.23, blue: 0.18)
        case .cancelled:
            return Color(red: 0.77, green: 0.57, blue: 0.18)
        case .failed:
            return Color(red: 0.79, green: 0.29, blue: 0.23)
        case .localFallback:
            return Color(red: 0.77, green: 0.57, blue: 0.18)
        case .uploading, .queued, .reconstructing, .training, .packaging, .downloading, .preparing:
            return Color(red: 0.12, green: 0.23, blue: 0.18)
        }
    }

    private var statusSymbolName: String {
        if record.isInspectionOnlyCandidate {
            return "eye.fill"
        }
        switch record.displayWorkflowStatus {
        case .completed:
            return "checkmark.circle.fill"
        case .cancelled:
            return "stop.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .localFallback:
            return "iphone.gen3.radiowaves.left.and.right"
        case .uploading:
            return "arrow.up.circle.fill"
        case .queued:
            return "clock.fill"
        case .reconstructing:
            return "camera.aperture"
        case .training:
            return "sparkles"
        case .packaging:
            return "shippingbox.fill"
        case .downloading:
            return "arrow.down.circle.fill"
        case .preparing:
            return "bolt.circle.fill"
        }
    }

    private var metaLineText: String? {
        record.galleryStatusMetaText
    }

    private var processingBackendBadgeTitle: String {
        if record.isObjectFastPublishV1 {
            return useEnglish ? "New Remote" : "新远端"
        }
        if useEnglish {
            return record.resolvedProcessingBackend == .cloud ? "Remote" : "Local"
        }
        return record.resolvedProcessingBackend == .cloud ? "远端方案" : "本地方案"
    }

    private var processingBackendBadgeColor: Color {
        if record.isObjectFastPublishV1 {
            return Color(red: 0.99, green: 0.87, blue: 0.71)
        }
        return record.resolvedProcessingBackend == .cloud
            ? Color(red: 0.90, green: 0.93, blue: 0.90)
            : Color(red: 0.84, green: 0.90, blue: 0.94)
    }

    private var cardBackgroundColor: Color { .white }

    private var cardBorderColor: Color {
        if record.isInspectionOnlyCandidate {
            return Color(red: 0.93, green: 0.86, blue: 0.71)
        }
        switch record.status {
        case .failed:
            return statusColor.opacity(0.22)
        case .cancelled:
            return statusColor.opacity(0.18)
        default:
            return .clear
        }
    }

    private func metaCapsule(text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: metaLineIconName)
                .font(.system(size: compactLayout ? 9 : 10, weight: .bold))
            Text(text)
                .font(.system(size: compactLayout ? 10 : 11, weight: .semibold))
                .lineLimit(2)
        }
        .foregroundColor(tint)
        .padding(.horizontal, compactLayout ? 8 : 10)
        .padding(.vertical, compactLayout ? 6 : 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(tint.opacity(0.10))
        )
    }

    private var metaLineIconName: String {
        if record.isInspectionOnlyCandidate {
            return "doc.text.magnifyingglass"
        }
        switch record.status {
        case .cancelled:
            return "arrow.clockwise.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        default:
            return "checkmark.seal.fill"
        }
    }

    private var showsStatusBadge: Bool {
        record.status != .completed || record.isInspectionOnlyCandidate
    }

    private var progressValue: Double? {
        guard record.isProcessing else { return nil }
        return min(max(record.displayProgressFraction, 0.02), 0.99)
    }

    private var footerLeadingText: String? {
        if let samplingProfileLabelText = record.gallerySamplingProfileLabelText,
           !samplingProfileLabelText.isEmpty {
            return samplingProfileLabelText
        }
        if let videoDurationLabelText = record.galleryVideoDurationLabelText,
           !videoDurationLabelText.isEmpty {
            return videoDurationLabelText
        }
        return processingBackendBadgeTitle
    }

    private var footerTrailingText: String? {
        if let processingDurationLabelText = record.galleryProcessingDurationLabelText,
           !processingDurationLabelText.isEmpty {
            return processingDurationLabelText
        }
        if let etaSummary = record.estimatedRemainingSummaryText,
           record.status != .completed,
           !etaSummary.isEmpty {
            return useEnglish ? "About \(etaSummary)" : "约 \(etaSummary)"
        }
        return nil
    }

    private var textPrimaryColor: Color {
        Color(red: 0.16, green: 0.17, blue: 0.15)
    }

    private var textSecondaryColor: Color {
        Color(red: 0.47, green: 0.49, blue: 0.46)
    }
}

#if canImport(UIKit) && canImport(AVFoundation)
private struct SourceVideoThumbnailView<Placeholder: View>: View {
    let recordId: UUID
    let sourceVideoPath: String
    let height: CGFloat
    let placeholder: Placeholder

    @State private var thumbnailImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .scaledToFill()
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipped()
        .onAppear {
            loadThumbnailIfNeeded()
        }
    }

    private func loadThumbnailIfNeeded() {
        guard thumbnailImage == nil, !isLoading else { return }
        isLoading = true

        let store = ScanRecordStore()
        let sourceURL = store.baseDirectoryURL().appendingPathComponent(sourceVideoPath)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            isLoading = false
            return
        }
        let recordId = self.recordId

        Task.detached(priority: .utility) {
            let thumbnailData = await makeSourceVideoThumbnailJPEGData(for: sourceURL)
            let persistedPath = thumbnailData.flatMap { data in
                ScanRecordStore().saveThumbnail(data, for: recordId)
            }

            await MainActor.run {
                self.thumbnailImage = thumbnailData.flatMap(UIImage.init(data:))
                self.isLoading = false
                if let persistedPath {
                    ScanRecordStore().updateThumbnailPath(recordId: recordId, thumbnailPath: persistedPath)
                }
            }
        }
    }
}
#endif
#endif
