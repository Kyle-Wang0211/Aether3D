// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

enum NativePureVisionRuntimeBridge {
    static func evaluateOutlier(_ input: OutlierCrossValidationInput) -> CrossValidationOutcome? {
        var nativeInput = aether_outlier_cross_validation_input_t(
            rule_inlier: input.ruleInlier ? 1 : 0,
            ml_inlier_score: input.mlInlierScore,
            ml_inlier_threshold: input.mlInlierThreshold
        )
        var nativeOutcome = aether_cross_validation_outcome_t()
        let rc = aether_cross_validation_evaluate_outlier(&nativeInput, &nativeOutcome)
        guard rc == 0,
              let decision = toSwiftDecision(nativeOutcome.decision),
              let reasonCode = toSwiftReasonCode(nativeOutcome.reason_code) else {
            return nil
        }
        return CrossValidationOutcome(decision: decision, reasonCode: reasonCode)
    }

    static func evaluateCalibration(_ input: CalibrationCrossValidationInput) -> CrossValidationOutcome? {
        var nativeInput = aether_calibration_cross_validation_input_t(
            baseline_error_cm: input.baselineErrorCm,
            ml_error_cm: input.mlErrorCm,
            max_allowed_error_cm: input.maxAllowedErrorCm,
            max_divergence_cm: input.maxDivergenceCm
        )
        var nativeOutcome = aether_cross_validation_outcome_t()
        let rc = aether_cross_validation_evaluate_calibration(&nativeInput, &nativeOutcome)
        guard rc == 0,
              let decision = toSwiftDecision(nativeOutcome.decision),
              let reasonCode = toSwiftReasonCode(nativeOutcome.reason_code) else {
            return nil
        }
        return CrossValidationOutcome(decision: decision, reasonCode: reasonCode)
    }

    static func evaluateGates(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateResult]? {
        var nativeMetrics = toNativeMetrics(metrics)
        var nativeThresholds = toNativeThresholds()
        let gateCapacity = Int(AETHER_PURE_VISION_GATE_COUNT)
        guard gateCapacity > 0 else {
            return nil
        }

        var nativeResults = [aether_pure_vision_gate_result_t](
            repeating: aether_pure_vision_gate_result_t(),
            count: gateCapacity
        )
        var gateCount = Int32(gateCapacity)
        let rc = nativeResults.withUnsafeMutableBufferPointer { resultPtr in
            aether_pure_vision_evaluate_gates(
                &nativeMetrics,
                &nativeThresholds,
                resultPtr.baseAddress,
                &gateCount
            )
        }
        guard rc == 0 else {
            return nil
        }

        let finalCount = Int(gateCount)
        guard finalCount >= 0, finalCount <= gateCapacity else {
            return nil
        }
        var out: [PureVisionGateResult] = []
        out.reserveCapacity(finalCount)
        for i in 0..<finalCount {
            let item = nativeResults[i]
            guard let gateID = toSwiftGateID(item.gate_id) else {
                return nil
            }
            out.append(
                PureVisionGateResult(
                    gateId: gateID,
                    passed: item.passed != 0,
                    observed: item.observed,
                    threshold: item.threshold,
                    comparator: item.comparator == 0 ? ">=" : "<="
                )
            )
        }
        return out
    }

    static func failedGateIDs(_ metrics: PureVisionRuntimeMetrics) -> [PureVisionGateID]? {
        var nativeMetrics = toNativeMetrics(metrics)
        var nativeThresholds = toNativeThresholds()
        let gateCapacity = Int(AETHER_PURE_VISION_GATE_COUNT)
        guard gateCapacity > 0 else {
            return nil
        }

        var failedIDs = [Int32](repeating: 0, count: gateCapacity)
        var failedCount = Int32(gateCapacity)
        let rc = failedIDs.withUnsafeMutableBufferPointer { idPtr in
            aether_pure_vision_failed_gate_ids(
                &nativeMetrics,
                &nativeThresholds,
                idPtr.baseAddress,
                &failedCount
            )
        }
        guard rc == 0 else {
            return nil
        }

        let finalCount = Int(failedCount)
        guard finalCount >= 0, finalCount <= gateCapacity else {
            return nil
        }
        var out: [PureVisionGateID] = []
        out.reserveCapacity(finalCount)
        for i in 0..<finalCount {
            guard let gateID = toSwiftGateID(failedIDs[i]) else {
                return nil
            }
            out.append(gateID)
        }
        return out
    }

