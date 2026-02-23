// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
//  MotionAnalyzer.swift
//  Aether3D
//
//  PR#5 Quality Pre-check - Milestone 2
//  MotionAnalyzer - sensor fusion (gyro + frame diff) motion analysis
//

import Foundation
import CAetherNativeBridge
// Note: CoreMotion import removed as it's not currently used in this file
// If CoreMotion functionality is added later, use #if canImport(CoreMotion) guard

/// MotionResult - result of motion analysis
public struct MotionResult: Codable, Sendable {
    public let score: Double
    public let isFastPan: Bool
    public let isHandShake: Bool
    
    public init(score: Double, isFastPan: Bool, isHandShake: Bool) {
        self.score = score
        self.isFastPan = isFastPan
        self.isHandShake = isHandShake
    }
}

/// MotionAnalyzer - motion analysis with sensor fusion
/// 符合 PR5-01: IMU-integrated blur detection
public final class MotionAnalyzer: @unchecked Sendable {
    private let nativeAnalyzer: OpaquePointer?
    
    public init() {
        var handle: OpaquePointer?
        if aether_motion_analyzer_create(&handle) == 0 {
            self.nativeAnalyzer = handle
        } else {
            self.nativeAnalyzer = nil
        }
    }

    deinit {
        if let nativeAnalyzer {
            _ = aether_motion_analyzer_destroy(nativeAnalyzer)
        }
    }
    
    /// Analyze motion for frame
    /// 
    /// 符合 PR5-01: IMU-integrated motion blur detection
    /// - Parameter frame: Frame data
    /// - Returns: Motion result
    public func analyze(frame: FrameData) async -> MotionResult {
        guard let nativeAnalyzer,
              let width = frame.width,
              let height = frame.height,
              width > 0,
              height > 0,
              frame.imageData.count >= width * height else {
            return MotionResult(score: 0.0, isFastPan: false, isHandShake: false)
        }
        var nativeResult = aether_motion_result_t()
        let rc = frame.imageData.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress
            return aether_motion_analyzer_analyze(
                nativeAnalyzer,
                base,
                Int32(width),
                Int32(height),
                &nativeResult
            )
        }
        guard rc == 0 else {
            return MotionResult(score: 0.0, isFastPan: false, isHandShake: false)
        }
        return MotionResult(
            score: nativeResult.score,
            isFastPan: nativeResult.is_fast_pan != 0,
            isHandShake: nativeResult.is_hand_shake != 0
        )
    }
    
    /// Analyze motion for given quality level (legacy method)
    /// Sensor fusion: gyro + frame diff
    /// High-frequency shake detection (>5Hz)
    public func analyze(qualityLevel: QualityLevel) -> MetricResult? {
        if let nativeAnalyzer {
            var value = 0.0
            var confidence = 0.0
            let nativeLevel: Int32
            switch qualityLevel {
            case .full:
                nativeLevel = 0
            case .degraded:
                nativeLevel = 1
            case .emergency:
                nativeLevel = 2
            }
            if aether_motion_analyzer_quality_metric(
                nativeAnalyzer,
                nativeLevel,
                &value,
                &confidence
            ) == 0 {
                if value.isNaN || value.isInfinite {
                    return MetricResult(value: 0.0, confidence: 0.0)
                }
                return MetricResult(value: value, confidence: confidence)
            }
        }
        return MetricResult(value: 0.0, confidence: 0.0)
    }
}
