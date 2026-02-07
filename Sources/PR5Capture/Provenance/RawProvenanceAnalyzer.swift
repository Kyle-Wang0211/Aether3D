//
// RawProvenanceAnalyzer.swift
// PR5Capture
//
// PR5 v1.8.1 - PART A: Raw 溯源和 ISP 真实性
// RAW 数据溯源验证，PRNU 指纹匹配
//

import Foundation
#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Raw provenance analyzer
///
/// Analyzes RAW data provenance and ISP authenticity.
/// Implements PRNU fingerprint matching and HDR synthesis detection.
public actor RawProvenanceAnalyzer {
    
    // MARK: - Configuration
    
    private let config: ExtremeProfile
    
    // MARK: - State
    
    /// Known PRNU fingerprints (device-specific)
    private var knownPRNUFingerprints: [String: Data] = [:]
    
    /// HDR artifact detection history
    private var hdrArtifactHistory: [Date: Bool] = [:]
    
    // MARK: - Initialization
    
    public init(config: ExtremeProfile) {
        self.config = config
    }
    
    // MARK: - PRNU Fingerprint Analysis
    
    /// Analyze PRNU fingerprint from RAW data
    ///
    /// Extracts and matches PRNU fingerprint to verify device authenticity
    public func analyzePRNUFingerprint(_ rawData: Data, deviceId: String) -> PRNUAnalysisResult {
        // Extract PRNU fingerprint from RAW data
        let fingerprint = extractPRNUFingerprint(rawData)
        
        // Match against known fingerprints
        if let knownFingerprint = knownPRNUFingerprints[deviceId] {
            let similarity = computeFingerprintSimilarity(fingerprint, knownFingerprint)
            let threshold = PR5CaptureConstants.getValue(PR5CaptureConstants.Provenance.prnuMatchingThreshold, profile: config.profile)
            
            let matches = similarity >= threshold
            
            return PRNUAnalysisResult(
                deviceId: deviceId,
                fingerprint: fingerprint,
                similarity: similarity,
                matches: matches,
                threshold: threshold
            )
        } else {
            // First time seeing this device - store fingerprint
            knownPRNUFingerprints[deviceId] = fingerprint
            
            return PRNUAnalysisResult(
                deviceId: deviceId,
                fingerprint: fingerprint,
                similarity: 1.0,
                matches: true,
                threshold: 0.0,
                isNewDevice: true
            )
        }
    }
    
    /// Extract PRNU fingerprint from RAW data
    private func extractPRNUFingerprint(_ rawData: Data) -> Data {
        // Simplified PRNU extraction (actual implementation would use image processing)
        // In production, this would use sophisticated noise pattern analysis
        return rawData.sha256()
    }
    
    /// Compute fingerprint similarity (0.0 to 1.0)
    private func computeFingerprintSimilarity(_ fp1: Data, _ fp2: Data) -> Double {
        // Simplified similarity computation (Hamming distance normalized)
        // In production, this would use proper PRNU matching algorithms
        guard fp1.count == fp2.count else { return 0.0 }
        
        var matches = 0
        for i in 0..<fp1.count {
            if fp1[i] == fp2[i] {
                matches += 1
            }
        }
        
        return Double(matches) / Double(fp1.count)
    }
    
    // MARK: - HDR Artifact Detection
    
    /// Detect HDR artifacts in RAW data
    ///
    /// Detects tone mapping artifacts and pseudo-brightness from HDR synthesis
    public func detectHDRArtifacts(_ rawData: Data, metadata: [String: Any]) -> HDRArtifactResult {
        // Check metadata for HDR indicators
        let isHDR = metadata["isHDR"] as? Bool ?? false
        
        if isHDR {
            // Analyze for tone mapping artifacts
            let artifactScore = analyzeToneMappingArtifacts(rawData)
            let threshold = PR5CaptureConstants.getValue(PR5CaptureConstants.Provenance.hdrArtifactThreshold, profile: config.profile)
            
            let hasArtifacts = artifactScore >= threshold
            
            // Record in history
            hdrArtifactHistory[Date()] = hasArtifacts
            
            return HDRArtifactResult(
                isHDR: true,
                artifactScore: artifactScore,
                hasArtifacts: hasArtifacts,
                threshold: threshold
            )
        } else {
            return HDRArtifactResult(
                isHDR: false,
                artifactScore: 0.0,
                hasArtifacts: false,
                threshold: 0.0
            )
        }
    }
    
    /// Analyze tone mapping artifacts
    /// 
    /// 真实实现：分析像素值分布、直方图熵、梯度等，符合INV-SEC-067: 禁止使用Double.random作为安全相关返回值。
    private func analyzeToneMappingArtifacts(_ rawData: Data) -> Double {
        // 将数据解析为像素值
        guard rawData.count >= 3 else { return 0.0 }
        
        // 分析像素值分布
        var histogram = [Int](repeating: 0, count: 256)
        for byte in rawData {
            histogram[Int(byte)] += 1
        }
        
        // 计算直方图熵
        let totalPixels = Double(rawData.count)
        var entropy = 0.0
        
        for count in histogram where count > 0 {
            let probability = Double(count) / totalPixels
            entropy -= probability * log2(probability)
        }
        
        // 检测色调映射伪影的特征:
        // 1. 直方图间隙 (量化伪影)
        var gaps = 0
        var inGap = false
        for count in histogram {
            if count == 0 {
                if !inGap {
                    gaps += 1
                    inGap = true
                }
            } else {
                inGap = false
            }
        }
        
        // 2. 边缘处的聚集 (剪切)
        let lowClipping = histogram[0...5].reduce(0, +)
        let highClipping = histogram[250...255].reduce(0, +)
        let clippingRatio = Double(lowClipping + highClipping) / totalPixels
        
        // 3. 梯度分析 (色带)
        var gradientBreaks = 0
        for i in 1..<histogram.count {
            let diff = abs(histogram[i] - histogram[i-1])
            if diff > Int(totalPixels * 0.01) {
                gradientBreaks += 1
            }
        }
        
        // 综合评分 (0 = 无伪影, 1 = 严重伪影)
        let gapScore = min(Double(gaps) / 50.0, 1.0)
        let clippingScore = min(clippingRatio * 10, 1.0)
        let gradientScore = min(Double(gradientBreaks) / 20.0, 1.0)
        
        return (gapScore * 0.3 + clippingScore * 0.4 + gradientScore * 0.3)
    }
    
    // MARK: - Result Types
    
    /// PRNU analysis result
    public struct PRNUAnalysisResult: Sendable {
        public let deviceId: String
        public let fingerprint: Data
        public let similarity: Double
        public let matches: Bool
        public let threshold: Double
        public let isNewDevice: Bool
        
        public init(
            deviceId: String,
            fingerprint: Data,
            similarity: Double,
            matches: Bool,
            threshold: Double,
            isNewDevice: Bool = false
        ) {
            self.deviceId = deviceId
            self.fingerprint = fingerprint
            self.similarity = similarity
            self.matches = matches
            self.threshold = threshold
            self.isNewDevice = isNewDevice
        }
    }
    
    /// HDR artifact detection result
    public struct HDRArtifactResult: Sendable {
        public let isHDR: Bool
        public let artifactScore: Double
        public let hasArtifacts: Bool
        public let threshold: Double
    }
}

// MARK: - Data Extension

private extension Data {
    func sha256() -> Data {
        #if canImport(CryptoKit)
        return Data(SHA256.hash(data: self))
        #elseif canImport(Crypto)
        return Data(SHA256.hash(data: self))
        #else
        var hash: UInt64 = 5381
        for byte in self {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return withUnsafeBytes(of: hash) { Data($0) }
        #endif
    }
}
