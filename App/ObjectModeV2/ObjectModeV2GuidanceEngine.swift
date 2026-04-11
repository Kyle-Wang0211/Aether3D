import Foundation

#if canImport(UIKit)
import UIKit
import Aether3DCore

struct ObjectModeV2GuidanceSnapshot: Sendable, Equatable {
    var acceptedFrames: Int
    var orbitCompletion: Double
    var hintText: String
    var stabilityScore: Double
    var lastAcceptedTimestamp: TimeInterval?

    static let idle = ObjectModeV2GuidanceSnapshot(
        acceptedFrames: 0,
        orbitCompletion: 0,
        hintText: "将物体放在画面中央，开始后沿着主体缓慢绕一圈。",
        stabilityScore: 1,
        lastAcceptedTimestamp: nil
    )
}

struct ObjectModeV2GuidanceAuditSummary: Sendable, Equatable {
    var totalSamples = 0
    var hardRejectBlurCount = 0
    var hardRejectDarkCount = 0
    var hardRejectBrightCount = 0
    var hardRejectOccupancyCount = 0
    var softDowngradeRedundantCount = 0
    var softDowngradeLowTextureCount = 0
    var softDowngradeWeakQualityCount = 0
    var guidanceRecenterCount = 0
    var guidanceNewAngleCount = 0
    var guidanceCoverageCount = 0
}

struct ObjectModeV2VisualFrameSample: Sendable, Equatable {
    let timestamp: TimeInterval
    let signatureWidth: Int
    let signatureHeight: Int
    let signature: Data
    let laplacianVariance: Double
    let meanBrightness: Double
    let globalVariance: Double
}

@MainActor
final class ObjectModeV2GuidanceEngine {
    private let maxAcceptedFrames = 150
    private let hardRejectTargetSignalThreshold = 0.10
    private let softWarnTargetSignalThreshold = 0.16
    var onUpdate: ((ObjectModeV2GuidanceSnapshot) -> Void)?

    private var snapshot = ObjectModeV2GuidanceSnapshot.idle
    private var recordingStartedAt: Date?
    private var lastAcceptedAt: TimeInterval?
    private var lastAcceptedSignature = Data()
    private var coverageCredits = 0.0
    private var smoothedQuality = 0.0
    private var auditSummary = ObjectModeV2GuidanceAuditSummary()

    func startMonitoring() {
        publish(snapshot)
    }

    func stopMonitoring() {}

    func beginRecording() {
        recordingStartedAt = Date()
        lastAcceptedAt = nil
        lastAcceptedSignature = Data()
        coverageCredits = 0
        smoothedQuality = 0
        auditSummary = ObjectModeV2GuidanceAuditSummary()
        publish(.init(
            acceptedFrames: 0,
            orbitCompletion: 0,
            hintText: "很好，开始缓慢绕主体移动，系统会自动挑选有效帧。",
            stabilityScore: 1,
            lastAcceptedTimestamp: nil
        ))
    }

    func endRecording() {
        recordingStartedAt = nil
        publish(snapshot)
    }

    func pipelineAuditFields(
        targetZoneAnchor: CGPoint,
        targetZoneMode: ObjectModeV2TargetZoneMode
    ) -> [String: String] {
        [
            "visual_policy_version": "v2_unified_capture_audit",
            "visual_min_target_signal": String(format: "%.4f", hardRejectTargetSignalThreshold),
            "visual_warn_target_signal": String(format: "%.4f", softWarnTargetSignalThreshold),
            "visual_min_orb_features": "\(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM)",
            "visual_warn_orb_features": "\(FrameQualityConstants.WARN_ORB_FEATURES_FOR_SFM)",
            "target_zone_anchor_x": String(format: "%.4f", targetZoneAnchor.x),
            "target_zone_anchor_y": String(format: "%.4f", targetZoneAnchor.y),
            "target_zone_mode_runtime": targetZoneMode.rawValue,
            "client_live_total_samples": "\(auditSummary.totalSamples)",
            "client_live_hard_reject_blur_count": "\(auditSummary.hardRejectBlurCount)",
            "client_live_hard_reject_dark_count": "\(auditSummary.hardRejectDarkCount)",
            "client_live_hard_reject_bright_count": "\(auditSummary.hardRejectBrightCount)",
            "client_live_hard_reject_occupancy_count": "\(auditSummary.hardRejectOccupancyCount)",
            "client_live_soft_redundant_count": "\(auditSummary.softDowngradeRedundantCount)",
            "client_live_soft_low_texture_count": "\(auditSummary.softDowngradeLowTextureCount)",
            "client_live_soft_weak_quality_count": "\(auditSummary.softDowngradeWeakQualityCount)",
            "client_live_guidance_recenter_count": "\(auditSummary.guidanceRecenterCount)",
            "client_live_guidance_new_angle_count": "\(auditSummary.guidanceNewAngleCount)",
            "client_live_guidance_coverage_count": "\(auditSummary.guidanceCoverageCount)"
        ]
    }