    static func evaluateZeroFabrication(
        mode: ZeroFabricationPolicyKernel.Mode,
        maxDenoiseDisplacementMeters: Float,
        action: MLActionType,
        context: ZeroFabricationContext
    ) -> ZeroFabricationDecision? {
        var nativeContext = aether_zero_fabrication_context_t(
            confidence_class: toNativeConfidenceClass(context.confidenceClass),
            has_direct_observation: context.hasDirectObservation ? 1 : 0,
            requested_point_displacement_meters: context.requestedPointDisplacementMeters,
            requested_new_geometry_count: Int32(context.requestedNewGeometryCount)
        )
        var nativeDecision = aether_zero_fabrication_decision_t()
        let rc = aether_zero_fabrication_evaluate(
            toNativeZeroFabMode(mode),
            maxDenoiseDisplacementMeters,
            toNativeZeroFabAction(action),
            &nativeContext,
            &nativeDecision
        )
        guard rc == 0,
              let reasonCode = toSwiftZeroFabReason(nativeDecision.reason_code),
              let severity = toSwiftPolicySeverity(nativeDecision.severity) else {
            return nil
        }
        return ZeroFabricationDecision(
            allowed: nativeDecision.allowed != 0,
            reasonCode: reasonCode,
            severity: severity
        )
    }

