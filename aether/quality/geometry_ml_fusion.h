// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_QUALITY_GEOMETRY_ML_FUSION_H
#define AETHER_QUALITY_GEOMETRY_ML_FUSION_H

#include <algorithm>
#include <cstdint>

#include "aether/quality/pure_vision_runtime.h"

namespace aether {
namespace quality {

// ---------------------------------------------------------------------------
// Capture signals: image-level quality indicators.
// ---------------------------------------------------------------------------

struct GeometryMLCaptureSignals {
    float motion_score{0.0f};
    float overexposure_ratio{0.0f};
    float underexposure_ratio{0.0f};
    bool has_large_blown_region{false};
};

// ---------------------------------------------------------------------------
// Evidence signals: provenance and coverage metrics.
// ---------------------------------------------------------------------------

struct GeometryMLEvidenceSignals {
    float coverage_score{0.0f};
    float soft_evidence_score{0.0f};
    int persistent_piz_region_count{0};
    int invariant_violation_count{0};
    double replay_stable_rate{0.0};
    float tri_tet_binding_coverage{0.0f};
    float merkle_proof_coverage{0.0f};
    float occlusion_excluded_area_ratio{0.0f};
    int provenance_gap_count{0};
};

// ---------------------------------------------------------------------------
// Transport signals: upload integrity and network health.
// ---------------------------------------------------------------------------

struct GeometryMLTransportSignals {
    float bandwidth_mbps{0.0f};
    float rtt_ms{0.0f};
    double loss_rate{0.0};
    int chunk_size_bytes{0};
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

// ---------------------------------------------------------------------------
// Security signals: client-side integrity indicators.
// ---------------------------------------------------------------------------

struct GeometryMLSecuritySignals {
    bool code_signature_valid{false};
    bool runtime_integrity_valid{false};
    bool telemetry_hmac_valid{false};
    bool debugger_detected{false};
    bool environment_tampered{false};
    int certificate_pin_mismatch_count{0};
    bool boot_chain_validated{false};
    double request_signer_valid_rate{0.0};
    bool secure_enclave_available{false};
};

// ---------------------------------------------------------------------------
// Cross-validation statistics input.
// ---------------------------------------------------------------------------

struct GeometryMLCrossValidationStatsInput {
    int keep_count{0};
    int downgrade_count{0};
    int reject_count{0};
};

// ---------------------------------------------------------------------------
// Tri-tet report input (optional -- may not be present).
// ---------------------------------------------------------------------------

struct GeometryMLTriTetReportInput {
    bool has_report{false};
    float combined_score{0.0f};
    int measured_count{0};
    int estimated_count{0};
    int unknown_count{0};
};

// ---------------------------------------------------------------------------
// Thresholds used by the fusion scoring logic.
// ---------------------------------------------------------------------------

struct GeometryMLThresholds {
    float min_fusion_score{0.0f};
    float max_risk_score{1.0f};
    float min_tri_tet_measured_ratio{0.0f};
    float min_cross_validation_keep_ratio{0.0f};
    float max_motion_score{1.0f};
    float max_exposure_penalty{1.0f};
    float min_coverage_score{0.0f};
    int max_persistent_piz_regions{0};
    int max_evidence_invariant_violations{0};
    double min_evidence_replay_stable_rate{0.0};
    float min_tri_tet_binding_coverage{0.0f};
    float min_evidence_merkle_proof_coverage{0.0f};
    float max_evidence_occlusion_excluded_ratio{1.0f};
    int max_evidence_provenance_gap_count{0};
    double max_upload_loss_rate{1.0};
    float max_upload_rtt_ms{10000.0f};
    double min_upload_byzantine_coverage{0.0};
    double min_upload_merkle_proof_success_rate{0.0};
    double min_upload_pop_success_rate{0.0};
    double max_upload_hmac_mismatch_rate{1.0};
    double max_upload_circuit_breaker_open_ratio{1.0};
    double max_upload_retry_exhaustion_rate{1.0};
    double max_upload_resume_corruption_rate{1.0};
    int max_certificate_pin_mismatch_count{0};
    double min_request_signer_valid_rate{0.0};
    float max_security_penalty{1.0f};
};

// ---------------------------------------------------------------------------
// Weights for the weighted fusion score.
// ---------------------------------------------------------------------------

struct GeometryMLWeights {
    float geometry{1.0f};
    float cross_validation{1.0f};
    float capture{1.0f};
    float evidence{1.0f};
    float transport{1.0f};
    float security{1.0f};
};

// ---------------------------------------------------------------------------
// Upload (content-defined-chunking) thresholds.
// ---------------------------------------------------------------------------

struct GeometryMLUploadThresholds {
    int min_chunk_size{0};
    int avg_chunk_size{0};
    int max_chunk_size{0};
    double dedup_min_savings_ratio{0.0};
    double compression_min_savings_ratio{0.0};
};

// ---------------------------------------------------------------------------
// Fusion result returned by evaluate_geometry_ml_fusion().
// ---------------------------------------------------------------------------

struct GeometryMLResult {
    bool passes{false};
    float fusion_score{0.0f};
    float risk_score{0.0f};
    float security_penalty{0.0f};
    float tri_tet_measured_ratio{0.0f};
    float tri_tet_unknown_ratio{0.0f};
    float cross_validation_keep_ratio{0.0f};
    float capture_exposure_penalty{0.0f};

