// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/quality/geometry_ml_fusion.h"

#include <algorithm>
#include <cmath>

namespace aether {
namespace quality {
namespace {

inline double clamp01(double value) {
    if (!std::isfinite(value)) {
        return 0.0;
    }
    return std::max(0.0, std::min(1.0, value));
}

inline double normalize_higher(double value, double min_value, double max_value) {
    if (!(max_value > min_value)) {
        return value >= max_value ? 1.0 : 0.0;
    }
    return clamp01((value - min_value) / (max_value - min_value));
}

inline double normalize_lower(double value, double min_value, double max_value) {
    if (!(max_value > min_value)) {
        return value <= min_value ? 1.0 : 0.0;
    }
    return clamp01((max_value - value) / (max_value - min_value));
}

inline void set_reason(std::uint64_t* reason_mask, GeometryMLReasonBit bit) {
    if (reason_mask == nullptr) {
        return;
    }
    const std::uint8_t bit_index = static_cast<std::uint8_t>(bit);
    if (bit_index < 64u) {
        *reason_mask |= (1ull << bit_index);
    }
}

}  // namespace

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
    const GeometryMLUploadThresholds& upload_thresholds) {
    GeometryMLResult result{};
    result.cross_validation_stats.keep_count = std::max(0, cross_validation_stats.keep_count);
    result.cross_validation_stats.downgrade_count = std::max(0, cross_validation_stats.downgrade_count);
    result.cross_validation_stats.reject_count = std::max(0, cross_validation_stats.reject_count);

    double tri_tet_measured_ratio = 0.0;
    double tri_tet_unknown_ratio = 1.0;
    double tri_tet_combined_score = 0.0;
    if (tri_tet_report_or_null == nullptr || !tri_tet_report_or_null->has_report) {
        tri_tet_unknown_ratio = clamp01(runtime_metrics.unknown_voxel_ratio);
        tri_tet_measured_ratio = clamp01(1.0 - tri_tet_unknown_ratio);
        tri_tet_combined_score = clamp01(tri_tet_measured_ratio * 0.9);
    } else {
        const std::int32_t measured = std::max(0, tri_tet_report_or_null->measured_count);
        const std::int32_t estimated = std::max(0, tri_tet_report_or_null->estimated_count);
        const std::int32_t unknown = std::max(0, tri_tet_report_or_null->unknown_count);
        const std::int32_t total = measured + estimated + unknown;
        if (total > 0) {
            tri_tet_measured_ratio = clamp01(static_cast<double>(measured) / static_cast<double>(total));
            tri_tet_unknown_ratio = clamp01(static_cast<double>(unknown) / static_cast<double>(total));
            tri_tet_combined_score = clamp01(static_cast<double>(tri_tet_report_or_null->combined_score));
        }
    }
    result.tri_tet_measured_ratio = tri_tet_measured_ratio;
    result.tri_tet_unknown_ratio = tri_tet_unknown_ratio;

    const std::int32_t cv_total =
        result.cross_validation_stats.keep_count +
        result.cross_validation_stats.downgrade_count +
        result.cross_validation_stats.reject_count;
    const double cv_keep_ratio = (cv_total <= 0)
        ? 1.0
        : static_cast<double>(result.cross_validation_stats.keep_count) / static_cast<double>(cv_total);
    result.cross_validation_keep_ratio = clamp01(cv_keep_ratio);

    const double geometry_score = clamp01(
        tri_tet_combined_score * 0.60 +
        tri_tet_measured_ratio * 0.25 +
        (1.0 - tri_tet_unknown_ratio) * 0.15);

    const double cv_score = clamp01(
        result.cross_validation_keep_ratio +
        (cv_total > 0
            ? (static_cast<double>(result.cross_validation_stats.downgrade_count) * 0.5 / static_cast<double>(cv_total))
            : 0.0));

    const double exposure_penalty = clamp01(
        capture_signals.overexposure_ratio +
        capture_signals.underexposure_ratio +
        (capture_signals.has_large_blown_region ? 0.15 : 0.0));
    result.capture_exposure_penalty = exposure_penalty;

    const double capture_score = clamp01(
        normalize_higher(runtime_metrics.blur_laplacian, 120.0, 420.0) * 0.20 +
        normalize_higher(static_cast<double>(runtime_metrics.orb_features), 200.0, 1200.0) * 0.18 +
        normalize_higher(runtime_metrics.parallax_ratio, 0.1, 0.5) * 0.14 +
        normalize_higher(runtime_metrics.baseline_pixels, 3.0, 12.0) * 0.08 +
        normalize_lower(runtime_metrics.depth_sigma_meters, 0.0, 0.02) * 0.08 +
        normalize_lower(capture_signals.motion_score, 0.0, thresholds.max_motion_score) * 0.14 +
        normalize_lower(exposure_penalty, 0.0, thresholds.max_exposure_penalty) * 0.10 +
        normalize_lower(runtime_metrics.thermal_celsius, 20.0, 50.0) * 0.08);

    const double evidence_score = clamp01(
        clamp01(evidence_signals.coverage_score) * 0.21 +
        clamp01(evidence_signals.soft_evidence_score) * 0.12 +
        clamp01(evidence_signals.replay_stable_rate) * 0.12 +
        clamp01(evidence_signals.tri_tet_binding_coverage) * 0.10 +
        clamp01(evidence_signals.merkle_proof_coverage) * 0.08 +
        normalize_lower(static_cast<double>(std::max(0, evidence_signals.persistent_piz_region_count)), 0.0, std::max(1, thresholds.max_persistent_piz_regions)) * 0.10 +
        normalize_lower(static_cast<double>(std::max(0, evidence_signals.invariant_violation_count)), 0.0, std::max(1, thresholds.max_evidence_invariant_violations)) * 0.07 +
        normalize_lower(evidence_signals.occlusion_excluded_area_ratio, 0.0, thresholds.max_evidence_occlusion_excluded_ratio) * 0.06 +
        normalize_lower(static_cast<double>(std::max(0, evidence_signals.provenance_gap_count)), 0.0, std::max(1, thresholds.max_evidence_provenance_gap_count)) * 0.04 +
        normalize_higher(runtime_metrics.closure_ratio, 0.8, 1.0) * 0.06 +
        normalize_lower(runtime_metrics.unknown_voxel_ratio, 0.0, 0.08) * 0.04);

    double chunk_score = 0.2;
    if (upload_thresholds.min_chunk_size > 0 &&
        upload_thresholds.max_chunk_size >= upload_thresholds.min_chunk_size &&
        transport_signals.chunk_size_bytes >= upload_thresholds.min_chunk_size &&
        transport_signals.chunk_size_bytes <= upload_thresholds.max_chunk_size) {
        chunk_score = 1.0;
    }

    const double transport_score = clamp01(
        normalize_higher(transport_signals.bandwidth_mbps, 1.0, 100.0) * 0.12 +
        normalize_lower(transport_signals.rtt_ms, 25.0, thresholds.max_upload_rtt_ms) * 0.11 +
        normalize_lower(transport_signals.loss_rate, 0.0, thresholds.max_upload_loss_rate) * 0.11 +
        chunk_score * 0.08 +
        normalize_higher(transport_signals.dedup_savings_ratio, upload_thresholds.dedup_min_savings_ratio * 0.7, std::max(upload_thresholds.dedup_min_savings_ratio + 0.15, upload_thresholds.dedup_min_savings_ratio)) * 0.07 +
        normalize_higher(transport_signals.compression_savings_ratio, upload_thresholds.compression_min_savings_ratio * 0.7, std::max(upload_thresholds.compression_min_savings_ratio + 0.10, upload_thresholds.compression_min_savings_ratio)) * 0.06 +
        clamp01(transport_signals.byzantine_coverage) * 0.11 +
        clamp01(transport_signals.merkle_proof_success_rate) * 0.10 +
        clamp01(transport_signals.proof_of_possession_success_rate) * 0.08 +
        normalize_lower(transport_signals.chunk_hmac_mismatch_rate, 0.0, thresholds.max_upload_hmac_mismatch_rate) * 0.07 +
        normalize_lower(transport_signals.circuit_breaker_open_ratio, 0.0, thresholds.max_upload_circuit_breaker_open_ratio) * 0.04 +
        normalize_lower(transport_signals.retry_exhaustion_rate, 0.0, thresholds.max_upload_retry_exhaustion_rate) * 0.03 +
        normalize_lower(transport_signals.resume_corruption_rate, 0.0, thresholds.max_upload_resume_corruption_rate) * 0.02);

    double security_penalty = 0.0;
    if (!security_signals.code_signature_valid) security_penalty += 0.35;
    if (!security_signals.runtime_integrity_valid) security_penalty += 0.30;
    if (!security_signals.telemetry_hmac_valid) security_penalty += 0.20;
    if (security_signals.debugger_detected) security_penalty += 0.20;
    if (security_signals.environment_tampered) security_penalty += 0.25;
    if (security_signals.certificate_pin_mismatch_count > 0) {
        security_penalty += std::min(0.30, static_cast<double>(security_signals.certificate_pin_mismatch_count) * 0.10);
    }
    if (!security_signals.boot_chain_validated) security_penalty += 0.25;
    security_penalty += (1.0 - clamp01(security_signals.request_signer_valid_rate)) * 0.25;
    if (!security_signals.secure_enclave_available) security_penalty += 0.05;
    security_penalty = clamp01(security_penalty);

    result.security_penalty = security_penalty;
    const double security_score = clamp01(1.0 - security_penalty);

    result.component_scores.geometry = geometry_score;
    result.component_scores.cross_validation = cv_score;
    result.component_scores.capture = capture_score;
    result.component_scores.evidence = evidence_score;
    result.component_scores.transport = transport_score;
    result.component_scores.security = security_score;

    const double weight_sum =
        std::max(0.0, weights.geometry) +
        std::max(0.0, weights.cross_validation) +
        std::max(0.0, weights.capture) +
        std::max(0.0, weights.evidence) +
        std::max(0.0, weights.transport) +
        std::max(0.0, weights.security);
    const double norm = weight_sum > 1e-12 ? 1.0 / weight_sum : 0.0;

    result.fusion_score = clamp01((
        geometry_score * std::max(0.0, weights.geometry) +
        cv_score * std::max(0.0, weights.cross_validation) +
        capture_score * std::max(0.0, weights.capture) +
        evidence_score * std::max(0.0, weights.evidence) +
        transport_score * std::max(0.0, weights.transport) +
        security_score * std::max(0.0, weights.security)) * norm);

    const double reject_ratio =
        (cv_total > 0)
            ? static_cast<double>(result.cross_validation_stats.reject_count) / static_cast<double>(cv_total)
            : 0.0;

    result.risk_score = clamp01(
        (1.0 - result.fusion_score) * 0.55 +
        tri_tet_unknown_ratio * 0.10 +
        reject_ratio * 0.12 +
        (1.0 - capture_score) * 0.05 +
        (1.0 - evidence_score) * 0.05 +
        (1.0 - transport_score) * 0.05 +
        security_penalty * 0.18);

    if (tri_tet_measured_ratio < thresholds.min_tri_tet_measured_ratio) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kTriTetMeasuredRatioLow);
    }
    if (result.cross_validation_keep_ratio < thresholds.min_cross_validation_keep_ratio) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kCrossValidationKeepRatioLow);
    }
    if (result.cross_validation_stats.reject_count > 0) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kCrossValidationRejectPresent);
    }
    if (capture_signals.motion_score > thresholds.max_motion_score) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kCaptureMotionExceeded);
    }
    if (exposure_penalty > thresholds.max_exposure_penalty) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kCaptureExposurePenaltyExceeded);
    }
    if (evidence_signals.coverage_score < thresholds.min_coverage_score) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceCoverageLow);
    }
    if (evidence_signals.invariant_violation_count > thresholds.max_evidence_invariant_violations) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceInvariantViolationExceeded);
    }
    if (evidence_signals.replay_stable_rate < thresholds.min_evidence_replay_stable_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceReplayStabilityLow);
    }
    if (evidence_signals.tri_tet_binding_coverage < thresholds.min_tri_tet_binding_coverage) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceTriTetBindingCoverageLow);
    }
    if (evidence_signals.merkle_proof_coverage < thresholds.min_evidence_merkle_proof_coverage) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceMerkleCoverageLow);
    }
    if (evidence_signals.occlusion_excluded_area_ratio > thresholds.max_evidence_occlusion_excluded_ratio) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceOcclusionExcludedRatioHigh);
    }
    if (evidence_signals.provenance_gap_count > thresholds.max_evidence_provenance_gap_count) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kEvidenceProvenanceGapExceeded);
    }
    if (transport_signals.loss_rate > thresholds.max_upload_loss_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kTransportLossExceeded);
    }
    if (transport_signals.rtt_ms > thresholds.max_upload_rtt_ms) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kTransportRttExceeded);
    }
    if (transport_signals.byzantine_coverage < thresholds.min_upload_byzantine_coverage) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadByzantineCoverageLow);
    }
    if (transport_signals.merkle_proof_success_rate < thresholds.min_upload_merkle_proof_success_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadMerkleProofSuccessLow);
    }
    if (transport_signals.proof_of_possession_success_rate < thresholds.min_upload_pop_success_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadPoPSuccessLow);
    }
    if (transport_signals.chunk_hmac_mismatch_rate > thresholds.max_upload_hmac_mismatch_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadHmacMismatchHigh);
    }
    if (transport_signals.circuit_breaker_open_ratio > thresholds.max_upload_circuit_breaker_open_ratio) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadCircuitBreakerOpenHigh);
    }
    if (transport_signals.retry_exhaustion_rate > thresholds.max_upload_retry_exhaustion_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadRetryExhaustionHigh);
    }
    if (transport_signals.resume_corruption_rate > thresholds.max_upload_resume_corruption_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kUploadResumeCorruptionHigh);
    }
    if (security_signals.certificate_pin_mismatch_count > thresholds.max_certificate_pin_mismatch_count) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kSecurityCertPinMismatchExceeded);
    }
    if (security_signals.request_signer_valid_rate < thresholds.min_request_signer_valid_rate) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kSecurityRequestSignerValidRateLow);
    }
    if (security_penalty > thresholds.max_security_penalty) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kSecurityPenaltyExceeded);
    }
    if (result.fusion_score < thresholds.min_fusion_score) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kFusionScoreLow);
    }
    if (result.risk_score > thresholds.max_risk_score) {
        set_reason(&result.reason_mask, GeometryMLReasonBit::kRiskScoreHigh);
    }

    result.passes = (result.reason_mask == 0u);
    return result;
}

}  // namespace quality
}  // namespace aether
