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
private func makeSourceVideoThumbnailJPEGData(for url: URL) -> Data? {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 960, height: 960)
    guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else {
        return nil
    }
    return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.82)
}
#endif

#if canImport(SwiftUI)
struct ScanRecordCell: View {
    let record: ScanRecord
    let relativeTime: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)

                thumbnailContent

                statusBadge
                    .padding(10)
            }

            Text(record.name)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            Text(record.displayStatusMessage)
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

            if let processingBackendLabelText = record.galleryProcessingBackendLabelText {
                Text(processingBackendLabelText)
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
                    Text("约 \(etaSummary)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.42))
                } else {
                    Text("等待统计")
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
        .accessibilityLabel("\(record.name)，\(record.displayStatusMessage)，\(relativeTime)")
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

    private var statusTitle: String {
        switch record.status {
        case .completed:
            return "已完成"
        case .cancelled:
            return "已取消"
        case .failed:
            return "失败"
        case .localFallback:
            return "本地兜底"
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
            let thumbnailData = makeSourceVideoThumbnailJPEGData(for: sourceURL)
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
