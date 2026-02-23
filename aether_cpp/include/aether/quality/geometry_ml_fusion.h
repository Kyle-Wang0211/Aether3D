// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_GEOMETRY_ML_FUSION_H
#define AETHER_QUALITY_GEOMETRY_ML_FUSION_H

#ifdef __cplusplus

#include "aether/quality/pure_vision_runtime.h"

#include <cstdint>

namespace aether {
namespace quality {

enum class GeometryMLReasonBit : std::uint8_t {
    kTriTetMeasuredRatioLow = 0u,
    kCrossValidationKeepRatioLow = 1u,
    kCrossValidationRejectPresent = 2u,
    kCaptureMotionExceeded = 3u,
    kCaptureExposurePenaltyExceeded = 4u,
    kEvidenceCoverageLow = 5u,
    kEvidenceInvariantViolationExceeded = 6u,
    kEvidenceReplayStabilityLow = 7u,
    kEvidenceTriTetBindingCoverageLow = 8u,
    kEvidenceMerkleCoverageLow = 9u,
    kEvidenceOcclusionExcludedRatioHigh = 10u,
    kEvidenceProvenanceGapExceeded = 11u,
    kTransportLossExceeded = 12u,
    kTransportRttExceeded = 13u,
    kUploadByzantineCoverageLow = 14u,
    kUploadMerkleProofSuccessLow = 15u,
    kUploadPoPSuccessLow = 16u,
    kUploadHmacMismatchHigh = 17u,
    kUploadCircuitBreakerOpenHigh = 18u,
    kUploadRetryExhaustionHigh = 19u,
    kUploadResumeCorruptionHigh = 20u,
    kSecurityCertPinMismatchExceeded = 21u,
    kSecurityRequestSignerValidRateLow = 22u,
    kSecurityPenaltyExceeded = 23u,
    kFusionScoreLow = 24u,
    kRiskScoreHigh = 25u,
};

struct GeometryMLCaptureSignals {
    double motion_score{0.0};
    double overexposure_ratio{0.0};
    double underexposure_ratio{0.0};
    bool has_large_blown_region{false};
};

struct GeometryMLEvidenceSignals {
    double coverage_score{0.0};
    double soft_evidence_score{0.0};
    std::int32_t persistent_piz_region_count{0};
    std::int32_t invariant_violation_count{0};
    double replay_stable_rate{0.0};
    double tri_tet_binding_coverage{0.0};
    double merkle_proof_coverage{0.0};
    double occlusion_excluded_area_ratio{0.0};
    std::int32_t provenance_gap_count{0};
};

struct GeometryMLTransportSignals {
    double bandwidth_mbps{0.0};
    double rtt_ms{0.0};
    double loss_rate{0.0};
    std::int64_t chunk_size_bytes{0};
    double dedup_savings_ratio{0.0};
    double compression_savings_ratio{0.0};
    double byzantine_coverage{0.0};
    double merkle_proof_success_rate{0.0};
    double proof_of_possession_success_rate{0.0};
    double chunk_hmac_mismatch_rate{0.0};
    double circuit_breaker_open_ratio{0.0};
    double retry_exhaustion_rate{0.0};
    double resume_corruption_rate{0.0};
};

struct GeometryMLSecuritySignals {
    bool code_signature_valid{true};
    bool runtime_integrity_valid{true};
    bool telemetry_hmac_valid{true};
    bool debugger_detected{false};
    bool environment_tampered{false};
    std::int32_t certificate_pin_mismatch_count{0};
    bool boot_chain_validated{true};
    double request_signer_valid_rate{1.0};
    bool secure_enclave_available{true};
};

struct GeometryMLCrossValidationStatsInput {
    std::int32_t keep_count{0};
    std::int32_t downgrade_count{0};
    std::int32_t reject_count{0};
};

struct GeometryMLTriTetReportInput {
    bool has_report{false};
    float combined_score{0.0f};
    std::int32_t measured_count{0};
    std::int32_t estimated_count{0};
    std::int32_t unknown_count{0};
};

struct GeometryMLThresholds {
    double min_fusion_score{0.72};
    double max_risk_score{0.26};
    double min_tri_tet_measured_ratio{0.45};
    double min_cross_validation_keep_ratio{0.70};
    double max_motion_score{0.60};
    double max_exposure_penalty{0.35};
    double min_coverage_score{0.75};
    std::int32_t max_persistent_piz_regions{3};
    std::int32_t max_evidence_invariant_violations{1};
    double min_evidence_replay_stable_rate{0.99};
    double min_tri_tet_binding_coverage{0.90};
    double min_evidence_merkle_proof_coverage{0.95};
    double max_evidence_occlusion_excluded_ratio{0.30};
    std::int32_t max_evidence_provenance_gap_count{1};
    double max_upload_loss_rate{0.05};
    double max_upload_rtt_ms{400.0};
    double min_upload_byzantine_coverage{0.95};
    double min_upload_merkle_proof_success_rate{0.97};
    double min_upload_pop_success_rate{0.98};
    double max_upload_hmac_mismatch_rate{0.01};
    double max_upload_circuit_breaker_open_ratio{0.08};
    double max_upload_retry_exhaustion_rate{0.03};
    double max_upload_resume_corruption_rate{0.015};
    std::int32_t max_certificate_pin_mismatch_count{1};
    double min_request_signer_valid_rate{0.98};
    double max_security_penalty{0.20};
};

struct GeometryMLWeights {
    double geometry{0.28};
    double cross_validation{0.22};
    double capture{0.20};
    double evidence{0.15};
    double transport{0.10};
    double security{0.05};
};

struct GeometryMLUploadThresholds {
    std::int32_t min_chunk_size{0};
    std::int32_t avg_chunk_size{0};
    std::int32_t max_chunk_size{0};
    double dedup_min_savings_ratio{0.0};
    double compression_min_savings_ratio{0.0};
};

struct GeometryMLComponentScores {
    double geometry{0.0};
    double cross_validation{0.0};
    double capture{0.0};
    double evidence{0.0};
    double transport{0.0};
    double security{0.0};
};

struct GeometryMLCrossValidationStats {
    std::int32_t keep_count{0};
    std::int32_t downgrade_count{0};
    std::int32_t reject_count{0};
};

struct GeometryMLResult {
    bool passes{false};
    double fusion_score{0.0};
    double risk_score{1.0};
    double security_penalty{1.0};
    double tri_tet_measured_ratio{0.0};
    double tri_tet_unknown_ratio{1.0};
    double cross_validation_keep_ratio{0.0};
    double capture_exposure_penalty{0.0};
    GeometryMLComponentScores component_scores{};
    GeometryMLCrossValidationStats cross_validation_stats{};
    std::uint64_t reason_mask{0u};
};

GeometryMLResult evaluate_geometry_ml_fusion(
    const PureVisionRuntimeMetrics& runtime_metrics,
    const GeometryMLTriTetReportInput* tri_tet_report_or_null,
    const GeometryMLCrossValidationStatsInput& cross_validation_stats,
    const GeometryMLCaptureSignals& capture_signals,
    const GeometryMLEvidenceSignals& evidence_signals,
    const GeometryMLTransportSignals& transport_signals,
    const GeometryMLSecuritySignals& security_signals,
    const GeometryMLThresholds& thresholds,
    const GeometryMLWeights& weights,
    const GeometryMLUploadThresholds& upload_thresholds);

}  // namespace quality
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_QUALITY_GEOMETRY_ML_FUSION_H