    func processVisualSample(
        _ sample: ObjectModeV2VisualFrameSample,
        targetZoneAnchor: CGPoint,
        targetZoneMode: ObjectModeV2TargetZoneMode
    ) {
        guard let recordingStartedAt else { return }

        let targetMetrics = targetZoneMetrics(
            from: sample,
            anchor: targetZoneAnchor,
            mode: targetZoneMode
        )
        let sharpnessScore = min(
            max(sample.laplacianVariance / (FrameQualityConstants.blurThresholdLaplacian * 1.35), 0),
            1
        )
        let brightnessScore = normalizedBrightnessScore(sample.meanBrightness)
        let occupancyScore = min(
            max(
                targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45,
                0
            ),
            1
        )
        let noveltyScore = novelty(
            current: sample.signature,
            previous: lastAcceptedSignature
        )
        let similarityScore = max(0, min(1 - noveltyScore, 1))
        let targetSignal = targetMetrics.textureScore * 0.55 + targetMetrics.contrastScore * 0.45
        let qualityScore = min(
            max(sharpnessScore * 0.58 + brightnessScore * 0.18 + occupancyScore * 0.24, 0),
            1
        )
        smoothedQuality = smoothedQuality == 0
            ? qualityScore
            : (smoothedQuality * 0.72 + qualityScore * 0.28)

        let now = sample.timestamp
        let recordingAge = Date().timeIntervalSince(recordingStartedAt)
        let enoughTimePassed = lastAcceptedAt.map { now - $0 > 0.28 } ?? true
        let qualityThreshold = acceptanceThreshold(for: snapshot.acceptedFrames)
        let maxSimilarity = maximumSimilarity(for: targetZoneMode)
        let lowTexture = sample.globalVariance < FrameQualityConstants.MIN_LOCAL_VARIANCE_FOR_TEXTURE

        var acceptedFrames = snapshot.acceptedFrames
        var acceptedNewFrame = false
        auditSummary.totalSamples += 1

        if sample.laplacianVariance < FrameQualityConstants.blurThresholdLaplacian {
            auditSummary.hardRejectBlurCount += 1
        }
        if sample.meanBrightness < FrameQualityConstants.darkThresholdBrightness {
            auditSummary.hardRejectDarkCount += 1
        }
        if sample.meanBrightness > FrameQualityConstants.brightThresholdBrightness {
            auditSummary.hardRejectBrightCount += 1
        }
        if targetSignal < hardRejectTargetSignalThreshold {
            auditSummary.hardRejectOccupancyCount += 1
        }
        if similarityScore > maxSimilarity {
            auditSummary.softDowngradeRedundantCount += 1
            auditSummary.guidanceNewAngleCount += 1
        }
        if lowTexture {
            auditSummary.softDowngradeLowTextureCount += 1
        }
        if qualityScore < qualityThreshold {
            auditSummary.softDowngradeWeakQualityCount += 1
        }
        if targetSignal < softWarnTargetSignalThreshold {
            auditSummary.guidanceRecenterCount += 1
        }
        if orbitCompletionHint(acceptedFrames: acceptedFrames, coverageCredits: coverageCredits) < 0.70 {
            auditSummary.guidanceCoverageCount += 1
        }

        if acceptedFrames == 0 {
            if recordingAge > 0.35,
               sharpnessScore > 0.20,
               brightnessScore > 0.32,
               occupancyScore > 0.10 {
                acceptedFrames = 1
                acceptedNewFrame = true
            }
        } else if acceptedFrames < maxAcceptedFrames,
                  enoughTimePassed,
                  sharpnessScore > 0.24,
                  brightnessScore > 0.28,
                  occupancyScore > 0.10,
                  similarityScore <= maxSimilarity,
                  qualityScore >= qualityThreshold {
            acceptedFrames += 1
            acceptedNewFrame = true
        }

        if acceptedNewFrame {
            lastAcceptedAt = now
            lastAcceptedSignature = sample.signature
            coverageCredits = min(
                1,
                coverageCredits + max(0.06, min(noveltyScore * 1.8, 0.16))
            )
        }

        let orbitCompletion = orbitCompletionHint(
            acceptedFrames: acceptedFrames,
            coverageCredits: coverageCredits
        )

        let hintText: String
        if acceptedFrames >= maxAcceptedFrames {
            hintText = "已达到当前模式的关键帧上限，可以结束生成。"
        } else if sharpnessScore < 0.22 {
            hintText = "画面有些模糊，放慢一点并稳住手机。"
        } else if brightnessScore < 0.28 {
            hintText = "当前光线不太理想，尽量让主体更亮、更清楚。"
        } else if occupancyScore < 0.12 {
            hintText = "让主体继续留在锁定目标区里，再补一个更明确的角度。"
        } else if acceptedFrames == 0 {
            hintText = "已经开始取证，继续围绕主体缓慢移动，很快会挑到第一帧。"
        } else if similarityScore > maxSimilarity {
            hintText = "继续移动到新的角度，避免一直停在同一面。"
        } else if orbitCompletion < 0.25 {
            hintText = "先补正面和侧面，保持主体始终在目标区附近。"
        } else if orbitCompletion < 0.70 {
            hintText = "很好，继续补背面和边缘角度，尽量绕满一圈。"
        } else if acceptedFrames < 20 {
            hintText = "快完成一圈了，再补一些新角度就能生成默认成品。"
        } else if acceptedFrames < 40 {
            hintText = "已经够做成品，继续补顶部和边缘细节会更稳。"
        } else {
            hintText = "质量已经不错，可以结束，也可以继续补更细节的角度。"
        }

        publish(.init(
            acceptedFrames: acceptedFrames,
            orbitCompletion: orbitCompletion,
            hintText: hintText,
            stabilityScore: smoothedQuality,
            lastAcceptedTimestamp: acceptedNewFrame ? now : nil
        ))
    }

