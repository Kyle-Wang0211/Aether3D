// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// VisionRegionDetector.swift
// Aether3D
//
// Apple Vision framework implementation of SensitiveRegionDetector.
// Detects faces and text regions in image data.
//
// Only available on Apple platforms (iOS/macOS).
// On Linux, use a server-side detector instead.
//

import Foundation

#if canImport(Vision) && canImport(CoreGraphics)
import Vision
import CoreGraphics
#if canImport(ImageIO)
import ImageIO
#endif

/// Apple Vision-based sensitive region detector
///
/// Uses VNDetectFaceRectanglesRequest for face detection
/// and VNRecognizeTextRequest for text/license plate detection.
/// Runs entirely on-device — no network required, no data leaves the device.
///
/// Usage:
/// ```swift
/// let detector = VisionRegionDetector()
/// let regions = try await detector.detectSensitiveRegions(in: imageData)
/// ```
public final class VisionRegionDetector: SensitiveRegionDetector, @unchecked Sendable {

    /// Minimum confidence threshold for face detection (0.0 - 1.0)
    private let faceConfidenceThreshold: Float

    /// Whether to also detect text regions (potential license plates, names, etc.)
    private let detectText: Bool

    public init(faceConfidenceThreshold: Float = 0.5, detectText: Bool = true) {
        self.faceConfidenceThreshold = faceConfidenceThreshold
        self.detectText = detectText
    }

    public func detectSensitiveRegions(in rawData: Data) async throws -> [SensitiveRegion] {
        // Create CGImage from raw data (supports JPEG, PNG, HEIC, etc.)
        guard let dataProvider = CGDataProvider(data: rawData as CFData),
              let cgImage = createCGImage(from: rawData, provider: dataProvider) else {
            // If we can't parse the image, return empty (no regions to mask)
            return []
        }

        let imageWidth = cgImage.width
        let imageHeight = cgImage.height

        var regions: [SensitiveRegion] = []

        // Face detection
        let faceRegions = try await detectFaces(in: cgImage, width: imageWidth, height: imageHeight)
        regions.append(contentsOf: faceRegions)

        // Text detection (for license plates, visible names, etc.)
        if detectText {
            let textRegions = try await detectTextRegions(in: cgImage, width: imageWidth, height: imageHeight)
            regions.append(contentsOf: textRegions)
        }

        return regions
    }

    // MARK: - Face Detection

    private func detectFaces(in cgImage: CGImage, width: Int, height: Int) async throws -> [SensitiveRegion] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNDetectFaceRectanglesRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let regions = (request.results as? [VNFaceObservation] ?? [])
                    .filter { $0.confidence >= self.faceConfidenceThreshold }
                    .map { observation -> SensitiveRegion in
                        // Vision coordinates are normalized (0-1), bottom-left origin
                        // Convert to pixel coordinates, top-left origin
                        let box = observation.boundingBox
                        let x = Int(box.origin.x * CGFloat(width))
                        let y = Int((1.0 - box.origin.y - box.height) * CGFloat(height))
                        let w = Int(box.width * CGFloat(width))
                        let h = Int(box.height * CGFloat(height))

                        return SensitiveRegion(
                            type: .face,
                            bounds: SensitiveRegion.RegionBounds(x: x, y: y, width: w, height: h),
                            confidence: Double(observation.confidence)
                        )
                    }

                continuation.resume(returning: regions)
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Text Detection

    private func detectTextRegions(in cgImage: CGImage, width: Int, height: Int) async throws -> [SensitiveRegion] {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                let regions = (request.results as? [VNRecognizedTextObservation] ?? [])
                    .filter { $0.confidence >= 0.5 }
                    .map { observation -> SensitiveRegion in
                        let box = observation.boundingBox
                        let x = Int(box.origin.x * CGFloat(width))
                        let y = Int((1.0 - box.origin.y - box.height) * CGFloat(height))
                        let w = Int(box.width * CGFloat(width))
                        let h = Int(box.height * CGFloat(height))

                        return SensitiveRegion(
                            type: .text,
                            bounds: SensitiveRegion.RegionBounds(x: x, y: y, width: w, height: h),
                            confidence: Double(observation.confidence)
                        )
                    }

                continuation.resume(returning: regions)
            }

            // Fast recognition is sufficient for detecting text presence
            request.recognitionLevel = .fast

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Image Parsing

    /// Create CGImage from raw data (JPEG, PNG, HEIC, TIFF, etc.)
    private func createCGImage(from data: Data, provider: CGDataProvider) -> CGImage? {
        // Try common image formats
        if let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }
        if let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }

        // Fallback: use ImageIO for other formats (HEIC, TIFF, etc.)
        #if canImport(ImageIO)
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return image
        }
        #endif

        return nil
    }
}

#endif

// MARK: - Fallback for non-Apple platforms

/// No-op detector for platforms without Vision framework (Linux, etc.)
///
/// Returns empty regions — no sensitive content detected.
/// On these platforms, use a server-side detector instead.
public final class NoOpRegionDetector: SensitiveRegionDetector, Sendable {
    public init() {}

    public func detectSensitiveRegions(in rawData: Data) async throws -> [SensitiveRegion] {
        return []
    }
}
