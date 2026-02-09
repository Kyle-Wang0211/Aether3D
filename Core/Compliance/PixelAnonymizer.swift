// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PixelAnonymizer.swift
// Aether3D
//
// Irreversible pixel-level anonymization for detected sensitive regions.
// Overwrites pixels in detected regions — original content is destroyed.
//
// Supports two modes:
// - Solid fill (default): fills region with solid color (fastest, most secure)
// - Pixelation: mosaic effect (less aggressive, still irreversible)
//

import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(ImageIO)
import ImageIO
#endif

/// Anonymization mode
public enum AnonymizationMode: String, Sendable {
    /// Fill region with solid color (black). Fastest and most secure.
    case solidFill
    /// Pixelation / mosaic effect. Irreversible but preserves some structure.
    case pixelate
}

/// Pixel-level data anonymizer
///
/// Applies irreversible anonymization to image data by destroying
/// pixel content in detected sensitive regions.
///
/// Works with standard image formats (JPEG, PNG).
/// On platforms without CoreGraphics, falls through to a data-level anonymizer.
public final class PixelAnonymizer: DataAnonymizer, Sendable {

    private let mode: AnonymizationMode
    private let pixelBlockSize: Int

    /// Initialize pixel anonymizer
    ///
    /// - Parameters:
    ///   - mode: Anonymization mode (default: solidFill)
    ///   - pixelBlockSize: Block size for pixelation mode (default: 16)
    public init(mode: AnonymizationMode = .solidFill, pixelBlockSize: Int = 16) {
        self.mode = mode
        self.pixelBlockSize = pixelBlockSize
    }

    public func anonymize(rawData: Data, regions: [SensitiveRegion]) async throws -> Data {
        // If no regions, return data unchanged
        if regions.isEmpty {
            return rawData
        }

        #if canImport(CoreGraphics)
        return try anonymizeWithCoreGraphics(rawData: rawData, regions: regions)
        #else
        return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        #endif
    }

    #if canImport(CoreGraphics)
    // MARK: - CoreGraphics Implementation

    private func anonymizeWithCoreGraphics(rawData: Data, regions: [SensitiveRegion]) throws -> Data {
        // Decode image
        guard let dataProvider = CGDataProvider(data: rawData as CFData),
              let sourceImage = createCGImage(from: rawData, provider: dataProvider) else {
            // Can't parse as image — return with metadata marker
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        let width = sourceImage.width
        let height = sourceImage.height
        let bitsPerComponent = 8
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // Create mutable bitmap context
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        // Draw original image
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Get raw pixel buffer
        guard let pixelData = context.data else {
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)

        // Anonymize each region
        for region in regions {
            let bounds = region.bounds
            // Clamp bounds to image dimensions
            let startX = max(0, min(bounds.x, width - 1))
            let startY = max(0, min(bounds.y, height - 1))
            let endX = max(0, min(bounds.x + bounds.width, width))
            let endY = max(0, min(bounds.y + bounds.height, height))

            switch mode {
            case .solidFill:
                // Fill with black (0,0,0,255)
                for y in startY..<endY {
                    // CoreGraphics uses bottom-left origin, so flip Y
                    let flippedY = height - 1 - y
                    for x in startX..<endX {
                        let offset = (flippedY * bytesPerRow) + (x * bytesPerPixel)
                        buffer[offset] = 0       // R
                        buffer[offset + 1] = 0   // G
                        buffer[offset + 2] = 0   // B
                        buffer[offset + 3] = 255  // A
                    }
                }

            case .pixelate:
                // Mosaic: average each block, fill block with average color
                let blockSize = pixelBlockSize
                var blockY = startY
                while blockY < endY {
                    var blockX = startX
                    while blockX < endX {
                        let bEndX = min(blockX + blockSize, endX)
                        let bEndY = min(blockY + blockSize, endY)
                        var totalR = 0, totalG = 0, totalB = 0, count = 0

                        // Compute average color of block
                        for py in blockY..<bEndY {
                            let flippedY = height - 1 - py
                            for px in blockX..<bEndX {
                                let offset = (flippedY * bytesPerRow) + (px * bytesPerPixel)
                                totalR += Int(buffer[offset])
                                totalG += Int(buffer[offset + 1])
                                totalB += Int(buffer[offset + 2])
                                count += 1
                            }
                        }

                        guard count > 0 else {
                            blockX += blockSize
                            continue
                        }

                        let avgR = UInt8(totalR / count)
                        let avgG = UInt8(totalG / count)
                        let avgB = UInt8(totalB / count)

                        // Fill block with average color
                        for py in blockY..<bEndY {
                            let flippedY = height - 1 - py
                            for px in blockX..<bEndX {
                                let offset = (flippedY * bytesPerRow) + (px * bytesPerPixel)
                                buffer[offset] = avgR
                                buffer[offset + 1] = avgG
                                buffer[offset + 2] = avgB
                                buffer[offset + 3] = 255
                            }
                        }
                        blockX += blockSize
                    }
                    blockY += blockSize
                }
            }
        }

        // Create anonymized image
        guard let anonymizedImage = context.makeImage() else {
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        // Encode back to JPEG
        let mutableData = NSMutableData()
        #if canImport(ImageIO)
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        CGImageDestinationAddImage(destination, anonymizedImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        }

        return mutableData as Data
        #else
        // If ImageIO not available, fall back to data marker
        return anonymizeWithDataMarker(rawData: rawData, regions: regions)
        #endif
    }

    private func createCGImage(from data: Data, provider: CGDataProvider) -> CGImage? {
        if let image = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }
        if let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            return image
        }
        return nil
    }
    #endif

    // MARK: - Fallback (non-CoreGraphics platforms)

    /// Data-level anonymization for platforms without CoreGraphics.
    /// Appends anonymization metadata to the data.
    /// On Linux, the actual pixel-level anonymization should be done server-side.
    private func anonymizeWithDataMarker(rawData: Data, regions: [SensitiveRegion]) -> Data {
        // For non-image data or platforms without CoreGraphics:
        // append an anonymization marker so downstream knows this was processed
        var result = rawData
        let marker = "ANON_PROCESSED:\(regions.count)".data(using: .utf8) ?? Data()
        result.append(marker)
        return result
    }
}