    private func acceptanceThreshold(for acceptedFrames: Int) -> Double {
        if acceptedFrames < 8 {
            return 0.30
        }
        if acceptedFrames < 20 {
            return 0.36
        }
        return 0.42
    }

    private func maximumSimilarity(for targetZoneMode: ObjectModeV2TargetZoneMode) -> Double {
        switch targetZoneMode {
        case .subject:
            return FrameQualityConstants.maxFrameSimilarity
        case .group:
            return max(FrameQualityConstants.minFrameSimilarity, FrameQualityConstants.maxFrameSimilarity - 0.04)
        }
    }

    private func orbitCompletionHint(acceptedFrames: Int, coverageCredits: Double) -> Double {
        max(
            coverageCredits,
            min(Double(acceptedFrames) / 20.0, 1)
        )
    }

    private func normalizedBrightnessScore(_ brightness: Double) -> Double {
        let dark = FrameQualityConstants.darkThresholdBrightness
        let bright = FrameQualityConstants.brightThresholdBrightness
        if brightness < dark {
            return max(0, brightness / dark)
        }
        if brightness > bright {
            let overflow = max(0, brightness - bright)
            return max(0, 1 - overflow / max(1, 255 - bright))
        }
        return 1
    }

    private func novelty(current: Data, previous: Data) -> Double {
        guard !previous.isEmpty, previous.count == current.count else { return 1 }
        let currentBytes = [UInt8](current)
        let previousBytes = [UInt8](previous)
        guard !currentBytes.isEmpty else { return 0 }

        var difference = 0.0
        for index in currentBytes.indices {
            difference += abs(Double(currentBytes[index]) - Double(previousBytes[index])) / 255.0
        }
        return difference / Double(currentBytes.count)
    }