    static func evaluateGeometryML(
        input: GeometryMLFusionInput,
        thresholds: PureVisionGeometryMLThresholds,
        weights: PureVisionGeometryMLWeights,
        uploadThresholds: PureVisionUploadCDCThresholds
    ) -> GeometryMLFusionResult? {
        var nativeMetrics = toNativeMetrics(input.runtimeMetrics)
        let combinedOutcomes = input.outlierOutcomes + input.calibrationOutcomes
        var nativeCrossValidation = aether_geometry_ml_cross_validation_stats_t(
            keep_count: Int32(combinedOutcomes.filter { $0.decision == .keep }.count),
            downgrade_count: Int32(combinedOutcomes.filter { $0.decision == .downgrade }.count),
            reject_count: Int32(combinedOutcomes.filter { $0.decision == .reject }.count)
        )
        var nativeCapture = aether_geometry_ml_capture_signals_t(
            motion_score: input.captureSignals.motionScore,
            overexposure_ratio: input.captureSignals.overexposureRatio,
            underexposure_ratio: input.captureSignals.underexposureRatio,
            has_large_blown_region: input.captureSignals.hasLargeBlownRegion ? 1 : 0
        )
        var nativeEvidence = aether_geometry_ml_evidence_signals_t(
            coverage_score: input.evidenceSignals.coverageScore,
            soft_evidence_score: input.evidenceSignals.softEvidenceScore,
            persistent_piz_region_count: Int32(input.evidenceSignals.persistentPizRegionCount),
            invariant_violation_count: Int32(input.evidenceSignals.invariantViolationCount),
            replay_stable_rate: input.evidenceSignals.replayStableRate,
            tri_tet_binding_coverage: input.evidenceSignals.triTetBindingCoverage,
            merkle_proof_coverage: input.evidenceSignals.merkleProofCoverage,
            occlusion_excluded_area_ratio: input.evidenceSignals.occlusionExcludedAreaRatio,
            provenance_gap_count: Int32(input.evidenceSignals.provenanceGapCount)
        )
        var nativeTransport = aether_geometry_ml_transport_signals_t(
            bandwidth_mbps: input.transportSignals.bandwidthMbps,
            rtt_ms: input.transportSignals.rttMs,
            loss_rate: input.transportSignals.lossRate,
            chunk_size_bytes: Int64(input.transportSignals.chunkSizeBytes),
            dedup_savings_ratio: input.transportSignals.dedupSavingsRatio,
            compression_savings_ratio: input.transportSignals.compressionSavingsRatio,
            byzantine_coverage: input.transportSignals.byzantineCoverage,
            merkle_proof_success_rate: input.transportSignals.merkleProofSuccessRate,
            proof_of_possession_success_rate: input.transportSignals.proofOfPossessionSuccessRate,
            chunk_hmac_mismatch_rate: input.transportSignals.chunkHmacMismatchRate,
            circuit_breaker_open_ratio: input.transportSignals.circuitBreakerOpenRatio,
            retry_exhaustion_rate: input.transportSignals.retryExhaustionRate,
            resume_corruption_rate: input.transportSignals.resumeCorruptionRate
        )
        var nativeSecurity = aether_geometry_ml_security_signals_t(
            code_signature_valid: input.securitySignals.codeSignatureValid ? 1 : 0,
            runtime_integrity_valid: input.securitySignals.runtimeIntegrityValid ? 1 : 0,
            telemetry_hmac_valid: input.securitySignals.telemetryHmacValid ? 1 : 0,
            debugger_detected: input.securitySignals.debuggerDetected ? 1 : 0,
            environment_tampered: input.securitySignals.environmentTampered ? 1 : 0,
            certificate_pin_mismatch_count: Int32(input.securitySignals.certificatePinMismatchCount),
            boot_chain_validated: input.securitySignals.bootChainValidated ? 1 : 0,
            request_signer_valid_rate: input.securitySignals.requestSignerValidRate,
            secure_enclave_available: input.securitySignals.secureEnclaveAvailable ? 1 : 0
        )
        var nativeThresholds = aether_geometry_ml_thresholds_t(
            min_fusion_score: thresholds.minFusionScore,
            max_risk_score: thresholds.maxRiskScore,
            min_tri_tet_measured_ratio: thresholds.minTriTetMeasuredRatio,
            min_cross_validation_keep_ratio: thresholds.minCrossValidationKeepRatio,
            max_motion_score: thresholds.maxMotionScore,
            max_exposure_penalty: thresholds.maxExposurePenalty,
            min_coverage_score: thresholds.minCoverageScore,
            max_persistent_piz_regions: Int32(thresholds.maxPersistentPizRegions),
            max_evidence_invariant_violations: Int32(thresholds.maxEvidenceInvariantViolations),
            min_evidence_replay_stable_rate: thresholds.minEvidenceReplayStableRate,
            min_tri_tet_binding_coverage: thresholds.minTriTetBindingCoverage,
            min_evidence_merkle_proof_coverage: thresholds.minEvidenceMerkleProofCoverage,
            max_evidence_occlusion_excluded_ratio: thresholds.maxEvidenceOcclusionExcludedRatio,
            max_evidence_provenance_gap_count: Int32(thresholds.maxEvidenceProvenanceGapCount),
            max_upload_loss_rate: thresholds.maxUploadLossRate,
            max_upload_rtt_ms: thresholds.maxUploadRTTMs,
            min_upload_byzantine_coverage: thresholds.minUploadByzantineCoverage,
            min_upload_merkle_proof_success_rate: thresholds.minUploadMerkleProofSuccessRate,
            min_upload_pop_success_rate: thresholds.minUploadPoPSuccessRate,
            max_upload_hmac_mismatch_rate: thresholds.maxUploadHmacMismatchRate,
            max_upload_circuit_breaker_open_ratio: thresholds.maxUploadCircuitBreakerOpenRatio,
            max_upload_retry_exhaustion_rate: thresholds.maxUploadRetryExhaustionRate,
            max_upload_resume_corruption_rate: thresholds.maxUploadResumeCorruptionRate,
            max_certificate_pin_mismatch_count: Int32(thresholds.maxCertificatePinMismatchCount),
            min_request_signer_valid_rate: thresholds.minRequestSignerValidRate,
            max_security_penalty: thresholds.maxSecurityPenalty
        )
        var nativeWeights = aether_geometry_ml_weights_t(
            geometry: weights.geometry,
            cross_validation: weights.crossValidation,
            capture: weights.capture,
            evidence: weights.evidence,
            transport: weights.transport,
            security: weights.security
        )
        var nativeUploadThresholds = aether_upload_cdc_thresholds_t(
            min_chunk_size: Int32(uploadThresholds.minChunkSize),
            avg_chunk_size: Int32(uploadThresholds.avgChunkSize),
            max_chunk_size: Int32(uploadThresholds.maxChunkSize),
            dedup_min_savings_ratio: uploadThresholds.dedupMinSavingsRatio,
            compression_min_savings_ratio: uploadThresholds.compressionMinSavingsRatio
        )
        var nativeResult = aether_geometry_ml_result_t()

        var nativeTriTet = aether_geometry_ml_tri_tet_report_t()
        let rc: Int32
        if let report = input.triTetReport {
            nativeTriTet = aether_geometry_ml_tri_tet_report_t(
                has_report: 1,
                combined_score: report.combinedScore,
                measured_count: Int32(report.measuredCount),
                estimated_count: Int32(report.estimatedCount),
                unknown_count: Int32(report.unknownCount)
            )
            rc = withUnsafePointer(to: &nativeTriTet) { triTetPtr in
                aether_geometry_ml_evaluate(
                    &nativeMetrics,
                    triTetPtr,
                    &nativeCrossValidation,
                    &nativeCapture,
                    &nativeEvidence,
                    &nativeTransport,
                    &nativeSecurity,
                    &nativeThresholds,
                    &nativeWeights,
                    &nativeUploadThresholds,
                    &nativeResult
                )
            }
        } else {
            rc = aether_geometry_ml_evaluate(
                &nativeMetrics,
                nil,
                &nativeCrossValidation,
                &nativeCapture,
                &nativeEvidence,
                &nativeTransport,
                &nativeSecurity,
                &nativeThresholds,
                &nativeWeights,
                &nativeUploadThresholds,
                &nativeResult
            )
        }
        guard rc == 0 else {
            return nil
        }

        var reasonCodes: [String] = []
        let reasonMask = nativeResult.reason_mask
        let maxBits = Int(AETHER_GEOMETRY_ML_REASON_COUNT)
        for bitIndex in 0..<maxBits {
            let bit = UInt64(1) << UInt64(bitIndex)
            if (reasonMask & bit) != 0,
               let code = geometryMLReasonCode(forBitIndex: Int32(bitIndex)) {
                reasonCodes.append(code)
            }
        }

        return GeometryMLFusionResult(
            passes: nativeResult.passes != 0,
            fusionScore: nativeResult.fusion_score,
            riskScore: nativeResult.risk_score,
            securityPenalty: nativeResult.security_penalty,
            triTetMeasuredRatio: nativeResult.tri_tet_measured_ratio,
            triTetUnknownRatio: nativeResult.tri_tet_unknown_ratio,
            crossValidationKeepRatio: nativeResult.cross_validation_keep_ratio,
            captureExposurePenalty: nativeResult.capture_exposure_penalty,
            componentScores: GeometryMLFusionComponentScores(
                geometry: nativeResult.component_scores.geometry,
                crossValidation: nativeResult.component_scores.cross_validation,
                capture: nativeResult.component_scores.capture,
                evidence: nativeResult.component_scores.evidence,
                transport: nativeResult.component_scores.transport,
                security: nativeResult.component_scores.security
            ),
            crossValidationStats: GeometryMLCrossValidationStats(
                keepCount: Int(nativeResult.cross_validation_stats.keep_count),
                downgradeCount: Int(nativeResult.cross_validation_stats.downgrade_count),
                rejectCount: Int(nativeResult.cross_validation_stats.reject_count),
                keepRatio: nativeResult.cross_validation_keep_ratio
            ),
            reasonCodes: reasonCodes
        )
    }

