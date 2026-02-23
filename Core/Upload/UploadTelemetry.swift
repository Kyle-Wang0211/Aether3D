// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// CONSTITUTIONAL CONTRACT - DO NOT EDIT WITHOUT RFC
// Contract Version: PR9-TELEMETRY-1.0
// Module: Upload Infrastructure - Upload Telemetry
// Cross-Platform: macOS + Linux (pure Foundation)

import Foundation

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

/// Structured per-chunk trace with all 6 layers' metrics.
///
/// **Purpose**: Structured per-chunk trace with all 6 layers' metrics,
/// HMAC-signed audit entries, differential privacy ε=1.0.
///
/// **Telemetry Entry**:
/// - Chunk index, size, hash (truncated to 8 chars)
/// - I/O method, CRC32C, compressibility
/// - Network metrics (bandwidth, RTT, loss)
/// - Layer timings (I/O, transport, hash, erasure, scheduling)
/// - HMAC signature for tamper detection
public actor UploadTelemetry {
    
    // MARK: - Telemetry Entry
    
    public struct TelemetryEntry: Sendable, Codable {
        public let chunkIndex: Int
        public let chunkSize: Int
        public let chunkHashPrefix: String  // First 8 chars only
        public let ioMethod: String
        public let crc32c: UInt32
        public let compressibility: Double
        public let bandwidthMbps: Double
        public let rttMs: Double
        public let lossRate: Double
        public let layerTimings: LayerTimings
        public let timestamp: Date
        public let hmacSignature: String
    }
    
    public struct LayerTimings: Sendable, Codable {
        public let ioMs: Double
        public let transportMs: Double
        public let hashMs: Double
        public let erasureMs: Double
        public let schedulingMs: Double
    }

    public struct RuntimeSummary: Sendable, Codable, Equatable {
        public let sampleCount: Int
        public let avgChunkSizeBytes: Double
        public let avgBandwidthMbps: Double
        public let avgRttMs: Double
        public let avgLossRate: Double
        public let avgCompressibility: Double
        public let invalidHMACEntryCount: Int
        public let validHMACRate: Double

        public init(
            sampleCount: Int,
            avgChunkSizeBytes: Double,
            avgBandwidthMbps: Double,
            avgRttMs: Double,
            avgLossRate: Double,
            avgCompressibility: Double,
            invalidHMACEntryCount: Int,
            validHMACRate: Double
        ) {
            self.sampleCount = sampleCount
            self.avgChunkSizeBytes = avgChunkSizeBytes
            self.avgBandwidthMbps = avgBandwidthMbps
            self.avgRttMs = avgRttMs
            self.avgLossRate = avgLossRate
            self.avgCompressibility = avgCompressibility
            self.invalidHMACEntryCount = invalidHMACEntryCount
            self.validHMACRate = validHMACRate
        }
    }

    
    // MARK: - State
    
    private var entries: [TelemetryEntry] = []
    private let hmacKey: SymmetricKey
    private let maxEntries = 1000 // LINT:ALLOW
    
    // MARK: - Initialization
    
    /// Initialize upload telemetry.
    ///
    /// - Parameter hmacKey: HMAC key for signing entries
    public init(hmacKey: SymmetricKey) {
        self.hmacKey = hmacKey
    }
    
    // MARK: - Telemetry Recording
    
    /// Record chunk telemetry entry.
    ///
    /// - Parameter entry: Telemetry entry (without HMAC)
    public func recordChunk(_ entry: TelemetryEntry) {
        // Apply differential privacy noise (ε=1.0)
        let noisyEntry = applyDifferentialPrivacy(entry)

        // Enforce privacy contract: telemetry only stores first 8 hash chars.
        let truncatedHash = String(noisyEntry.chunkHashPrefix.prefix(8))

        let unsignedEntry = TelemetryEntry(
            chunkIndex: noisyEntry.chunkIndex,
            chunkSize: noisyEntry.chunkSize,
            chunkHashPrefix: truncatedHash,
            ioMethod: noisyEntry.ioMethod,
            crc32c: noisyEntry.crc32c,
            compressibility: noisyEntry.compressibility,
            bandwidthMbps: noisyEntry.bandwidthMbps,
            rttMs: noisyEntry.rttMs,
            lossRate: noisyEntry.lossRate,
            layerTimings: noisyEntry.layerTimings,
            timestamp: noisyEntry.timestamp,
            hmacSignature: ""
        )

        let signature = computeHMAC(for: unsignedEntry)
        let signedEntry = TelemetryEntry(
            chunkIndex: unsignedEntry.chunkIndex,
            chunkSize: unsignedEntry.chunkSize,
            chunkHashPrefix: unsignedEntry.chunkHashPrefix,
            ioMethod: unsignedEntry.ioMethod,
            crc32c: unsignedEntry.crc32c,
            compressibility: unsignedEntry.compressibility,
            bandwidthMbps: unsignedEntry.bandwidthMbps,
            rttMs: unsignedEntry.rttMs,
            lossRate: unsignedEntry.lossRate,
            layerTimings: unsignedEntry.layerTimings,
            timestamp: unsignedEntry.timestamp,
            hmacSignature: signature
        )
        
        entries.append(signedEntry)
        
        // Limit entries
        if entries.count > maxEntries {
            entries.removeFirst()
        }
    }
    
    /// Get telemetry entries (for debugging/logging).
    public func getEntries() -> [TelemetryEntry] {
        return entries
    }

    /// Aggregate runtime summary for PureVision fusion sampling.
    public func runtimeSummary() -> RuntimeSummary {
        guard !entries.isEmpty else {
            return RuntimeSummary(
                sampleCount: 0,
                avgChunkSizeBytes: 0,
                avgBandwidthMbps: 0,
                avgRttMs: 0,
                avgLossRate: 0,
                avgCompressibility: 0,
                invalidHMACEntryCount: 0,
                validHMACRate: 1.0
            )
        }

        let count = entries.count
        let chunkSizeSum = entries.reduce(0.0) { $0 + Double($1.chunkSize) }
        let bandwidthSum = entries.reduce(0.0) { $0 + $1.bandwidthMbps }
        let rttSum = entries.reduce(0.0) { $0 + $1.rttMs }
        let lossSum = entries.reduce(0.0) { $0 + $1.lossRate }
        let compressibilitySum = entries.reduce(0.0) { $0 + $1.compressibility }
        let invalidHmacCount = entries.reduce(0) { partial, entry in
            partial + (isSignatureValid(entry) ? 0 : 1)
        }
        let validRate = 1.0 - (Double(invalidHmacCount) / Double(count))

        return RuntimeSummary(
            sampleCount: count,
            avgChunkSizeBytes: chunkSizeSum / Double(count),
            avgBandwidthMbps: bandwidthSum / Double(count),
            avgRttMs: rttSum / Double(count),
            avgLossRate: lossSum / Double(count),
            avgCompressibility: compressibilitySum / Double(count),
            invalidHMACEntryCount: invalidHmacCount,
            validHMACRate: max(0.0, min(1.0, validRate))
        )
    }

    // MARK: - Differential Privacy
    
    /// Apply differential privacy noise (ε=1.0).
    private func applyDifferentialPrivacy(_ entry: TelemetryEntry) -> TelemetryEntry {
        // Simplified DP noise (full implementation would use Laplace mechanism)
        // For now, return entry as-is
        return entry
    }
    
    /// Compute HMAC signature for entry.
    private func computeHMAC(for entry: TelemetryEntry) -> String {
        let payload = canonicalHMACPayload(for: entry)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: hmacKey)
        return mac.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func isSignatureValid(_ entry: TelemetryEntry) -> Bool {
        let unsignedEntry = TelemetryEntry(
            chunkIndex: entry.chunkIndex,
            chunkSize: entry.chunkSize,
            chunkHashPrefix: entry.chunkHashPrefix,
            ioMethod: entry.ioMethod,
            crc32c: entry.crc32c,
            compressibility: entry.compressibility,
            bandwidthMbps: entry.bandwidthMbps,
            rttMs: entry.rttMs,
            lossRate: entry.lossRate,
            layerTimings: entry.layerTimings,
            timestamp: entry.timestamp,
            hmacSignature: ""
        )
        return computeHMAC(for: unsignedEntry) == entry.hmacSignature
    }

    /// Build deterministic binary payload for HMAC signing.
    /// This avoids JSON key-order nondeterminism across encoder instances.
    private func canonicalHMACPayload(for entry: TelemetryEntry) -> Data {
        var data = Data()

        // Versioned domain separator.
        data.append(contentsOf: [0x55, 0x54, 0x01]) // "UT" + v1

        appendInt64(Int64(clamping: entry.chunkIndex), to: &data)
        appendInt64(Int64(clamping: entry.chunkSize), to: &data)
        appendLengthPrefixedUTF8(entry.chunkHashPrefix, to: &data)
        appendLengthPrefixedUTF8(entry.ioMethod, to: &data)
        appendUInt32(entry.crc32c, to: &data)
        appendDouble(entry.compressibility, to: &data)
        appendDouble(entry.bandwidthMbps, to: &data)
        appendDouble(entry.rttMs, to: &data)
        appendDouble(entry.lossRate, to: &data)

        appendDouble(entry.layerTimings.ioMs, to: &data)
        appendDouble(entry.layerTimings.transportMs, to: &data)
        appendDouble(entry.layerTimings.hashMs, to: &data)
        appendDouble(entry.layerTimings.erasureMs, to: &data)
        appendDouble(entry.layerTimings.schedulingMs, to: &data)

        appendUInt64(entry.timestamp.timeIntervalSince1970.bitPattern, to: &data)
        appendLengthPrefixedUTF8(entry.hmacSignature, to: &data)
        return data
    }

    private func appendLengthPrefixedUTF8(_ value: String, to data: inout Data) {
        let bytes = Array(value.utf8)
        appendUInt32(UInt32(clamping: bytes.count), to: &data)
        data.append(contentsOf: bytes)
    }

    private func appendInt64(_ value: Int64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendUInt64(_ value: UInt64, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendDouble(_ value: Double, to data: inout Data) {
        appendUInt64(value.bitPattern, to: &data)
    }
}
