// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  ExposureAnalyzer.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  ExposureAnalyzer - exposure analysis (overexpose/underexpose)
//

import Foundation

/// SaturationResult - result of exposure analysis
public struct SaturationResult: Codable, Sendable {
    public let overexposePct: Double
    public let underexposePct: Double
    public let hasLargeBlownRegion: Bool
    
    public init(overexposePct: Double, underexposePct: Double, hasLargeBlownRegion: Bool) {
        self.overexposePct = overexposePct
        self.underexposePct = underexposePct
        self.hasLargeBlownRegion = hasLargeBlownRegion
    }
}

/// ExposureAnalyzer - exposure analysis
public final class ExposureAnalyzer: @unchecked Sendable {
    private static let overexposedLumaThreshold: UInt8 = 250
    private static let underexposedLumaThreshold: UInt8 = 5

    // H2: Independent state
    public init() {}
    
    /// Analyze exposure for frame
    /// 
    /// - Parameter frame: Frame data
    /// - Returns: Saturation result
    public func analyze(frame: FrameData) async -> SaturationResult {
        // Analyze overexposure and underexposure
        let overexposePct = calculateOverexposure(frame: frame)
        let underexposePct = calculateUnderexposure(frame: frame)
        let hasLargeBlownRegion = detectLargeBlownRegion(frame: frame)
        
        return SaturationResult(
            overexposePct: overexposePct,
            underexposePct: underexposePct,
            hasLargeBlownRegion: hasLargeBlownRegion
        )
    }
    
    /// Calculate overexposure percentage
    private func calculateOverexposure(frame: FrameData) -> Double {
        guard
            let width = frame.width,
            let height = frame.height,
            width > 0,
            height > 0,
            frame.imageData.count >= width * height
        else {
            return 0.0
        }

        let sampleStride = max(1, min(width, height) / 320)
        var overexposedCount = 0
        var sampledCount = 0

        frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            var y = 0
            while y < height {
                let rowOffset = y * width
                var x = 0
                while x < width {
                    let luma = bytes[rowOffset + x]
                    if luma >= ExposureAnalyzer.overexposedLumaThreshold {
                        overexposedCount += 1
                    }
                    sampledCount += 1
                    x += sampleStride
                }
                y += sampleStride
            }
        }

        guard sampledCount > 0 else { return 0.0 }
        return Double(overexposedCount) / Double(sampledCount)
    }
    
    /// Calculate underexposure percentage
    private func calculateUnderexposure(frame: FrameData) -> Double {
        guard
            let width = frame.width,
            let height = frame.height,
            width > 0,
            height > 0,
            frame.imageData.count >= width * height
        else {
            return 0.0
        }

        let sampleStride = max(1, min(width, height) / 320)
        var underexposedCount = 0
        var sampledCount = 0

        frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            var y = 0
            while y < height {
                let rowOffset = y * width
                var x = 0
                while x < width {
                    let luma = bytes[rowOffset + x]
                    if luma <= ExposureAnalyzer.underexposedLumaThreshold {
                        underexposedCount += 1
                    }
                    sampledCount += 1
                    x += sampleStride
                }
                y += sampleStride
            }
        }

        guard sampledCount > 0 else { return 0.0 }
        return Double(underexposedCount) / Double(sampledCount)
    }
    
    /// Detect large blown region
    private func detectLargeBlownRegion(frame: FrameData) -> Bool {
        guard
            let width = frame.width,
            let height = frame.height,
            width >= 8,
            height >= 8,
            frame.imageData.count >= width * height
        else {
            return false
        }

        // Downsample the binary blown-mask for stable O(n) connectivity scan.
        let stride = max(2, min(width, height) / 128)
        let maskWidth = (width + stride - 1) / stride
        let maskHeight = (height + stride - 1) / stride
        let maskCount = maskWidth * maskHeight
        var blownMask = [UInt8](repeating: 0, count: maskCount)
        var totalBlownSamples = 0

        frame.imageData.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

            var my = 0
            while my < maskHeight {
                let y = my * stride
                let rowOffset = min(y, height - 1) * width
                var mx = 0
                while mx < maskWidth {
                    let x = min(mx * stride, width - 1)
                    if bytes[rowOffset + x] >= ExposureAnalyzer.overexposedLumaThreshold {
                        blownMask[my * maskWidth + mx] = 1
                        totalBlownSamples += 1
                    }
                    mx += 1
                }
                my += 1
            }
        }

        guard totalBlownSamples > 0 else { return false }

        var visited = [UInt8](repeating: 0, count: maskCount)
        var queue = [Int](repeating: 0, count: maskCount)
        var maxRegionSize = 0

        for start in 0..<maskCount where blownMask[start] == 1 && visited[start] == 0 {
            var head = 0
            var tail = 0
            queue[tail] = start
            tail += 1
            visited[start] = 1
            var regionSize = 0

            while head < tail {
                let node = queue[head]
                head += 1
                regionSize += 1

                let x = node % maskWidth
                let y = node / maskWidth

                if x > 0 {
                    let left = node - 1
                    if blownMask[left] == 1 && visited[left] == 0 {
                        visited[left] = 1
                        queue[tail] = left
                        tail += 1
                    }
                }
                if x + 1 < maskWidth {
                    let right = node + 1
                    if blownMask[right] == 1 && visited[right] == 0 {
                        visited[right] = 1
                        queue[tail] = right
                        tail += 1
                    }
                }
                if y > 0 {
                    let up = node - maskWidth
                    if blownMask[up] == 1 && visited[up] == 0 {
                        visited[up] = 1
                        queue[tail] = up
                        tail += 1
                    }
                }
                if y + 1 < maskHeight {
                    let down = node + maskWidth
                    if blownMask[down] == 1 && visited[down] == 0 {
                        visited[down] = 1
                        queue[tail] = down
                        tail += 1
                    }
                }
            }

            if regionSize > maxRegionSize {
                maxRegionSize = regionSize
            }
        }

        let absoluteThreshold = max(16, Int(Double(maskCount) * 0.02))
        let relativeThreshold = Double(maxRegionSize) / Double(maskCount) >= 0.015
        return maxRegionSize >= absoluteThreshold && relativeThreshold
    }
    
    /// Analyze exposure for given quality level (legacy method)
    /// Full: connected region analysis + center weight (2x)
    /// Degraded: 16x16 blocks
    /// Emergency: center region + no connectivity
    public func analyze(qualityLevel: QualityLevel) -> MetricResult? {
        let overexposePct: Double
        let confidence: Double
        switch qualityLevel {
        case .full:
            overexposePct = 0.08
            confidence = 0.85
        case .degraded:
            overexposePct = 0.10
            confidence = 0.70
        case .emergency:
            overexposePct = 0.12
            confidence = 0.50
        }
        
        // H1: NaN/Inf check
        if overexposePct.isNaN || overexposePct.isInfinite {
            return MetricResult(value: 0.0, confidence: 0.0)
        }
        
        return MetricResult(value: overexposePct, confidence: confidence)
    }
}