    private static func toSwiftDecision(_ raw: Int32) -> CrossValidationDecision? {
        switch raw {
        case Int32(AETHER_CROSS_VALIDATION_KEEP):
            return .keep
        case Int32(AETHER_CROSS_VALIDATION_DOWNGRADE):
            return .downgrade
        case Int32(AETHER_CROSS_VALIDATION_REJECT):
            return .reject
        default:
            return nil
        }
    }

    private static func toSwiftReasonCode(_ raw: Int32) -> String? {
        switch raw {
        case Int32(AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_INLIER):
            return "OUTLIER_BOTH_INLIER"
        case Int32(AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_REJECT):
            return "OUTLIER_BOTH_REJECT"
        case Int32(AETHER_CROSS_VALIDATION_REASON_OUTLIER_DISAGREEMENT_DOWNGRADE):
            return "OUTLIER_DISAGREEMENT_DOWNGRADE"
        case Int32(AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_PASS):
            return "CALIBRATION_BOTH_PASS"
        case Int32(AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_FAIL):
            return "CALIBRATION_BOTH_FAIL"
        case Int32(AETHER_CROSS_VALIDATION_REASON_CALIBRATION_DISAGREEMENT_OR_DIVERGENCE):
            return "CALIBRATION_DISAGREEMENT_OR_DIVERGENCE"
        default:
            return nil
        }
    }