    private func targetZoneMetrics(
        from sample: ObjectModeV2VisualFrameSample,
        anchor: CGPoint,
        mode: ObjectModeV2TargetZoneMode
    ) -> (textureScore: Double, contrastScore: Double) {
        let pixels = [UInt8](sample.signature)
        let width = sample.signatureWidth
        let height = sample.signatureHeight
        guard width > 4, height > 4, pixels.count == width * height else {
            return (0, 0)
        }

        let zoneWidthFraction = mode == .subject ? 0.24 : 0.38
        let zoneHeightFraction = mode == .subject ? 0.28 : 0.34
        let rect = normalizedRect(
            anchor: anchor,
            widthFraction: zoneWidthFraction,
            heightFraction: zoneHeightFraction,
            imageWidth: width,
            imageHeight: height
        )
        let ringRect = expandedRect(rect, padding: mode == .subject ? 3 : 4, maxWidth: width, maxHeight: height)

        let zoneValues = pixelValues(in: rect, width: width, pixels: pixels)
        let ringValues = pixelValues(in: ringRect, width: width, pixels: pixels, excluding: rect)

        let zoneVariance = variance(of: zoneValues)
        let zoneMean = mean(of: zoneValues)
        let ringMean = mean(of: ringValues)

        let textureScore = min(zoneVariance / 420.0, 1)
        let contrastScore = min(abs(zoneMean - ringMean) / 28.0, 1)
        return (textureScore, contrastScore)
    }

    private func normalizedRect(
        anchor: CGPoint,
        widthFraction: Double,
        heightFraction: Double,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let width = max(4, Int(round(Double(imageWidth) * widthFraction)))
        let height = max(4, Int(round(Double(imageHeight) * heightFraction)))
        let centerX = Int(round(anchor.x * Double(imageWidth)))
        let centerY = Int(round(anchor.y * Double(imageHeight)))
        let x = min(max(centerX - width / 2, 0), max(imageWidth - width, 0))
        let y = min(max(centerY - height / 2, 0), max(imageHeight - height, 0))
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func expandedRect(_ rect: CGRect, padding: Int, maxWidth: Int, maxHeight: Int) -> CGRect {
        let x = max(Int(rect.minX) - padding, 0)
        let y = max(Int(rect.minY) - padding, 0)
        let maxX = min(Int(rect.maxX) + padding, maxWidth)
        let maxY = min(Int(rect.maxY) + padding, maxHeight)
        return CGRect(x: x, y: y, width: max(maxX - x, 1), height: max(maxY - y, 1))
    }

    private func pixelValues(
        in rect: CGRect,
        width: Int,
        pixels: [UInt8],
        excluding excludedRect: CGRect? = nil
    ) -> [Double] {
        let minX = Int(rect.minX)
        let maxX = Int(rect.maxX)
        let minY = Int(rect.minY)
        let maxY = Int(rect.maxY)
        var values: [Double] = []
        values.reserveCapacity(max((maxX - minX) * (maxY - minY), 0))

        for y in minY..<maxY {
            for x in minX..<maxX {
                if let excludedRect,
                   excludedRect.contains(CGPoint(x: x, y: y)) {
                    continue
                }
                let index = y * width + x
                guard pixels.indices.contains(index) else { continue }
                values.append(Double(pixels[index]))
            }
        }
        return values
    }

    private func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func variance(of values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let meanValue = mean(of: values)
        return values.reduce(0) { partial, value in
            let delta = value - meanValue
            return partial + delta * delta
        } / Double(values.count)
    }

    private func publish(_ snapshot: ObjectModeV2GuidanceSnapshot) {
        self.snapshot = snapshot
        onUpdate?(snapshot)
    }
}

#endif
