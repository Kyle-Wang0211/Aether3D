//
// ScanRecordCell.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Gallery Cell
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                thumbnailContent
            }
            .overlay(alignment: .topLeading) {
                statusBadge
                    .padding(10)
            }
            .overlay(alignment: .topTrailing) {
                processingBackendBadge
                    .padding(10)
            }

            Text(record.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(localizedStatusMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(statusColor.opacity(0.92))
                .lineLimit(2)

            if let detailMessage = record.detailMessage, !detailMessage.isEmpty {
                Text(detailMessage)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(2)
            }

            if let metaLine = metaLineText {
                metaCapsule(text: metaLine, tint: statusColor)
            }

            if record.isProcessing {
                ProgressView(value: record.displayProgressFraction)
                    .tint(statusColor)
            }

            if let videoDurationLabelText = record.galleryVideoDurationLabelText {
                Text(videoDurationLabelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
            }

            if let samplingProfileLabelText = record.gallerySamplingProfileLabelText {
                Text(samplingProfileLabelText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.50))
                    .lineLimit(1)
            }

            HStack {
                Text(relativeTime)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                Spacer()

                if let processingDurationLabelText = record.galleryProcessingDurationLabelText {
                    Text(processingDurationLabelText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.42))
                } else if let etaSummary = record.estimatedRemainingSummaryText, record.status != .completed {
                    Text(useEnglish ? "About \(etaSummary)" : "约 \(etaSummary)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.42))
                } else {
                    Text(useEnglish ? "Waiting for stats" : "等待统计")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.32))
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(cardBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(cardBorderColor, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(record.name)，\(localizedStatusMessage)，\(relativeTime)")
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnailPath = record.thumbnailPath {
            #if canImport(UIKit)
            if let image = persistedThumbnailImage(for: thumbnailPath) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else if let sourceVideoPath = record.sourceVideoPath {
                SourceVideoThumbnailView(
                    recordId: record.id,
                    sourceVideoPath: sourceVideoPath,
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
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                thumbnailPlaceholder
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            #endif
        } else if let sourceVideoPath = record.sourceVideoPath {
            SourceVideoThumbnailView(
                recordId: record.id,
                sourceVideoPath: sourceVideoPath,
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

    private var thumbnailPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
            Image(systemName: placeholderSymbolName)
                .font(.system(size: 28))
                .foregroundColor(.gray)
        }
    }

    private var placeholderSymbolName: String {
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
        HStack(spacing: 5) {
            Image(systemName: statusSymbolName)
                .font(.system(size: 10, weight: .bold))
            Text(statusTitle)
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(statusColor)
        .cornerRadius(999)
    }

    private var processingBackendBadge: some View {
        Text(processingBackendBadgeTitle)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(processingBackendBadgeColor)
            .cornerRadius(999)
    }

    private var statusTitle: String {
        if useEnglish {
            switch record.status {
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
                return "Exporting"
            case .downloading:
                return "Downloading"
            case .preparing:
                return "Preparing"
            }
        }
        switch record.status {
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case .failed:
            return "失败"
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
            return "导出中"
        case .downloading:
            return "回传中"
        case .preparing:
            return "准备中"
        }
    }

    private var localizedStatusMessage: String {
        guard useEnglish else { return record.displayStatusMessage }
        let message = record.displayStatusMessage
        let fallback = ScanRecord.defaultStatusMessage(for: record.status)
        if message == fallback {
            return englishDefaultStatusMessage(for: record.status)
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
            return "Exporting and packaging the 3DGS"
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
        switch record.status {
        case .completed:
            return .green
        case .cancelled:
            return .orange
        case .failed:
            return .red
        case .localFallback:
            return .orange
        case .uploading, .queued, .reconstructing, .training, .packaging, .downloading, .preparing:
            return .cyan
        }
    }

    private var statusSymbolName: String {
        switch record.status {
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
        if useEnglish {
            return record.resolvedProcessingBackend == .cloud ? "Remote" : "Local"
        }
        return record.resolvedProcessingBackend == .cloud ? "远端方案" : "本地方案"
    }

    private var processingBackendBadgeColor: Color {
        record.resolvedProcessingBackend == .cloud ? Color.cyan.opacity(0.92) : Color.green.opacity(0.85)
    }

    private var cardBackgroundColor: Color {
        switch record.status {
        case .cancelled:
            return Color.orange.opacity(0.10)
        case .failed:
            return Color.red.opacity(0.08)
        default:
            return Color.white.opacity(0.04)
        }
    }

    private var cardBorderColor: Color {
        switch record.status {
        case .cancelled:
            return Color.orange.opacity(0.24)
        case .failed:
            return Color.red.opacity(0.18)
        default:
            return Color.white.opacity(0.06)
        }
    }

    private func metaCapsule(text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: metaLineIconName)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(tint.opacity(0.10))
        )
    }

    private var metaLineIconName: String {
        switch record.status {
        case .cancelled:
            return "arrow.clockwise.circle.fill"
        case .failed:
            return "exclamationmark.circle.fill"
        default:
            return "checkmark.seal.fill"
        }
    }
}

#if canImport(UIKit) && canImport(AVFoundation)
private struct SourceVideoThumbnailView<Placeholder: View>: View {
    let recordId: UUID
    let sourceVideoPath: String
    let placeholder: Placeholder

    @State private var thumbnailImage: UIImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let thumbnailImage {
                Image(uiImage: thumbnailImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