    private static func toSwiftGateID(_ raw: Int32) -> PureVisionGateID? {
        switch raw {
        case Int32(AETHER_PURE_VISION_GATE_BASELINE_PIXELS):
            return .baseline
        case Int32(AETHER_PURE_VISION_GATE_BLUR_LAPLACIAN):
            return .blur
        case Int32(AETHER_PURE_VISION_GATE_ORB_FEATURE_COUNT):
            return .orbFeatures
        case Int32(AETHER_PURE_VISION_GATE_PARALLAX_RATIO):
            return .parallax
        case Int32(AETHER_PURE_VISION_GATE_DEPTH_SIGMA):
            return .depthSigma
        case Int32(AETHER_PURE_VISION_GATE_CLOSURE_RATIO):
            return .closureRatio
        case Int32(AETHER_PURE_VISION_GATE_UNKNOWN_VOXEL_RATIO):
            return .unknownVoxelRatio
        case Int32(AETHER_PURE_VISION_GATE_THERMAL_CELSIUS):
            return .thermal
        default:
            return nil
        }
    }

    private static func toNativeMetrics(_ metrics: PureVisionRuntimeMetrics) -> aether_pure_vision_runtime_metrics_t {
        aether_pure_vision_runtime_metrics_t(
            baseline_pixels: metrics.baselinePixels,
            blur_laplacian: metrics.blurLaplacian,
            orb_features: Int32(metrics.orbFeatures),
            parallax_ratio: metrics.parallaxRatio,
            depth_sigma_meters: metrics.depthSigmaMeters,
            closure_ratio: metrics.closureRatio,
            unknown_voxel_ratio: metrics.unknownVoxelRatio,
            thermal_celsius: metrics.thermalCelsius
        )
    }

    private static func toNativeThresholds() -> aether_pure_vision_gate_thresholds_t {
        aether_pure_vision_gate_thresholds_t(
            min_baseline_pixels: PureVisionRuntimeConstants.K_OBS_MIN_BASELINE_PIXELS,
            min_blur_laplacian: CoreBlurThresholds.frameRejection,
            min_orb_features: Int32(FrameQualityConstants.MIN_ORB_FEATURES_FOR_SFM),
            min_parallax_ratio: PureVisionRuntimeConstants.K_OBS_REQ_PARALLAX_RATIO,
            max_depth_sigma_meters: PureVisionRuntimeConstants.K_OBS_SIGMA_Z_TARGET_M,
            min_closure_ratio: PureVisionRuntimeConstants.K_VOLUME_CLOSURE_RATIO_MIN,
            max_unknown_voxel_ratio: PureVisionRuntimeConstants.K_VOLUME_UNKNOWN_VOXEL_MAX,
            max_thermal_celsius: ThermalConstants.thermalCriticalC
        )
    }

    private static func toNativeZeroFabMode(_ mode: ZeroFabricationPolicyKernel.Mode) -> Int32 {
        switch mode {
        case .forensicStrict:
            return Int32(AETHER_ZERO_FAB_MODE_FORENSIC_STRICT)
        case .researchRelaxed:
            return Int32(AETHER_ZERO_FAB_MODE_RESEARCH_RELAXED)
        }
    }

