// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Runtime context for building a PureVisionRuntimeAuditInput from live modules.
public struct PureVisionRuntimeAuditSamplingContext: Sendable {
    public let runtimeProfile: PureVisionRuntimeProfile
    public let policyMode: ZeroFabricationPolicyKernel.Mode
    public let maxDenoiseDisplacementMeters: Float
    public let policyActionAttempts: [ZeroFabricationPolicyActionAttempt]
    public let outlierCrossValidation: [OutlierCrossValidationInput]
    public let calibrationCrossValidation: [CalibrationCrossValidationInput]
    public let triTetInput: PureVisionRuntimeTriTetInput?
    public let runtimeMetrics: PureVisionRuntimeMetrics?
    public let fusionThresholdsOverride: PureVisionGeometryMLThresholds?
    public let fusionWeightsOverride: PureVisionGeometryMLWeights?
    public let thresholds: PureVisionRuntimeAuditThresholds

    public init(
        runtimeProfile: PureVisionRuntimeProfile = .balanced,
        policyMode: ZeroFabricationPolicyKernel.Mode = .forensicStrict,
        maxDenoiseDisplacementMeters: Float = 0,
        policyActionAttempts: [ZeroFabricationPolicyActionAttempt] = [],
        outlierCrossValidation: [OutlierCrossValidationInput] = [],
        calibrationCrossValidation: [CalibrationCrossValidationInput] = [],
        triTetInput: PureVisionRuntimeTriTetInput? = nil,
        runtimeMetrics: PureVisionRuntimeMetrics? = nil,
        fusionThresholdsOverride: PureVisionGeometryMLThresholds? = nil,
        fusionWeightsOverride: PureVisionGeometryMLWeights? = nil,
        thresholds: PureVisionRuntimeAuditThresholds = .init()
    ) {
        self.runtimeProfile = runtimeProfile
        self.policyMode = policyMode
        self.maxDenoiseDisplacementMeters = maxDenoiseDisplacementMeters
        self.policyActionAttempts = policyActionAttempts
        self.outlierCrossValidation = outlierCrossValidation
        self.calibrationCrossValidation = calibrationCrossValidation
        self.triTetInput = triTetInput
        self.runtimeMetrics = runtimeMetrics
        self.fusionThresholdsOverride = fusionThresholdsOverride
        self.fusionWeightsOverride = fusionWeightsOverride
        self.thresholds = thresholds
    }
}

/// Runtime module bundle for automatic PureVision audit signal sampling.
public struct PureVisionRuntimeAuditRuntimeModules: Sendable {
    public let qualityAnalyzer: QualityAnalyzer?
    public let evidenceEngine: IsolatedEvidenceEngine?
    public let uploader: ChunkedUploader?
    public let requestSigner: RequestSigner?
    public let bootChainValidator: BootChainValidator?
    public let certificatePinManager: PR9CertificatePinManager?
    public let secureEnclaveAvailableOverride: Bool?

    public init(
        qualityAnalyzer: QualityAnalyzer? = nil,
        evidenceEngine: IsolatedEvidenceEngine? = nil,
        uploader: ChunkedUploader? = nil,
        requestSigner: RequestSigner? = nil,
        bootChainValidator: BootChainValidator? = nil,
        certificatePinManager: PR9CertificatePinManager? = nil,
        secureEnclaveAvailableOverride: Bool? = nil
    ) {
        self.qualityAnalyzer = qualityAnalyzer
        self.evidenceEngine = evidenceEngine
        self.uploader = uploader
        self.requestSigner = requestSigner
        self.bootChainValidator = bootChainValidator
        self.certificatePinManager = certificatePinManager
        self.secureEnclaveAvailableOverride = secureEnclaveAvailableOverride
    }
}

/// Builds PureVisionRuntimeAuditInput by sampling live runtime modules.
public enum PureVisionRuntimeAuditInputSampler {
    public static func sample(
        context: PureVisionRuntimeAuditSamplingContext,
        modules: PureVisionRuntimeAuditRuntimeModules
    ) async -> PureVisionRuntimeAuditInput {
        async let captureSignals = sampleCaptureSignals(modules: modules)
        async let evidenceSignals = sampleEvidenceSignals(modules: modules)
        async let transportSignals = sampleTransportSignals(modules: modules)
        async let securitySignals = sampleSecuritySignals(modules: modules)

        return PureVisionRuntimeAuditInput(
            runtimeProfile: context.runtimeProfile,
            policyMode: context.policyMode,
            maxDenoiseDisplacementMeters: context.maxDenoiseDisplacementMeters,
            policyActionAttempts: context.policyActionAttempts,
            outlierCrossValidation: context.outlierCrossValidation,
            calibrationCrossValidation: context.calibrationCrossValidation,
            triTetInput: context.triTetInput,
            runtimeMetrics: context.runtimeMetrics,
            captureSignals: await captureSignals,
            evidenceSignals: await evidenceSignals,
            transportSignals: await transportSignals,
            securitySignals: await securitySignals,
            fusionThresholdsOverride: context.fusionThresholdsOverride,
            fusionWeightsOverride: context.fusionWeightsOverride,
            thresholds: context.thresholds
        )
    }