    struct ComponentScores {
        float geometry{0.0f};
        float cross_validation{0.0f};
        float capture{0.0f};
        float evidence{0.0f};
        float transport{0.0f};
        float security{0.0f};
    } component_scores;

    struct CrossValidationStats {
        int keep_count{0};
        int downgrade_count{0};
        int reject_count{0};
    } cross_validation_stats;

    std::uint32_t reason_mask{0u};
};

// ---------------------------------------------------------------------------
// Evaluate geometry ML fusion.
//
// Computes per-component scores, blends them with the supplied weights, and
// applies threshold-based hard gates to produce a pass / fail decision.
// ---------------------------------------------------------------------------

inline GeometryMLResult evaluate_geometry_ml_fusion(
    const PureVisionRuntimeMetrics& runtime_metrics,
    const GeometryMLTriTetReportInput* tri_tet_report_or_null,
    const GeometryMLCrossValidationStatsInput& cv_stats,
    const GeometryMLCaptureSignals& capture,
    const GeometryMLEvidenceSignals& evidence,
    const GeometryMLTransportSignals& transport,
    const GeometryMLSecuritySignals& security,
    const GeometryMLThresholds& thresholds,
    const GeometryMLWeights& weights,
    const GeometryMLUploadThresholds& upload_thresholds) {

    GeometryMLResult result{};

    // -- Cross-validation stats passthrough --------------------------------
    result.cross_validation_stats.keep_count = cv_stats.keep_count;
    result.cross_validation_stats.downgrade_count = cv_stats.downgrade_count;
    result.cross_validation_stats.reject_count = cv_stats.reject_count;

    const int cv_total =
        cv_stats.keep_count + cv_stats.downgrade_count + cv_stats.reject_count;
    result.cross_validation_keep_ratio =
        (cv_total > 0)
            ? static_cast<float>(cv_stats.keep_count) / static_cast<float>(cv_total)
            : 0.0f;

    // -- Tri-tet ratios ----------------------------------------------------
    if (tri_tet_report_or_null != nullptr && tri_tet_report_or_null->has_report) {
        const int tri_total =
            tri_tet_report_or_null->measured_count +
            tri_tet_report_or_null->estimated_count +
            tri_tet_report_or_null->unknown_count;
        if (tri_total > 0) {
            result.tri_tet_measured_ratio =
                static_cast<float>(tri_tet_report_or_null->measured_count) /
                static_cast<float>(tri_total);
            result.tri_tet_unknown_ratio =
                static_cast<float>(tri_tet_report_or_null->unknown_count) /
                static_cast<float>(tri_total);
        }
    }

    // -- Geometry component score ------------------------------------------
    // Derived from PureVisionRuntimeMetrics: favour high closure ratio and
    // low depth sigma.
    const float geometry_score = static_cast<float>(
        std::min(1.0, runtime_metrics.closure_ratio) *
        std::max(0.0, 1.0 - runtime_metrics.depth_sigma_meters * 50.0));
    result.component_scores.geometry = geometry_score;

    // -- Cross-validation component score ----------------------------------
    result.component_scores.cross_validation = result.cross_validation_keep_ratio;

    // -- Capture component score -------------------------------------------
    const float exposure_penalty =
        capture.overexposure_ratio + capture.underexposure_ratio +
        (capture.has_large_blown_region ? 0.25f : 0.0f);
    result.capture_exposure_penalty = std::min(exposure_penalty, 1.0f);
    const float capture_score =
        std::max(0.0f, 1.0f - capture.motion_score) *
        std::max(0.0f, 1.0f - result.capture_exposure_penalty);
    result.component_scores.capture = capture_score;

    // -- Evidence component score ------------------------------------------
    const float evidence_base =
        evidence.coverage_score * 0.4f +
        evidence.soft_evidence_score * 0.2f +
        evidence.tri_tet_binding_coverage * 0.2f +
        evidence.merkle_proof_coverage * 0.2f;
    const float evidence_penalty =
        static_cast<float>(evidence.invariant_violation_count) * 0.05f +
        evidence.occlusion_excluded_area_ratio * 0.1f +
        static_cast<float>(evidence.provenance_gap_count) * 0.02f;
    const float evidence_score = std::max(0.0f, std::min(1.0f, evidence_base - evidence_penalty));
    result.component_scores.evidence = evidence_score;

    // -- Transport component score -----------------------------------------
    const float transport_base = static_cast<float>(
        (1.0 - transport.loss_rate) *
        (1.0 - transport.chunk_hmac_mismatch_rate) *
        transport.merkle_proof_success_rate *
        transport.proof_of_possession_success_rate *
        transport.byzantine_coverage);
    const float transport_penalty = static_cast<float>(
        transport.circuit_breaker_open_ratio * 0.3 +
        transport.retry_exhaustion_rate * 0.3 +
        transport.resume_corruption_rate * 0.4);
    const float transport_score = std::max(0.0f, std::min(1.0f, transport_base - transport_penalty));
    result.component_scores.transport = transport_score;

    // -- Security component score ------------------------------------------
    float sec_score = 1.0f;
    if (!security.code_signature_valid) { sec_score -= 0.25f; }
    if (!security.runtime_integrity_valid) { sec_score -= 0.20f; }
    if (!security.telemetry_hmac_valid) { sec_score -= 0.15f; }
    if (security.debugger_detected) { sec_score -= 0.15f; }
    if (security.environment_tampered) { sec_score -= 0.15f; }
    if (!security.boot_chain_validated) { sec_score -= 0.05f; }
    if (!security.secure_enclave_available) { sec_score -= 0.05f; }
    sec_score -= static_cast<float>(security.certificate_pin_mismatch_count) * 0.05f;
    sec_score -= static_cast<float>(1.0 - security.request_signer_valid_rate) * 0.10f;
    sec_score = std::max(0.0f, sec_score);
    result.component_scores.security = sec_score;
    result.security_penalty = 1.0f - sec_score;

    // -- Weighted fusion score ---------------------------------------------
    const float weight_sum =
        weights.geometry + weights.cross_validation + weights.capture +
        weights.evidence + weights.transport + weights.security;
    if (weight_sum > 0.0f) {
        result.fusion_score =
            (weights.geometry * geometry_score +
             weights.cross_validation * result.cross_validation_keep_ratio +
             weights.capture * capture_score +
             weights.evidence * evidence_score +
             weights.transport * transport_score +
             weights.security * sec_score) /
            weight_sum;
    }

    // -- Risk score (inverse of fusion, clamped) ---------------------------
    result.risk_score = std::max(0.0f, std::min(1.0f, 1.0f - result.fusion_score));

    // -- Reason mask (bit flags for threshold violations) ------------------
    std::uint32_t mask = 0u;
    if (result.fusion_score < thresholds.min_fusion_score)              { mask |= (1u << 0); }
    if (result.risk_score > thresholds.max_risk_score)                  { mask |= (1u << 1); }
    if (result.tri_tet_measured_ratio < thresholds.min_tri_tet_measured_ratio) { mask |= (1u << 2); }
    if (result.cross_validation_keep_ratio < thresholds.min_cross_validation_keep_ratio) { mask |= (1u << 3); }
    if (capture.motion_score > thresholds.max_motion_score)             { mask |= (1u << 4); }
    if (result.capture_exposure_penalty > thresholds.max_exposure_penalty) { mask |= (1u << 5); }
    if (evidence.coverage_score < thresholds.min_coverage_score)        { mask |= (1u << 6); }
    if (evidence.persistent_piz_region_count > thresholds.max_persistent_piz_regions) { mask |= (1u << 7); }
    if (evidence.invariant_violation_count > thresholds.max_evidence_invariant_violations) { mask |= (1u << 8); }
    if (evidence.replay_stable_rate < thresholds.min_evidence_replay_stable_rate) { mask |= (1u << 9); }
    if (evidence.tri_tet_binding_coverage < thresholds.min_tri_tet_binding_coverage) { mask |= (1u << 10); }
    if (evidence.merkle_proof_coverage < thresholds.min_evidence_merkle_proof_coverage) { mask |= (1u << 11); }
    if (evidence.occlusion_excluded_area_ratio > thresholds.max_evidence_occlusion_excluded_ratio) { mask |= (1u << 12); }
    if (evidence.provenance_gap_count > thresholds.max_evidence_provenance_gap_count) { mask |= (1u << 13); }
    if (transport.loss_rate > thresholds.max_upload_loss_rate)          { mask |= (1u << 14); }
    if (transport.rtt_ms > thresholds.max_upload_rtt_ms)               { mask |= (1u << 15); }
    if (transport.byzantine_coverage < thresholds.min_upload_byzantine_coverage) { mask |= (1u << 16); }
    if (transport.merkle_proof_success_rate < thresholds.min_upload_merkle_proof_success_rate) { mask |= (1u << 17); }
    if (transport.proof_of_possession_success_rate < thresholds.min_upload_pop_success_rate) { mask |= (1u << 18); }
    if (transport.chunk_hmac_mismatch_rate > thresholds.max_upload_hmac_mismatch_rate) { mask |= (1u << 19); }
    if (transport.circuit_breaker_open_ratio > thresholds.max_upload_circuit_breaker_open_ratio) { mask |= (1u << 20); }
    if (transport.retry_exhaustion_rate > thresholds.max_upload_retry_exhaustion_rate) { mask |= (1u << 21); }
    if (transport.resume_corruption_rate > thresholds.max_upload_resume_corruption_rate) { mask |= (1u << 22); }
    if (security.certificate_pin_mismatch_count > thresholds.max_certificate_pin_mismatch_count) { mask |= (1u << 23); }
    if (security.request_signer_valid_rate < thresholds.min_request_signer_valid_rate) { mask |= (1u << 24); }
    if (result.security_penalty > thresholds.max_security_penalty)      { mask |= (1u << 25); }
    result.reason_mask = mask;

    // -- Final pass decision -----------------------------------------------
    result.passes = (mask == 0u);

    return result;
}

}  // namespace quality
}  // namespace aether

#endif  // AETHER_QUALITY_GEOMETRY_ML_FUSION_H