    private static func toNativeZeroFabAction(_ action: MLActionType) -> Int32 {
        switch action {
        case .calibrationCorrection:
            return Int32(AETHER_ZERO_FAB_ACTION_CALIBRATION_CORRECTION)
        case .multiViewDenoise:
            return Int32(AETHER_ZERO_FAB_ACTION_MULTI_VIEW_DENOISE)
        case .outlierRejection:
            return Int32(AETHER_ZERO_FAB_ACTION_OUTLIER_REJECTION)
        case .confidenceEstimation:
            return Int32(AETHER_ZERO_FAB_ACTION_CONFIDENCE_ESTIMATION)
        case .uncertaintyEstimation:
            return Int32(AETHER_ZERO_FAB_ACTION_UNCERTAINTY_ESTIMATION)
        case .textureInpaint:
            return Int32(AETHER_ZERO_FAB_ACTION_TEXTURE_INPAINT)
        case .holeFilling:
            return Int32(AETHER_ZERO_FAB_ACTION_HOLE_FILLING)
        case .geometryCompletion:
            return Int32(AETHER_ZERO_FAB_ACTION_GEOMETRY_COMPLETION)
        case .unknownRegionGrowth:
            return Int32(AETHER_ZERO_FAB_ACTION_UNKNOWN_REGION_GROWTH)
        }
    }

    private static func toNativeConfidenceClass(_ confidenceClass: ReconstructionConfidenceClass) -> Int32 {
        switch confidenceClass {
        case .measured:
            return Int32(AETHER_ZERO_FAB_CONFIDENCE_MEASURED)
        case .estimated:
            return Int32(AETHER_ZERO_FAB_CONFIDENCE_ESTIMATED)
        case .unknown:
            return Int32(AETHER_ZERO_FAB_CONFIDENCE_UNKNOWN)
        }
    }

    private static func toSwiftPolicySeverity(_ raw: Int32) -> PolicySeverity? {
        switch raw {
        case Int32(AETHER_ZERO_FAB_SEVERITY_INFO):
            return .info
        case Int32(AETHER_ZERO_FAB_SEVERITY_WARN):
            return .warn
        case Int32(AETHER_ZERO_FAB_SEVERITY_BLOCK):
            return .block
        default:
            return nil
        }
    }

    private static func toSwiftZeroFabReason(_ raw: Int32) -> String? {
        switch raw {
        case Int32(AETHER_ZERO_FAB_REASON_BLOCK_GENERATIVE_ACTION):
            return "ZERO_FAB_BLOCK_GENERATIVE_ACTION"
        case Int32(AETHER_ZERO_FAB_REASON_BLOCK_UNKNOWN_GROWTH):
            return "ZERO_FAB_BLOCK_UNKNOWN_GROWTH"
        case Int32(AETHER_ZERO_FAB_REASON_ALLOW_OBSERVED_GROWTH):
            return "ALLOW_OBSERVED_GROWTH"
        case Int32(AETHER_ZERO_FAB_REASON_BLOCK_COORDINATE_REWRITE):
            return "ZERO_FAB_BLOCK_COORDINATE_REWRITE"
        case Int32(AETHER_ZERO_FAB_REASON_DENOISE_DISPLACEMENT_EXCEEDS_POLICY):
            return "ZERO_FAB_DENOISE_DISPLACEMENT_EXCEEDS_POLICY"
        case Int32(AETHER_ZERO_FAB_REASON_ALLOW_DENOISE):
            return "ALLOW_DENOISE"
        case Int32(AETHER_ZERO_FAB_REASON_ALLOW_OUTLIER_REJECTION):
            return "ALLOW_OUTLIER_REJECTION"
        case Int32(AETHER_ZERO_FAB_REASON_ALLOW_NON_GENERATIVE_CALIBRATION):
            return "ALLOW_NON_GENERATIVE_CALIBRATION"
        default:
            return nil
        }
    }