    public static func evaluate(
        context: PureVisionRuntimeAuditSamplingContext,
        modules: PureVisionRuntimeAuditRuntimeModules
    ) async -> PureVisionRuntimeAuditReport {
        let input = await sample(context: context, modules: modules)
        return PureVisionRuntimeAuditEvaluator.evaluate(input)
    }

    private static func sampleCaptureSignals(modules: PureVisionRuntimeAuditRuntimeModules) async -> GeometryMLCaptureSignals {
        if let qualityAnalyzer = modules.qualityAnalyzer {
            return await qualityAnalyzer.runtimeAuditCaptureSignals()
        }
        if let evidenceEngine = modules.evidenceEngine {
            return await evidenceEngine.runtimeAuditCaptureSignals()
        }
        return .init()
    }

    private static func sampleEvidenceSignals(modules: PureVisionRuntimeAuditRuntimeModules) async -> GeometryMLEvidenceSignals {
        if let evidenceEngine = modules.evidenceEngine {
            return await evidenceEngine.runtimeAuditEvidenceSignals()
        }
        return .init()
    }

    private static func sampleTransportSignals(modules: PureVisionRuntimeAuditRuntimeModules) async -> GeometryMLTransportSignals {
        if let uploader = modules.uploader {
            return await uploader.runtimeAuditTransportSignals()
        }
        return .init()
    }

    private static func sampleSecuritySignals(modules: PureVisionRuntimeAuditRuntimeModules) async -> GeometryMLSecuritySignals {
        var security = GeometryMLSecuritySignals()

        if let uploader = modules.uploader {
            let uploadSecurity = await uploader.runtimeAuditSecuritySignals()
            security = uploadSecurity
        }

        if let bootChain = modules.bootChainValidator {
            let bootSnapshot = await bootChain.runtimeSnapshot()
            security = GeometryMLSecuritySignals(
                codeSignatureValid: security.codeSignatureValid && bootSnapshot.bootChainValidated,
                runtimeIntegrityValid: security.runtimeIntegrityValid && bootSnapshot.bootChainValidated,
                telemetryHmacValid: security.telemetryHmacValid,
                debuggerDetected: security.debuggerDetected || bootSnapshot.debuggerDetected,
                environmentTampered: security.environmentTampered || bootSnapshot.isTerminated,
                certificatePinMismatchCount: security.certificatePinMismatchCount,
                bootChainValidated: bootSnapshot.bootChainValidated,
                requestSignerValidRate: security.requestSignerValidRate,
                secureEnclaveAvailable: security.secureEnclaveAvailable
            )
        }

        if let signer = modules.requestSigner {
            let signerSnapshot = await signer.runtimeSnapshot()
            security = GeometryMLSecuritySignals(
                codeSignatureValid: security.codeSignatureValid,
                runtimeIntegrityValid: security.runtimeIntegrityValid,
                telemetryHmacValid: security.telemetryHmacValid,
                debuggerDetected: security.debuggerDetected,
                environmentTampered: security.environmentTampered,
                certificatePinMismatchCount: security.certificatePinMismatchCount,
                bootChainValidated: security.bootChainValidated,
                requestSignerValidRate: signerSnapshot.validRate,
                secureEnclaveAvailable: security.secureEnclaveAvailable
            )
        }

        if let pinManager = modules.certificatePinManager {
            security = GeometryMLSecuritySignals(
                codeSignatureValid: security.codeSignatureValid,
                runtimeIntegrityValid: security.runtimeIntegrityValid,
                telemetryHmacValid: security.telemetryHmacValid,
                debuggerDetected: security.debuggerDetected,
                environmentTampered: security.environmentTampered,
                certificatePinMismatchCount: max(
                    security.certificatePinMismatchCount,
                    pinManager.getPinMismatchCount()
                ),
                bootChainValidated: security.bootChainValidated,
                requestSignerValidRate: security.requestSignerValidRate,
                secureEnclaveAvailable: security.secureEnclaveAvailable
            )
        }

        let secureEnclaveAvailable: Bool = {
            if let override = modules.secureEnclaveAvailableOverride {
                return override
            }
            #if os(iOS) || os(macOS) || os(tvOS) || os(watchOS)
            return SecureEnclaveKeyManager.isSecureEnclaveAvailable()
            #else
            return false
            #endif
        }()

        return GeometryMLSecuritySignals(
            codeSignatureValid: security.codeSignatureValid,
            runtimeIntegrityValid: security.runtimeIntegrityValid,
            telemetryHmacValid: security.telemetryHmacValid,
            debuggerDetected: security.debuggerDetected,
            environmentTampered: security.environmentTampered,
            certificatePinMismatchCount: security.certificatePinMismatchCount,
            bootChainValidated: security.bootChainValidated,
            requestSignerValidRate: security.requestSignerValidRate,
            secureEnclaveAvailable: secureEnclaveAvailable
        )
    }
}
