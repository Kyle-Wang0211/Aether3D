// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

final class PureVisionRuntimeAuditInputSamplerTests: XCTestCase {
    func testSamplerAutoSamplesFromRuntimeModules() async throws {
        let qualityAnalyzer = QualityAnalyzer()
        let darkFrame = FrameData(
            index: 0,
            timestamp: Date(),
            imageData: Data(repeating: 0, count: 64),
            width: 8,
            height: 8
        )
        let brightFrame = FrameData(
            index: 1,
            timestamp: Date(),
            imageData: Data(repeating: 255, count: 64),
            width: 8,
            height: 8
        )
        _ = await qualityAnalyzer.analyzeFrame(darkFrame)
        _ = await qualityAnalyzer.analyzeFrame(brightFrame)

        let evidenceEngine = await IsolatedEvidenceEngine()
        let observation = EvidenceObservation(
            patchId: "tri_patch_0",
            timestamp: 1.0,
            frameId: "frame_0",
            triTetMetadata: .init(
                triTetBindingDigest: "binding_digest",
                crossValidationReasonCode: "OUTLIER_BOTH_INLIER"
            )
        )
        await evidenceEngine.processObservation(
            observation,
            gateQuality: 0.86,
            softQuality: 0.79,
            verdict: .good
        )
        await evidenceEngine.recordReplayValidation(stable: true)
        await evidenceEngine.recordReplayValidation(stable: false)

        let requestSigner = RequestSigner(secretKey: SymmetricKey(size: .bits256))
        let timestamp = Date()
        let nonce = UUID()
        let signature = await requestSigner.signRequest(
            method: "POST",
            path: "/api/upload",
            timestamp: timestamp,
            body: nil,
            nonce: nonce
        )
        let verifyPass = try await requestSigner.verifyRequest(
            method: "POST",
            path: "/api/upload",
            timestamp: timestamp,
            body: nil,
            nonce: nonce,
            signature: signature
        )
        XCTAssertTrue(verifyPass)

        let context = PureVisionRuntimeAuditSamplingContext(
            runtimeMetrics: .init(
                baselinePixels: 10.0,
                blurLaplacian: 280.0,
                orbFeatures: 700,
                parallaxRatio: 0.09,
                depthSigmaMeters: 0.01,
                closureRatio: 0.92,
                unknownVoxelRatio: 0.04,
                thermalCelsius: 40.0
            )
        )
        let modules = PureVisionRuntimeAuditRuntimeModules(
            qualityAnalyzer: qualityAnalyzer,
            evidenceEngine: evidenceEngine,
            requestSigner: requestSigner
        )

        let sampled = await PureVisionRuntimeAuditInputSampler.sample(
            context: context,
            modules: modules
        )

        XCTAssertGreaterThan(sampled.captureSignals.motionScore, 0.0)
        XCTAssertGreaterThan(
            sampled.captureSignals.overexposureRatio + sampled.captureSignals.underexposureRatio,
            0.0
        )
        XCTAssertGreaterThan(sampled.evidenceSignals.triTetBindingCoverage, 0.0)
        XCTAssertEqual(sampled.evidenceSignals.replayStableRate, 0.5, accuracy: 0.0001)
        XCTAssertEqual(sampled.securitySignals.requestSignerValidRate, 1.0, accuracy: 0.0001)
    }

    func testSamplerReadsUploaderTransportSignals() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("purevision-sampler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }

        let fileURL = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0xAB, count: 4 * 1024).write(to: fileURL)

        let uploader = try ChunkedUploader(
            fileURL: fileURL,
            uploadEndpoint: URL(string: "https://example.com/uploads")!,
            resumeDirectory: root,
            masterKey: SymmetricKey(size: .bits256)
        )

        let sampled = await PureVisionRuntimeAuditInputSampler.sample(
            context: .init(),
            modules: .init(uploader: uploader)
        )

        XCTAssertGreaterThanOrEqual(sampled.transportSignals.chunkSizeBytes, UploadConstants.CHUNK_SIZE_MIN_BYTES)
        XCTAssertGreaterThanOrEqual(sampled.transportSignals.proofOfPossessionSuccessRate, 0.0)
        XCTAssertEqual(sampled.securitySignals.certificatePinMismatchCount, 0)
    }
}