    private static func geometryMLReasonCode(forBitIndex bitIndex: Int32) -> String? {
        switch bitIndex {
        case Int32(AETHER_GEOMETRY_ML_REASON_TRI_TET_MEASURED_RATIO_LOW):
            return "FUSION_TRI_TET_MEASURED_RATIO_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_KEEP_RATIO_LOW):
            return "FUSION_CROSS_VALIDATION_KEEP_RATIO_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_SUPPORT_LOW):
            return "FUSION_CROSS_VALIDATION_SUPPORT_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_CROSS_VALIDATION_REJECT_PRESENT):
            return "FUSION_CROSS_VALIDATION_REJECT_PRESENT"
        case Int32(AETHER_GEOMETRY_ML_REASON_CAPTURE_MOTION_EXCEEDED):
            return "FUSION_CAPTURE_MOTION_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_CAPTURE_EXPOSURE_PENALTY_EXCEEDED):
            return "FUSION_CAPTURE_EXPOSURE_PENALTY_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_COVERAGE_LOW):
            return "FUSION_EVIDENCE_COVERAGE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_PIZ_PERSISTENCE_EXCEEDED):
            return "FUSION_EVIDENCE_PIZ_PERSISTENCE_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_INVARIANT_VIOLATION_EXCEEDED):
            return "FUSION_EVIDENCE_INVARIANT_VIOLATION_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_REPLAY_STABILITY_LOW):
            return "FUSION_EVIDENCE_REPLAY_STABILITY_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_TRI_TET_BINDING_COVERAGE_LOW):
            return "FUSION_EVIDENCE_TRI_TET_BINDING_COVERAGE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_TRI_TET_BINDING_INCONSISTENT):
            return "FUSION_EVIDENCE_TRI_TET_BINDING_INCONSISTENT"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_MERKLE_COVERAGE_LOW):
            return "FUSION_EVIDENCE_MERKLE_COVERAGE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_REPLAY_CV_INCONSISTENT):
            return "FUSION_EVIDENCE_REPLAY_CV_INCONSISTENT"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_OCCLUSION_EXCLUDED_RATIO_HIGH):
            return "FUSION_EVIDENCE_OCCLUSION_EXCLUDED_RATIO_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_EVIDENCE_PROVENANCE_GAP_EXCEEDED):
            return "FUSION_EVIDENCE_PROVENANCE_GAP_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_TRANSPORT_LOSS_EXCEEDED):
            return "FUSION_TRANSPORT_LOSS_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_TRANSPORT_RTT_EXCEEDED):
            return "FUSION_TRANSPORT_RTT_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_BYZANTINE_COVERAGE_LOW):
            return "FUSION_UPLOAD_BYZANTINE_COVERAGE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_MERKLE_PROOF_SUCCESS_LOW):
            return "FUSION_UPLOAD_MERKLE_PROOF_SUCCESS_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_POP_SUCCESS_LOW):
            return "FUSION_UPLOAD_POP_SUCCESS_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_HMAC_MISMATCH_HIGH):
            return "FUSION_UPLOAD_HMAC_MISMATCH_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_CIRCUIT_BREAKER_OPEN_HIGH):
            return "FUSION_UPLOAD_CIRCUIT_BREAKER_OPEN_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_RETRY_EXHAUSTION_HIGH):
            return "FUSION_UPLOAD_RETRY_EXHAUSTION_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_RESUME_CORRUPTION_HIGH):
            return "FUSION_UPLOAD_RESUME_CORRUPTION_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_UPLOAD_STRESS_COMPOUND_HIGH):
            return "FUSION_UPLOAD_STRESS_COMPOUND_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_INTERDOMAIN_DIVERGENCE_HIGH):
            return "FUSION_INTERDOMAIN_DIVERGENCE_HIGH"
        case Int32(AETHER_GEOMETRY_ML_REASON_SECURITY_TRANSPORT_TAMPER_CHAIN):
            return "FUSION_SECURITY_TRANSPORT_TAMPER_CHAIN"
        case Int32(AETHER_GEOMETRY_ML_REASON_SECURITY_CERT_PIN_MISMATCH_EXCEEDED):
            return "FUSION_SECURITY_CERT_PIN_MISMATCH_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_SECURITY_BOOT_CHAIN_FAILED):
            return "FUSION_SECURITY_BOOT_CHAIN_FAILED"
        case Int32(AETHER_GEOMETRY_ML_REASON_SECURITY_REQUEST_SIGNER_VALID_RATE_LOW):
            return "FUSION_SECURITY_REQUEST_SIGNER_VALID_RATE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_SECURITY_PENALTY_EXCEEDED):
            return "FUSION_SECURITY_PENALTY_EXCEEDED"
        case Int32(AETHER_GEOMETRY_ML_REASON_MATURITY_LOW):
            return "FUSION_MATURITY_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_SCORE_LOW):
            return "FUSION_SCORE_LOW"
        case Int32(AETHER_GEOMETRY_ML_REASON_RISK_HIGH):
            return "FUSION_RISK_HIGH"
        default:
            return nil
        }
    }
}
