// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_tsdf_c.h"

#include "aether/core/status.h"
#include "aether/core/numeric_guard.h"
#include "aether/crypto/sha256.h"
#include "aether/evidence/admission_controller.h"
#include "aether/evidence/coverage_estimator.h"
#include "aether/evidence/deterministic_json.h"
#include "aether/evidence/ds_mass_function.h"
#include "aether/evidence/patch_display_kernel.h"
#include "aether/evidence/pr1_admission_kernel.h"
#include "aether/evidence/pr1_information_gain.h"
#include "aether/evidence/evidence_state_machine.h"
#include "aether/evidence/smart_anti_boost_smoother.h"
#include "aether/innovation/f1_time_mirror.h"
#include "aether/innovation/f3_evidence_constrained_compression.h"
#include "aether/innovation/f5_delta_patch_chain.h"
#include "aether/innovation/f6_conflict_dynamic_rejection.h"
#include "aether/merkle/consistency_proof.h"
#include "aether/merkle/inclusion_proof.h"
#include "aether/merkle/merkle_tree.h"
#include "aether/merkle/merkle_tree_hash.h"
#include "aether/quality/deterministic_triangulator.h"
#include "aether/quality/image_metrics.h"
#include "aether/quality/motion_analyzer.h"
#include "aether/quality/photometric_checker.h"
#include "aether/quality/geometry_ml_fusion.h"
#include "aether/quality/pure_vision_runtime.h"
#include "aether/quality/spatial_hash_adjacency.h"
#include "aether/quality/zero_fabrication_policy.h"
#include "aether/render/color_correction.h"
#include "aether/render/confidence_decay.h"
#include "aether/render/flip_animation.h"
#include "aether/render/fracture_display_mesh.h"
#include "aether/render/ripple_propagation.h"
#include "aether/render/wedge_geometry.h"
#include "aether/tsdf/adaptive_resolution.h"
#include "aether/scheduler/gpu_scheduler.h"
#include "aether/tsdf/depth_filter.h"
#include "aether/tsdf/icp_registration.h"
#include "aether/tsdf/loop_detector.h"
#include "aether/tsdf/marching_cubes.h"
#include "aether/tsdf/pose_graph.h"
#include "aether/tsdf/pose_stabilizer.h"
#include "aether/tsdf/spatial_quantizer.h"
#include "aether/tsdf/thermal_engine.h"
#include "aether/tsdf/tri_tet_consistency.h"
#include "aether/tsdf/tsdf_constants.h"
#include "aether/tsdf/tsdf_types.h"
#include "aether/tsdf/tsdf_volume.h"
#include "aether/tsdf/volume_controller.h"
#include "aether/upload/erasure_coding.h"
#include "aether/upload/kalman_bandwidth.h"
#include "aether/trainer/da3_depth_fuser.h"
#include "aether/innovation/f1_progressive_compression.h"
#include "aether/innovation/f2_scaffold_collision.h"
#include "aether/innovation/f7_shaderml_decode.h"
#include "aether/innovation/f8_uncertainty_field.h"
#include "aether/innovation/f9_scene_passport_watermark.h"
#include "aether/innovation/scaffold_patch_map.h"
#include "aether/render/dgrut_renderer.h"
#include "aether/render/frustum_culler.h"
#include "aether/render/meshlet_builder.h"
#include "aether/render/screen_detail_selector.h"
#include "aether/render/tri_tet_splat_projector.h"
#include "aether/render/two_pass_culler.h"
#include "aether/tsdf/mesh_extraction_scheduler.h"
#include "aether/tsdf/mesh_topology.h"
#include "aether/tsdf/mesh_fiedler.h"
#include "aether/trainer/noise_aware_trainer.h"
#include "aether/core/canonicalize.h"
#include "aether/evidence/pr_math.h"
#include "aether/tsdf/tri_tet_mapping.h"

#include "aether/math/half.h"
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <limits>
#include <new>
#include <string>
#include <unordered_map>
#include <vector>
#include "aether/render/gpu_device.h"
#include "aether/render/gpu_command.h"

struct aether_tsdf_volume {
    aether::tsdf::TSDFVolume impl;
};

struct aether_coverage_estimator {
    explicit aether_coverage_estimator(const aether::evidence::CoverageEstimatorConfig& config)
        : impl(config) {}
    aether::evidence::CoverageEstimator impl;
};

struct aether_spam_protection {
    aether::evidence::SpamProtection impl;
};

struct aether_token_bucket {
    aether::evidence::TokenBucketLimiter impl;
};

struct aether_view_diversity_tracker {
    aether::evidence::ViewDiversityTracker impl;
};

struct aether_admission_controller {
    aether::evidence::AdmissionController impl;
};

struct aether_merkle_tree {
    aether::merkle::MerkleTree impl;
};

struct aether_f5_chain {
    aether::innovation::F5DeltaPatchChain impl;
};

struct aether_f6_rejector {
    explicit aether_f6_rejector(const aether::innovation::F6RejectorConfig& config)
        : impl(config) {}
    aether::innovation::F6ConflictDynamicRejector impl;
};

struct aether_gpu_scheduler {
    explicit aether_gpu_scheduler(const aether::scheduler::GPUSchedulerConfig& config)
        : impl(config) {}
    aether::scheduler::TwoStateGPUScheduler impl;
};

struct aether_motion_analyzer {
    aether::quality::MotionAnalyzer impl;
};

struct aether_photometric_checker {
    explicit aether_photometric_checker(std::size_t window_size)
        : impl(window_size) {}
    aether::quality::PhotometricChecker impl;
};

struct aether_depth_filter {
    explicit aether_depth_filter(
        int width,
        int height,
        const aether::tsdf::DepthFilterConfig& config)
        : impl(width, height, config) {}
    aether::tsdf::DepthFilter impl;
};

struct aether_thermal_engine {
    aether::tsdf::AetherThermalEngine impl;
};

struct aether_pose_stabilizer {
    explicit aether_pose_stabilizer(const aether::tsdf::PoseStabilizerConfig& config)
        : impl(config) {}
    aether::tsdf::PoseStabilizer impl;
};

struct aether_smart_smoother {
    explicit aether_smart_smoother(const aether::evidence::SmartSmootherConfig& config)
        : impl(config) {}
    aether::evidence::SmartAntiBoostSmoother impl;
};

struct aether_capture_style_runtime {
    struct PatchState {
        float display{0.0f};
        float metallic{0.0f};
        float roughness{1.0f};
        float thickness{0.0f};
        float border_width{0.0f};
        float border_alpha{0.0f};
        float grayscale{0.0f};
        bool visual_frozen{false};
        bool border_frozen{false};
        bool has_visual{false};
        bool has_border{false};
        bool has_grayscale{false};
    };

    explicit aether_capture_style_runtime(const aether_capture_style_runtime_config_t& cfg)
        : config(cfg) {}

    aether_capture_style_runtime_config_t config{};
    std::unordered_map<std::uint64_t, PatchState> states;
};

struct aether_flip_runtime {
    struct ActiveFlip {
        double start_time_s{0.0};
        aether::innovation::Float3 axis_origin{};
        aether::innovation::Float3 axis_direction{1.0f, 0.0f, 0.0f};
    };

    explicit aether_flip_runtime(const aether_flip_runtime_config_t& cfg)
        : config(cfg) {}

    aether_flip_runtime_config_t config{};
    std::unordered_map<std::int32_t, ActiveFlip> active;
};

struct aether_ripple_runtime {
    struct Wave {
        std::int32_t source_triangle{0};
        double spawn_time_s{0.0};
        int max_hop{0};
    };

    explicit aether_ripple_runtime(const aether_ripple_runtime_config_t& cfg)
        : config(cfg) {}

    aether_ripple_runtime_config_t config{};
    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    int triangle_count{0};
    std::vector<Wave> active_waves;
    std::unordered_map<std::int32_t, double> last_spawn_times;
};

struct aether_f7_decoder {
    aether::innovation::F7AppearanceDecoder impl;
};

struct aether_f8_field {
    explicit aether_f8_field(const aether::innovation::F8FieldConfig& config)
        : impl(config) {}
    aether::innovation::F8UncertaintyField impl;
};

struct aether_scaffold_patch_map {
    aether::innovation::ScaffoldPatchMap impl;
};

struct aether_f2_collision_mesh {
    aether::innovation::F2CollisionMesh impl;
};

struct aether_mesh_extraction_scheduler {
    aether::tsdf::MeshExtractionScheduler impl;
};

struct aether_render_selection_runtime {
    explicit aether_render_selection_runtime(int32_t hold)
        : hold_frames(std::max<int32_t>(1, hold)) {}

    int32_t hold_frames{90};
    std::unordered_map<std::uint64_t, int32_t> residency_until_by_patch;
};

namespace {

using aether::core::Status;

inline int to_rc(Status status) {
    return static_cast<int>(status);
}

struct CoreHealthStore {
    aether_core_health_t snapshot{};
    aether_memory_footprint_t memory{};
};

CoreHealthStore& core_health_store() {
    static CoreHealthStore store{};
    return store;
}

aether_tsdf_volume_t*& mesh_stability_volume_anchor() {
    static aether_tsdf_volume_t* volume = nullptr;
    return volume;
}

double& mesh_stability_latest_timestamp_s() {
    static double timestamp_s = 0.0;
    return timestamp_s;
}

[[maybe_unused]] std::unordered_map<std::uint32_t, std::uint64_t>& gaussian_last_seen_frames() {
    static std::unordered_map<std::uint32_t, std::uint64_t> map;
    return map;
}

[[maybe_unused]] std::unordered_map<std::uint32_t, float>& gaussian_peak_confidence_map() {
    static std::unordered_map<std::uint32_t, float> map;
    return map;
}

bool checked_count(int count, std::size_t* out_size) {
    if (out_size == nullptr || count < 0) {
        return false;
    }
    *out_size = static_cast<std::size_t>(count);
    return true;
}

bool finite_non_negative(double value) {
    return value >= 0.0 && value == value && value != std::numeric_limits<double>::infinity();
}

bool finite_pose(const float* pose16) {
    if (pose16 == nullptr) {
        return false;
    }
    for (int i = 0; i < 16; ++i) {
        if (!std::isfinite(pose16[i])) {
            return false;
        }
    }
    return true;
}

aether::trainer::TriTetClass to_cpp_tri_tet_class(std::uint8_t tri_tet_class) {
    switch (tri_tet_class) {
        case AETHER_TRI_TET_CLASS_MEASURED:
            return aether::trainer::TriTetClass::kMeasured;
        case AETHER_TRI_TET_CLASS_ESTIMATED:
            return aether::trainer::TriTetClass::kEstimated;
        case AETHER_TRI_TET_CLASS_UNKNOWN:
        default:
            return aether::trainer::TriTetClass::kUnknown;
    }
}

int to_c_cross_validation_decision(aether::quality::CrossValidationDecision decision) {
    switch (decision) {
        case aether::quality::CrossValidationDecision::kKeep:
            return AETHER_CROSS_VALIDATION_KEEP;
        case aether::quality::CrossValidationDecision::kReject:
            return AETHER_CROSS_VALIDATION_REJECT;
        case aether::quality::CrossValidationDecision::kDowngrade:
        default:
            return AETHER_CROSS_VALIDATION_DOWNGRADE;
    }
}

int to_c_cross_validation_reason(aether::quality::CrossValidationReasonCode reason) {
    switch (reason) {
        case aether::quality::CrossValidationReasonCode::kOutlierBothInlier:
            return AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_INLIER;
        case aether::quality::CrossValidationReasonCode::kOutlierBothReject:
            return AETHER_CROSS_VALIDATION_REASON_OUTLIER_BOTH_REJECT;
        case aether::quality::CrossValidationReasonCode::kOutlierDisagreementDowngrade:
            return AETHER_CROSS_VALIDATION_REASON_OUTLIER_DISAGREEMENT_DOWNGRADE;
        case aether::quality::CrossValidationReasonCode::kCalibrationBothPass:
            return AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_PASS;
        case aether::quality::CrossValidationReasonCode::kCalibrationBothFail:
            return AETHER_CROSS_VALIDATION_REASON_CALIBRATION_BOTH_FAIL;
        case aether::quality::CrossValidationReasonCode::kCalibrationDisagreementOrDivergence:
        default:
            return AETHER_CROSS_VALIDATION_REASON_CALIBRATION_DISAGREEMENT_OR_DIVERGENCE;
    }
}

int to_c_pure_vision_gate_id(aether::quality::PureVisionGateId gate_id) {
    switch (gate_id) {
        case aether::quality::PureVisionGateId::kBaselinePixels:
            return AETHER_PURE_VISION_GATE_BASELINE_PIXELS;
        case aether::quality::PureVisionGateId::kBlurLaplacian:
            return AETHER_PURE_VISION_GATE_BLUR_LAPLACIAN;
        case aether::quality::PureVisionGateId::kOrbFeatureCount:
            return AETHER_PURE_VISION_GATE_ORB_FEATURE_COUNT;
        case aether::quality::PureVisionGateId::kParallaxRatio:
            return AETHER_PURE_VISION_GATE_PARALLAX_RATIO;
        case aether::quality::PureVisionGateId::kDepthSigma:
            return AETHER_PURE_VISION_GATE_DEPTH_SIGMA;
        case aether::quality::PureVisionGateId::kClosureRatio:
            return AETHER_PURE_VISION_GATE_CLOSURE_RATIO;
        case aether::quality::PureVisionGateId::kUnknownVoxelRatio:
            return AETHER_PURE_VISION_GATE_UNKNOWN_VOXEL_RATIO;
        case aether::quality::PureVisionGateId::kThermalCelsius:
            return AETHER_PURE_VISION_GATE_THERMAL_CELSIUS;
        default:
            return -1;
    }
}

void pure_vision_default_thresholds(aether_pure_vision_gate_thresholds_t* out_thresholds) {
    if (out_thresholds == nullptr) {
        return;
    }
    out_thresholds->min_baseline_pixels = 3.0;
    out_thresholds->min_blur_laplacian = 200.0;
    out_thresholds->min_orb_features = 500;
    out_thresholds->min_parallax_ratio = 0.2;
    out_thresholds->max_depth_sigma_meters = 0.015;
    out_thresholds->min_closure_ratio = 0.97;
    out_thresholds->max_unknown_voxel_ratio = 0.03;
    out_thresholds->max_thermal_celsius = 45.0;
}

aether::quality::PureVisionGateThresholds to_cpp_pure_vision_thresholds(
    const aether_pure_vision_gate_thresholds_t* thresholds_or_null) {
    aether_pure_vision_gate_thresholds_t defaults{};
    pure_vision_default_thresholds(&defaults);
    const aether_pure_vision_gate_thresholds_t* src =
        (thresholds_or_null != nullptr) ? thresholds_or_null : &defaults;
    aether::quality::PureVisionGateThresholds out{};
    out.min_baseline_pixels = src->min_baseline_pixels;
    out.min_blur_laplacian = src->min_blur_laplacian;
    out.min_orb_features = src->min_orb_features;
    out.min_parallax_ratio = src->min_parallax_ratio;
    out.max_depth_sigma_meters = src->max_depth_sigma_meters;
    out.min_closure_ratio = src->min_closure_ratio;
    out.max_unknown_voxel_ratio = src->max_unknown_voxel_ratio;
    out.max_thermal_celsius = src->max_thermal_celsius;
    return out;
}

aether::quality::PureVisionRuntimeMetrics to_cpp_pure_vision_metrics(
    const aether_pure_vision_runtime_metrics_t& src) {
    return aether::quality::PureVisionRuntimeMetrics{
        src.baseline_pixels,
        src.blur_laplacian,
        src.orb_features,
        src.parallax_ratio,
        src.depth_sigma_meters,
        src.closure_ratio,
        src.unknown_voxel_ratio,
        src.thermal_celsius};
}

aether::quality::ZeroFabricationMode to_cpp_zero_fab_mode(int mode) {
    switch (mode) {
        case AETHER_ZERO_FAB_MODE_RESEARCH_RELAXED:
            return aether::quality::ZeroFabricationMode::kResearchRelaxed;
        case AETHER_ZERO_FAB_MODE_FORENSIC_STRICT:
        default:
            return aether::quality::ZeroFabricationMode::kForensicStrict;
    }
}

aether::quality::MLAction to_cpp_zero_fab_action(int action) {
    switch (action) {
        case AETHER_ZERO_FAB_ACTION_CALIBRATION_CORRECTION:
            return aether::quality::MLAction::kCalibrationCorrection;
        case AETHER_ZERO_FAB_ACTION_MULTI_VIEW_DENOISE:
            return aether::quality::MLAction::kMultiViewDenoise;
        case AETHER_ZERO_FAB_ACTION_OUTLIER_REJECTION:
            return aether::quality::MLAction::kOutlierRejection;
        case AETHER_ZERO_FAB_ACTION_CONFIDENCE_ESTIMATION:
            return aether::quality::MLAction::kConfidenceEstimation;
        case AETHER_ZERO_FAB_ACTION_UNCERTAINTY_ESTIMATION:
            return aether::quality::MLAction::kUncertaintyEstimation;
        case AETHER_ZERO_FAB_ACTION_TEXTURE_INPAINT:
            return aether::quality::MLAction::kTextureInpaint;
        case AETHER_ZERO_FAB_ACTION_HOLE_FILLING:
            return aether::quality::MLAction::kHoleFilling;
        case AETHER_ZERO_FAB_ACTION_GEOMETRY_COMPLETION:
            return aether::quality::MLAction::kGeometryCompletion;
        case AETHER_ZERO_FAB_ACTION_UNKNOWN_REGION_GROWTH:
            return aether::quality::MLAction::kUnknownRegionGrowth;
        default:
            return aether::quality::MLAction::kCalibrationCorrection;
    }
}

aether::quality::ReconstructionConfidenceClass to_cpp_zero_fab_confidence(
    int confidence_class) {
    switch (confidence_class) {
        case AETHER_ZERO_FAB_CONFIDENCE_MEASURED:
            return aether::quality::ReconstructionConfidenceClass::kMeasured;
        case AETHER_ZERO_FAB_CONFIDENCE_ESTIMATED:
            return aether::quality::ReconstructionConfidenceClass::kEstimated;
        case AETHER_ZERO_FAB_CONFIDENCE_UNKNOWN:
        default:
            return aether::quality::ReconstructionConfidenceClass::kUnknown;
    }
}

int to_c_zero_fab_reason(aether::quality::ZeroFabricationReason reason) {
    switch (reason) {
        case aether::quality::ZeroFabricationReason::kBlockGenerativeAction:
            return AETHER_ZERO_FAB_REASON_BLOCK_GENERATIVE_ACTION;
        case aether::quality::ZeroFabricationReason::kBlockUnknownGrowth:
            return AETHER_ZERO_FAB_REASON_BLOCK_UNKNOWN_GROWTH;
        case aether::quality::ZeroFabricationReason::kAllowObservedGrowth:
            return AETHER_ZERO_FAB_REASON_ALLOW_OBSERVED_GROWTH;
        case aether::quality::ZeroFabricationReason::kBlockCoordinateRewrite:
            return AETHER_ZERO_FAB_REASON_BLOCK_COORDINATE_REWRITE;
        case aether::quality::ZeroFabricationReason::kDenoiseDisplacementExceedsPolicy:
            return AETHER_ZERO_FAB_REASON_DENOISE_DISPLACEMENT_EXCEEDS_POLICY;
        case aether::quality::ZeroFabricationReason::kAllowDenoise:
            return AETHER_ZERO_FAB_REASON_ALLOW_DENOISE;
        case aether::quality::ZeroFabricationReason::kAllowOutlierRejection:
            return AETHER_ZERO_FAB_REASON_ALLOW_OUTLIER_REJECTION;
        case aether::quality::ZeroFabricationReason::kAllowNonGenerativeCalibration:
        default:
            return AETHER_ZERO_FAB_REASON_ALLOW_NON_GENERATIVE_CALIBRATION;
    }
}

int to_c_zero_fab_severity(aether::quality::PolicySeverity severity) {
    switch (severity) {
        case aether::quality::PolicySeverity::kInfo:
            return AETHER_ZERO_FAB_SEVERITY_INFO;
        case aether::quality::PolicySeverity::kWarn:
            return AETHER_ZERO_FAB_SEVERITY_WARN;
        case aether::quality::PolicySeverity::kBlock:
        default:
            return AETHER_ZERO_FAB_SEVERITY_BLOCK;
    }
}

aether::quality::GeometryMLCaptureSignals to_cpp_geometry_capture_signals(
    const aether_geometry_ml_capture_signals_t& src) {
    return aether::quality::GeometryMLCaptureSignals{
        src.motion_score,
        src.overexposure_ratio,
        src.underexposure_ratio,
        src.has_large_blown_region != 0};
}

aether::quality::GeometryMLEvidenceSignals to_cpp_geometry_evidence_signals(
    const aether_geometry_ml_evidence_signals_t& src) {
    return aether::quality::GeometryMLEvidenceSignals{
        src.coverage_score,
        src.soft_evidence_score,
        src.persistent_piz_region_count,
        src.invariant_violation_count,
        src.replay_stable_rate,
        src.tri_tet_binding_coverage,
        src.merkle_proof_coverage,
        src.occlusion_excluded_area_ratio,
        src.provenance_gap_count};
}

aether::quality::GeometryMLTransportSignals to_cpp_geometry_transport_signals(
    const aether_geometry_ml_transport_signals_t& src) {
    return aether::quality::GeometryMLTransportSignals{
        src.bandwidth_mbps,
        src.rtt_ms,
        src.loss_rate,
        src.chunk_size_bytes,
        src.dedup_savings_ratio,
        src.compression_savings_ratio,
        src.byzantine_coverage,
        src.merkle_proof_success_rate,
        src.proof_of_possession_success_rate,
        src.chunk_hmac_mismatch_rate,
        src.circuit_breaker_open_ratio,
        src.retry_exhaustion_rate,
        src.resume_corruption_rate};
}

aether::quality::GeometryMLSecuritySignals to_cpp_geometry_security_signals(
    const aether_geometry_ml_security_signals_t& src) {
    return aether::quality::GeometryMLSecuritySignals{
        src.code_signature_valid != 0,
        src.runtime_integrity_valid != 0,
        src.telemetry_hmac_valid != 0,
        src.debugger_detected != 0,
        src.environment_tampered != 0,
        src.certificate_pin_mismatch_count,
        src.boot_chain_validated != 0,
        src.request_signer_valid_rate,
        src.secure_enclave_available != 0};
}

aether::quality::GeometryMLCrossValidationStatsInput to_cpp_geometry_cv_stats(
    const aether_geometry_ml_cross_validation_stats_t& src) {
    return aether::quality::GeometryMLCrossValidationStatsInput{
        src.keep_count,
        src.downgrade_count,
        src.reject_count};
}

aether::quality::GeometryMLTriTetReportInput to_cpp_geometry_tri_tet_report(
    const aether_geometry_ml_tri_tet_report_t* src_or_null) {
    aether::quality::GeometryMLTriTetReportInput out{};
    if (src_or_null == nullptr) {
        out.has_report = false;
        return out;
    }
    out.has_report = src_or_null->has_report != 0;
    out.combined_score = src_or_null->combined_score;
    out.measured_count = src_or_null->measured_count;
    out.estimated_count = src_or_null->estimated_count;
    out.unknown_count = src_or_null->unknown_count;
    return out;
}

aether::quality::GeometryMLThresholds to_cpp_geometry_ml_thresholds(
    const aether_geometry_ml_thresholds_t& src) {
    return aether::quality::GeometryMLThresholds{
        src.min_fusion_score,
        src.max_risk_score,
        src.min_tri_tet_measured_ratio,
        src.min_cross_validation_keep_ratio,
        src.max_motion_score,
        src.max_exposure_penalty,
        src.min_coverage_score,
        src.max_persistent_piz_regions,
        src.max_evidence_invariant_violations,
        src.min_evidence_replay_stable_rate,
        src.min_tri_tet_binding_coverage,
        src.min_evidence_merkle_proof_coverage,
        src.max_evidence_occlusion_excluded_ratio,
        src.max_evidence_provenance_gap_count,
        src.max_upload_loss_rate,
        src.max_upload_rtt_ms,
        src.min_upload_byzantine_coverage,
        src.min_upload_merkle_proof_success_rate,
        src.min_upload_pop_success_rate,
        src.max_upload_hmac_mismatch_rate,
        src.max_upload_circuit_breaker_open_ratio,
        src.max_upload_retry_exhaustion_rate,
        src.max_upload_resume_corruption_rate,
        src.max_certificate_pin_mismatch_count,
        src.min_request_signer_valid_rate,
        src.max_security_penalty};
}

aether::quality::GeometryMLWeights to_cpp_geometry_ml_weights(
    const aether_geometry_ml_weights_t& src) {
    return aether::quality::GeometryMLWeights{
        src.geometry,
        src.cross_validation,
        src.capture,
        src.evidence,
        src.transport,
        src.security};
}

aether::quality::GeometryMLUploadThresholds to_cpp_geometry_ml_upload_thresholds(
    const aether_upload_cdc_thresholds_t& src) {
    return aether::quality::GeometryMLUploadThresholds{
        src.min_chunk_size,
        src.avg_chunk_size,
        src.max_chunk_size,
        src.dedup_min_savings_ratio,
        src.compression_min_savings_ratio};
}

void to_c_geometry_ml_result(
    const aether::quality::GeometryMLResult& src,
    aether_geometry_ml_result_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->passes = src.passes ? 1 : 0;
    dst->fusion_score = src.fusion_score;
    dst->risk_score = src.risk_score;
    dst->security_penalty = src.security_penalty;
    dst->tri_tet_measured_ratio = src.tri_tet_measured_ratio;
    dst->tri_tet_unknown_ratio = src.tri_tet_unknown_ratio;
    dst->cross_validation_keep_ratio = src.cross_validation_keep_ratio;
    dst->capture_exposure_penalty = src.capture_exposure_penalty;
    dst->component_scores.geometry = src.component_scores.geometry;
    dst->component_scores.cross_validation = src.component_scores.cross_validation;
    dst->component_scores.capture = src.component_scores.capture;
    dst->component_scores.evidence = src.component_scores.evidence;
    dst->component_scores.transport = src.component_scores.transport;
    dst->component_scores.security = src.component_scores.security;
    dst->cross_validation_stats.keep_count = src.cross_validation_stats.keep_count;
    dst->cross_validation_stats.downgrade_count = src.cross_validation_stats.downgrade_count;
    dst->cross_validation_stats.reject_count = src.cross_validation_stats.reject_count;
    dst->reason_mask = src.reason_mask;
}

[[maybe_unused]] aether::evidence::PatchDisplayKernelConfig to_cpp_patch_display_config(
    const aether_patch_display_kernel_config_t* config_or_null) {
    aether::evidence::PatchDisplayKernelConfig out{};
    if (config_or_null == nullptr) {
        return out;
    }
    out.patch_display_alpha = config_or_null->patch_display_alpha;
    out.patch_display_locked_acceleration = config_or_null->patch_display_locked_acceleration;
    out.color_evidence_local_weight = config_or_null->color_evidence_local_weight;
    out.color_evidence_global_weight = config_or_null->color_evidence_global_weight;
    out.ghost_recovery_acceleration = config_or_null->ghost_recovery_acceleration;
    return out;
}

[[maybe_unused]] aether::evidence::SmartSmootherConfig to_cpp_smart_smoother_config(
    const aether_smart_smoother_config_t* config_or_null) {
    aether::evidence::SmartSmootherConfig out{};
    if (config_or_null == nullptr) {
        return out;
    }
    out.window_size = static_cast<std::size_t>(std::max(1, config_or_null->window_size));
    out.jitter_band = config_or_null->jitter_band;
    out.anti_boost_factor = config_or_null->anti_boost_factor;
    out.normal_improve_factor = config_or_null->normal_improve_factor;
    out.degrade_factor = config_or_null->degrade_factor;
    out.max_consecutive_invalid = std::max(1, config_or_null->max_consecutive_invalid);
    out.worst_case_fallback = config_or_null->worst_case_fallback;
    out.capture_mode = (config_or_null->capture_mode != 0);
    return out;
}

[[maybe_unused]] aether::render::FlipEasingConfig to_cpp_flip_easing_config(
    const aether_flip_easing_config_t* config_or_null) {
    aether::render::FlipEasingConfig out{};
    if (config_or_null == nullptr) {
        return out;
    }
    out.duration_s = config_or_null->duration_s;
    out.cp1x = config_or_null->cp1x;
    out.cp1y = config_or_null->cp1y;
    out.cp2x = config_or_null->cp2x;
    out.cp2y = config_or_null->cp2y;
    out.stagger_delay_s = config_or_null->stagger_delay_s;
    out.max_concurrent = config_or_null->max_concurrent;
    return out;
}

[[maybe_unused]] aether::render::RippleConfig to_cpp_ripple_config(
    const aether_ripple_config_t* config_or_null) {
    aether::render::RippleConfig out{};
    if (config_or_null == nullptr) {
        return out;
    }
    out.damping = config_or_null->damping;
    out.max_hops = config_or_null->max_hops;
    out.delay_per_hop_s = config_or_null->delay_per_hop_s;
    return out;
}

aether::render::Quaternion to_cpp_quaternion(const aether_quaternion_t& in) {
    aether::render::Quaternion out{};
    out.x = in.x;
    out.y = in.y;
    out.z = in.z;
    out.w = in.w;
    return out;
}

aether_quaternion_t to_c_quaternion(const aether::render::Quaternion& in) {
    aether_quaternion_t out{};
    out.x = in.x;
    out.y = in.y;
    out.z = in.z;
    out.w = in.w;
    return out;
}

[[maybe_unused]] aether::render::FlipAnimationState to_cpp_flip_state(const aether_flip_animation_state_t& in) {
    aether::render::FlipAnimationState out{};
    out.start_time_s = in.start_time_s;
    out.flip_angle = in.flip_angle;
    out.flip_axis_origin = aether::innovation::make_float3(
        in.flip_axis_origin.x, in.flip_axis_origin.y, in.flip_axis_origin.z);
    out.flip_axis_direction = aether::innovation::make_float3(
        in.flip_axis_direction.x, in.flip_axis_direction.y, in.flip_axis_direction.z);
    out.ripple_amplitude = in.ripple_amplitude;
    out.rotation = to_cpp_quaternion(in.rotation);
    out.rotated_normal = aether::innovation::make_float3(
        in.rotated_normal.x, in.rotated_normal.y, in.rotated_normal.z);
    return out;
}

[[maybe_unused]] void to_c_flip_state(
    const aether::render::FlipAnimationState& in,
    aether_flip_animation_state_t* out) {
    if (out == nullptr) {
        return;
    }
    out->start_time_s = in.start_time_s;
    out->flip_angle = in.flip_angle;
    out->flip_axis_origin.x = in.flip_axis_origin.x;
    out->flip_axis_origin.y = in.flip_axis_origin.y;
    out->flip_axis_origin.z = in.flip_axis_origin.z;
    out->flip_axis_direction.x = in.flip_axis_direction.x;
    out->flip_axis_direction.y = in.flip_axis_direction.y;
    out->flip_axis_direction.z = in.flip_axis_direction.z;
    out->ripple_amplitude = in.ripple_amplitude;
    out->rotation = to_c_quaternion(in.rotation);
    out->rotated_normal.x = in.rotated_normal.x;
    out->rotated_normal.y = in.rotated_normal.y;
    out->rotated_normal.z = in.rotated_normal.z;
}

[[maybe_unused]] aether::render::WedgeLodLevel to_cpp_wedge_lod_level(int lod_level) {
    switch (lod_level) {
        case 0:
            return aether::render::WedgeLodLevel::kFull;
        case 1:
            return aether::render::WedgeLodLevel::kMedium;
        case 2:
            return aether::render::WedgeLodLevel::kLow;
        case 3:
            return aether::render::WedgeLodLevel::kFlat;
        default:
            return static_cast<aether::render::WedgeLodLevel>(-1);
    }
}

[[maybe_unused]] aether::render::WedgeTriangleInput to_cpp_wedge_triangle(
    const aether_wedge_input_triangle_t& src) {
    aether::render::WedgeTriangleInput dst{};
    dst.v0 = aether::innovation::make_float3(src.v0.x, src.v0.y, src.v0.z);
    dst.v1 = aether::innovation::make_float3(src.v1.x, src.v1.y, src.v1.z);
    dst.v2 = aether::innovation::make_float3(src.v2.x, src.v2.y, src.v2.z);
    dst.normal = aether::innovation::make_float3(src.normal.x, src.normal.y, src.normal.z);
    dst.metallic = src.metallic;
    dst.roughness = src.roughness;
    dst.display = src.display;
    dst.thickness = src.thickness;
    dst.triangle_id = src.triangle_id;
    return dst;
}

[[maybe_unused]] void to_c_wedge_vertex(
    const aether::render::WedgeVertex& src,
    aether_wedge_vertex_t* dst) {
    if (dst == nullptr) {
        return;
    }
    dst->position.x = src.position.x;
    dst->position.y = src.position.y;
    dst->position.z = src.position.z;
    dst->normal.x = src.normal.x;
    dst->normal.y = src.normal.y;
    dst->normal.z = src.normal.z;
    dst->metallic = src.metallic;
    dst->roughness = src.roughness;
    dst->display = src.display;
    dst->thickness = src.thickness;
    dst->triangle_id = src.triangle_id;
}

inline float clamp01(float value) {
    return std::max(0.0f, std::min(1.0f, value));
}

[[maybe_unused]] constexpr float kPiF = 3.14159265358979323846f;

aether_capture_style_runtime_config_t capture_style_default_config() {
    aether_capture_style_runtime_config_t config{};
    config.smoothing_alpha = 0.2f;
    config.freeze_threshold = 0.75f;
    config.min_thickness = 0.0005f;
    config.max_thickness = 0.008f;
    config.min_border_width = 2.8f;
    config.max_border_width = 26.0f;
    config.min_area_sq_m = 1e-8f;
    config.min_median_area_sq_m = 1e-6f;
    return config;
}

[[maybe_unused]] aether_capture_style_runtime_config_t sanitize_capture_style_config(
    const aether_capture_style_runtime_config_t* config_or_null) {
    aether_capture_style_runtime_config_t config = capture_style_default_config();
    if (config_or_null == nullptr) {
        return config;
    }
    const aether_capture_style_runtime_config_t& src = *config_or_null;

    if (std::isfinite(src.smoothing_alpha)) {
        config.smoothing_alpha = clamp01(src.smoothing_alpha);
    }
    if (std::isfinite(src.freeze_threshold)) {
        config.freeze_threshold = clamp01(src.freeze_threshold);
    }
    if (std::isfinite(src.min_thickness)) {
        config.min_thickness = std::max(0.0f, src.min_thickness);
    }
    if (std::isfinite(src.max_thickness)) {
        config.max_thickness = std::max(0.0f, src.max_thickness);
    }
    if (config.min_thickness > config.max_thickness) {
        std::swap(config.min_thickness, config.max_thickness);
    }

    if (std::isfinite(src.min_border_width)) {
        config.min_border_width = std::max(0.0f, src.min_border_width);
    }
    if (std::isfinite(src.max_border_width)) {
        config.max_border_width = std::max(0.0f, src.max_border_width);
    }
    if (config.min_border_width > config.max_border_width) {
        std::swap(config.min_border_width, config.max_border_width);
    }

    if (std::isfinite(src.min_area_sq_m)) {
        config.min_area_sq_m = std::max(1e-12f, src.min_area_sq_m);
    }
    if (std::isfinite(src.min_median_area_sq_m)) {
        config.min_median_area_sq_m = std::max(1e-12f, src.min_median_area_sq_m);
    }
    return config;
}

aether_flip_runtime_config_t flip_runtime_default_config() {
    aether_flip_runtime_config_t config{};
    config.easing.duration_s = 0.5f;
    config.easing.cp1x = 0.34f;
    config.easing.cp1y = 1.56f;
    config.easing.cp2x = 0.64f;
    config.easing.cp2y = 1.0f;
    config.easing.stagger_delay_s = 0.03f;
    config.easing.max_concurrent = 20;
    config.min_display_delta = 0.05f;
    config.threshold_s0_to_s1 = 0.10f;
    config.threshold_s1_to_s2 = 0.25f;
    config.threshold_s2_to_s3 = 0.50f;
    config.threshold_s3_to_s4 = 0.75f;
    config.threshold_s4_to_s5 = 0.88f;
    return config;
}

[[maybe_unused]] aether_flip_runtime_config_t sanitize_flip_runtime_config(
    const aether_flip_runtime_config_t* config_or_null) {
    aether_flip_runtime_config_t config = flip_runtime_default_config();
    if (config_or_null == nullptr) {
        return config;
    }
    const aether_flip_runtime_config_t& src = *config_or_null;
    config.easing = src.easing;
    if (!std::isfinite(config.easing.duration_s) || config.easing.duration_s <= 1e-4f) {
        config.easing.duration_s = 0.5f;
    }
    if (!std::isfinite(config.easing.cp1x)) config.easing.cp1x = 0.34f;
    if (!std::isfinite(config.easing.cp1y)) config.easing.cp1y = 1.56f;
    if (!std::isfinite(config.easing.cp2x)) config.easing.cp2x = 0.64f;
    if (!std::isfinite(config.easing.cp2y)) config.easing.cp2y = 1.0f;
    if (!std::isfinite(config.easing.stagger_delay_s) || config.easing.stagger_delay_s < 0.0f) {
        config.easing.stagger_delay_s = 0.03f;
    }
    config.easing.max_concurrent = std::max(1, config.easing.max_concurrent);

    config.min_display_delta = std::isfinite(src.min_display_delta)
        ? std::max(0.0f, src.min_display_delta)
        : 0.05f;

    config.threshold_s0_to_s1 = std::isfinite(src.threshold_s0_to_s1)
        ? clamp01(src.threshold_s0_to_s1)
        : 0.10f;
    config.threshold_s1_to_s2 = std::isfinite(src.threshold_s1_to_s2)
        ? clamp01(src.threshold_s1_to_s2)
        : 0.25f;
    config.threshold_s2_to_s3 = std::isfinite(src.threshold_s2_to_s3)
        ? clamp01(src.threshold_s2_to_s3)
        : 0.50f;
    config.threshold_s3_to_s4 = std::isfinite(src.threshold_s3_to_s4)
        ? clamp01(src.threshold_s3_to_s4)
        : 0.75f;
    config.threshold_s4_to_s5 = std::isfinite(src.threshold_s4_to_s5)
        ? clamp01(src.threshold_s4_to_s5)
        : 0.88f;

    float thresholds[5] = {
        config.threshold_s0_to_s1,
        config.threshold_s1_to_s2,
        config.threshold_s2_to_s3,
        config.threshold_s3_to_s4,
        config.threshold_s4_to_s5};
    for (int i = 1; i < 5; ++i) {
        thresholds[i] = std::max(thresholds[i], thresholds[i - 1]);
    }
    config.threshold_s0_to_s1 = thresholds[0];
    config.threshold_s1_to_s2 = thresholds[1];
    config.threshold_s2_to_s3 = thresholds[2];
    config.threshold_s3_to_s4 = thresholds[3];
    config.threshold_s4_to_s5 = thresholds[4];
    return config;
}

[[maybe_unused]] float flip_runtime_duration_s(const aether_flip_runtime_config_t& config) {
    return std::max(1e-4f, config.easing.duration_s);
}

[[maybe_unused]] bool flip_runtime_crossed_threshold(
    const aether_flip_runtime_config_t& config,
    float previous_display,
    float current_display) {
    const float thresholds[5] = {
        config.threshold_s0_to_s1,
        config.threshold_s1_to_s2,
        config.threshold_s2_to_s3,
        config.threshold_s3_to_s4,
        config.threshold_s4_to_s5};
    for (float threshold : thresholds) {
        if (previous_display < threshold && current_display >= threshold) {
            return true;
        }
    }
    return false;
}

[[maybe_unused]] aether::innovation::Float3 normalize_direction_or_default(
    const aether::innovation::Float3& candidate,
    const aether::innovation::Float3& fallback) {
    const float len_sq = candidate.x * candidate.x +
                         candidate.y * candidate.y +
                         candidate.z * candidate.z;
    if (!std::isfinite(len_sq) || len_sq <= 1e-12f) {
        return fallback;
    }
    const float inv_len = 1.0f / std::sqrt(len_sq);
    return aether::innovation::make_float3(
        candidate.x * inv_len,
        candidate.y * inv_len,
        candidate.z * inv_len);
}

[[maybe_unused]] bool build_flip_runtime_states(
    const aether_flip_runtime_t* runtime,
    double now_s,
    std::vector<std::int32_t>* out_triangle_ids,
    std::vector<aether_flip_animation_state_t>* out_states) {
    if (runtime == nullptr || out_triangle_ids == nullptr || out_states == nullptr || !std::isfinite(now_s)) {
        return false;
    }
    out_triangle_ids->clear();
    out_states->clear();
    if (runtime->active.empty()) {
        return true;
    }

    out_triangle_ids->reserve(runtime->active.size());
    for (const auto& entry : runtime->active) {
        out_triangle_ids->push_back(entry.first);
    }
    std::sort(out_triangle_ids->begin(), out_triangle_ids->end());

    std::vector<aether_flip_animation_state_t> in_states(out_triangle_ids->size());
    std::vector<aether_flip_animation_state_t> solved_states(out_triangle_ids->size());
    std::vector<aether_float3_t> rest_normals(
        out_triangle_ids->size(),
        aether_float3_t{0.0f, 0.0f, 1.0f});
    for (std::size_t i = 0u; i < out_triangle_ids->size(); ++i) {
        const auto it = runtime->active.find((*out_triangle_ids)[i]);
        if (it == runtime->active.end()) {
            continue;
        }
        const aether_flip_runtime_t::ActiveFlip& active = it->second;
        aether_flip_animation_state_t state{};
        state.start_time_s = static_cast<float>(active.start_time_s);
        state.flip_axis_origin = aether_float3_t{
            active.axis_origin.x,
            active.axis_origin.y,
            active.axis_origin.z};
        state.flip_axis_direction = aether_float3_t{
            active.axis_direction.x,
            active.axis_direction.y,
            active.axis_direction.z};
        state.rotation = aether_quaternion_t{0.0f, 0.0f, 0.0f, 1.0f};
        state.rotated_normal = aether_float3_t{0.0f, 0.0f, 1.0f};
        in_states[i] = state;
    }

    const int rc = aether_compute_flip_states(
        in_states.data(),
        static_cast<int>(in_states.size()),
        static_cast<float>(now_s),
        &runtime->config.easing,
        rest_normals.data(),
        solved_states.data());
    if (rc != 0) {
        return false;
    }
    *out_states = std::move(solved_states);
    return true;
}

aether_ripple_runtime_config_t ripple_runtime_default_config() {
    aether_ripple_runtime_config_t config{};
    config.ripple.damping = 0.85f;
    config.ripple.max_hops = 8;
    config.ripple.delay_per_hop_s = 0.06f;
    config.max_concurrent_waves = 5;
    config.min_spawn_interval_s = 0.5f;
    return config;
}

[[maybe_unused]] aether_ripple_runtime_config_t sanitize_ripple_runtime_config(
    const aether_ripple_runtime_config_t* config_or_null) {
    aether_ripple_runtime_config_t config = ripple_runtime_default_config();
    if (config_or_null == nullptr) {
        return config;
    }
    const aether_ripple_runtime_config_t& src = *config_or_null;
    config.ripple.damping = std::isfinite(src.ripple.damping)
        ? clamp01(src.ripple.damping)
        : 0.85f;
    config.ripple.max_hops = std::max(0, src.ripple.max_hops);
    config.ripple.delay_per_hop_s = (std::isfinite(src.ripple.delay_per_hop_s) &&
                                     src.ripple.delay_per_hop_s >= 0.0f)
        ? src.ripple.delay_per_hop_s
        : 0.06f;
    config.max_concurrent_waves = std::max(1, src.max_concurrent_waves);
    config.min_spawn_interval_s = (std::isfinite(src.min_spawn_interval_s) &&
                                   src.min_spawn_interval_s >= 0.0f)
        ? src.min_spawn_interval_s
        : 0.5f;
    return config;
}

[[maybe_unused]] int ripple_runtime_compute_max_hop(
    const aether_ripple_runtime_t* runtime,
    std::int32_t source_triangle) {
    if (runtime == nullptr || source_triangle < 0 || source_triangle >= runtime->triangle_count) {
        return 0;
    }
    if (runtime->offsets.size() != static_cast<std::size_t>(runtime->triangle_count + 1)) {
        return 0;
    }
    const int max_hops = std::max(0, runtime->config.ripple.max_hops);
    const int n = runtime->triangle_count;
    std::vector<int> distances(static_cast<std::size_t>(n), -1);
    std::vector<std::int32_t> queue;
    queue.reserve(static_cast<std::size_t>(n));
    distances[static_cast<std::size_t>(source_triangle)] = 0;
    queue.push_back(source_triangle);
    std::size_t head = 0u;
    int max_hop = 0;
    while (head < queue.size()) {
        const std::int32_t tri = queue[head++];
        const int hop = distances[static_cast<std::size_t>(tri)];
        max_hop = std::max(max_hop, hop);
        if (hop >= max_hops) {
            continue;
        }
        const std::uint32_t begin = runtime->offsets[static_cast<std::size_t>(tri)];
        const std::uint32_t end = runtime->offsets[static_cast<std::size_t>(tri) + 1u];
        for (std::uint32_t index = begin; index < end; ++index) {
            if (index >= runtime->neighbors.size()) {
                break;
            }
            const std::uint32_t neighbor = runtime->neighbors[index];
            if (neighbor >= static_cast<std::uint32_t>(n)) {
                continue;
            }
            if (distances[neighbor] >= 0) {
                continue;
            }
            distances[neighbor] = hop + 1;
            queue.push_back(static_cast<std::int32_t>(neighbor));
        }
    }
    return max_hop;
}

bool ripple_runtime_compute_amplitudes(
    const aether_ripple_runtime_t* runtime,
    double current_time_s,
    std::vector<float>* out_amplitudes) {
    if (runtime == nullptr || out_amplitudes == nullptr || !std::isfinite(current_time_s) ||
        runtime->triangle_count < 0) {
        return false;
    }
    out_amplitudes->assign(
        static_cast<std::size_t>(runtime->triangle_count),
        0.0f);
    if (runtime->triangle_count == 0 || runtime->active_waves.empty()) {
        return true;
    }
    if (runtime->offsets.size() != static_cast<std::size_t>(runtime->triangle_count + 1)) {
        return false;
    }

    std::vector<std::uint32_t> trigger_ids;
    std::vector<float> trigger_starts;
    trigger_ids.reserve(runtime->active_waves.size());
    trigger_starts.reserve(runtime->active_waves.size());
    for (const aether_ripple_runtime_t::Wave& wave : runtime->active_waves) {
        if (wave.source_triangle < 0 || wave.source_triangle >= runtime->triangle_count) {
            continue;
        }
        trigger_ids.push_back(static_cast<std::uint32_t>(wave.source_triangle));
        trigger_starts.push_back(static_cast<float>(wave.spawn_time_s));
    }
    if (trigger_ids.empty()) {
        return true;
    }

    const int rc = aether_compute_ripple_amplitudes(
        runtime->offsets.data(),
        runtime->neighbors.empty() ? nullptr : runtime->neighbors.data(),
        runtime->triangle_count,
        trigger_ids.data(),
        static_cast<int>(trigger_ids.size()),
        trigger_starts.data(),
        static_cast<float>(current_time_s),
        &runtime->config.ripple,
        out_amplitudes->data());
    return rc == 0;
}

aether::evidence::DSMassFunction to_cpp_ds_mass(const aether_ds_mass_t& src) {
    return aether::evidence::DSMassFunction(src.occupied, src.free_mass, src.unknown);
}

aether_ds_mass_t to_c_ds_mass(const aether::evidence::DSMassFunction& src) {
    aether_ds_mass_t out{};
    out.occupied = src.occupied;
    out.free_mass = src.free_;
    out.unknown = src.unknown;
    return out;
}

aether::evidence::CoverageEstimatorConfig to_cpp_coverage_config(
    const aether_coverage_estimator_config_t* config) {
    aether::evidence::CoverageEstimatorConfig cpp{};
    if (config == nullptr) {
        return cpp;
    }
    if (config->use_custom_level_weights != 0) {
        for (std::size_t i = 0u; i < cpp.level_weights.size(); ++i) {
            const double w = config->level_weights[i];
            if (finite_non_negative(w)) {
                cpp.level_weights[i] = w;
            }
        }
    }
    if (config->ema_alpha >= 0.0 && config->ema_alpha <= 1.0 &&
        config->ema_alpha == config->ema_alpha) {
        cpp.ema_alpha = config->ema_alpha;
    }
    if (finite_non_negative(config->max_coverage_delta_per_sec)) {
        cpp.max_coverage_delta_per_sec = config->max_coverage_delta_per_sec;
    }
    if (config->view_diversity_boost >= 0.0 && config->view_diversity_boost <= 1.0 &&
        config->view_diversity_boost == config->view_diversity_boost) {
        cpp.view_diversity_boost = config->view_diversity_boost;
    }
    cpp.monotonic_mode = (config->monotonic_mode != 0);
    cpp.use_fisher_weights = (config->use_fisher_weights != 0);
    if (finite_non_negative(config->fisher_normalization) && config->fisher_normalization > 0.0) {
        cpp.fisher_normalization = config->fisher_normalization;
    }
    if (config->fisher_floor >= 0.0 && config->fisher_floor <= 1.0 &&
        config->fisher_floor == config->fisher_floor) {
        cpp.fisher_floor = config->fisher_floor;
    }
    return cpp;
}

void to_c_coverage_config(
    const aether::evidence::CoverageEstimatorConfig& src,
    aether_coverage_estimator_config_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    for (std::size_t i = 0u; i < src.level_weights.size(); ++i) {
        dst->level_weights[i] = src.level_weights[i];
    }
    dst->ema_alpha = src.ema_alpha;
    dst->max_coverage_delta_per_sec = src.max_coverage_delta_per_sec;
    dst->view_diversity_boost = src.view_diversity_boost;
    dst->use_custom_level_weights = 1;
    dst->monotonic_mode = src.monotonic_mode ? 1 : 0;
    dst->use_fisher_weights = src.use_fisher_weights ? 1 : 0;
    dst->fisher_normalization = src.fisher_normalization;
    dst->fisher_floor = src.fisher_floor;
}

aether::evidence::CoverageCellObservation to_cpp_coverage_cell(
    const aether_coverage_cell_observation_t& src) {
    aether::evidence::CoverageCellObservation dst{};
    dst.level = src.level;
    dst.mass = aether::evidence::DSMassFunction(
        src.occupied,
        src.free_mass,
        src.unknown).sealed();
    dst.area_weight = src.area_weight;
    dst.excluded = src.excluded != 0;
    dst.view_count = src.view_count;
    return dst;
}

void to_c_coverage_result(
    const aether::evidence::CoverageResult& src,
    aether_coverage_result_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->raw_coverage = src.raw_coverage;
    dst->smoothed_coverage = src.smoothed_coverage;
    dst->coverage = src.coverage;
    for (std::size_t i = 0u; i < src.breakdown_counts.size(); ++i) {
        dst->breakdown_counts[i] = src.breakdown_counts[i];
        dst->weighted_sum_components[i] = src.weighted_sum_components[i];
    }
    dst->active_cell_count = static_cast<std::uint64_t>(src.active_cell_count);
    dst->excluded_area_weight = src.excluded_area_weight;
    dst->non_monotonic_time_count = src.non_monotonic_time_count;
    dst->lyapunov_convergence = src.lyapunov_convergence;
    dst->high_observation_ratio = src.high_observation_ratio;
    dst->belief_coverage = src.belief_coverage;
    dst->plausibility_coverage = src.plausibility_coverage;
    dst->uncertainty_width = src.uncertainty_width;
    dst->mean_fisher_info = src.mean_fisher_info;
    dst->lyapunov_rate = src.lyapunov_rate;
    dst->pac_failure_bound = src.pac_failure_bound;
    dst->pac_max_cell_risk = src.pac_max_cell_risk;
    dst->pac_certified_cell_count = static_cast<uint64_t>(src.pac_certified_cell_count);
}

const std::string& safe_patch_id(const char* patch_id, std::string* scratch) {
    if (patch_id != nullptr) {
        scratch->assign(patch_id);
    } else {
        scratch->clear();
    }
    return *scratch;
}

void to_c_admission_decision(
    const aether::evidence::EvidenceAdmissionDecision& src,
    aether_admission_decision_t* dst) {
    if (dst == nullptr) {
        return;
    }
    dst->allowed = src.allowed ? 1 : 0;
    dst->quality_scale = src.quality_scale;
    dst->reason_mask = src.reason_mask;
    dst->hard_blocked = src.is_hard_blocked() ? 1 : 0;
}

aether::evidence::PR1BuildMode to_cpp_pr1_build_mode(int mode) {
    if (mode == AETHER_PR1_BUILD_MODE_DAMPING) {
        return aether::evidence::PR1BuildMode::kDamping;
    }
    if (mode == AETHER_PR1_BUILD_MODE_SATURATED) {
        return aether::evidence::PR1BuildMode::kSaturated;
    }
    return aether::evidence::PR1BuildMode::kNormal;
}

aether::evidence::PR1HardFuseTrigger to_cpp_pr1_hard_trigger(int trigger) {
    if (trigger == AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD) {
        return aether::evidence::PR1HardFuseTrigger::kPatchCountHard;
    }
    if (trigger == AETHER_PR1_HARD_FUSE_EEB_HARD) {
        return aether::evidence::PR1HardFuseTrigger::kEEBHard;
    }
    return aether::evidence::PR1HardFuseTrigger::kNone;
}

int to_c_pr1_build_mode(aether::evidence::PR1BuildMode mode) {
    if (mode == aether::evidence::PR1BuildMode::kDamping) {
        return AETHER_PR1_BUILD_MODE_DAMPING;
    }
    if (mode == aether::evidence::PR1BuildMode::kSaturated) {
        return AETHER_PR1_BUILD_MODE_SATURATED;
    }
    return AETHER_PR1_BUILD_MODE_NORMAL;
}

int to_c_pr1_classification(aether::evidence::PR1Classification classification) {
    if (classification == aether::evidence::PR1Classification::kRejected) {
        return AETHER_PR1_CLASSIFICATION_REJECTED;
    }
    if (classification == aether::evidence::PR1Classification::kDuplicateRejected) {
        return AETHER_PR1_CLASSIFICATION_DUPLICATE_REJECTED;
    }
    return AETHER_PR1_CLASSIFICATION_ACCEPTED;
}

int to_c_pr1_reason(aether::evidence::PR1RejectReason reason) {
    switch (reason) {
        case aether::evidence::PR1RejectReason::kLowGainSoft:
            return AETHER_PR1_REJECT_REASON_LOW_GAIN_SOFT;
        case aether::evidence::PR1RejectReason::kRedundantCoverage:
            return AETHER_PR1_REJECT_REASON_REDUNDANT_COVERAGE;
        case aether::evidence::PR1RejectReason::kDuplicate:
            return AETHER_PR1_REJECT_REASON_DUPLICATE;
        case aether::evidence::PR1RejectReason::kHardCap:
            return AETHER_PR1_REJECT_REASON_HARD_CAP;
        case aether::evidence::PR1RejectReason::kNone:
        default:
            return AETHER_PR1_REJECT_REASON_NONE;
    }
}

int to_c_pr1_guidance(aether::evidence::PR1GuidanceSignal signal) {
    if (signal == aether::evidence::PR1GuidanceSignal::kHeatCoolCoverage) {
        return AETHER_PR1_GUIDANCE_HEAT_COOL_COVERAGE;
    }
    if (signal == aether::evidence::PR1GuidanceSignal::kDirectionalAffordance) {
        return AETHER_PR1_GUIDANCE_DIRECTIONAL_AFFORDANCE;
    }
    if (signal == aether::evidence::PR1GuidanceSignal::kStaticOverlay) {
        return AETHER_PR1_GUIDANCE_STATIC_OVERLAY;
    }
    return AETHER_PR1_GUIDANCE_NONE;
}

int to_c_pr1_hard_trigger(aether::evidence::PR1HardFuseTrigger trigger) {
    if (trigger == aether::evidence::PR1HardFuseTrigger::kPatchCountHard) {
        return AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD;
    }
    if (trigger == aether::evidence::PR1HardFuseTrigger::kEEBHard) {
        return AETHER_PR1_HARD_FUSE_EEB_HARD;
    }
    return AETHER_PR1_HARD_FUSE_NONE;
}

double sanitize_non_negative(double value, double fallback) {
    if (!std::isfinite(value) || value < 0.0) {
        return fallback;
    }
    return value;
}

int sanitize_non_negative_int(int value, int fallback) {
    if (value < 0) {
        return fallback;
    }
    return value;
}

aether::evidence::PR1PatchDescriptor to_cpp_pr1_patch(
    const aether_pr1_patch_descriptor_t& src) {
    aether::evidence::PR1PatchDescriptor patch{};
    patch.pose_x = src.pose_x;
    patch.pose_y = src.pose_y;
    patch.pose_z = src.pose_z;
    patch.coverage_x = src.coverage_x;
    patch.coverage_y = src.coverage_y;
    patch.radiance_x = src.radiance_x;
    patch.radiance_y = src.radiance_y;
    patch.radiance_z = src.radiance_z;
    return patch;
}

aether::evidence::PR1InfoGainStrategy to_cpp_pr1_info_gain_strategy(int strategy) {
    switch (strategy) {
        case AETHER_PR1_INFO_GAIN_STRATEGY_ENTROPY_FRONTIER:
            return aether::evidence::PR1InfoGainStrategy::kEntropyFrontier;
        case AETHER_PR1_INFO_GAIN_STRATEGY_HYBRID_CROSSCHECK:
            return aether::evidence::PR1InfoGainStrategy::kHybridCrossCheck;
        case AETHER_PR1_INFO_GAIN_STRATEGY_LEGACY:
        default:
            return aether::evidence::PR1InfoGainStrategy::kLegacy;
    }
}

aether::evidence::PR1NoveltyStrategy to_cpp_pr1_novelty_strategy(int strategy) {
    switch (strategy) {
        case AETHER_PR1_NOVELTY_STRATEGY_KERNEL_ROBUST:
            return aether::evidence::PR1NoveltyStrategy::kKernelRobust;
        case AETHER_PR1_NOVELTY_STRATEGY_HYBRID_CROSSCHECK:
            return aether::evidence::PR1NoveltyStrategy::kHybridCrossCheck;
        case AETHER_PR1_NOVELTY_STRATEGY_LEGACY:
        default:
            return aether::evidence::PR1NoveltyStrategy::kLegacy;
    }
}

void to_c_pr1_info_gain_config(
    const aether::evidence::PR1InformationGainConfig& src,
    aether_pr1_info_gain_config_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->info_gain_strategy = static_cast<int>(src.info_gain_strategy);
    dst->novelty_strategy = static_cast<int>(src.novelty_strategy);
    dst->state_gain_uncovered = src.state_gain_uncovered;
    dst->state_gain_gray = src.state_gain_gray;
    dst->state_gain_white = src.state_gain_white;
    dst->state_weight = src.state_weight;
    dst->frontier_weight = src.frontier_weight;
    dst->entropy_weight = src.entropy_weight;
    dst->rarity_weight = src.rarity_weight;
    dst->pose_eps = src.pose_eps;
    dst->robust_quantile = src.robust_quantile;
    dst->robustness_scale = src.robustness_scale;
    dst->hybrid_agreement_tolerance = src.hybrid_agreement_tolerance;
    dst->hybrid_high_weight = src.hybrid_high_weight;
}

aether::evidence::PR1InformationGainConfig to_cpp_pr1_info_gain_config(
    const aether_pr1_info_gain_config_t* src,
    int grid_size) {
    aether::evidence::PR1InformationGainConfig cfg{};
    if (grid_size > 0) {
        cfg.coverage_grid_size = grid_size;
    }
    if (src == nullptr) {
        return cfg;
    }
    cfg.info_gain_strategy = to_cpp_pr1_info_gain_strategy(src->info_gain_strategy);
    cfg.novelty_strategy = to_cpp_pr1_novelty_strategy(src->novelty_strategy);
    cfg.state_gain_uncovered = src->state_gain_uncovered;
    cfg.state_gain_gray = src->state_gain_gray;
    cfg.state_gain_white = src->state_gain_white;
    cfg.state_weight = src->state_weight;
    cfg.frontier_weight = src->frontier_weight;
    cfg.entropy_weight = src->entropy_weight;
    cfg.rarity_weight = src->rarity_weight;
    cfg.pose_eps = src->pose_eps;
    cfg.robust_quantile = src->robust_quantile;
    cfg.robustness_scale = src->robustness_scale;
    cfg.hybrid_agreement_tolerance = src->hybrid_agreement_tolerance;
    cfg.hybrid_high_weight = src->hybrid_high_weight;
    return cfg;
}

void hash_to_bytes(const aether::merkle::Hash32& src, uint8_t* dst32) {
    if (dst32 == nullptr) {
        return;
    }
    std::memcpy(dst32, src.data(), src.size());
}

bool bytes_to_hash32(const uint8_t* src32, aether::merkle::Hash32* out_hash) {
    if (src32 == nullptr || out_hash == nullptr) {
        return false;
    }
    std::memcpy(out_hash->data(), src32, out_hash->size());
    return true;
}

void fill_c_inclusion_proof(
    const aether::merkle::InclusionProof& src,
    aether_merkle_inclusion_proof_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->tree_size = src.tree_size;
    dst->leaf_index = src.leaf_index;
    dst->path_length = src.path_length;
    hash_to_bytes(src.leaf_hash, dst->leaf_hash);
    for (std::uint32_t i = 0; i < src.path_length &&
                              i < static_cast<std::uint32_t>(AETHER_MERKLE_MAX_INCLUSION_HASHES); ++i) {
        hash_to_bytes(src.path[i], dst->path_hashes + (static_cast<std::size_t>(i) * 32u));
    }
}

void fill_c_consistency_proof(
    const aether::merkle::ConsistencyProof& src,
    aether_merkle_consistency_proof_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->first_tree_size = src.first_tree_size;
    dst->second_tree_size = src.second_tree_size;
    dst->path_length = src.proof_length;
    for (std::uint32_t i = 0; i < src.proof_length &&
                              i < static_cast<std::uint32_t>(AETHER_MERKLE_MAX_CONSISTENCY_HASHES); ++i) {
        hash_to_bytes(src.proof[i], dst->path_hashes + (static_cast<std::size_t>(i) * 32u));
    }
}

bool load_cpp_inclusion_proof(
    const aether_merkle_inclusion_proof_t& src,
    aether::merkle::InclusionProof* dst) {
    if (dst == nullptr) {
        return false;
    }
    if (src.path_length > AETHER_MERKLE_MAX_INCLUSION_HASHES) {
        return false;
    }
    dst->tree_size = src.tree_size;
    dst->leaf_index = src.leaf_index;
    dst->path_length = src.path_length;
    if (!bytes_to_hash32(src.leaf_hash, &dst->leaf_hash)) {
        return false;
    }
    for (std::uint32_t i = 0; i < src.path_length; ++i) {
        if (!bytes_to_hash32(
                src.path_hashes + (static_cast<std::size_t>(i) * 32u),
                &dst->path[i])) {
            return false;
        }
    }
    return true;
}

bool load_cpp_consistency_proof(
    const aether_merkle_consistency_proof_t& src,
    aether::merkle::ConsistencyProof* dst) {
    if (dst == nullptr) {
        return false;
    }
    if (src.path_length > AETHER_MERKLE_MAX_CONSISTENCY_HASHES) {
        return false;
    }
    dst->first_tree_size = src.first_tree_size;
    dst->second_tree_size = src.second_tree_size;
    dst->proof_length = src.path_length;
    for (std::uint32_t i = 0; i < src.path_length; ++i) {
        if (!bytes_to_hash32(
                src.path_hashes + (static_cast<std::size_t>(i) * 32u),
                &dst->proof[i])) {
            return false;
        }
    }
    return true;
}

Status build_evidence_state_canonical(
    const aether_evidence_state_input_t* input,
    aether::evidence::CanonicalJsonValue* out_root) {
    if (input == nullptr || out_root == nullptr) {
        return Status::kInvalidArgument;
    }
    if (input->patch_count < 0) {
        return Status::kInvalidArgument;
    }
    if (input->patch_count > 0 && input->patches == nullptr) {
        return Status::kInvalidArgument;
    }
    if (input->schema_version == nullptr) {
        return Status::kInvalidArgument;
    }

    std::vector<std::pair<std::string, aether::evidence::CanonicalJsonValue>> patch_pairs;
    patch_pairs.reserve(static_cast<std::size_t>(input->patch_count));
    for (int i = 0; i < input->patch_count; ++i) {
        const aether_evidence_patch_snapshot_t& patch = input->patches[i];
        if (patch.patch_id == nullptr) {
            return Status::kInvalidArgument;
        }

        aether::evidence::CanonicalJsonValue best_frame =
            (patch.best_frame_id != nullptr)
                ? aether::evidence::CanonicalJsonValue::make_string(std::string(patch.best_frame_id))
                : aether::evidence::CanonicalJsonValue::make_null();
        aether::evidence::CanonicalJsonValue last_good =
            (patch.has_last_good_update_ms != 0)
                ? aether::evidence::CanonicalJsonValue::make_int(patch.last_good_update_ms)
                : aether::evidence::CanonicalJsonValue::make_null();

        patch_pairs.push_back({
            std::string(patch.patch_id),
            aether::evidence::CanonicalJsonValue::make_object({
                {"evidence", aether::evidence::CanonicalJsonValue::make_number_quantized(patch.evidence, 4)},
                {"lastUpdateMs", aether::evidence::CanonicalJsonValue::make_int(patch.last_update_ms)},
                {"observationCount", aether::evidence::CanonicalJsonValue::make_int(patch.observation_count)},
                {"bestFrameId", std::move(best_frame)},
                {"errorCount", aether::evidence::CanonicalJsonValue::make_int(patch.error_count)},
                {"errorStreak", aether::evidence::CanonicalJsonValue::make_int(patch.error_streak)},
                {"lastGoodUpdateMs", std::move(last_good)},
            })});
    }

    *out_root = aether::evidence::CanonicalJsonValue::make_object({
        {"patches", aether::evidence::CanonicalJsonValue::make_object(std::move(patch_pairs), true)},
        {"gateDisplay", aether::evidence::CanonicalJsonValue::make_number_quantized(input->gate_display, 4)},
        {"softDisplay", aether::evidence::CanonicalJsonValue::make_number_quantized(input->soft_display, 4)},
        {"lastTotalDisplay", aether::evidence::CanonicalJsonValue::make_number_quantized(input->last_total_display, 4)},
        {"schemaVersion", aether::evidence::CanonicalJsonValue::make_string(std::string(input->schema_version))},
        {"exportedAtMs", aether::evidence::CanonicalJsonValue::make_int(input->exported_at_ms)},
    });
    return Status::kOk;
}

void fill_result(const aether::tsdf::IntegrationResult& src, aether_integration_result_t* dst) {
    dst->voxels_integrated = src.voxels_integrated;
    dst->blocks_updated = src.blocks_updated;
    dst->success = src.success ? 1 : 0;
    dst->skipped = src.skipped ? 1 : 0;
    dst->skip_reason = static_cast<int>(src.skip_reason);
}

aether::tsdf::IntegrationInput map_input(const aether_integration_input_t* input, bool legacy_compat_mode) {
    aether::tsdf::IntegrationInput mapped{};
    mapped.depth_data = input->depth_data;
    mapped.depth_width = input->depth_width;
    mapped.depth_height = input->depth_height;
    mapped.confidence_data = input->confidence_data;
    mapped.voxel_size = input->voxel_size;
    mapped.fx = input->fx;
    mapped.fy = input->fy;
    mapped.cx = input->cx;
    mapped.cy = input->cy;
    mapped.view_matrix = input->view_matrix;
    mapped.timestamp = input->timestamp;
    if (legacy_compat_mode && input->tracking_state == 0) {
        mapped.tracking_state = 2;
    } else {
        mapped.tracking_state = input->tracking_state;
    }
    return mapped;
}

inline float clamp_unit(float value) {
    return std::max(-1.0f, std::min(1.0f, value));
}

inline void world_to_camera(
    const float* camera_to_world,
    float wx,
    float wy,
    float wz,
    float* x_cam,
    float* y_cam,
    float* z_cam) {
    const float dx = wx - camera_to_world[12];
    const float dy = wy - camera_to_world[13];
    const float dz = wz - camera_to_world[14];
    *x_cam = camera_to_world[0] * dx + camera_to_world[1] * dy + camera_to_world[2] * dz;
    *y_cam = camera_to_world[4] * dx + camera_to_world[5] * dy + camera_to_world[6] * dz;
    *z_cam = camera_to_world[8] * dx + camera_to_world[9] * dy + camera_to_world[10] * dz;
}

void to_c_tsdf_runtime_state(
    const aether::tsdf::TSDFRuntimeState& src,
    aether_tsdf_runtime_state_t* dst) {
    if (dst == nullptr) {
        return;
    }
    std::memset(dst, 0, sizeof(*dst));
    dst->frame_count = src.frame_count;
    dst->has_last_pose = src.has_last_pose ? 1 : 0;
    std::memcpy(dst->last_pose, src.last_pose, sizeof(src.last_pose));
    dst->last_timestamp = src.last_timestamp;
    dst->system_thermal_ceiling = src.system_thermal_ceiling;
    dst->current_integration_skip = src.current_integration_skip;
    dst->consecutive_good_frames = src.consecutive_good_frames;
    dst->consecutive_rejections = src.consecutive_rejections;
    dst->last_thermal_change_time_s = src.last_thermal_change_time_s;
    dst->hash_table_size = src.hash_table_size;
    dst->hash_table_capacity = src.hash_table_capacity;
    dst->current_max_blocks_per_extraction = src.current_max_blocks_per_extraction;
    dst->consecutive_good_meshing_cycles = src.consecutive_good_meshing_cycles;
    dst->forgiveness_window_remaining = src.forgiveness_window_remaining;
    dst->consecutive_teleport_count = src.consecutive_teleport_count;
    dst->last_angular_velocity = src.last_angular_velocity;
    dst->recent_pose_count = src.recent_pose_count;
    dst->last_idle_check_time_s = src.last_idle_check_time_s;
    dst->memory_water_level = src.memory_water_level;
    dst->memory_pressure_ratio = src.memory_pressure_ratio;
    dst->last_memory_pressure_change_time_s = src.last_memory_pressure_change_time_s;
    dst->free_block_slot_count = src.free_block_slot_count;
    dst->last_evicted_blocks = src.last_evicted_blocks;
}

aether::tsdf::TSDFRuntimeState to_cpp_tsdf_runtime_state(
    const aether_tsdf_runtime_state_t& src) {
    aether::tsdf::TSDFRuntimeState out{};
    out.frame_count = src.frame_count;
    out.has_last_pose = src.has_last_pose != 0;
    std::memcpy(out.last_pose, src.last_pose, sizeof(out.last_pose));
    out.last_timestamp = src.last_timestamp;
    out.system_thermal_ceiling = src.system_thermal_ceiling;
    out.current_integration_skip = src.current_integration_skip;
    out.consecutive_good_frames = src.consecutive_good_frames;
    out.consecutive_rejections = src.consecutive_rejections;
    out.last_thermal_change_time_s = src.last_thermal_change_time_s;
    out.hash_table_size = src.hash_table_size;
    out.hash_table_capacity = src.hash_table_capacity;
    out.current_max_blocks_per_extraction = src.current_max_blocks_per_extraction;
    out.consecutive_good_meshing_cycles = src.consecutive_good_meshing_cycles;
    out.forgiveness_window_remaining = src.forgiveness_window_remaining;
    out.consecutive_teleport_count = src.consecutive_teleport_count;
    out.last_angular_velocity = src.last_angular_velocity;
    out.recent_pose_count = src.recent_pose_count;
    out.last_idle_check_time_s = src.last_idle_check_time_s;
    out.memory_water_level = src.memory_water_level;
    out.memory_pressure_ratio = src.memory_pressure_ratio;
    out.last_memory_pressure_change_time_s = src.last_memory_pressure_change_time_s;
    out.free_block_slot_count = src.free_block_slot_count;
    out.last_evicted_blocks = src.last_evicted_blocks;
    return out;
}

aether::math::Vec3 to_cpp_vec3(const aether_float3_t& in) {
    return aether::math::Vec3(in.x, in.y, in.z);
}

aether::tsdf::TriTetTriangle to_cpp_tri_tet_triangle(const aether_tri_tet_triangle_t& in) {
    aether::tsdf::TriTetTriangle out{};
    out.a = to_cpp_vec3(in.a);
    out.b = to_cpp_vec3(in.b);
    out.c = to_cpp_vec3(in.c);
    return out;
}

aether::tsdf::TriTetVertex to_cpp_tri_tet_vertex(const aether_tri_tet_vertex_t& in) {
    aether::tsdf::TriTetVertex out{};
    out.index = in.index;
    out.position = to_cpp_vec3(in.position);
    out.view_count = in.view_count;
    return out;
}

aether::tsdf::TriTetTetrahedron to_cpp_tri_tet_tet(const aether_tri_tet_tetrahedron_t& in) {
    aether::tsdf::TriTetTetrahedron out{};
    out.id = in.id;
    out.v0 = in.v0;
    out.v1 = in.v1;
    out.v2 = in.v2;
    out.v3 = in.v3;
    return out;
}

int to_c_tri_tet_class(aether::tsdf::TriTetConsistencyClass cls) {
    switch (cls) {
        case aether::tsdf::TriTetConsistencyClass::kMeasured:
            return AETHER_TRI_TET_CLASS_MEASURED;
        case aether::tsdf::TriTetConsistencyClass::kEstimated:
            return AETHER_TRI_TET_CLASS_ESTIMATED;
        case aether::tsdf::TriTetConsistencyClass::kUnknown:
        default:
            return AETHER_TRI_TET_CLASS_UNKNOWN;
    }
}

aether::tsdf::QuantizedPosition to_cpp_quantized_position(const aether_quantized_position_t& in) {
    aether::tsdf::QuantizedPosition out{};
    out.x = in.x;
    out.y = in.y;
    out.z = in.z;
    return out;
}

void to_c_quantized_position(
    const aether::tsdf::QuantizedPosition& in,
    aether_quantized_position_t* out) {
    if (out == nullptr) {
        return;
    }
    out->x = in.x;
    out->y = in.y;
    out->z = in.z;
}

aether::quality::Triangle3f to_cpp_quality_triangle(const aether_scan_triangle_t& in) {
    aether::quality::Triangle3f out{};
    out.ax = in.a.x;
    out.ay = in.a.y;
    out.az = in.a.z;
    out.bx = in.b.x;
    out.by = in.b.y;
    out.bz = in.b.z;
    out.cx = in.c.x;
    out.cy = in.c.y;
    out.cz = in.c.z;
    return out;
}

float squared_distance(const aether_float3_t& lhs, const aether_float3_t& rhs) {
    const float dx = lhs.x - rhs.x;
    const float dy = lhs.y - rhs.y;
    const float dz = lhs.z - rhs.z;
    return dx * dx + dy * dy + dz * dz;
}

[[maybe_unused]] void longest_edge_of_scan_triangle(
    const aether_scan_triangle_t& tri,
    aether_float3_t* out_start,
    aether_float3_t* out_end,
    float* out_length_sq) {
    const float edge01 = squared_distance(tri.a, tri.b);
    const float edge12 = squared_distance(tri.b, tri.c);
    const float edge20 = squared_distance(tri.c, tri.a);

    aether_float3_t start = tri.a;
    aether_float3_t end = tri.b;
    float length_sq = edge01;
    if (edge12 > length_sq) {
        start = tri.b;
        end = tri.c;
        length_sq = edge12;
    }
    if (edge20 > length_sq) {
        start = tri.c;
        end = tri.a;
        length_sq = edge20;
    }

    if (out_start != nullptr) {
        *out_start = start;
    }
    if (out_end != nullptr) {
        *out_end = end;
    }
    if (out_length_sq != nullptr) {
        *out_length_sq = length_sq;
    }
}

[[maybe_unused]] std::vector<aether_float3_t> compute_bevel_normals_c(
    const aether_float3_t& top_face_normal,
    const aether_float3_t& side_face_normal,
    int segments) {
    const int safe_segments = std::max(1, segments);
    std::vector<aether_float3_t> out;
    out.reserve(static_cast<std::size_t>(safe_segments + 1));
    for (int i = 0; i <= safe_segments; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(safe_segments);
        const aether_float3_t mixed{
            top_face_normal.x * (1.0f - t) + side_face_normal.x * t,
            top_face_normal.y * (1.0f - t) + side_face_normal.y * t,
            top_face_normal.z * (1.0f - t) + side_face_normal.z * t,
        };
        const float len_sq = mixed.x * mixed.x + mixed.y * mixed.y + mixed.z * mixed.z;
        if (!std::isfinite(len_sq) || len_sq <= 1e-12f) {
            out.push_back(top_face_normal);
            continue;
        }
        const float inv_len = 1.0f / std::sqrt(len_sq);
        out.push_back(aether_float3_t{
            mixed.x * inv_len,
            mixed.y * inv_len,
            mixed.z * inv_len,
        });
    }
    return out;
}

aether::quality::Point2d to_cpp_point2d(const aether_point2d_t& in) {
    aether::quality::Point2d out{};
    out.x = in.x;
    out.y = in.y;
    return out;
}

aether_point2d_t to_c_point2d(const aether::quality::Point2d& in) {
    aether_point2d_t out{};
    out.x = in.x;
    out.y = in.y;
    return out;
}

aether::quality::LabColor to_cpp_lab(const double l, const double a, const double b) {
    aether::quality::LabColor out{};
    out.l = l;
    out.a = a;
    out.b = b;
    return out;
}

aether::tsdf::TrackingState to_cpp_tracking_state(int state) {
    if (state == 0) {
        return aether::tsdf::TrackingState::kUnavailable;
    }
    if (state == 1) {
        return aether::tsdf::TrackingState::kLimited;
    }
    return aether::tsdf::TrackingState::kNormal;
}

aether::tsdf::MemoryPressure to_cpp_memory_pressure(int state) {
    switch (state) {
        case 1: return aether::tsdf::MemoryPressure::kYellow;
        case 2: return aether::tsdf::MemoryPressure::kOrange;
        case 3: return aether::tsdf::MemoryPressure::kRed;
        case 4: return aether::tsdf::MemoryPressure::kCritical;
        default: return aether::tsdf::MemoryPressure::kGreen;
    }
}

aether::tsdf::AetherThermalState to_cpp_thermal_state(const aether_thermal_state_t& in) {
    aether::tsdf::AetherThermalState out{};
    out.level = static_cast<aether::tsdf::AetherThermalLevel>(std::clamp(in.level, 0, 9));
    out.headroom = in.headroom;
    out.time_to_next_s = in.time_to_next_s;
    out.slope = in.slope;
    out.slope_2nd = in.slope_2nd;
    out.confidence = in.confidence;
    return out;
}

void to_c_thermal_state(
    const aether::tsdf::AetherThermalState& in,
    aether_thermal_state_t* out) {
    if (out == nullptr) {
        return;
    }
    out->level = static_cast<int>(in.level);
    out->headroom = in.headroom;
    out->time_to_next_s = in.time_to_next_s;
    out->slope = in.slope;
    out->slope_2nd = in.slope_2nd;
    out->confidence = in.confidence;
}

aether::tsdf::ThermalObservation to_cpp_thermal_observation(const aether_thermal_observation_t& in) {
    aether::tsdf::ThermalObservation out{};
    out.os_level = in.os_level;
    out.os_headroom = in.os_headroom;
    out.battery_temp_c = in.battery_temp_c;
    out.soc_temp_c = in.soc_temp_c;
    out.skin_temp_c = in.skin_temp_c;
    out.gpu_busy_ratio = in.gpu_busy_ratio;
    out.cpu_probe_ms = in.cpu_probe_ms;
    out.timestamp_s = in.timestamp_s;
    return out;
}

aether::tsdf::PlatformSignals to_cpp_volume_signals(
    const aether_volume_controller_signals_t& in) {
    aether::tsdf::PlatformSignals out{};
    out.thermal_level = in.thermal_level;
    out.thermal_headroom = in.thermal_headroom;
    out.thermal = to_cpp_thermal_state(in.thermal);
    if (out.thermal.headroom <= 0.0f) {
        out.thermal.headroom = in.thermal_headroom;
    }
    if (out.thermal.confidence <= 0.0f) {
        out.thermal.confidence = 1.0f;
    }
    if (out.thermal.level == aether::tsdf::AetherThermalLevel::kFrost && in.thermal_level > 0) {
        out.thermal.level = static_cast<aether::tsdf::AetherThermalLevel>(std::clamp(in.thermal_level, 0, 9));
    }
    out.memory_water_level = in.memory_water_level;
    out.memory = to_cpp_memory_pressure(in.memory_pressure);
    out.tracking = to_cpp_tracking_state(in.tracking_state);
    for (int i = 0; i < 16; ++i) {
        out.camera_pose[i] = in.camera_pose[i];
    }
    out.angular_velocity = in.angular_velocity;
    out.frame_actual_duration_ms = in.frame_actual_duration_ms;
    out.valid_pixel_count = in.valid_pixel_count;
    out.total_pixel_count = in.total_pixel_count;
    out.timestamp_s = in.timestamp_s;
    return out;
}

aether::tsdf::VolumeControllerState to_cpp_volume_state(
    const aether_volume_controller_state_t& in) {
    aether::tsdf::VolumeControllerState out{};
    out.frame_counter = in.frame_counter;
    out.integration_skip_rate = in.integration_skip_rate;
    out.consecutive_good_frames = in.consecutive_good_frames;
    out.consecutive_bad_frames = in.consecutive_bad_frames;
    out.consecutive_good_time_s = in.consecutive_good_time_s;
    out.consecutive_bad_time_s = in.consecutive_bad_time_s;
    out.system_thermal_ceiling = in.system_thermal_ceiling;
    out.memory_skip_floor = in.memory_skip_floor;
    out.last_update_s = in.last_update_s;
    return out;
}

void to_c_volume_state(
    const aether::tsdf::VolumeControllerState& in,
    aether_volume_controller_state_t* out) {
    if (out == nullptr) {
        return;
    }
    out->frame_counter = in.frame_counter;
    out->integration_skip_rate = in.integration_skip_rate;
    out->consecutive_good_frames = in.consecutive_good_frames;
    out->consecutive_bad_frames = in.consecutive_bad_frames;
    out->consecutive_good_time_s = in.consecutive_good_time_s;
    out->consecutive_bad_time_s = in.consecutive_bad_time_s;
    out->system_thermal_ceiling = in.system_thermal_ceiling;
    out->memory_skip_floor = in.memory_skip_floor;
    out->last_update_s = in.last_update_s;
}

void to_c_volume_decision(
    const aether::tsdf::ControllerDecision& in,
    aether_volume_controller_decision_t* out) {
    if (out == nullptr) {
        return;
    }
    out->should_skip_frame = in.should_skip_frame ? 1 : 0;
    out->integration_skip_rate = in.integration_skip_rate;
    out->should_evict = in.should_evict ? 1 : 0;
    out->blocks_to_evict = in.blocks_to_evict;
    out->is_keyframe = in.is_keyframe ? 1 : 0;
    out->blocks_to_preallocate = in.blocks_to_preallocate;
    out->quality_weight = in.quality_weight;
}

aether::tsdf::DepthFilterConfig to_cpp_depth_filter_config(
    const aether_depth_filter_config_t* in) {
    aether::tsdf::DepthFilterConfig out{};
    if (in == nullptr) {
        return out;
    }
    out.sigma_spatial = in->sigma_spatial;
    out.sigma_range = in->sigma_range;
    out.kernel_radius = in->kernel_radius;
    out.max_fill_radius = in->max_fill_radius;
    out.min_valid_depth = in->min_valid_depth;
    out.max_valid_depth = in->max_valid_depth;
    return out;
}

void to_c_depth_filter_quality(
    const aether::tsdf::DepthFilterQuality& in,
    aether_depth_filter_quality_t* out) {
    if (out == nullptr) {
        return;
    }
    out->noise_residual = in.noise_residual;
    out->valid_ratio = in.valid_ratio;
    out->edge_risk_score = in.edge_risk_score;
}

aether::tsdf::FusionFeedback to_cpp_fusion_feedback(const aether_fusion_feedback_t& in) {
    aether::tsdf::FusionFeedback out{};
    out.voxel_weight_median = in.voxel_weight_median;
    out.sdf_variance_p95 = in.sdf_variance_p95;
    out.ghosting_score = in.ghosting_score;
    return out;
}

aether::tsdf::ICPPoint to_cpp_icp_point(const aether_icp_point_t& in) {
    aether::tsdf::ICPPoint out{};
    out.x = in.x;
    out.y = in.y;
    out.z = in.z;
    return out;
}

aether::tsdf::ICPConfig to_cpp_icp_config(const aether_icp_config_t* in) {
    aether::tsdf::ICPConfig out{};
    if (in == nullptr) {
        return out;
    }
    out.max_iterations = in->max_iterations;
    out.distance_threshold = in->distance_threshold;
    out.normal_threshold_deg = in->normal_threshold_deg;
    out.huber_delta = in->huber_delta;
    out.convergence_translation = in->convergence_translation;
    out.convergence_rotation = in->convergence_rotation;
    if (in->watchdog_max_diag_ratio > 0.0f) {
        out.watchdog_max_diag_ratio = in->watchdog_max_diag_ratio;
    }
    if (in->watchdog_max_residual_rise > 0) {
        out.watchdog_max_residual_rise = in->watchdog_max_residual_rise;
    }
    return out;
}

void to_c_icp_result(
    const aether::tsdf::ICPResult& in,
    aether_icp_result_t* out) {
    if (out == nullptr) {
        return;
    }
    for (int i = 0; i < 16; ++i) {
        out->pose_out[i] = in.pose_out[i];
    }
    out->iterations = in.iterations;
    out->correspondence_count = in.correspondence_count;
    out->rmse = in.rmse;
    out->watchdog_diag_ratio = in.watchdog_diag_ratio;
    out->watchdog_tripped = in.watchdog_tripped ? 1 : 0;
    out->converged = in.converged ? 1 : 0;
}

aether::render::ColorCorrectionConfig to_cpp_color_config(
    const aether_color_correction_config_t* in) {
    aether::render::ColorCorrectionConfig out{};
    if (in == nullptr) {
        return out;
    }
    out.mode = (in->mode == 0)
        ? aether::render::ColorCorrectionMode::kGrayWorld
        : aether::render::ColorCorrectionMode::kGrayWorldWithExposure;
    out.min_gain = in->min_gain;
    out.max_gain = in->max_gain;
    out.min_exposure_ratio = in->min_exposure_ratio;
    out.max_exposure_ratio = in->max_exposure_ratio;
    return out;
}

aether::render::ColorCorrectionState to_cpp_color_state(
    const aether_color_correction_state_t& in) {
    aether::render::ColorCorrectionState out{};
    out.has_reference = in.has_reference != 0;
    out.reference_luminance = in.reference_luminance;
    return out;
}

void to_c_color_state(
    const aether::render::ColorCorrectionState& in,
    aether_color_correction_state_t* out) {
    if (out == nullptr) {
        return;
    }
    out->has_reference = in.has_reference ? 1 : 0;
    out->reference_luminance = in.reference_luminance;
}

void to_c_color_stats(
    const aether::render::ColorCorrectionStats& in,
    aether_color_correction_stats_t* out) {
    if (out == nullptr) {
        return;
    }
    out->gain_r = in.gain_r;
    out->gain_g = in.gain_g;
    out->gain_b = in.gain_b;
    out->exposure_ratio = in.exposure_ratio;
}

aether::upload::KalmanBandwidthState to_cpp_kalman_state(
    const aether_kalman_bandwidth_state_t& in) {
    aether::upload::KalmanBandwidthState out{};
    for (int i = 0; i < 4; ++i) {
        out.x[static_cast<std::size_t>(i)] = in.x[i];
    }
    for (int i = 0; i < 16; ++i) {
        out.p[static_cast<std::size_t>(i)] = in.p[i];
    }
    out.q_base = in.q_base;
    out.r = in.r;
    for (int i = 0; i < 10; ++i) {
        out.recent_bps[static_cast<std::size_t>(i)] = in.recent_bps[i];
    }
    out.recent_count = in.recent_count;
    out.recent_head = in.recent_head;
    out.total_samples = in.total_samples;
    return out;
}

void to_c_kalman_state(
    const aether::upload::KalmanBandwidthState& in,
    aether_kalman_bandwidth_state_t* out) {
    if (out == nullptr) {
        return;
    }
    for (int i = 0; i < 4; ++i) {
        out->x[i] = in.x[static_cast<std::size_t>(i)];
    }
    for (int i = 0; i < 16; ++i) {
        out->p[i] = in.p[static_cast<std::size_t>(i)];
    }
    out->q_base = in.q_base;
    out->r = in.r;
    for (int i = 0; i < 10; ++i) {
        out->recent_bps[i] = in.recent_bps[static_cast<std::size_t>(i)];
    }
    out->recent_count = in.recent_count;
    out->recent_head = in.recent_head;
    out->total_samples = in.total_samples;
}

void to_c_kalman_output(
    const aether::upload::KalmanBandwidthOutput& in,
    aether_kalman_bandwidth_output_t* out) {
    if (out == nullptr) {
        return;
    }
    out->predicted_bps = in.predicted_bps;
    out->ci_low = in.ci_low;
    out->ci_high = in.ci_high;
    out->trend = static_cast<int>(in.trend);
    out->reliable = in.reliable ? 1 : 0;
}

aether::tsdf::PoseGraphConfig to_cpp_pose_graph_config(
    const aether_pose_graph_config_t* in) {
    aether::tsdf::PoseGraphConfig out{};
    if (in == nullptr) {
        return out;
    }
    out.max_iterations = in->max_iterations;
    out.step_size = in->step_size;
    out.huber_delta = in->huber_delta;
    out.stop_translation = in->stop_translation;
    if (in->stop_rotation > 0.0f) {
        out.stop_rotation = in->stop_rotation;
    }
    if (in->watchdog_max_diag_ratio > 0.0f) {
        out.watchdog_max_diag_ratio = in->watchdog_max_diag_ratio;
    }
    if (in->watchdog_max_residual_rise > 0) {
        out.watchdog_max_residual_rise = in->watchdog_max_residual_rise;
    }
    return out;
}

aether::innovation::Float3 to_cpp_float3(const aether_float3_t& in) {
    return aether::innovation::make_float3(in.x, in.y, in.z);
}

aether_float3_t to_c_float3(const aether::innovation::Float3& in) {
    aether_float3_t out{};
    out.x = in.x;
    out.y = in.y;
    out.z = in.z;
    return out;
}

[[maybe_unused]]
aether::innovation::GaussianPrimitive to_cpp_gaussian(const aether_gaussian_t& in) {
    aether::innovation::GaussianPrimitive out{};
    out.id = in.id;
    out.position = to_cpp_float3(in.position);
    out.scale = to_cpp_float3(in.scale);
    out.opacity = in.opacity;
    for (std::size_t i = 0u; i < out.sh_coeffs.size(); ++i) {
        out.sh_coeffs[i] = in.sh_coeffs[i];
    }
    out.host_unit_id = in.host_unit_id;
    out.bind_generation = in.bind_generation;
    out.observation_count = in.observation_count;
    out.patch_priority = in.patch_priority;
    out.capture_sequence = in.capture_sequence;
    out.first_observed_frame_id = in.first_observed_frame_id;
    out.first_observed_ms = in.first_observed_ms;
    out.flags = in.flags;
    out.lod_level = in.lod_level;
    if (in.binding_state == 1u) {
        out.binding_state = aether::innovation::BindingState::kSoft;
    } else if (in.binding_state == 2u) {
        out.binding_state = aether::innovation::BindingState::kHard;
    } else if (in.binding_state == 3u) {
        out.binding_state = aether::innovation::BindingState::kDynamic;
    } else {
        out.binding_state = aether::innovation::BindingState::kFree;
    }
    out.uncertainty = in.uncertainty;
    if (in.patch_id != nullptr) {
        out.patch_id = in.patch_id;
    }
    return out;
}

bool map_scheduler_state(int state, aether::scheduler::GPUSchedulerState* out_state) {
    if (out_state == nullptr) {
        return false;
    }
    if (state == 0) {
        *out_state = aether::scheduler::GPUSchedulerState::kCapturing;
        return true;
    }
    if (state == 1) {
        *out_state = aether::scheduler::GPUSchedulerState::kCaptureFinished;
        return true;
    }
    return false;
}

}  // namespace

extern "C" {

int aether_ds_mass_sealed(
    const aether_ds_mass_t* input,
    aether_ds_mass_t* out_mass) {
    if (input == nullptr || out_mass == nullptr) {
        return -1;
    }
    *out_mass = to_c_ds_mass(to_cpp_ds_mass(*input).sealed());
    return 0;
}

int aether_ds_combine_dempster(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_combine_result_t* out_result) {
    if (first == nullptr || second == nullptr || out_result == nullptr) {
        return -1;
    }
    const aether::evidence::DSMassCombineResult result =
        aether::evidence::DSMassFusion::dempster_combine(
            to_cpp_ds_mass(*first),
            to_cpp_ds_mass(*second));
    out_result->mass = to_c_ds_mass(result.mass);
    out_result->conflict = result.conflict;
    out_result->used_yager = result.used_yager ? 1 : 0;
    return 0;
}

int aether_ds_combine_yager(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_mass_t* out_mass) {
    if (first == nullptr || second == nullptr || out_mass == nullptr) {
        return -1;
    }
    *out_mass = to_c_ds_mass(aether::evidence::DSMassFusion::yager_combine(
        to_cpp_ds_mass(*first),
        to_cpp_ds_mass(*second)));
    return 0;
}

int aether_ds_combine_auto(
    const aether_ds_mass_t* first,
    const aether_ds_mass_t* second,
    aether_ds_mass_t* out_mass) {
    if (first == nullptr || second == nullptr || out_mass == nullptr) {
        return -1;
    }
    *out_mass = to_c_ds_mass(aether::evidence::DSMassFusion::combine(
        to_cpp_ds_mass(*first),
        to_cpp_ds_mass(*second)));
    return 0;
}

int aether_ds_discount(
    const aether_ds_mass_t* input,
    double reliability,
    aether_ds_mass_t* out_mass) {
    if (input == nullptr || out_mass == nullptr) {
        return -1;
    }
    *out_mass = to_c_ds_mass(aether::evidence::DSMassFusion::discount(
        to_cpp_ds_mass(*input),
        reliability));
    return 0;
}

int aether_ds_from_delta_multiplier(
    double delta_multiplier,
    aether_ds_mass_t* out_mass) {
    if (out_mass == nullptr) {
        return -1;
    }
    *out_mass = to_c_ds_mass(aether::evidence::DSMassFusion::from_delta_multiplier(
        delta_multiplier));
    return 0;
}

int aether_coverage_estimator_default_config(
    aether_coverage_estimator_config_t* out_config) {
    if (out_config == nullptr) {
        return -1;
    }
    to_c_coverage_config(aether::evidence::CoverageEstimatorConfig{}, out_config);
    return 0;
}

int aether_coverage_estimator_create(
    const aether_coverage_estimator_config_t* config,
    aether_coverage_estimator_t** out_estimator) {
    if (out_estimator == nullptr) {
        return -1;
    }
    const aether::evidence::CoverageEstimatorConfig cpp_config = to_cpp_coverage_config(config);
    aether_coverage_estimator_t* estimator =
        new (std::nothrow) aether_coverage_estimator_t(cpp_config);
    if (estimator == nullptr) {
        return -2;
    }
    *out_estimator = estimator;
    return 0;
}

int aether_coverage_estimator_destroy(aether_coverage_estimator_t* estimator) {
    if (estimator == nullptr) {
        return -1;
    }
    delete estimator;
    return 0;
}

int aether_coverage_estimator_reset(aether_coverage_estimator_t* estimator) {
    if (estimator == nullptr) {
        return -1;
    }
    estimator->impl.reset();
    return 0;
}

int aether_coverage_estimator_update(
    aether_coverage_estimator_t* estimator,
    const aether_coverage_cell_observation_t* cells,
    int cell_count,
    std::int64_t monotonic_timestamp_ms,
    aether_coverage_result_t* out_result) {
    std::size_t cell_size = 0u;
    if (estimator == nullptr ||
        !checked_count(cell_count, &cell_size) ||
        out_result == nullptr ||
        (cell_size > 0u && cells == nullptr)) {
        return -1;
    }
    std::vector<aether::evidence::CoverageCellObservation> cpp_cells;
    cpp_cells.reserve(cell_size);
    for (std::size_t i = 0u; i < cell_size; ++i) {
        cpp_cells.push_back(to_cpp_coverage_cell(cells[i]));
    }
    aether::evidence::CoverageResult result{};
    const Status status = estimator->impl.update(
        cpp_cells.data(),
        cpp_cells.size(),
        monotonic_timestamp_ms,
        &result);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_coverage_result(result, out_result);
    return 0;
}

int aether_coverage_estimator_last_coverage(
    const aether_coverage_estimator_t* estimator,
    double* out_coverage) {
    if (estimator == nullptr || out_coverage == nullptr) {
        return -1;
    }
    *out_coverage = estimator->impl.last_coverage();
    return 0;
}

int aether_coverage_estimator_non_monotonic_count(
    const aether_coverage_estimator_t* estimator,
    int* out_count) {
    if (estimator == nullptr || out_count == nullptr) {
        return -1;
    }
    *out_count = estimator->impl.non_monotonic_time_count();
    return 0;
}

int aether_spam_protection_create(aether_spam_protection_t** out_spam) {
    if (out_spam == nullptr) {
        return -1;
    }
    aether_spam_protection_t* spam = new (std::nothrow) aether_spam_protection_t();
    if (spam == nullptr) {
        return -2;
    }
    *out_spam = spam;
    return 0;
}

int aether_spam_protection_destroy(aether_spam_protection_t* spam) {
    if (spam == nullptr) {
        return -1;
    }
    delete spam;
    return 0;
}

int aether_spam_protection_reset(aether_spam_protection_t* spam) {
    if (spam == nullptr) {
        return -1;
    }
    spam->impl.reset();
    return 0;
}

int aether_spam_protection_should_allow_update(
    const aether_spam_protection_t* spam,
    const char* patch_id,
    std::int64_t timestamp_ms,
    int* out_allowed) {
    if (spam == nullptr || out_allowed == nullptr) {
        return -1;
    }
    std::string patch;
    const bool allowed = spam->impl.should_allow_update(safe_patch_id(patch_id, &patch), timestamp_ms);
    *out_allowed = allowed ? 1 : 0;
    return 0;
}

int aether_spam_protection_novelty_scale(
    const aether_spam_protection_t* spam,
    double raw_novelty,
    double* out_scale) {
    if (spam == nullptr || out_scale == nullptr) {
        return -1;
    }
    *out_scale = spam->impl.novelty_scale(raw_novelty);
    return 0;
}

int aether_spam_protection_frequency_scale(
    aether_spam_protection_t* spam,
    const char* patch_id,
    std::int64_t timestamp_ms,
    double* out_scale) {
    if (spam == nullptr || out_scale == nullptr) {
        return -1;
    }
    std::string patch;
    *out_scale = spam->impl.frequency_scale(safe_patch_id(patch_id, &patch), timestamp_ms);
    return 0;
}

int aether_token_bucket_create(aether_token_bucket_t** out_limiter) {
    if (out_limiter == nullptr) {
        return -1;
    }
    aether_token_bucket_t* limiter = new (std::nothrow) aether_token_bucket_t();
    if (limiter == nullptr) {
        return -2;
    }
    *out_limiter = limiter;
    return 0;
}

int aether_token_bucket_destroy(aether_token_bucket_t* limiter) {
    if (limiter == nullptr) {
        return -1;
    }
    delete limiter;
    return 0;
}

int aether_token_bucket_reset(aether_token_bucket_t* limiter) {
    if (limiter == nullptr) {
        return -1;
    }
    limiter->impl.reset();
    return 0;
}

int aether_token_bucket_try_consume(
    aether_token_bucket_t* limiter,
    const char* patch_id,
    std::int64_t timestamp_ms,
    int* out_consumed) {
    if (limiter == nullptr || out_consumed == nullptr) {
        return -1;
    }
    bool consumed = false;
    std::string patch;
    const Status status = limiter->impl.try_consume(safe_patch_id(patch_id, &patch), timestamp_ms, consumed);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    *out_consumed = consumed ? 1 : 0;
    return 0;
}

int aether_token_bucket_available_tokens(
    aether_token_bucket_t* limiter,
    const char* patch_id,
    std::int64_t timestamp_ms,
    double* out_tokens) {
    if (limiter == nullptr || out_tokens == nullptr) {
        return -1;
    }
    std::string patch;
    double tokens = 0.0;
    const Status status = limiter->impl.available_tokens(safe_patch_id(patch_id, &patch), timestamp_ms, tokens);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    *out_tokens = tokens;
    return 0;
}

int aether_view_diversity_create(aether_view_diversity_tracker_t** out_tracker) {
    if (out_tracker == nullptr) {
        return -1;
    }
    aether_view_diversity_tracker_t* tracker = new (std::nothrow) aether_view_diversity_tracker_t();
    if (tracker == nullptr) {
        return -2;
    }
    *out_tracker = tracker;
    return 0;
}

int aether_view_diversity_destroy(aether_view_diversity_tracker_t* tracker) {
    if (tracker == nullptr) {
        return -1;
    }
    delete tracker;
    return 0;
}

int aether_view_diversity_reset(aether_view_diversity_tracker_t* tracker) {
    if (tracker == nullptr) {
        return -1;
    }
    tracker->impl.reset();
    return 0;
}

int aether_view_diversity_add_observation(
    aether_view_diversity_tracker_t* tracker,
    const char* patch_id,
    double view_angle_deg,
    std::int64_t timestamp_ms,
    double* out_diversity) {
    if (tracker == nullptr || out_diversity == nullptr) {
        return -1;
    }
    std::string patch;
    *out_diversity = tracker->impl.add_observation(
        safe_patch_id(patch_id, &patch),
        view_angle_deg,
        timestamp_ms);
    return 0;
}

int aether_view_diversity_score(
    const aether_view_diversity_tracker_t* tracker,
    const char* patch_id,
    double* out_diversity) {
    if (tracker == nullptr || out_diversity == nullptr) {
        return -1;
    }
    std::string patch;
    *out_diversity = tracker->impl.diversity_score(safe_patch_id(patch_id, &patch));
    return 0;
}

int aether_admission_controller_create(aether_admission_controller_t** out_controller) {
    if (out_controller == nullptr) {
        return -1;
    }
    aether_admission_controller_t* controller = new (std::nothrow) aether_admission_controller_t();
    if (controller == nullptr) {
        return -2;
    }
    *out_controller = controller;
    return 0;
}

int aether_admission_controller_destroy(aether_admission_controller_t* controller) {
    if (controller == nullptr) {
        return -1;
    }
    delete controller;
    return 0;
}

int aether_admission_controller_reset(aether_admission_controller_t* controller) {
    if (controller == nullptr) {
        return -1;
    }
    controller->impl.reset();
    return 0;
}

int aether_admission_controller_check(
    aether_admission_controller_t* controller,
    const char* patch_id,
    double view_angle_deg,
    std::int64_t timestamp_ms,
    aether_admission_decision_t* out_decision) {
    if (controller == nullptr || out_decision == nullptr) {
        return -1;
    }
    std::string patch;
    const aether::evidence::EvidenceAdmissionDecision decision = controller->impl.check_admission(
        safe_patch_id(patch_id, &patch),
        view_angle_deg,
        timestamp_ms);
    to_c_admission_decision(decision, out_decision);
    return 0;
}

int aether_admission_controller_check_confirmed_spam(
    const aether_admission_controller_t* controller,
    const char* patch_id,
    double spam_score,
    double threshold,
    aether_admission_decision_t* out_decision) {
    if (controller == nullptr || out_decision == nullptr) {
        return -1;
    }
    std::string patch;
    const aether::evidence::EvidenceAdmissionDecision decision = controller->impl.check_confirmed_spam(
        safe_patch_id(patch_id, &patch),
        spam_score,
        threshold);
    to_c_admission_decision(decision, out_decision);
    return 0;
}

int aether_pr1_admission_evaluate(
    const aether_pr1_admission_input_t* input,
    aether_pr1_admission_decision_t* out_decision) {
    if (input == nullptr || out_decision == nullptr) {
        return -1;
    }

    aether::evidence::PR1AdmissionInput cpp_input{};
    cpp_input.is_duplicate = input->is_duplicate != 0;
    cpp_input.current_mode = to_cpp_pr1_build_mode(input->current_mode);
    cpp_input.should_trigger_soft_limit = input->should_trigger_soft_limit != 0;
    cpp_input.hard_trigger = to_cpp_pr1_hard_trigger(input->hard_trigger);
    cpp_input.info_gain = input->info_gain;
    cpp_input.novelty = input->novelty;
    cpp_input.ig_min_soft = input->ig_min_soft;
    cpp_input.novelty_min_soft = input->novelty_min_soft;
    cpp_input.eeb_min_quantum = input->eeb_min_quantum;

    aether::evidence::PR1AdmissionDecision cpp_decision{};
    const Status status = aether::evidence::evaluate_pr1_admission(cpp_input, &cpp_decision);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    out_decision->classification = to_c_pr1_classification(cpp_decision.classification);
    out_decision->reason = to_c_pr1_reason(cpp_decision.reason);
    out_decision->eeb_delta = cpp_decision.eeb_delta;
    out_decision->build_mode = to_c_pr1_build_mode(cpp_decision.build_mode);
    out_decision->guidance_signal = to_c_pr1_guidance(cpp_decision.guidance_signal);
    out_decision->hard_fuse_trigger = to_c_pr1_hard_trigger(cpp_decision.hard_fuse_trigger);
    return 0;
}

int aether_pr1_capacity_state_step(
    const aether_pr1_capacity_state_input_t* input,
    aether_pr1_capacity_state_output_t* out_state) {
    if (input == nullptr || out_state == nullptr) {
        return -1;
    }

    const int patch_count_shadow = sanitize_non_negative_int(input->patch_count_shadow, 0);
    const double eeb_remaining = sanitize_non_negative(input->eeb_remaining, 0.0);
    const int soft_limit_patch_count = sanitize_non_negative_int(input->soft_limit_patch_count, 0);
    const double soft_budget_threshold = sanitize_non_negative(input->soft_budget_threshold, 0.0);
    const int hard_limit_patch_count = sanitize_non_negative_int(input->hard_limit_patch_count, 0);
    const double hard_budget_threshold = sanitize_non_negative(input->hard_budget_threshold, 0.0);
    const int saturated_latched = input->saturated_latched != 0 ? 1 : 0;
    const int current_mode = input->current_mode;

    const bool soft_trigger = patch_count_shadow >= soft_limit_patch_count ||
                              eeb_remaining <= soft_budget_threshold;

    int hard_trigger = AETHER_PR1_HARD_FUSE_NONE;
    if (patch_count_shadow >= hard_limit_patch_count) {
        hard_trigger = AETHER_PR1_HARD_FUSE_PATCHCOUNT_HARD;
    } else if (eeb_remaining <= hard_budget_threshold) {
        hard_trigger = AETHER_PR1_HARD_FUSE_EEB_HARD;
    }

    int next_mode = AETHER_PR1_BUILD_MODE_NORMAL;
    if (saturated_latched != 0 ||
        current_mode == AETHER_PR1_BUILD_MODE_SATURATED ||
        hard_trigger != AETHER_PR1_HARD_FUSE_NONE) {
        next_mode = AETHER_PR1_BUILD_MODE_SATURATED;
    } else if (soft_trigger) {
        next_mode = AETHER_PR1_BUILD_MODE_DAMPING;
    }

    out_state->should_trigger_soft_limit = soft_trigger ? 1 : 0;
    out_state->hard_trigger = hard_trigger;
    out_state->next_mode = next_mode;
    out_state->should_latch_saturated =
        (hard_trigger != AETHER_PR1_HARD_FUSE_NONE && saturated_latched == 0) ? 1 : 0;
    return 0;
}

int aether_pr1_info_gain_default_config(aether_pr1_info_gain_config_t* out_config) {
    if (out_config == nullptr) {
        return -1;
    }
    to_c_pr1_info_gain_config(aether::evidence::PR1InformationGainConfig{}, out_config);
    return 0;
}

int aether_pr1_compute_info_gain(
    const aether_pr1_patch_descriptor_t* patch,
    const uint8_t* coverage_grid_states,
    int grid_size,
    double* out_info_gain) {
    return aether_pr1_compute_info_gain_with_config(
        patch,
        coverage_grid_states,
        grid_size,
        nullptr,
        out_info_gain);
}

int aether_pr1_compute_info_gain_with_config(
    const aether_pr1_patch_descriptor_t* patch,
    const uint8_t* coverage_grid_states,
    int grid_size,
    const aether_pr1_info_gain_config_t* config,
    double* out_info_gain) {
    if (patch == nullptr || out_info_gain == nullptr || grid_size <= 0) {
        return -1;
    }
    const std::size_t coverage_count = static_cast<std::size_t>(grid_size) * static_cast<std::size_t>(grid_size);
    if (coverage_grid_states == nullptr) {
        return -1;
    }

    const aether::evidence::PR1InformationGainConfig cpp_config = to_cpp_pr1_info_gain_config(config, grid_size);
    const Status status = aether::evidence::pr1_compute_information_gain(
        to_cpp_pr1_patch(*patch),
        coverage_grid_states,
        coverage_count,
        cpp_config,
        out_info_gain);
    return to_rc(status);
}

int aether_pr1_compute_novelty(
    const aether_pr1_patch_descriptor_t* patch,
    const aether_pr1_patch_descriptor_t* existing_patches,
    int existing_count,
    double pose_eps,
    double* out_novelty) {
    aether_pr1_info_gain_config_t config{};
    to_c_pr1_info_gain_config(aether::evidence::PR1InformationGainConfig{}, &config);
    if (pose_eps > 0.0 && std::isfinite(pose_eps)) {
        config.pose_eps = pose_eps;
    }
    return aether_pr1_compute_novelty_with_config(
        patch,
        existing_patches,
        existing_count,
        &config,
        out_novelty);
}

int aether_pr1_compute_novelty_with_config(
    const aether_pr1_patch_descriptor_t* patch,
    const aether_pr1_patch_descriptor_t* existing_patches,
    int existing_count,
    const aether_pr1_info_gain_config_t* config,
    double* out_novelty) {
    if (patch == nullptr || out_novelty == nullptr || existing_count < 0) {
        return -1;
    }
    if (existing_count > 0 && existing_patches == nullptr) {
        return -1;
    }

    std::vector<aether::evidence::PR1PatchDescriptor> existing_cpp;
    existing_cpp.reserve(static_cast<std::size_t>(existing_count));
    for (int i = 0; i < existing_count; ++i) {
        existing_cpp.push_back(to_cpp_pr1_patch(existing_patches[i]));
    }

    const aether::evidence::PR1InformationGainConfig cpp_config = to_cpp_pr1_info_gain_config(config, 0);
    const Status status = aether::evidence::pr1_compute_novelty(
        to_cpp_pr1_patch(*patch),
        existing_cpp.empty() ? nullptr : existing_cpp.data(),
        existing_cpp.size(),
        cpp_config,
        out_novelty);
    return to_rc(status);
}

int aether_sha256(
    const uint8_t* data,
    int data_len,
    uint8_t out_digest[AETHER_SHA256_DIGEST_BYTES]) {
    if (out_digest == nullptr || data_len < 0) {
        return -1;
    }
    if (data_len > 0 && data == nullptr) {
        return -1;
    }
    aether::crypto::Sha256Digest digest{};
    aether::crypto::sha256(data, static_cast<std::size_t>(data_len), digest);
    std::memcpy(out_digest, digest.bytes, sizeof(digest.bytes));
    return 0;
}

int aether_sha256_hex(
    const uint8_t* data,
    int data_len,
    char out_hex[AETHER_SHA256_HEX_BYTES]) {
    if (out_hex == nullptr || data_len < 0) {
        return -1;
    }
    if (data_len > 0 && data == nullptr) {
        return -1;
    }
    aether::crypto::Sha256Digest digest{};
    aether::crypto::sha256(data, static_cast<std::size_t>(data_len), digest);
    static constexpr char kHex[] = "0123456789abcdef";
    for (std::size_t i = 0; i < sizeof(digest.bytes); ++i) {
        const uint8_t byte = digest.bytes[i];
        out_hex[i * 2u] = kHex[(byte >> 4u) & 0x0Fu];
        out_hex[i * 2u + 1u] = kHex[byte & 0x0Fu];
    }
    out_hex[64] = '\0';
    return 0;
}

int aether_evidence_state_encode_canonical_json(
    const aether_evidence_state_input_t* input,
    char* out_json,
    int* inout_json_capacity) {
    if (input == nullptr || inout_json_capacity == nullptr || *inout_json_capacity < 0) {
        return -1;
    }
    aether::evidence::CanonicalJsonValue root{};
    Status status = build_evidence_state_canonical(input, &root);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    std::string json;
    status = aether::evidence::encode_canonical_json(root, json);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    const int required = static_cast<int>(json.size() + 1u);
    if (out_json == nullptr || *inout_json_capacity < required) {
        *inout_json_capacity = required;
        return to_rc(Status::kResourceExhausted);
    }
    std::memcpy(out_json, json.data(), json.size());
    out_json[json.size()] = '\0';
    *inout_json_capacity = required;
    return 0;
}

int aether_evidence_state_canonical_sha256_hex(
    const aether_evidence_state_input_t* input,
    char out_hex[AETHER_SHA256_HEX_BYTES]) {
    if (input == nullptr || out_hex == nullptr) {
        return -1;
    }
    aether::evidence::CanonicalJsonValue root{};
    Status status = build_evidence_state_canonical(input, &root);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    std::string hex;
    status = aether::evidence::canonical_json_sha256_hex(root, hex);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    if (hex.size() != 64u) {
        return -2;
    }
    std::memcpy(out_hex, hex.data(), hex.size());
    out_hex[64] = '\0';
    return 0;
}

int aether_merkle_hash_leaf(
    const uint8_t* data,
    int data_len,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (out_hash == nullptr || data_len < 0) {
        return -1;
    }
    if (data_len > 0 && data == nullptr) {
        return -1;
    }
    const aether::merkle::Hash32 hash =
        aether::merkle::hash_leaf(data, static_cast<std::size_t>(data_len));
    hash_to_bytes(hash, out_hash);
    return 0;
}

int aether_merkle_hash_nodes(
    const uint8_t left_hash[AETHER_MERKLE_HASH_BYTES],
    const uint8_t right_hash[AETHER_MERKLE_HASH_BYTES],
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (left_hash == nullptr || right_hash == nullptr || out_hash == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 left{};
    aether::merkle::Hash32 right{};
    if (!bytes_to_hash32(left_hash, &left) || !bytes_to_hash32(right_hash, &right)) {
        return -1;
    }
    const aether::merkle::Hash32 hash = aether::merkle::hash_nodes(left, right);
    hash_to_bytes(hash, out_hash);
    return 0;
}

int aether_merkle_empty_root(uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (out_hash == nullptr) {
        return -1;
    }
    const aether::merkle::Hash32 root = aether::merkle::empty_root();
    hash_to_bytes(root, out_hash);
    return 0;
}

int aether_merkle_tree_create(aether_merkle_tree_t** out_tree) {
    if (out_tree == nullptr) {
        return -1;
    }
    aether_merkle_tree_t* tree = new (std::nothrow) aether_merkle_tree_t();
    if (tree == nullptr) {
        return -2;
    }
    *out_tree = tree;
    return 0;
}

int aether_merkle_tree_destroy(aether_merkle_tree_t* tree) {
    if (tree == nullptr) {
        return -1;
    }
    delete tree;
    return 0;
}

int aether_merkle_tree_reset(aether_merkle_tree_t* tree) {
    if (tree == nullptr) {
        return -1;
    }
    return to_rc(tree->impl.reset());
}

int aether_merkle_tree_size(const aether_merkle_tree_t* tree, std::uint64_t* out_size) {
    if (tree == nullptr || out_size == nullptr) {
        return -1;
    }
    *out_size = tree->impl.size();
    return 0;
}

int aether_merkle_tree_root_hash(
    const aether_merkle_tree_t* tree,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (tree == nullptr || out_hash == nullptr) {
        return -1;
    }
    hash_to_bytes(tree->impl.root_hash(), out_hash);
    return 0;
}

int aether_merkle_tree_append(
    aether_merkle_tree_t* tree,
    const uint8_t* leaf_data,
    int leaf_data_len) {
    if (tree == nullptr || leaf_data_len < 0) {
        return -1;
    }
    if (leaf_data_len > 0 && leaf_data == nullptr) {
        return -1;
    }
    return to_rc(tree->impl.append(leaf_data, static_cast<std::size_t>(leaf_data_len)));
}

int aether_merkle_tree_append_hash(
    aether_merkle_tree_t* tree,
    const uint8_t leaf_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (tree == nullptr || leaf_hash == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 hash{};
    if (!bytes_to_hash32(leaf_hash, &hash)) {
        return -1;
    }
    return to_rc(tree->impl.append_hash(hash));
}

int aether_merkle_tree_root_at_size(
    const aether_merkle_tree_t* tree,
    std::uint64_t tree_size,
    uint8_t out_hash[AETHER_MERKLE_HASH_BYTES]) {
    if (tree == nullptr || out_hash == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 root{};
    const Status st = tree->impl.root_at_size(tree_size, root);
    if (st != Status::kOk) {
        return to_rc(st);
    }
    hash_to_bytes(root, out_hash);
    return 0;
}

int aether_merkle_tree_inclusion_proof(
    const aether_merkle_tree_t* tree,
    std::uint64_t leaf_index,
    aether_merkle_inclusion_proof_t* out_proof) {
    if (tree == nullptr || out_proof == nullptr) {
        return -1;
    }
    aether::merkle::InclusionProof proof{};
    const Status st = tree->impl.inclusion_proof(leaf_index, proof);
    if (st != Status::kOk) {
        return to_rc(st);
    }
    fill_c_inclusion_proof(proof, out_proof);
    return 0;
}

int aether_merkle_tree_consistency_proof(
    const aether_merkle_tree_t* tree,
    std::uint64_t first_size,
    std::uint64_t second_size,
    aether_merkle_consistency_proof_t* out_proof) {
    if (tree == nullptr || out_proof == nullptr) {
        return -1;
    }
    aether::merkle::ConsistencyProof proof{};
    const Status st = tree->impl.consistency_proof(first_size, second_size, proof);
    if (st != Status::kOk) {
        return to_rc(st);
    }
    fill_c_consistency_proof(proof, out_proof);
    return 0;
}

int aether_merkle_verify_inclusion(
    const aether_merkle_inclusion_proof_t* proof,
    const uint8_t expected_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid) {
    if (proof == nullptr || expected_root == nullptr || out_valid == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 root{};
    if (!bytes_to_hash32(expected_root, &root)) {
        return -1;
    }
    aether::merkle::InclusionProof cpp_proof{};
    if (!load_cpp_inclusion_proof(*proof, &cpp_proof)) {
        return -1;
    }
    *out_valid = cpp_proof.verify(root) ? 1 : 0;
    return 0;
}

int aether_merkle_verify_inclusion_with_leaf_data(
    const aether_merkle_inclusion_proof_t* proof,
    const uint8_t* leaf_data,
    int leaf_data_len,
    const uint8_t expected_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid) {
    if (proof == nullptr || expected_root == nullptr || out_valid == nullptr || leaf_data_len < 0) {
        return -1;
    }
    if (leaf_data_len > 0 && leaf_data == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 root{};
    if (!bytes_to_hash32(expected_root, &root)) {
        return -1;
    }
    aether::merkle::InclusionProof cpp_proof{};
    if (!load_cpp_inclusion_proof(*proof, &cpp_proof)) {
        return -1;
    }
    *out_valid = cpp_proof.verify_with_leaf_data(leaf_data, static_cast<std::size_t>(leaf_data_len), root) ? 1 : 0;
    return 0;
}

int aether_merkle_verify_consistency(
    const aether_merkle_consistency_proof_t* proof,
    const uint8_t first_root[AETHER_MERKLE_HASH_BYTES],
    const uint8_t second_root[AETHER_MERKLE_HASH_BYTES],
    int* out_valid) {
    if (proof == nullptr || first_root == nullptr || second_root == nullptr || out_valid == nullptr) {
        return -1;
    }
    aether::merkle::Hash32 first{};
    aether::merkle::Hash32 second{};
    if (!bytes_to_hash32(first_root, &first) || !bytes_to_hash32(second_root, &second)) {
        return -1;
    }
    aether::merkle::ConsistencyProof cpp_proof{};
    if (!load_cpp_consistency_proof(*proof, &cpp_proof)) {
        return -1;
    }
    *out_valid = cpp_proof.verify(first, second) ? 1 : 0;
    return 0;
}

int aether_tri_tet_kuhn5_table(int parity, int out_vertices[20]) {
    if (out_vertices == nullptr) {
        return -1;
    }
    return to_rc(aether::tsdf::kuhn5_table(parity, out_vertices));
}

int aether_tri_tet_evaluate(
    const aether_tri_tet_triangle_t* triangles,
    int triangle_count,
    const aether_tri_tet_vertex_t* vertices,
    int vertex_count,
    const aether_tri_tet_tetrahedron_t* tetrahedra,
    int tetrahedron_count,
    const aether_tri_tet_config_t* config,
    aether_tri_tet_binding_t* out_bindings,
    int binding_capacity,
    aether_tri_tet_report_t* out_report) {
    std::size_t triangle_size = 0u;
    std::size_t vertex_size = 0u;
    std::size_t tetra_size = 0u;
    std::size_t binding_size = 0u;
    if (!checked_count(triangle_count, &triangle_size) ||
        !checked_count(vertex_count, &vertex_size) ||
        !checked_count(tetrahedron_count, &tetra_size) ||
        !checked_count(binding_capacity, &binding_size) ||
        out_report == nullptr) {
        return -1;
    }
    if ((triangle_size > 0u && triangles == nullptr) ||
        (vertex_size > 0u && vertices == nullptr) ||
        (tetra_size > 0u && tetrahedra == nullptr)) {
        return -1;
    }
    if (triangle_size > 0u && out_bindings == nullptr) {
        return -1;
    }

    std::vector<aether::tsdf::TriTetTriangle> tri_cpp;
    tri_cpp.reserve(triangle_size);
    for (std::size_t i = 0u; i < triangle_size; ++i) {
        tri_cpp.push_back(to_cpp_tri_tet_triangle(triangles[i]));
    }
    std::vector<aether::tsdf::TriTetVertex> vertex_cpp;
    vertex_cpp.reserve(vertex_size);
    for (std::size_t i = 0u; i < vertex_size; ++i) {
        vertex_cpp.push_back(to_cpp_tri_tet_vertex(vertices[i]));
    }
    std::vector<aether::tsdf::TriTetTetrahedron> tetra_cpp;
    tetra_cpp.reserve(tetra_size);
    for (std::size_t i = 0u; i < tetra_size; ++i) {
        tetra_cpp.push_back(to_cpp_tri_tet_tet(tetrahedra[i]));
    }

    aether::tsdf::TriTetConfig cfg{};
    if (config != nullptr) {
        cfg.measured_min_view_count = config->measured_min_view_count;
        cfg.estimated_min_view_count = config->estimated_min_view_count;
        cfg.max_triangle_to_tet_distance = config->max_triangle_to_tet_distance;
    }

    std::vector<aether::tsdf::TriTetBinding> binding_cpp(binding_size);
    aether::tsdf::TriTetReport report_cpp{};
    const Status status = aether::tsdf::evaluate_tri_tet_consistency(
        tri_cpp.empty() ? nullptr : tri_cpp.data(),
        tri_cpp.size(),
        vertex_cpp.empty() ? nullptr : vertex_cpp.data(),
        vertex_cpp.size(),
        tetra_cpp.empty() ? nullptr : tetra_cpp.data(),
        tetra_cpp.size(),
        cfg,
        binding_cpp.empty() ? nullptr : binding_cpp.data(),
        binding_cpp.size(),
        &report_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    for (std::size_t i = 0u; i < triangle_size; ++i) {
        const aether::tsdf::TriTetBinding& src = binding_cpp[i];
        aether_tri_tet_binding_t dst{};
        dst.triangle_index = src.triangle_index;
        dst.tetrahedron_id = src.tetrahedron_id;
        dst.classification = static_cast<std::uint8_t>(to_c_tri_tet_class(src.classification));
        dst.tri_to_tet_distance = src.tri_to_tet_distance;
        dst.min_tet_view_count = src.min_tet_view_count;
        out_bindings[i] = dst;
    }

    out_report->combined_score = report_cpp.combined_score;
    out_report->measured_count = report_cpp.measured_count;
    out_report->estimated_count = report_cpp.estimated_count;
    out_report->unknown_count = report_cpp.unknown_count;
    return 0;
}

int aether_tritet_score(
    const aether_tri_tet_triangle_t* triangles,
    int triangle_count,
    const aether_tri_tet_vertex_t* vertices,
    int vertex_count,
    const aether_tri_tet_tetrahedron_t* tetrahedra,
    int tetrahedron_count,
    const aether_tri_tet_config_t* config,
    aether_tri_tet_binding_t* out_bindings,
    int binding_capacity,
    aether_tri_tet_report_t* out_report) {
    return aether_tri_tet_evaluate(
        triangles,
        triangle_count,
        vertices,
        vertex_count,
        tetrahedra,
        tetrahedron_count,
        config,
        out_bindings,
        binding_capacity,
        out_report);
}

int aether_spatial_quantize_world_position(
    double world_x,
    double world_y,
    double world_z,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    aether_quantized_position_t* out_position) {
    if (out_position == nullptr) {
        return -1;
    }
    aether::tsdf::QuantizedPosition pos{};
    const Status status = aether::tsdf::quantize_world_position(
        world_x,
        world_y,
        world_z,
        origin_x,
        origin_y,
        origin_z,
        cell_size_meters,
        &pos);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_quantized_position(pos, out_position);
    return 0;
}

int aether_spatial_morton_encode_21bit(
    int32_t x,
    int32_t y,
    int32_t z,
    uint64_t* out_code) {
    return to_rc(aether::tsdf::morton_encode_21bit(x, y, z, out_code));
}

int aether_spatial_morton_decode_21bit(
    uint64_t code,
    aether_quantized_position_t* out_position) {
    if (out_position == nullptr) {
        return -1;
    }
    aether::tsdf::QuantizedPosition pos{};
    const Status status = aether::tsdf::morton_decode_21bit(code, &pos);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_quantized_position(pos, out_position);
    return 0;
}

int aether_spatial_dequantize_world_position(
    const aether_quantized_position_t* position,
    double origin_x,
    double origin_y,
    double origin_z,
    double cell_size_meters,
    double* out_world_x,
    double* out_world_y,
    double* out_world_z) {
    if (position == nullptr) {
        return -1;
    }
    return to_rc(aether::tsdf::dequantize_world_position(
        to_cpp_quantized_position(*position),
        origin_x,
        origin_y,
        origin_z,
        cell_size_meters,
        out_world_x,
        out_world_y,
        out_world_z));
}

int aether_spatial_adjacency_build(
    const aether_scan_triangle_t* triangles,
    int triangle_count,
    float cell_size,
    float epsilon,
    uint32_t* out_offsets,
    uint32_t* out_neighbors,
    int* inout_neighbor_count) {
    std::size_t tri_size = 0u;
    if (!checked_count(triangle_count, &tri_size) || out_offsets == nullptr || inout_neighbor_count == nullptr) {
        return -1;
    }
    if (tri_size > 0u && triangles == nullptr) {
        return -1;
    }

    std::vector<aether::quality::Triangle3f> cpp_triangles;
    cpp_triangles.reserve(tri_size);
    for (std::size_t i = 0u; i < tri_size; ++i) {
        cpp_triangles.push_back(to_cpp_quality_triangle(triangles[i]));
    }

    std::vector<std::uint32_t> offsets;
    std::vector<std::uint32_t> neighbors;
    const Status status = aether::quality::build_spatial_hash_adjacency(
        cpp_triangles.empty() ? nullptr : cpp_triangles.data(),
        cpp_triangles.size(),
        cell_size,
        epsilon,
        &offsets,
        &neighbors);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    const int required = static_cast<int>(neighbors.size());
    if (out_neighbors == nullptr || *inout_neighbor_count < required) {
        *inout_neighbor_count = required;
        return to_rc(Status::kResourceExhausted);
    }

    for (std::size_t i = 0u; i < offsets.size(); ++i) {
        out_offsets[i] = offsets[i];
    }
    for (std::size_t i = 0u; i < neighbors.size(); ++i) {
        out_neighbors[i] = neighbors[i];
    }
    *inout_neighbor_count = required;
    return 0;
}

int aether_spatial_adjacency_bfs(
    const uint32_t* offsets,
    const uint32_t* neighbors,
    int triangle_count,
    const uint32_t* sources,
    int source_count,
    int max_hops,
    int32_t* out_distances) {
    std::size_t tri_size = 0u;
    std::size_t source_size = 0u;
    if (!checked_count(triangle_count, &tri_size) ||
        !checked_count(source_count, &source_size) ||
        out_distances == nullptr) {
        return -1;
    }
    if ((tri_size > 0u && (offsets == nullptr || neighbors == nullptr)) ||
        (source_size > 0u && sources == nullptr)) {
        return -1;
    }

    std::vector<std::int32_t> distances;
    const Status status = aether::quality::bfs_distances(
        offsets,
        neighbors,
        tri_size,
        sources,
        source_size,
        max_hops,
        &distances);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    for (std::size_t i = 0u; i < distances.size(); ++i) {
        out_distances[i] = distances[i];
    }
    return 0;
}

// aether_scan_triangle_longest_edge, aether_hash_fnv1a32, and
// aether_hash_fnv1a64 are implemented further below in the wedge/render
// helper section to avoid duplication.

int aether_motion_analyzer_create(aether_motion_analyzer_t** out_analyzer) {
    if (out_analyzer == nullptr) {
        return -1;
    }
    aether_motion_analyzer_t* analyzer = new (std::nothrow) aether_motion_analyzer_t();
    if (analyzer == nullptr) {
        return -2;
    }
    *out_analyzer = analyzer;
    return 0;
}

int aether_motion_analyzer_destroy(aether_motion_analyzer_t* analyzer) {
    if (analyzer == nullptr) {
        return -1;
    }
    delete analyzer;
    return 0;
}

int aether_motion_analyzer_reset(aether_motion_analyzer_t* analyzer) {
    if (analyzer == nullptr) {
        return -1;
    }
    analyzer->impl.reset();
    return 0;
}

int aether_motion_analyzer_analyze(
    aether_motion_analyzer_t* analyzer,
    const uint8_t* image,
    int width,
    int height,
    aether_motion_result_t* out_result) {
    if (analyzer == nullptr || out_result == nullptr || width < 0 || height < 0) {
        return -1;
    }
    if ((width > 0 && height > 0) && image == nullptr) {
        return -1;
    }
    const aether::quality::MotionResult result = analyzer->impl.analyze_frame(image, width, height);
    out_result->score = result.score;
    out_result->is_fast_pan = result.is_fast_pan ? 1 : 0;
    out_result->is_hand_shake = result.is_hand_shake ? 1 : 0;
    return 0;
}

int aether_motion_analyzer_quality_metric(
    const aether_motion_analyzer_t* analyzer,
    int quality_level,
    double* out_value,
    double* out_confidence) {
    if (analyzer == nullptr || out_value == nullptr || out_confidence == nullptr) {
        return -1;
    }
    const aether::quality::MotionMetric metric = analyzer->impl.analyze_quality(quality_level);
    *out_value = metric.value;
    *out_confidence = metric.confidence;
    return 0;
}

int aether_laplacian_variance_compute(
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    double* out_variance) {
    return to_rc(aether::quality::laplacian_variance(image, width, height, row_bytes, out_variance));
}

int aether_tenengrad_detect(
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    int* out_skipped) {
    if (out_skipped == nullptr) {
        return -1;
    }
    bool skipped = false;
    const Status status = aether::quality::tenengrad_metric_for_quality(
        quality_level,
        tenengrad_threshold,
        out_value,
        out_confidence,
        out_roi_coverage,
        &skipped);
    *out_skipped = skipped ? 1 : 0;
    return to_rc(status);
}

int aether_tenengrad_compute(
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    int quality_level,
    double tenengrad_threshold,
    double* out_value,
    double* out_confidence,
    double* out_roi_coverage,
    int* out_skipped) {
    if (out_skipped == nullptr) {
        return -1;
    }
    bool skipped = false;
    const Status status = aether::quality::tenengrad_metric_from_image(
        image,
        width,
        height,
        row_bytes,
        quality_level,
        tenengrad_threshold,
        out_value,
        out_confidence,
        out_roi_coverage,
        &skipped);
    *out_skipped = skipped ? 1 : 0;
    return to_rc(status);
}

int aether_frame_quality_eval(
    aether_motion_analyzer_t* analyzer,
    const uint8_t* image,
    int width,
    int height,
    int row_bytes,
    int quality_level,
    double tenengrad_threshold,
    aether_frame_quality_result_t* out_result) {
    if (analyzer == nullptr || image == nullptr || out_result == nullptr ||
        width <= 0 || height <= 0 || row_bytes < width) {
        return -1;
    }
    std::memset(out_result, 0, sizeof(*out_result));

    aether_motion_result_t motion{};
    const int motion_rc = aether_motion_analyzer_analyze(analyzer, image, width, height, &motion);
    if (motion_rc != 0) {
        return motion_rc;
    }
    out_result->motion_score = motion.score;
    out_result->is_fast_pan = motion.is_fast_pan;
    out_result->is_hand_shake = motion.is_hand_shake;

    const int lap_rc = aether_laplacian_variance_compute(image, width, height, row_bytes, &out_result->laplacian_variance);
    if (lap_rc != 0) {
        return lap_rc;
    }

    double ten_conf = 0.0;
    double ten_roi = 0.0;
    int ten_skip = 0;
    const int ten_rc = aether_tenengrad_compute(
        image,
        width,
        height,
        row_bytes,
        quality_level,
        tenengrad_threshold,
        &out_result->tenengrad_score,
        &ten_conf,
        &ten_roi,
        &ten_skip);
    if (ten_rc != 0) {
        return ten_rc;
    }

    aether::core::guard_finite_scalar(&out_result->laplacian_variance);
    aether::core::guard_finite_scalar(&out_result->tenengrad_score);
    aether::core::guard_finite_scalar(&out_result->motion_score);

    const bool reject = (out_result->laplacian_variance < 6.0) ||
        (ten_skip == 0 && out_result->tenengrad_score < tenengrad_threshold * 0.8) ||
        (out_result->is_hand_shake != 0);
    out_result->should_reject = reject ? 1 : 0;
    return 0;
}

int aether_cross_validation_evaluate_outlier(
    const aether_outlier_cross_validation_input_t* input,
    aether_cross_validation_outcome_t* out_outcome) {
    if (input == nullptr || out_outcome == nullptr) {
        return -1;
    }
    const aether::quality::OutlierCrossValidationInput cpp_input{
        input->rule_inlier != 0,
        input->ml_inlier_score,
        input->ml_inlier_threshold};
    const aether::quality::CrossValidationOutcome outcome =
        aether::quality::evaluate_outlier_cross_validation(cpp_input);
    out_outcome->decision = to_c_cross_validation_decision(outcome.decision);
    out_outcome->reason_code = to_c_cross_validation_reason(outcome.reason);
    return 0;
}

int aether_cross_validation_evaluate_calibration(
    const aether_calibration_cross_validation_input_t* input,
    aether_cross_validation_outcome_t* out_outcome) {
    if (input == nullptr || out_outcome == nullptr) {
        return -1;
    }
    const aether::quality::CalibrationCrossValidationInput cpp_input{
        input->baseline_error_cm,
        input->ml_error_cm,
        input->max_allowed_error_cm,
        input->max_divergence_cm};
    const aether::quality::CrossValidationOutcome outcome =
        aether::quality::evaluate_calibration_cross_validation(cpp_input);
    out_outcome->decision = to_c_cross_validation_decision(outcome.decision);
    out_outcome->reason_code = to_c_cross_validation_reason(outcome.reason);
    return 0;
}

int aether_pure_vision_default_gate_thresholds(
    aether_pure_vision_gate_thresholds_t* out_thresholds) {
    if (out_thresholds == nullptr) {
        return -1;
    }
    pure_vision_default_thresholds(out_thresholds);
    return 0;
}

int aether_pure_vision_evaluate_gates(
    const aether_pure_vision_runtime_metrics_t* metrics,
    const aether_pure_vision_gate_thresholds_t* thresholds_or_null,
    aether_pure_vision_gate_result_t* out_results,
    int* out_result_count) {
    if (metrics == nullptr || out_results == nullptr || out_result_count == nullptr) {
        return -1;
    }
    if (*out_result_count < AETHER_PURE_VISION_GATE_COUNT) {
        *out_result_count = AETHER_PURE_VISION_GATE_COUNT;
        return -3;
    }

    const aether::quality::PureVisionRuntimeMetrics cpp_metrics{
        metrics->baseline_pixels,
        metrics->blur_laplacian,
        metrics->orb_features,
        metrics->parallax_ratio,
        metrics->depth_sigma_meters,
        metrics->closure_ratio,
        metrics->unknown_voxel_ratio,
        metrics->thermal_celsius};
    const aether::quality::PureVisionGateThresholds cpp_thresholds =
        to_cpp_pure_vision_thresholds(thresholds_or_null);
    aether::quality::PureVisionGateEvaluation evals[aether::quality::kPureVisionGateCount]{};
    const std::size_t n =
        aether::quality::evaluate_pure_vision_gates(cpp_metrics, cpp_thresholds, evals);
    for (std::size_t i = 0u; i < n; ++i) {
        out_results[i].gate_id = to_c_pure_vision_gate_id(evals[i].gate_id);
        out_results[i].passed = evals[i].passed ? 1 : 0;
        out_results[i].observed = evals[i].observed;
        out_results[i].threshold = evals[i].threshold;
        out_results[i].comparator = evals[i].comparator_greater_equal ? 0 : 1;
    }
    *out_result_count = static_cast<int>(n);
    return 0;
}

int aether_pure_vision_failed_gate_ids(
    const aether_pure_vision_runtime_metrics_t* metrics,
    const aether_pure_vision_gate_thresholds_t* thresholds_or_null,
    int* out_gate_ids,
    int* inout_gate_count) {
    if (metrics == nullptr || out_gate_ids == nullptr || inout_gate_count == nullptr) {
        return -1;
    }
    if (*inout_gate_count < 0) {
        return -1;
    }
    aether_pure_vision_gate_result_t evals[AETHER_PURE_VISION_GATE_COUNT]{};
    int eval_count = AETHER_PURE_VISION_GATE_COUNT;
    const int rc = aether_pure_vision_evaluate_gates(
        metrics,
        thresholds_or_null,
        evals,
        &eval_count);
    if (rc != 0) {
        return rc;
    }
    int failed_count = 0;
    for (int i = 0; i < eval_count; ++i) {
        if (evals[i].passed == 0) {
            if (failed_count < *inout_gate_count) {
                out_gate_ids[failed_count] = evals[i].gate_id;
            }
            failed_count += 1;
        }
    }
    *inout_gate_count = failed_count;
    return 0;
}

int aether_zero_fabrication_evaluate(
    int mode,
    float max_denoise_displacement_meters,
    int action,
    const aether_zero_fabrication_context_t* context,
    aether_zero_fabrication_decision_t* out_decision) {
    if (context == nullptr || out_decision == nullptr) {
        return -1;
    }

    const aether::quality::ZeroFabricationPolicyConfig cpp_config{
        to_cpp_zero_fab_mode(mode),
        max_denoise_displacement_meters};
    const aether::quality::ZeroFabricationContext cpp_context{
        to_cpp_zero_fab_confidence(context->confidence_class),
        context->has_direct_observation != 0,
        context->requested_point_displacement_meters,
        context->requested_new_geometry_count};
    const aether::quality::ZeroFabricationDecision decision =
        aether::quality::evaluate_zero_fabrication(
            cpp_config,
            to_cpp_zero_fab_action(action),
            cpp_context);

    out_decision->allowed = decision.allowed ? 1 : 0;
    out_decision->reason_code = to_c_zero_fab_reason(decision.reason);
    out_decision->severity = to_c_zero_fab_severity(decision.severity);
    return 0;
}

int aether_geometry_ml_evaluate(
    const aether_pure_vision_runtime_metrics_t* runtime_metrics,
    const aether_geometry_ml_tri_tet_report_t* tri_tet_report_or_null,
    const aether_geometry_ml_cross_validation_stats_t* cross_validation_stats,
    const aether_geometry_ml_capture_signals_t* capture_signals,
    const aether_geometry_ml_evidence_signals_t* evidence_signals,
    const aether_geometry_ml_transport_signals_t* transport_signals,
    const aether_geometry_ml_security_signals_t* security_signals,
    const aether_geometry_ml_thresholds_t* thresholds,
    const aether_geometry_ml_weights_t* weights,
    const aether_upload_cdc_thresholds_t* upload_thresholds,
    aether_geometry_ml_result_t* out_result) {
    if (runtime_metrics == nullptr ||
        cross_validation_stats == nullptr ||
        capture_signals == nullptr ||
        evidence_signals == nullptr ||
        transport_signals == nullptr ||
        security_signals == nullptr ||
        thresholds == nullptr ||
        weights == nullptr ||
        upload_thresholds == nullptr ||
        out_result == nullptr) {
        return -1;
    }

    const aether::quality::PureVisionRuntimeMetrics cpp_metrics =
        to_cpp_pure_vision_metrics(*runtime_metrics);
    const aether::quality::GeometryMLTriTetReportInput cpp_tri_tet =
        to_cpp_geometry_tri_tet_report(tri_tet_report_or_null);
    const aether::quality::GeometryMLResult cpp_result =
        aether::quality::evaluate_geometry_ml_fusion(
            cpp_metrics,
            tri_tet_report_or_null == nullptr ? nullptr : &cpp_tri_tet,
            to_cpp_geometry_cv_stats(*cross_validation_stats),
            to_cpp_geometry_capture_signals(*capture_signals),
            to_cpp_geometry_evidence_signals(*evidence_signals),
            to_cpp_geometry_transport_signals(*transport_signals),
            to_cpp_geometry_security_signals(*security_signals),
            to_cpp_geometry_ml_thresholds(*thresholds),
            to_cpp_geometry_ml_weights(*weights),
            to_cpp_geometry_ml_upload_thresholds(*upload_thresholds));
    to_c_geometry_ml_result(cpp_result, out_result);
    return 0;
}

int aether_deterministic_triangulate_quad(
    const aether_point2d_t* quad_vertices,
    double epsilon,
    aether_point2d_t* out_triangle_vertices,
    int* inout_vertex_count) {
    if (quad_vertices == nullptr || inout_vertex_count == nullptr) {
        return -1;
    }
    const int required = 6;
    if (out_triangle_vertices == nullptr || *inout_vertex_count < required) {
        *inout_vertex_count = required;
        return to_rc(Status::kResourceExhausted);
    }

    aether::quality::Point2d quad[4] = {
        to_cpp_point2d(quad_vertices[0]),
        to_cpp_point2d(quad_vertices[1]),
        to_cpp_point2d(quad_vertices[2]),
        to_cpp_point2d(quad_vertices[3])};
    aether::quality::Triangle2d tris[2]{};
    const Status status = aether::quality::triangulate_quad(quad, epsilon, tris);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    out_triangle_vertices[0] = to_c_point2d(tris[0].a);
    out_triangle_vertices[1] = to_c_point2d(tris[0].b);
    out_triangle_vertices[2] = to_c_point2d(tris[0].c);
    out_triangle_vertices[3] = to_c_point2d(tris[1].a);
    out_triangle_vertices[4] = to_c_point2d(tris[1].b);
    out_triangle_vertices[5] = to_c_point2d(tris[1].c);
    *inout_vertex_count = required;
    return 0;
}

int aether_deterministic_sort_triangles(
    const aether_point2d_t* triangle_vertices,
    int triangle_count,
    double epsilon,
    aether_point2d_t* out_triangle_vertices) {
    std::size_t tri_size = 0u;
    if (!checked_count(triangle_count, &tri_size) || out_triangle_vertices == nullptr) {
        return -1;
    }
    if (tri_size > 0u && triangle_vertices == nullptr) {
        return -1;
    }

    std::vector<aether::quality::Triangle2d> in_tris;
    in_tris.reserve(tri_size);
    for (std::size_t i = 0u; i < tri_size; ++i) {
        const std::size_t base = i * 3u;
        in_tris.push_back(aether::quality::Triangle2d{
            to_cpp_point2d(triangle_vertices[base]),
            to_cpp_point2d(triangle_vertices[base + 1u]),
            to_cpp_point2d(triangle_vertices[base + 2u])});
    }

    std::vector<aether::quality::Triangle2d> out_tris;
    const Status status = aether::quality::sort_triangles(
        in_tris.empty() ? nullptr : in_tris.data(),
        in_tris.size(),
        epsilon,
        &out_tris);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    for (std::size_t i = 0u; i < out_tris.size(); ++i) {
        const std::size_t base = i * 3u;
        out_triangle_vertices[base] = to_c_point2d(out_tris[i].a);
        out_triangle_vertices[base + 1u] = to_c_point2d(out_tris[i].b);
        out_triangle_vertices[base + 2u] = to_c_point2d(out_tris[i].c);
    }
    return 0;
}

int aether_photometric_checker_create(
    int window_size,
    aether_photometric_checker_t** out_checker) {
    if (out_checker == nullptr || window_size <= 0) {
        return -1;
    }
    aether_photometric_checker_t* checker =
        new (std::nothrow) aether_photometric_checker_t(static_cast<std::size_t>(window_size));
    if (checker == nullptr) {
        return -2;
    }
    *out_checker = checker;
    return 0;
}

int aether_photometric_checker_destroy(aether_photometric_checker_t* checker) {
    if (checker == nullptr) {
        return -1;
    }
    delete checker;
    return 0;
}

int aether_photometric_checker_reset(aether_photometric_checker_t* checker) {
    if (checker == nullptr) {
        return -1;
    }
    checker->impl.reset();
    return 0;
}

int aether_photometric_checker_update(
    aether_photometric_checker_t* checker,
    double luminance,
    double exposure,
    double lab_l,
    double lab_a,
    double lab_b) {
    if (checker == nullptr) {
        return -1;
    }
    checker->impl.update(luminance, exposure, to_cpp_lab(lab_l, lab_a, lab_b));
    return 0;
}

int aether_photometric_checker_check(
    const aether_photometric_checker_t* checker,
    double max_luminance_variance,
    double max_lab_variance,
    double min_exposure_consistency,
    aether_photometric_result_t* out_result) {
    if (checker == nullptr || out_result == nullptr) {
        return -1;
    }
    const aether::quality::PhotometricResult result = checker->impl.check(
        max_luminance_variance,
        max_lab_variance,
        min_exposure_consistency);
    out_result->luminance_variance = result.luminance_variance;
    out_result->lab_variance = result.lab_variance;
    out_result->exposure_consistency = result.exposure_consistency;
    out_result->is_consistent = result.is_consistent ? 1 : 0;
    out_result->confidence = result.confidence;
    return 0;
}

int aether_photometric_check(
    const aether_photometric_checker_t* checker,
    double max_luminance_variance,
    double max_lab_variance,
    double min_exposure_consistency,
    aether_photometric_result_t* out_result) {
    return aether_photometric_checker_check(
        checker,
        max_luminance_variance,
        max_lab_variance,
        min_exposure_consistency,
        out_result);
}

int aether_marching_cubes_run(
    const float* sdf_grid,
    int dim,
    float origin_x,
    float origin_y,
    float origin_z,
    float voxel_size,
    aether_mc_vertex_t* out_vertices,
    int* inout_vertex_count,
    uint32_t* out_indices,
    int* inout_index_count) {
    if (sdf_grid == nullptr || dim < 2 || inout_vertex_count == nullptr || inout_index_count == nullptr) {
        return -1;
    }

    aether::tsdf::MarchingCubesResult result{};
    aether::tsdf::marching_cubes(sdf_grid, dim, origin_x, origin_y, origin_z, voxel_size, result);

    const int required_vertices = static_cast<int>(result.vertex_count);
    const int required_indices = static_cast<int>(result.index_count);
    if (out_vertices == nullptr || out_indices == nullptr ||
        *inout_vertex_count < required_vertices ||
        *inout_index_count < required_indices) {
        *inout_vertex_count = required_vertices;
        *inout_index_count = required_indices;
        std::free(result.vertices);
        std::free(result.indices);
        return to_rc(Status::kResourceExhausted);
    }

    for (int i = 0; i < required_vertices; ++i) {
        out_vertices[i].x = result.vertices[static_cast<std::size_t>(i)].x;
        out_vertices[i].y = result.vertices[static_cast<std::size_t>(i)].y;
        out_vertices[i].z = result.vertices[static_cast<std::size_t>(i)].z;
    }
    for (int i = 0; i < required_indices; ++i) {
        out_indices[i] = result.indices[static_cast<std::size_t>(i)];
    }
    *inout_vertex_count = required_vertices;
    *inout_index_count = required_indices;

    std::free(result.vertices);
    std::free(result.indices);
    return 0;
}

int aether_tsdf_integrate_frame(
    const aether_integration_input_t* input,
    aether_integration_result_t* result) {
    return aether_tsdf_integrate(input, result);
}

int aether_volume_controller_decide(
    const aether_volume_controller_signals_t* signals,
    aether_volume_controller_state_t* state,
    aether_volume_controller_decision_t* out_decision) {
    if (signals == nullptr || state == nullptr || out_decision == nullptr) {
        return -1;
    }
    aether::tsdf::VolumeControllerState cpp_state = to_cpp_volume_state(*state);
    aether::tsdf::ControllerDecision cpp_decision{};
    const Status status = aether::tsdf::volume_controller_decide(
        to_cpp_volume_signals(*signals),
        &cpp_state,
        &cpp_decision);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_volume_state(cpp_state, state);
    to_c_volume_decision(cpp_decision, out_decision);
    CoreHealthStore& health = core_health_store();
    health.snapshot.thermal_headroom = signals->thermal.headroom;
    health.snapshot.thermal_slope = signals->thermal.slope;
    health.snapshot.thermal_confidence = signals->thermal.confidence;
    health.snapshot.memory_water_level = signals->memory_water_level;
    health.snapshot.current_integration_skip = out_decision->integration_skip_rate;
    return 0;
}

int aether_thermal_engine_create(aether_thermal_engine_t** out_engine) {
    if (out_engine == nullptr) {
        return -1;
    }
    aether_thermal_engine_t* engine = new (std::nothrow) aether_thermal_engine_t();
    if (engine == nullptr) {
        return -2;
    }
    *out_engine = engine;
    return 0;
}

int aether_thermal_engine_destroy(aether_thermal_engine_t* engine) {
    if (engine == nullptr) {
        return -1;
    }
    delete engine;
    return 0;
}

int aether_thermal_engine_reset(aether_thermal_engine_t* engine) {
    if (engine == nullptr) {
        return -1;
    }
    engine->impl = aether::tsdf::AetherThermalEngine{};
    return 0;
}

int aether_thermal_engine_update(
    aether_thermal_engine_t* engine,
    const aether_thermal_observation_t* observation,
    aether_thermal_state_t* out_state) {
    if (engine == nullptr || observation == nullptr || out_state == nullptr) {
        return -1;
    }
    aether::tsdf::AetherThermalState state{};
    const Status status = engine->impl.update(to_cpp_thermal_observation(*observation), &state);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_thermal_state(state, out_state);
    CoreHealthStore& health = core_health_store();
    health.snapshot.thermal_headroom = out_state->headroom;
    health.snapshot.thermal_slope = out_state->slope;
    health.snapshot.thermal_confidence = out_state->confidence;
    return 0;
}

float aether_thermal_engine_cpu_probe_ms(void) {
    return aether::tsdf::AetherThermalEngine::run_cpu_probe();
}

int aether_depth_filter_create(
    int width,
    int height,
    const aether_depth_filter_config_t* config,
    aether_depth_filter_t** out_filter) {
    if (out_filter == nullptr || width <= 0 || height <= 0) {
        return -1;
    }
    aether_depth_filter_t* filter = new (std::nothrow) aether_depth_filter_t(
        width,
        height,
        to_cpp_depth_filter_config(config));
    if (filter == nullptr) {
        return -2;
    }
    *out_filter = filter;
    return 0;
}

int aether_depth_filter_destroy(aether_depth_filter_t* filter) {
    if (filter == nullptr) {
        return -1;
    }
    delete filter;
    return 0;
}

int aether_depth_filter_reset(aether_depth_filter_t* filter) {
    if (filter == nullptr) {
        return -1;
    }
    filter->impl.reset();
    return 0;
}

int aether_depth_filter_run(
    aether_depth_filter_t* filter,
    const float* depth_in,
    const uint8_t* confidence_in,
    float angular_velocity,
    float* depth_out,
    aether_depth_filter_quality_t* out_quality) {
    if (filter == nullptr || depth_in == nullptr || depth_out == nullptr) {
        return -1;
    }
    aether::tsdf::DepthFilterQuality quality{};
    const Status status = filter->impl.run(depth_in, confidence_in, angular_velocity, depth_out, &quality);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    if (out_quality != nullptr) {
        to_c_depth_filter_quality(quality, out_quality);
    }
    return 0;
}

int aether_depth_filter_apply_fusion_feedback(
    aether_depth_filter_t* filter,
    const aether_fusion_feedback_t* feedback) {
    if (filter == nullptr || feedback == nullptr) {
        return -1;
    }
    return to_rc(filter->impl.apply_fusion_feedback(to_cpp_fusion_feedback(*feedback)));
}

int aether_icp_refine(
    const aether_icp_point_t* source_points,
    int source_count,
    const aether_icp_point_t* target_points,
    int target_count,
    const aether_icp_point_t* target_normals,
    const float initial_pose[16],
    float angular_velocity,
    const aether_icp_config_t* config,
    aether_icp_result_t* out_result) {
    std::size_t source_size = 0u;
    std::size_t target_size = 0u;
    if (!checked_count(source_count, &source_size) ||
        !checked_count(target_count, &target_size) ||
        out_result == nullptr ||
        initial_pose == nullptr) {
        return -1;
    }
    if ((source_size > 0u && source_points == nullptr) ||
        (target_size > 0u && (target_points == nullptr || target_normals == nullptr))) {
        return -1;
    }

    std::vector<aether::tsdf::ICPPoint> source_cpp;
    source_cpp.reserve(source_size);
    for (std::size_t i = 0u; i < source_size; ++i) {
        source_cpp.push_back(to_cpp_icp_point(source_points[i]));
    }
    std::vector<aether::tsdf::ICPPoint> target_cpp;
    target_cpp.reserve(target_size);
    std::vector<aether::tsdf::ICPPoint> normal_cpp;
    normal_cpp.reserve(target_size);
    for (std::size_t i = 0u; i < target_size; ++i) {
        target_cpp.push_back(to_cpp_icp_point(target_points[i]));
        normal_cpp.push_back(to_cpp_icp_point(target_normals[i]));
    }

    aether::tsdf::ICPResult cpp_result{};
    const Status status = aether::tsdf::icp_refine(
        source_cpp.empty() ? nullptr : source_cpp.data(),
        source_cpp.size(),
        target_cpp.empty() ? nullptr : target_cpp.data(),
        target_cpp.size(),
        normal_cpp.empty() ? nullptr : normal_cpp.data(),
        initial_pose,
        angular_velocity,
        to_cpp_icp_config(config),
        &cpp_result);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_icp_result(cpp_result, out_result);
    aether::core::guard_finite_vector(out_result->pose_out, 16u);
    aether::core::guard_finite_scalar(&out_result->rmse);
    aether::core::guard_finite_scalar(&out_result->watchdog_diag_ratio);
    CoreHealthStore& health = core_health_store();
    health.snapshot.icp_last_rmse = out_result->rmse;
    health.snapshot.icp_last_diag_ratio = out_result->watchdog_diag_ratio;
    return 0;
}

int aether_color_correct(
    const uint8_t* image_in,
    int width,
    int height,
    int row_bytes,
    const aether_color_correction_config_t* config,
    aether_color_correction_state_t* state,
    uint8_t* image_out,
    aether_color_correction_stats_t* out_stats) {
    if (image_in == nullptr || image_out == nullptr || state == nullptr) {
        return -1;
    }
    aether::render::ColorCorrectionState cpp_state = to_cpp_color_state(*state);
    aether::render::ColorCorrectionStats cpp_stats{};
    const Status status = aether::render::color_correct_rgb8(
        image_in,
        width,
        height,
        row_bytes,
        to_cpp_color_config(config),
        &cpp_state,
        image_out,
        &cpp_stats);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    to_c_color_state(cpp_state, state);
    if (out_stats != nullptr) {
        to_c_color_stats(cpp_stats, out_stats);
    }
    return 0;
}

int aether_da3_fuse_depth(
    const aether_da3_depth_sample_t* sample,
    float* out_fused_depth,
    float* out_confidence) {
    if (sample == nullptr || out_fused_depth == nullptr) {
        return -1;
    }
    if (!std::isfinite(sample->depth_from_vision) ||
        !std::isfinite(sample->depth_from_tsdf) ||
        !std::isfinite(sample->sigma2_vision) ||
        !std::isfinite(sample->sigma2_tsdf)) {
        return -1;
    }
    aether::trainer::DA3DepthSample cpp_sample{};
    cpp_sample.depth_from_vision = sample->depth_from_vision;
    cpp_sample.depth_from_tsdf = sample->depth_from_tsdf;
    cpp_sample.sigma2_vision = sample->sigma2_vision;
    cpp_sample.sigma2_tsdf = sample->sigma2_tsdf;
    cpp_sample.tri_tet_class = to_cpp_tri_tet_class(sample->tri_tet_class);
    float confidence = 0.0f;
    *out_fused_depth = aether::trainer::fuse_da3_depth(
        cpp_sample,
        out_confidence != nullptr ? &confidence : nullptr);
    if (out_confidence != nullptr) {
        *out_confidence = confidence;
    }
    return 0;
}

int aether_monocular_depth_to_metric(
    const float* relative_depth,
    int width,
    int height,
    const float* camera_pose_16,
    const float* history_poses_16,
    int history_pose_count,
    float* out_metric_depth,
    float* out_scale_factor) {
    std::size_t history_size = 0u;
    if (!checked_count(history_pose_count, &history_size) ||
        relative_depth == nullptr || camera_pose_16 == nullptr ||
        out_metric_depth == nullptr || out_scale_factor == nullptr ||
        width <= 0 || height <= 0) {
        return -1;
    }
    if (history_size > 0u && history_poses_16 == nullptr) {
        return -1;
    }
    if (!finite_pose(camera_pose_16)) {
        return -1;
    }
    const std::size_t count = static_cast<std::size_t>(width) * static_cast<std::size_t>(height);
    if (count == 0u) {
        return -1;
    }

    std::vector<float> valid_depth;
    valid_depth.reserve(count);
    for (std::size_t i = 0u; i < count; ++i) {
        const float d = relative_depth[i];
        if (std::isfinite(d) && d > 0.0f) {
            valid_depth.push_back(d);
        }
    }
    if (valid_depth.empty()) {
        return to_rc(Status::kOutOfRange);
    }
    const std::size_t mid = valid_depth.size() / 2u;
    std::nth_element(valid_depth.begin(), valid_depth.begin() + static_cast<std::ptrdiff_t>(mid), valid_depth.end());
    const float median_relative = std::max(valid_depth[mid], 1e-3f);

    struct PoseTranslation {
        float x;
        float y;
        float z;
    };
    auto pose_translation = [](const float* pose16) -> PoseTranslation {
        return PoseTranslation{pose16[12], pose16[13], pose16[14]};
    };
    auto clamp_scale = [](float value) -> float {
        return std::max(0.05f, std::min(20.0f, value));
    };

    double path_length = 0.0;
    PoseTranslation prev = pose_translation(camera_pose_16);
    if (history_size > 0u) {
        prev = pose_translation(history_poses_16);
        for (std::size_t i = 1u; i < history_size; ++i) {
            const PoseTranslation curr = pose_translation(history_poses_16 + i * 16u);
            const double dx = static_cast<double>(curr.x - prev.x);
            const double dy = static_cast<double>(curr.y - prev.y);
            const double dz = static_cast<double>(curr.z - prev.z);
            path_length += std::sqrt(dx * dx + dy * dy + dz * dz);
            prev = curr;
        }
    }
    const PoseTranslation current = pose_translation(camera_pose_16);
    const double dx = static_cast<double>(current.x - prev.x);
    const double dy = static_cast<double>(current.y - prev.y);
    const double dz = static_cast<double>(current.z - prev.z);
    path_length += std::sqrt(dx * dx + dy * dy + dz * dz);

    float scale = 1.0f;
    if (std::isfinite(path_length) && path_length > 1e-4) {
        scale = static_cast<float>(path_length / static_cast<double>(median_relative));
    }
    if (!std::isfinite(scale) || scale <= 0.0f) {
        scale = 1.0f;
    }
    scale = clamp_scale(scale);
    // Keep inter-frame scale changes conservative for runtime stability.
    const float stability_gain = 1.0f - (0.25f / std::max(1.0f, static_cast<float>(history_size + 1u)));
    scale *= std::max(0.75f, std::min(1.0f, stability_gain));
    scale = clamp_scale(scale);

    for (std::size_t i = 0u; i < count; ++i) {
        const float d = relative_depth[i];
        out_metric_depth[i] = (std::isfinite(d) && d > 0.0f) ? (d * scale) : 0.0f;
    }
    *out_scale_factor = scale;
    return 0;
}

int aether_bandwidth_kalman_reset(aether_kalman_bandwidth_state_t* state) {
    if (state == nullptr) {
        return -1;
    }
    aether::upload::KalmanBandwidthState cpp{};
    aether::upload::kalman_bandwidth_reset(&cpp);
    to_c_kalman_state(cpp, state);
    return 0;
}

int aether_bandwidth_kalman_step(
    aether_kalman_bandwidth_state_t* state,
    int64_t bytes_transferred,
    double duration_seconds,
    aether_kalman_bandwidth_output_t* out) {
    if (state == nullptr || out == nullptr) {
        return -1;
    }
    aether::upload::KalmanBandwidthState cpp = to_cpp_kalman_state(*state);
    aether::upload::KalmanBandwidthOutput cpp_out{};
    const Status status = aether::upload::kalman_bandwidth_step(
        &cpp,
        bytes_transferred,
        duration_seconds,
        &cpp_out);
    to_c_kalman_state(cpp, state);
    to_c_kalman_output(cpp_out, out);
    return to_rc(status);
}

int aether_bandwidth_kalman_predict(
    const aether_kalman_bandwidth_state_t* state,
    aether_kalman_bandwidth_output_t* out) {
    if (state == nullptr || out == nullptr) {
        return -1;
    }
    aether::upload::KalmanBandwidthState cpp_state = to_cpp_kalman_state(*state);
    aether::upload::KalmanBandwidthOutput cpp_out{};
    const Status status = aether::upload::kalman_bandwidth_predict(
        &cpp_state,
        &cpp_out);
    to_c_kalman_output(cpp_out, out);
    return to_rc(status);
}

int aether_erasure_select_mode(
    int chunk_count,
    double loss_rate,
    aether_erasure_selection_t* out_selection) {
    if (out_selection == nullptr) {
        return -1;
    }
    aether::upload::ErasureSelection selection{};
    const Status status = aether::upload::erasure_select_mode(chunk_count, loss_rate, &selection);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out_selection->mode = static_cast<int>(selection.mode);
    out_selection->field = static_cast<int>(selection.field);
    return 0;
}

static bool parse_erasure_mode(int mode, aether::upload::ErasureMode* out_mode) {
    if (out_mode == nullptr) {
        return false;
    }
    if (mode == 0) {
        *out_mode = aether::upload::ErasureMode::kReedSolomon;
        return true;
    }
    if (mode == 1) {
        *out_mode = aether::upload::ErasureMode::kRaptorQ;
        return true;
    }
    return false;
}

static bool parse_erasure_field(int field, aether::upload::ErasureField* out_field) {
    if (out_field == nullptr) {
        return false;
    }
    if (field == 0) {
        *out_field = aether::upload::ErasureField::kGF256;
        return true;
    }
    if (field == 1) {
        *out_field = aether::upload::ErasureField::kGF65536;
        return true;
    }
    return false;
}

int aether_erasure_encode(
    const uint8_t* input_data,
    const uint32_t* input_offsets,
    int block_count,
    double redundancy,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size) {
    return to_rc(aether::upload::erasure_encode(
        input_data,
        input_offsets,
        block_count,
        redundancy,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size));
}

int aether_erasure_encode_with_mode(
    const uint8_t* input_data,
    const uint32_t* input_offsets,
    int block_count,
    double redundancy,
    int mode,
    int field,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size) {
    aether::upload::ErasureMode cpp_mode = aether::upload::ErasureMode::kReedSolomon;
    aether::upload::ErasureField cpp_field = aether::upload::ErasureField::kGF256;
    if (!parse_erasure_mode(mode, &cpp_mode) || !parse_erasure_field(field, &cpp_field)) {
        return -1;
    }
    return to_rc(aether::upload::erasure_encode_with_mode(
        input_data,
        input_offsets,
        block_count,
        redundancy,
        cpp_mode,
        cpp_field,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size));
}

int aether_erasure_decode_systematic(
    const uint8_t* blocks_data,
    const uint32_t* block_offsets,
    const uint8_t* block_present,
    int block_count,
    int original_count,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size) {
    return to_rc(aether::upload::erasure_decode_systematic(
        blocks_data,
        block_offsets,
        block_present,
        block_count,
        original_count,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size));
}

int aether_erasure_decode_systematic_with_mode(
    const uint8_t* blocks_data,
    const uint32_t* block_offsets,
    const uint8_t* block_present,
    int block_count,
    int original_count,
    int mode,
    int field,
    uint8_t* out_data,
    uint32_t out_data_capacity,
    uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    uint32_t* out_data_size) {
    aether::upload::ErasureMode cpp_mode = aether::upload::ErasureMode::kReedSolomon;
    aether::upload::ErasureField cpp_field = aether::upload::ErasureField::kGF256;
    if (!parse_erasure_mode(mode, &cpp_mode) || !parse_erasure_field(field, &cpp_field)) {
        return -1;
    }
    return to_rc(aether::upload::erasure_decode_systematic_with_mode(
        blocks_data,
        block_offsets,
        block_present,
        block_count,
        original_count,
        cpp_mode,
        cpp_field,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size));
}

int aether_loop_detect(
    const uint64_t* current_blocks,
    int current_count,
    const uint64_t* history_blocks,
    const uint32_t* history_offsets,
    int history_frame_count,
    int skip_recent,
    float overlap_threshold,
    float yaw_sigma,
    float time_tau,
    const float* yaw_deltas,
    const float* time_deltas,
    aether_loop_candidate_t* out_candidate) {
    std::size_t cur_size = 0u;
    std::size_t frame_size = 0u;
    if (!checked_count(current_count, &cur_size) ||
        !checked_count(history_frame_count, &frame_size) ||
        out_candidate == nullptr) {
        return -1;
    }
    aether::tsdf::LoopCandidate candidate{};
    const Status status = aether::tsdf::loop_detect_best(
        current_blocks,
        cur_size,
        history_blocks,
        history_offsets,
        frame_size,
        skip_recent,
        overlap_threshold,
        yaw_sigma,
        time_tau,
        yaw_deltas,
        time_deltas,
        &candidate);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out_candidate->frame_index = candidate.frame_index;
    out_candidate->overlap_ratio = candidate.overlap_ratio;
    out_candidate->score = candidate.score;
    CoreHealthStore& health = core_health_store();
    health.snapshot.loop_last_score = candidate.score;
    return 0;
}

int aether_pose_graph_optimize(
    aether_pose_graph_node_t* nodes,
    int node_count,
    const aether_pose_graph_edge_t* edges,
    int edge_count,
    const aether_pose_graph_config_t* config,
    aether_pose_graph_result_t* out_result) {
    std::size_t node_size = 0u;
    std::size_t edge_size = 0u;
    if (!checked_count(node_count, &node_size) ||
        !checked_count(edge_count, &edge_size) ||
        nodes == nullptr ||
        edges == nullptr ||
        out_result == nullptr) {
        return -1;
    }

    std::vector<aether::tsdf::PoseGraphNode> node_cpp;
    node_cpp.reserve(node_size);
    for (std::size_t i = 0u; i < node_size; ++i) {
        aether::tsdf::PoseGraphNode node{};
        node.id = nodes[i].id;
        for (int j = 0; j < 16; ++j) {
            node.pose[j] = nodes[i].pose[j];
        }
        node.fixed = nodes[i].fixed != 0;
        node_cpp.push_back(node);
    }

    std::vector<aether::tsdf::PoseGraphEdge> edge_cpp;
    edge_cpp.reserve(edge_size);
    for (std::size_t i = 0u; i < edge_size; ++i) {
        aether::tsdf::PoseGraphEdge edge{};
        edge.from_id = edges[i].from_id;
        edge.to_id = edges[i].to_id;
        for (int j = 0; j < 16; ++j) {
            edge.transform[j] = edges[i].transform[j];
        }
        for (int j = 0; j < 36; ++j) {
            edge.information[j] = edges[i].information[j];
        }
        edge.is_loop = edges[i].is_loop != 0;
        edge_cpp.push_back(edge);
    }

    aether::tsdf::PoseGraphResult result_cpp{};
    const Status status = aether::tsdf::optimize_pose_graph(
        node_cpp.data(),
        node_cpp.size(),
        edge_cpp.data(),
        edge_cpp.size(),
        to_cpp_pose_graph_config(config),
        &result_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }

    for (std::size_t i = 0u; i < node_size; ++i) {
        for (int j = 0; j < 16; ++j) {
            nodes[i].pose[j] = node_cpp[i].pose[j];
        }
    }
    out_result->iterations = result_cpp.iterations;
    out_result->initial_error = result_cpp.initial_error;
    out_result->final_error = result_cpp.final_error;
    out_result->watchdog_diag_ratio = result_cpp.watchdog_diag_ratio;
    out_result->watchdog_tripped = result_cpp.watchdog_tripped ? 1 : 0;
    out_result->converged = result_cpp.converged ? 1 : 0;

    for (std::size_t i = 0u; i < node_size; ++i) {
        aether::core::guard_finite_vector(nodes[i].pose, 16u);
    }
    aether::core::guard_finite_scalar(&out_result->initial_error);
    aether::core::guard_finite_scalar(&out_result->final_error);
    aether::core::guard_finite_scalar(&out_result->watchdog_diag_ratio);

    CoreHealthStore& health = core_health_store();
    health.snapshot.pose_graph_last_error = out_result->final_error;
    health.snapshot.pose_graph_last_diag_ratio = out_result->watchdog_diag_ratio;
    return 0;
}

int aether_pose_stabilizer_create(
    const aether_pose_stabilizer_config_t* config_or_null,
    aether_pose_stabilizer_t** out_stabilizer) {
    if (out_stabilizer == nullptr) {
        return -1;
    }
    aether::tsdf::PoseStabilizerConfig config{};
    if (config_or_null != nullptr) {
        config.translation_alpha = config_or_null->translation_alpha;
        config.rotation_alpha = config_or_null->rotation_alpha;
        config.max_prediction_horizon_s = config_or_null->max_prediction_horizon_s;
        config.bias_alpha = config_or_null->bias_alpha;
        config.init_frames = config_or_null->init_frames;
        config.fast_init = (config_or_null->fast_init != 0);
        config.use_ieskf = (config_or_null->use_ieskf != 0);
    }
    aether_pose_stabilizer_t* stabilizer =
        new (std::nothrow) aether_pose_stabilizer_t(config);
    if (stabilizer == nullptr) {
        return -2;
    }
    *out_stabilizer = stabilizer;
    return 0;
}

int aether_pose_stabilizer_destroy(aether_pose_stabilizer_t* stabilizer) {
    if (stabilizer == nullptr) {
        return -1;
    }
    delete stabilizer;
    return 0;
}

int aether_pose_stabilizer_reset(aether_pose_stabilizer_t* stabilizer) {
    if (stabilizer == nullptr) {
        return -1;
    }
    stabilizer->impl.reset();
    return 0;
}

int aether_pose_stabilizer_update(
    aether_pose_stabilizer_t* stabilizer,
    const float* raw_pose_16,
    const float* gyro_xyz,
    const float* accel_xyz,
    uint64_t timestamp_ns,
    float* out_stabilized_pose_16,
    float* out_pose_quality) {
    if (stabilizer == nullptr ||
        raw_pose_16 == nullptr ||
        gyro_xyz == nullptr ||
        accel_xyz == nullptr ||
        out_stabilized_pose_16 == nullptr ||
        out_pose_quality == nullptr) {
        return -1;
    }
    const Status status = stabilizer->impl.update(
        raw_pose_16,
        gyro_xyz,
        accel_xyz,
        timestamp_ns,
        out_stabilized_pose_16,
        out_pose_quality);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    aether::core::guard_finite_vector(out_stabilized_pose_16, 16u);
    aether::core::guard_finite_scalar(out_pose_quality);
    return 0;
}

int aether_pose_stabilizer_predict(
    const aether_pose_stabilizer_t* stabilizer,
    uint64_t target_timestamp_ns,
    float* out_predicted_pose_16) {
    if (stabilizer == nullptr || out_predicted_pose_16 == nullptr) {
        return -1;
    }
    const Status status = stabilizer->impl.predict(
        target_timestamp_ns,
        out_predicted_pose_16);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    aether::core::guard_finite_vector(out_predicted_pose_16, 16u);
    return 0;
}

int aether_tsdf_volume_create(aether_tsdf_volume_t** out) {
    if (!out) return -1;
    aether_tsdf_volume_t* vol = new (std::nothrow) aether_tsdf_volume_t();
    if (!vol) return -2;
    *out = vol;
    if (mesh_stability_volume_anchor() == nullptr) {
        mesh_stability_volume_anchor() = vol;
    }
    return 0;
}

int aether_tsdf_volume_destroy(aether_tsdf_volume_t* vol) {
    if (!vol) return -1;
    if (mesh_stability_volume_anchor() == vol) {
        mesh_stability_volume_anchor() = nullptr;
    }
    delete vol;
    return 0;
}

int aether_tsdf_volume_reset(aether_tsdf_volume_t* vol) {
    if (!vol) return -1;
    vol->impl.reset();
    return 0;
}

int aether_tsdf_volume_integrate(
    aether_tsdf_volume_t* vol,
    const aether_integration_input_t* input,
    aether_integration_result_t* result) {
    if (!vol || !input || !result) return -1;
    mesh_stability_volume_anchor() = vol;
    const aether::tsdf::IntegrationInput mapped = map_input(input, false);
    if (std::isfinite(mapped.timestamp) && mapped.timestamp > mesh_stability_latest_timestamp_s()) {
        mesh_stability_latest_timestamp_s() = mapped.timestamp;
    }
    aether::tsdf::IntegrationResult out{};
    const int rc = vol->impl.integrate(mapped, out);
    fill_result(out, result);
    return rc;
}

int aether_tsdf_volume_handle_thermal_state(aether_tsdf_volume_t* vol, int state) {
    if (!vol) return -1;
    vol->impl.handle_thermal_state(state);
    return 0;
}

int aether_tsdf_volume_handle_memory_pressure(aether_tsdf_volume_t* vol, int level) {
    if (!vol) return -1;
    if (level <= 0) {
        vol->impl.handle_memory_pressure_ratio(0.50f);
        return 0;
    }
    aether::tsdf::MemoryPressureLevel mapped = aether::tsdf::MemoryPressureLevel::kWarning;
    if (level == 2) mapped = aether::tsdf::MemoryPressureLevel::kCritical;
    if (level >= 3) mapped = aether::tsdf::MemoryPressureLevel::kTerminal;
    vol->impl.handle_memory_pressure(mapped);
    return 0;
}

int aether_tsdf_volume_handle_memory_pressure_ratio(aether_tsdf_volume_t* vol, float pressure_ratio) {
    if (vol == nullptr || !std::isfinite(pressure_ratio)) {
        return -1;
    }
    vol->impl.handle_memory_pressure_ratio(pressure_ratio);
    core_health_store().snapshot.memory_pressure_ratio = pressure_ratio;
    return 0;
}

int aether_tsdf_volume_apply_frame_feedback(aether_tsdf_volume_t* vol, double gpu_time_ms) {
    if (vol == nullptr || !std::isfinite(gpu_time_ms) || gpu_time_ms < 0.0) {
        return -1;
    }
    vol->impl.apply_frame_feedback(gpu_time_ms);
    return 0;
}

int aether_tsdf_volume_get_runtime_state(
    const aether_tsdf_volume_t* vol,
    aether_tsdf_runtime_state_t* out_state) {
    if (vol == nullptr || out_state == nullptr) {
        return -1;
    }
    aether::tsdf::TSDFRuntimeState runtime{};
    vol->impl.runtime_state(&runtime);
    to_c_tsdf_runtime_state(runtime, out_state);
    CoreHealthStore& health = core_health_store();
    health.snapshot.memory_water_level = out_state->memory_water_level;
    health.snapshot.memory_pressure_ratio = out_state->memory_pressure_ratio;
    health.snapshot.current_integration_skip = out_state->current_integration_skip;
    health.snapshot.hash_table_size = out_state->hash_table_size;
    health.snapshot.last_evicted_blocks = out_state->last_evicted_blocks;
    return 0;
}

int aether_tsdf_volume_set_runtime_state(
    aether_tsdf_volume_t* vol,
    const aether_tsdf_runtime_state_t* state) {
    if (vol == nullptr || state == nullptr) {
        return -1;
    }
    mesh_stability_volume_anchor() = vol;
    const aether::tsdf::TSDFRuntimeState runtime = to_cpp_tsdf_runtime_state(*state);
    vol->impl.restore_runtime_state(runtime);
    return 0;
}

int aether_tsdf_integrate(const aether_integration_input_t* input, aether_integration_result_t* result) {
    if (!input || !result) return -1;
    const aether::tsdf::IntegrationInput mapped = map_input(input, true);
    if (std::isfinite(mapped.timestamp) && mapped.timestamp > mesh_stability_latest_timestamp_s()) {
        mesh_stability_latest_timestamp_s() = mapped.timestamp;
    }
    aether::tsdf::IntegrationResult out{};
    const int rc = aether::tsdf::integrate(mapped, out);
    fill_result(out, result);
    return rc;
}

int aether_tsdf_integrate_external_blocks(
    const aether_integration_input_t* input,
    aether_external_block_t* blocks,
    int block_count,
    aether_integration_result_t* result) {
    if (input == nullptr || blocks == nullptr || result == nullptr ||
        block_count < 0 || input->depth_data == nullptr ||
        input->confidence_data == nullptr || input->view_matrix == nullptr ||
        input->depth_width <= 0 || input->depth_height <= 0 ||
        !std::isfinite(input->fx) || !std::isfinite(input->fy) ||
        !std::isfinite(input->cx) || !std::isfinite(input->cy) ||
        std::fabs(input->fx) <= 1e-8f || std::fabs(input->fy) <= 1e-8f) {
        return -1;
    }

    aether::tsdf::IntegrationResult out{};
    if (std::isfinite(input->timestamp) && input->timestamp > mesh_stability_latest_timestamp_s()) {
        mesh_stability_latest_timestamp_s() = input->timestamp;
    }

    if (input->tracking_state != 2) {
        out.success = false;
        out.skipped = true;
        out.skip_reason = aether::tsdf::IntegrationSkipReason::kTrackingLost;
        fill_result(out, result);
        return 0;
    }

    const int width = input->depth_width;
    const int height = input->depth_height;
    const float fx = input->fx;
    const float fy = input->fy;
    const float cx = input->cx;
    const float cy = input->cy;
    const float* camera_to_world = input->view_matrix;
    const float camera_x = camera_to_world[12];
    const float camera_y = camera_to_world[13];
    const float camera_z = camera_to_world[14];

    int blocks_updated = 0;
    int voxels_updated = 0;

    for (int bi = 0; bi < block_count; ++bi) {
        aether_external_block_t& block = blocks[bi];
        if (block.voxels == nullptr ||
            block.voxel_count != static_cast<uint32_t>(aether::tsdf::BLOCK_SIZE * aether::tsdf::BLOCK_SIZE * aether::tsdf::BLOCK_SIZE) ||
            !std::isfinite(block.voxel_size) || block.voxel_size <= 0.0f) {
            return -1;
        }

        const float truncation = aether::tsdf::truncation_distance(block.voxel_size);
        const float block_world_size = block.voxel_size * static_cast<float>(aether::tsdf::BLOCK_SIZE);
        bool touched = false;

        for (int x = 0; x < aether::tsdf::BLOCK_SIZE; ++x) {
            for (int y = 0; y < aether::tsdf::BLOCK_SIZE; ++y) {
                for (int z = 0; z < aether::tsdf::BLOCK_SIZE; ++z) {
                    const std::size_t voxel_index = static_cast<std::size_t>(
                        x + y * aether::tsdf::BLOCK_SIZE +
                        z * aether::tsdf::BLOCK_SIZE * aether::tsdf::BLOCK_SIZE);

                    const float wx =
                        static_cast<float>(block.x) * block_world_size +
                        (static_cast<float>(x) + 0.5f) * block.voxel_size;
                    const float wy =
                        static_cast<float>(block.y) * block_world_size +
                        (static_cast<float>(y) + 0.5f) * block.voxel_size;
                    const float wz =
                        static_cast<float>(block.z) * block_world_size +
                        (static_cast<float>(z) + 0.5f) * block.voxel_size;

                    float x_cam = 0.0f;
                    float y_cam = 0.0f;
                    float z_cam = 0.0f;
                    world_to_camera(camera_to_world, wx, wy, wz, &x_cam, &y_cam, &z_cam);
                    if (!(z_cam > 0.0f) || !std::isfinite(z_cam)) {
                        continue;
                    }

                    const int px = static_cast<int>(std::lround(fx * x_cam / z_cam + cx));
                    const int py = static_cast<int>(std::lround(fy * y_cam / z_cam + cy));
                    if (px < 0 || px >= width || py < 0 || py >= height) {
                        continue;
                    }

                    const std::size_t image_index = static_cast<std::size_t>(py * width + px);
                    const float measured_depth = input->depth_data[image_index];
                    if (!std::isfinite(measured_depth) || measured_depth < aether::tsdf::DEPTH_MIN) {
                        continue;
                    }

                    const float sdf = measured_depth - z_cam;
                    if (sdf > truncation) {
                        continue;
                    }

                    const uint8_t confidence = input->confidence_data[image_index];
                    const float w_conf = aether::tsdf::confidence_weight(confidence);
                    const float w_dist = aether::tsdf::distance_weight(z_cam);
                    const float vx = camera_x - wx;
                    const float vy = camera_y - wy;
                    const float vz = camera_z - wz;
                    const float v_len = std::sqrt(vx * vx + vy * vy + vz * vz);
                    if (!(v_len > 1e-8f) || !std::isfinite(v_len)) {
                        continue;
                    }
                    const float cosine = vy / v_len;
                    const float w_angle = aether::tsdf::viewing_angle_weight(cosine);
                    const float w_obs = w_conf * w_dist * w_angle;
                    if (!(w_obs > 0.0f) || !std::isfinite(w_obs)) {
                        continue;
                    }

                    const float sdf_normalized = clamp_unit(sdf / truncation);

                    aether_external_voxel_t& voxel = block.voxels[voxel_index];
                    const float old_weight = static_cast<float>(voxel.weight);
                    const float old_sdf = aether::math::half_to_float(voxel.sdf_bits);
                    // M2 FIX: Guard against NaN/Inf from corrupted half-float storage.
                    // Without this check, a single corrupted voxel propagates NaN to all
                    // subsequent fusions on this cell.
                    if (!std::isfinite(old_sdf)) {
                        // Reset corrupted voxel to empty state
                        voxel.sdf_bits = aether::math::float_to_half(1.0f);
                        voxel.weight = 0;
                        continue;
                    }
                    const float sum_weight = old_weight + w_obs;
                    const float new_weight = std::min(sum_weight, static_cast<float>(aether::tsdf::WEIGHT_MAX));
                    const float new_sdf = (sum_weight > 0.0f)
                        ? ((old_sdf * old_weight + sdf_normalized * w_obs) / sum_weight)
                        : sdf_normalized;

                    voxel.sdf_bits = aether::math::float_to_half(clamp_unit(new_sdf));
                    voxel.weight = static_cast<uint8_t>(std::max(
                        0,
                        std::min(
                            static_cast<int>(aether::tsdf::WEIGHT_MAX),
                            static_cast<int>(std::lround(new_weight)))));
                    voxel.confidence = std::max(voxel.confidence, confidence);
                    ++voxels_updated;
                    touched = true;
                }
            }
        }

        if (touched) {
            block.integration_generation += 1u;
            block.last_observed_timestamp = input->timestamp;
            ++blocks_updated;
        }
    }

    out.voxels_integrated = voxels_updated;
    out.blocks_updated = blocks_updated;
    out.success = true;
    out.skipped = false;
    out.skip_reason = aether::tsdf::IntegrationSkipReason::kNone;
    out.stats.voxels_updated = voxels_updated;
    out.stats.blocks_updated = blocks_updated;
    out.stats.blocks_allocated = 0;
    fill_result(out, result);
    return 0;
}

float aether_tsdf_voxel_size_near(void) {
    return aether::tsdf::VOXEL_SIZE_NEAR;
}

int aether_tsdf_block_size(void) {
    return aether::tsdf::BLOCK_SIZE;
}

int aether_query_mesh_stability(
    const aether_mesh_stability_query_t* queries,
    int query_count,
    uint64_t current_integration_generation,
    uint64_t mesh_generation,
    double staleness_threshold_s,
    aether_mesh_stability_result_t* out_result) {
    std::size_t n = 0u;
    if (queries == nullptr || out_result == nullptr || !checked_count(query_count, &n) || n == 0u) {
        return -1;
    }
    if (!std::isfinite(staleness_threshold_s) || staleness_threshold_s < 0.0) {
        return -1;
    }
    const aether_tsdf_volume_t* anchor = mesh_stability_volume_anchor();
    aether_tsdf_runtime_state_t runtime{};
    const bool has_runtime = (anchor != nullptr) && (aether_tsdf_volume_get_runtime_state(anchor, &runtime) == 0);
    const double latest_ts = mesh_stability_latest_timestamp_s();

    const uint32_t fallback_generation =
        (current_integration_generation > static_cast<uint64_t>(std::numeric_limits<uint32_t>::max()))
            ? std::numeric_limits<uint32_t>::max()
            : static_cast<uint32_t>(current_integration_generation);

    for (std::size_t i = 0u; i < n; ++i) {
        const aether_mesh_stability_query_t& q = queries[i];
        uint32_t effective_integration_generation = fallback_generation;

        if (anchor != nullptr) {
            const aether::tsdf::BlockIndex block_index{
                static_cast<std::int32_t>(q.block_x),
                static_cast<std::int32_t>(q.block_y),
                static_cast<std::int32_t>(q.block_z),
            };
            aether::tsdf::TSDFBlockRuntimeInfo block_info{};
            const bool has_block = anchor->impl.query_block_runtime_info(block_index, &block_info);
            if (has_block) {
                effective_integration_generation = block_info.integration_generation;
            }
        }

        const bool needs_re_extraction = effective_integration_generation > q.last_mesh_generation;
        const float fade_in_alpha = needs_re_extraction ? 0.0f : 1.0f;

        float eviction_weight = 1.0f;
        if (staleness_threshold_s > 0.0 &&
            has_runtime &&
            std::isfinite(runtime.last_timestamp) &&
            std::isfinite(latest_ts) &&
            latest_ts > 0.0) {
            const double age_s = runtime.last_timestamp - latest_ts;
            if (age_s > staleness_threshold_s) {
                eviction_weight = 0.0f;
            }
        }

        out_result[i].current_integration_generation = effective_integration_generation;
        out_result[i].needs_re_extraction = needs_re_extraction ? 1 : 0;
        out_result[i].fade_in_alpha = fade_in_alpha;
        out_result[i].eviction_weight = eviction_weight;
    }

    (void)mesh_generation;
    return 0;
}

// [OLD f1_build_fragment_queue and f1_animate_frame removed - see NEW implementations below]

// [OLD f3/f5/f6 implementations removed - see NEW implementations below]

int aether_gpu_scheduler_create(
    const aether_gpu_scheduler_config_t* config,
    aether_gpu_scheduler_t** out_scheduler) {
    if (out_scheduler == nullptr) {
        return -1;
    }
    aether::scheduler::GPUSchedulerConfig cpp_config{};
    if (config != nullptr) {
        cpp_config.total_frame_budget_ms = config->total_frame_budget_ms;
        cpp_config.system_reserve_ms = config->system_reserve_ms;
        cpp_config.capture_tracking_min_ms = config->capture_tracking_min_ms;
        cpp_config.capture_rendering_min_ms = config->capture_rendering_min_ms;
        cpp_config.capture_optimization_min_ms = config->capture_optimization_min_ms;
        cpp_config.finished_tracking_min_ms = config->finished_tracking_min_ms;
        cpp_config.finished_rendering_min_ms = config->finished_rendering_min_ms;
        cpp_config.finished_optimization_min_ms = config->finished_optimization_min_ms;
        if (config->capture_tracking_weight > 0.0f) cpp_config.capture_tracking_weight = config->capture_tracking_weight;
        if (config->capture_rendering_weight > 0.0f) cpp_config.capture_rendering_weight = config->capture_rendering_weight;
        if (config->capture_optimization_weight > 0.0f) cpp_config.capture_optimization_weight = config->capture_optimization_weight;
        if (config->finished_tracking_weight > 0.0f) cpp_config.finished_tracking_weight = config->finished_tracking_weight;
        if (config->finished_rendering_weight > 0.0f) cpp_config.finished_rendering_weight = config->finished_rendering_weight;
        if (config->finished_optimization_weight > 0.0f) cpp_config.finished_optimization_weight = config->finished_optimization_weight;
    }
    aether_gpu_scheduler_t* scheduler = new (std::nothrow) aether_gpu_scheduler_t(cpp_config);
    if (scheduler == nullptr) {
        return -2;
    }
    *out_scheduler = scheduler;
    return 0;
}

int aether_gpu_scheduler_destroy(aether_gpu_scheduler_t* scheduler) {
    if (scheduler == nullptr) {
        return -1;
    }
    delete scheduler;
    return 0;
}

int aether_gpu_scheduler_allocate_budget(
    const aether_gpu_scheduler_t* scheduler,
    int state,
    aether_gpu_budget_t* out_budget) {
    if (scheduler == nullptr || out_budget == nullptr) {
        return -1;
    }
    aether::scheduler::GPUSchedulerState cpp_state{};
    if (!map_scheduler_state(state, &cpp_state)) {
        return -1;
    }
    aether::scheduler::GPUBudget budget{};
    const Status status = scheduler->impl.allocate_budget(cpp_state, &budget);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out_budget->tracking_ms = budget.tracking_ms;
    out_budget->rendering_ms = budget.rendering_ms;
    out_budget->optimization_ms = budget.optimization_ms;
    out_budget->flexible_pool_ms = budget.flexible_pool_ms;
    out_budget->system_reserve_ms = budget.system_reserve_ms;
    out_budget->total_frame_budget_ms = budget.total_frame_budget_ms;
    return 0;
}

int aether_gpu_scheduler_execute_frame(
    const aether_gpu_scheduler_t* scheduler,
    int state,
    const aether_gpu_workload_t* workload,
    aether_gpu_frame_result_t* out_result) {
    if (scheduler == nullptr || workload == nullptr || out_result == nullptr) {
        return -1;
    }
    aether::scheduler::GPUSchedulerState cpp_state{};
    if (!map_scheduler_state(state, &cpp_state)) {
        return -1;
    }
    aether::scheduler::GPUWorkload cpp_workload{};
    cpp_workload.tracking_demand_ms = workload->tracking_demand_ms;
    cpp_workload.rendering_demand_ms = workload->rendering_demand_ms;
    cpp_workload.optimization_demand_ms = workload->optimization_demand_ms;

    aether::scheduler::GPUFrameResult result{};
    const Status status = scheduler->impl.execute_frame(cpp_state, cpp_workload, &result);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out_result->budget.tracking_ms = result.budget.tracking_ms;
    out_result->budget.rendering_ms = result.budget.rendering_ms;
    out_result->budget.optimization_ms = result.budget.optimization_ms;
    out_result->budget.flexible_pool_ms = result.budget.flexible_pool_ms;
    out_result->budget.system_reserve_ms = result.budget.system_reserve_ms;
    out_result->budget.total_frame_budget_ms = result.budget.total_frame_budget_ms;
    out_result->tracking_assigned_ms = result.tracking_assigned_ms;
    out_result->rendering_assigned_ms = result.rendering_assigned_ms;
    out_result->optimization_assigned_ms = result.optimization_assigned_ms;
    out_result->unused_flexible_ms = result.unused_flexible_ms;
    return 0;
}

int aether_get_core_health(aether_core_health_t* out_health) {
    if (out_health == nullptr) {
        return -1;
    }
    CoreHealthStore& store = core_health_store();
    const aether::core::NumericalHealthSnapshot counters = aether::core::numerical_health_snapshot();
    store.snapshot.nan_count = counters.nan_count;
    store.snapshot.inf_count = counters.inf_count;
    store.snapshot.guarded_scalar_count = counters.guarded_scalar_count;
    store.snapshot.guarded_vector_count = counters.guarded_vector_count;
    *out_health = store.snapshot;
    return 0;
}

int aether_reset_core_health(void) {
    core_health_store() = CoreHealthStore{};
    aether::core::reset_numerical_health_counters();
    return 0;
}

int aether_patch_display_step(
    double previous_display,
    double previous_ema,
    int observation_count,
    double target,
    int is_locked,
    const aether_patch_display_kernel_config_t* config_or_null,
    aether_patch_display_step_result_t* out_result) {
    if (out_result == nullptr) {
        return -1;
    }
    const aether::evidence::PatchDisplayKernelConfig config =
        to_cpp_patch_display_config(config_or_null);
    const aether::evidence::PatchDisplayStepResult step =
        aether::evidence::patch_display_step(
            previous_display,
            previous_ema,
            static_cast<std::int32_t>(observation_count),
            target,
            is_locked != 0,
            config,
            0.0);
    out_result->display = step.display;
    out_result->ema = step.ema;
    out_result->color_evidence = step.color_evidence;
    out_result->used_ghost_warmstart = step.used_ghost_warmstart ? 1 : 0;
    return 0;
}

int aether_patch_color_evidence(
    double local_display,
    double global_display,
    const aether_patch_display_kernel_config_t* config_or_null,
    double* out_color_evidence) {
    if (out_color_evidence == nullptr) {
        return -1;
    }
    const aether::evidence::PatchDisplayKernelConfig config =
        to_cpp_patch_display_config(config_or_null);
    *out_color_evidence = aether::evidence::patch_color_evidence(
        local_display,
        global_display,
        config);
    return 0;
}

int aether_smart_smoother_create(
    const aether_smart_smoother_config_t* config_or_null,
    aether_smart_smoother_t** out_smoother) {
    if (out_smoother == nullptr) {
        return -1;
    }
    const aether::evidence::SmartSmootherConfig config =
        to_cpp_smart_smoother_config(config_or_null);
    aether_smart_smoother_t* smoother =
        new (std::nothrow) aether_smart_smoother_t(config);
    if (smoother == nullptr) {
        return -2;
    }
    *out_smoother = smoother;
    return 0;
}

int aether_smart_smoother_destroy(aether_smart_smoother_t* smoother) {
    if (smoother == nullptr) {
        return -1;
    }
    delete smoother;
    return 0;
}

int aether_smart_smoother_reset(aether_smart_smoother_t* smoother) {
    if (smoother == nullptr) {
        return -1;
    }
    smoother->impl.reset();
    return 0;
}

int aether_smart_smoother_add(
    aether_smart_smoother_t* smoother,
    double value,
    double* out_smoothed) {
    if (smoother == nullptr || out_smoothed == nullptr) {
        return -1;
    }
    *out_smoothed = smoother->impl.add(value);
    return 0;
}

int aether_resolve_visual_style_state(
    const aether_visual_style_state_input_t* input,
    aether_visual_style_state_output_t* out_state) {
    if (input == nullptr || out_state == nullptr) {
        return -1;
    }
    const float alpha = clamp01(std::isfinite(input->smoothing_alpha) ? input->smoothing_alpha : 0.2f);
    const float freeze_threshold = clamp01(std::isfinite(input->freeze_threshold) ? input->freeze_threshold : 0.75f);
    float min_thickness = std::isfinite(input->min_thickness) ? std::max(0.0f, input->min_thickness) : 0.0005f;
    float max_thickness = std::isfinite(input->max_thickness) ? std::max(0.0f, input->max_thickness) : 0.008f;
    if (min_thickness > max_thickness) {
        std::swap(min_thickness, max_thickness);
    }

    const float current_metallic = clamp01(input->current_metallic);
    const float current_roughness = clamp01(input->current_roughness);
    const float current_thickness = std::max(min_thickness, std::min(max_thickness, input->current_thickness));

    float metallic = current_metallic;
    float roughness = current_roughness;
    float thickness = current_thickness;
    if (input->has_previous != 0) {
        const float prev_metallic = clamp01(input->previous_metallic);
        const float prev_roughness = clamp01(input->previous_roughness);
        const float prev_thickness = std::max(min_thickness, std::min(max_thickness, input->previous_thickness));

        metallic = prev_metallic + alpha * (current_metallic - prev_metallic);
        roughness = prev_roughness + alpha * (current_roughness - prev_roughness);
        thickness = prev_thickness + alpha * (current_thickness - prev_thickness);

        metallic = std::max(prev_metallic, metallic);
        roughness = std::min(prev_roughness, roughness);
        thickness = std::min(prev_thickness, thickness);

        if (input->is_frozen != 0) {
            metallic = prev_metallic;
            roughness = prev_roughness;
            thickness = prev_thickness;
        }
    }

    metallic = clamp01(metallic);
    roughness = clamp01(roughness);
    thickness = std::max(min_thickness, std::min(max_thickness, thickness));

    const float previous_display = clamp01(input->previous_display);
    const float current_display = clamp01(input->current_display);
    const int should_freeze =
        (input->is_frozen != 0 || std::max(previous_display, current_display) >= freeze_threshold) ? 1 : 0;

    out_state->metallic = metallic;
    out_state->roughness = roughness;
    out_state->thickness = thickness;
    out_state->should_freeze = should_freeze;
    return 0;
}

int aether_resolve_border_style_state(
    const aether_border_style_state_input_t* input,
    aether_border_style_state_output_t* out_state) {
    if (input == nullptr || out_state == nullptr) {
        return -1;
    }
    float min_width = std::isfinite(input->min_width) ? std::max(0.0f, input->min_width) : 1.0f;
    float max_width = std::isfinite(input->max_width) ? std::max(0.0f, input->max_width) : 12.0f;
    if (min_width > max_width) {
        std::swap(min_width, max_width);
    }
    const float freeze_threshold = clamp01(std::isfinite(input->freeze_threshold) ? input->freeze_threshold : 0.75f);

    float width = std::max(min_width, std::min(max_width, input->current_width));
    if (input->has_previous != 0) {
        const float prev_width = std::max(min_width, std::min(max_width, input->previous_width));
        width = std::min(prev_width, width);
        if (input->is_frozen != 0) {
            width = prev_width;
        }
    }

    const float previous_display = clamp01(input->previous_display);
    const float current_display = clamp01(input->current_display);
    const int should_freeze =
        (input->is_frozen != 0 || std::max(previous_display, current_display) >= freeze_threshold) ? 1 : 0;

    out_state->width = std::max(min_width, std::min(max_width, width));
    out_state->should_freeze = should_freeze;
    return 0;
}

int aether_resolve_visual_style_state_batch(
    const aether_visual_style_state_input_t* inputs,
    int input_count,
    aether_visual_style_state_output_t* out_states) {
    std::size_t count = 0u;
    if (!checked_count(input_count, &count) || inputs == nullptr || out_states == nullptr) {
        return -1;
    }
    for (std::size_t i = 0u; i < count; ++i) {
        const int rc = aether_resolve_visual_style_state(&inputs[i], &out_states[i]);
        if (rc != 0) {
            return rc;
        }
    }
    return 0;
}

int aether_resolve_border_style_state_batch(
    const aether_border_style_state_input_t* inputs,
    int input_count,
    aether_border_style_state_output_t* out_states) {
    std::size_t count = 0u;
    if (!checked_count(input_count, &count) || inputs == nullptr || out_states == nullptr) {
        return -1;
    }
    for (std::size_t i = 0u; i < count; ++i) {
        const int rc = aether_resolve_border_style_state(&inputs[i], &out_states[i]);
        if (rc != 0) {
            return rc;
        }
    }
    return 0;
}

int aether_capture_style_runtime_default_config(
    aether_capture_style_runtime_config_t* out_config) {
    if (out_config == nullptr) {
        return -1;
    }
    *out_config = capture_style_default_config();
    return 0;
}

int aether_capture_style_runtime_create(
    const aether_capture_style_runtime_config_t* config_or_null,
    aether_capture_style_runtime_t** out_runtime) {
    if (out_runtime == nullptr) {
        return -1;
    }
    const aether_capture_style_runtime_config_t config = sanitize_capture_style_config(config_or_null);
    aether_capture_style_runtime_t* runtime =
        new (std::nothrow) aether_capture_style_runtime_t(config);
    if (runtime == nullptr) {
        return -2;
    }
    *out_runtime = runtime;
    return 0;
}

int aether_capture_style_runtime_destroy(aether_capture_style_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    delete runtime;
    return 0;
}

int aether_capture_style_runtime_reset(aether_capture_style_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    runtime->states.clear();
    return 0;
}

int aether_capture_style_runtime_resolve(
    aether_capture_style_runtime_t* runtime,
    const aether_capture_style_input_t* inputs,
    int input_count,
    aether_capture_style_output_t* out_states) {
    std::size_t count = 0u;
    if (!checked_count(input_count, &count) || runtime == nullptr || inputs == nullptr || out_states == nullptr) {
        return -1;
    }
    const aether_capture_style_runtime_config_t& config = runtime->config;

    for (std::size_t i = 0u; i < count; ++i) {
        const aether_capture_style_input_t& in = inputs[i];
        aether_capture_style_runtime_t::PatchState& state = runtime->states[in.patch_key];

        const float current_display = clamp01(std::isfinite(in.display) ? in.display : 0.0f);
        const float alpha = clamp01(config.smoothing_alpha);
        float resolved_display = current_display;
        if (state.has_visual) {
            resolved_display = state.display + alpha * (current_display - state.display);
            resolved_display = std::max(state.display, clamp01(resolved_display));
        }

        const float area_sq_m = std::max(
            config.min_area_sq_m,
            std::isfinite(in.area_sq_m) ? in.area_sq_m : config.min_area_sq_m);
        const aether::render::FragmentVisualParams params = aether::render::compute_visual_params(
            resolved_display,
            1.0f,
            area_sq_m,
            std::max(area_sq_m, config.min_median_area_sq_m));

        float metallic = clamp01(params.metallic);
        float roughness = clamp01(params.roughness);
        float thickness = std::max(
            config.min_thickness,
            std::min(config.max_thickness, params.wedge_thickness));
        float border_width = std::max(
            config.min_border_width,
            std::min(config.max_border_width, params.border_width_px));
        float border_alpha = clamp01(params.border_alpha);
        float grayscale = clamp01(params.fill_gray);

        if (state.has_visual) {
            metallic = std::max(state.metallic, metallic);
            roughness = std::min(state.roughness, roughness);
            thickness = std::min(state.thickness, thickness);
            grayscale = std::max(state.grayscale, grayscale);
        }
        if (state.has_border) {
            border_width = std::min(state.border_width, border_width);
            border_alpha = std::min(state.border_alpha, border_alpha);
        }

        const bool visual_should_freeze =
            (resolved_display >= config.freeze_threshold) || state.visual_frozen;
        const bool border_should_freeze =
            (resolved_display >= config.freeze_threshold) || state.border_frozen;
        if (visual_should_freeze) {
            state.visual_frozen = true;
        }
        if (border_should_freeze) {
            state.border_frozen = true;
        }

        state.display = resolved_display;
        state.metallic = metallic;
        state.roughness = roughness;
        state.thickness = thickness;
        state.border_width = border_width;
        state.border_alpha = border_alpha;
        state.grayscale = grayscale;
        state.has_visual = true;
        state.has_border = true;
        state.has_grayscale = true;

        aether_capture_style_output_t out{};
        out.resolved_display = resolved_display;
        out.metallic = metallic;
        out.roughness = roughness;
        out.thickness = thickness;
        out.border_width = border_width;
        out.border_alpha = border_alpha;
        out.grayscale = grayscale;
        out.ripple_min_amplitude = std::max(0.0f, 0.015f + 0.02f * (1.0f - resolved_display));
        out.ripple_boost_scale = std::max(0.0f, 0.10f + 0.20f * (1.0f - resolved_display));
        out.fill_dither_start = 0.90f;
        out.fill_dither_end = 0.985f;
        out.border_min_width_px = 0.0f;
        out.border_min_alpha = 0.0f;
        out.border_aa_factor = 1.25f;
        out.border_fwidth_epsilon = 1e-4f;
        out.border_discard_alpha = 0.002f;
        out.visual_frozen = state.visual_frozen ? 1 : 0;
        out.border_frozen = state.border_frozen ? 1 : 0;
        out.visual_should_freeze = visual_should_freeze ? 1 : 0;
        out.border_should_freeze = border_should_freeze ? 1 : 0;
        out_states[i] = out;
    }
    return 0;
}

int aether_capture_style_resolve_stateless(
    const aether_capture_style_runtime_config_t* config_or_null,
    const aether_capture_style_input_t* inputs,
    int input_count,
    float median_area_sq_m,
    aether_capture_style_output_t* out_states) {
    std::size_t count = 0u;
    if (!checked_count(input_count, &count) || inputs == nullptr || out_states == nullptr) {
        return -1;
    }
    const aether_capture_style_runtime_config_t config = sanitize_capture_style_config(config_or_null);
    const float safe_median = std::max(
        config.min_median_area_sq_m,
        std::isfinite(median_area_sq_m) ? median_area_sq_m : config.min_median_area_sq_m);

    for (std::size_t i = 0u; i < count; ++i) {
        const aether_capture_style_input_t& in = inputs[i];
        const float resolved_display = clamp01(std::isfinite(in.display) ? in.display : 0.0f);
        const float area_sq_m = std::max(
            config.min_area_sq_m,
            std::isfinite(in.area_sq_m) ? in.area_sq_m : config.min_area_sq_m);
        const aether::render::FragmentVisualParams params = aether::render::compute_visual_params(
            resolved_display,
            1.0f,
            area_sq_m,
            std::max(area_sq_m, safe_median));

        aether_capture_style_output_t out{};
        out.resolved_display = resolved_display;
        out.metallic = clamp01(params.metallic);
        out.roughness = clamp01(params.roughness);
        out.thickness = std::max(config.min_thickness, std::min(config.max_thickness, params.wedge_thickness));
        out.border_width = std::max(
            config.min_border_width,
            std::min(config.max_border_width, params.border_width_px));
        out.border_alpha = clamp01(params.border_alpha);
        out.grayscale = clamp01(params.fill_gray);
        out.ripple_min_amplitude = std::max(0.0f, 0.015f + 0.02f * (1.0f - resolved_display));
        out.ripple_boost_scale = std::max(0.0f, 0.10f + 0.20f * (1.0f - resolved_display));
        out.fill_dither_start = 0.90f;
        out.fill_dither_end = 0.985f;
        out.border_min_width_px = 0.0f;
        out.border_min_alpha = 0.0f;
        out.border_aa_factor = 1.25f;
        out.border_fwidth_epsilon = 1e-4f;
        out.border_discard_alpha = 0.002f;
        out.visual_frozen = 0;
        out.border_frozen = 0;
        out.visual_should_freeze = (resolved_display >= config.freeze_threshold) ? 1 : 0;
        out.border_should_freeze = (resolved_display >= config.freeze_threshold) ? 1 : 0;
        out_states[i] = out;
    }
    return 0;
}

int aether_hash_fnv1a32(
    const uint8_t* bytes,
    int byte_count,
    uint32_t* out_hash) {
    if (out_hash == nullptr || byte_count < 0 || (byte_count > 0 && bytes == nullptr)) {
        return -1;
    }
    std::uint32_t hash = 2166136261u;
    for (int i = 0; i < byte_count; ++i) {
        hash ^= static_cast<std::uint32_t>(bytes[i]);
        hash *= 16777619u;
    }
    *out_hash = hash;
    return 0;
}

int aether_hash_fnv1a64(
    const uint8_t* bytes,
    int byte_count,
    uint64_t* out_hash) {
    if (out_hash == nullptr || byte_count < 0 || (byte_count > 0 && bytes == nullptr)) {
        return -1;
    }
    std::uint64_t hash = 1469598103934665603ull;
    for (int i = 0; i < byte_count; ++i) {
        hash ^= static_cast<std::uint64_t>(bytes[i]);
        hash *= 1099511628211ull;
    }
    *out_hash = hash;
    return 0;
}

int aether_scan_triangle_longest_edge(
    const aether_scan_triangle_t* triangle,
    aether_float3_t* out_start,
    aether_float3_t* out_end,
    float* out_length_sq) {
    if (triangle == nullptr || out_start == nullptr || out_end == nullptr || out_length_sq == nullptr) {
        return -1;
    }
    const aether_float3_t verts[3] = {triangle->a, triangle->b, triangle->c};
    const int edge_pairs[3][2] = {{0, 1}, {1, 2}, {2, 0}};
    int best_edge = 0;
    float best_len_sq = -1.0f;
    for (int i = 0; i < 3; ++i) {
        const aether_float3_t a = verts[edge_pairs[i][0]];
        const aether_float3_t b = verts[edge_pairs[i][1]];
        const float dx = a.x - b.x;
        const float dy = a.y - b.y;
        const float dz = a.z - b.z;
        const float len_sq = dx * dx + dy * dy + dz * dz;
        if (len_sq > best_len_sq) {
            best_len_sq = len_sq;
            best_edge = i;
        }
    }
    *out_start = verts[edge_pairs[best_edge][0]];
    *out_end = verts[edge_pairs[best_edge][1]];
    *out_length_sq = std::max(0.0f, best_len_sq);
    return 0;
}

int aether_generate_fracture_display_triangles(
    const aether_fracture_input_triangle_t* triangles,
    int triangle_count,
    aether_fracture_output_triangle_t* out_triangles,
    int* inout_triangle_count) {
    std::size_t tri_count = 0u;
    if (!checked_count(triangle_count, &tri_count) || inout_triangle_count == nullptr) {
        return -1;
    }
    if (tri_count == 0u) {
        *inout_triangle_count = 0;
        return 0;
    }
    if (triangles == nullptr) {
        return -1;
    }

    struct ParsedCandidate {
        std::size_t index{0u};
        float score{0.0f};
    };

    std::vector<ParsedCandidate> scored_candidates;
    scored_candidates.reserve(tri_count);
    std::vector<uint8_t> selected_mask(tri_count, 0u);
    std::unordered_map<std::uint64_t, ParsedCandidate> best_by_cell;
    best_by_cell.reserve(tri_count);

    for (std::size_t i = 0u; i < tri_count; ++i) {
        const aether_fracture_input_triangle_t& in = triangles[i];
        const aether::innovation::Float3 v0 = to_cpp_float3(in.v0);
        const aether::innovation::Float3 v1 = to_cpp_float3(in.v1);
        const aether::innovation::Float3 v2 = to_cpp_float3(in.v2);

        float area = in.area_sq_m;
        if (!std::isfinite(area) || area <= 1e-12f) {
            area = aether::innovation::triangle_area(v0, v1, v2);
        }
        if (!std::isfinite(area) || area <= 1e-12f) {
            continue;
        }

        const float display = std::max(0.0f, std::min(1.0f, in.display));
        const float depth = (std::isfinite(in.depth) && in.depth > 0.0f) ? in.depth : 1.0f;
        const float depth_norm = std::max(0.0f, std::min(1.0f, (depth - 0.25f) / 1.75f));
        const float detail = std::max(0.0f, std::min(1.0f, 0.80f * display + 0.20f * (1.0f - depth_norm)));
        const float area_term = std::sqrt(std::max(area, 1e-8f));
        const float score = 1.35f * detail + 0.35f * area_term;
        scored_candidates.push_back(ParsedCandidate{i, score});

        // Sparse sampling for distant low-evidence regions to remove "grid wall" look.
        const float keep_ratio = std::max(0.02f, std::min(1.0f, 0.02f + 0.98f * detail * detail));
        const std::uint64_t keep_seed = aether::innovation::splitmix64(
            (in.patch_key != 0u ? in.patch_key : static_cast<std::uint64_t>(i + 1u))
            ^ (static_cast<std::uint64_t>(i + 1u) * 0x9E3779B97F4A7C15ULL));
        const float keep_roll =
            static_cast<float>(keep_seed & 0x00FFFFFFu) / static_cast<float>(0x00FFFFFFu);
        if (keep_roll > keep_ratio) {
            continue;
        }

        const aether::innovation::Float3 centroid = aether::innovation::make_float3(
            (v0.x + v1.x + v2.x) / 3.0f,
            (v0.y + v1.y + v2.y) / 3.0f,
            (v0.z + v1.z + v2.z) / 3.0f);
        const float cell_size = std::max(0.03f, std::min(0.35f, 0.35f - 0.32f * detail));
        const int32_t qx = static_cast<int32_t>(std::floor(centroid.x / cell_size));
        const int32_t qy = static_cast<int32_t>(std::floor(centroid.y / cell_size));
        const int32_t qz = static_cast<int32_t>(std::floor(centroid.z / cell_size));
        const std::uint64_t packed = (static_cast<std::uint64_t>(static_cast<uint32_t>(qx)) << 42u) ^
                                     (static_cast<std::uint64_t>(static_cast<uint32_t>(qy)) << 21u) ^
                                     static_cast<std::uint64_t>(static_cast<uint32_t>(qz));
        const std::uint64_t cell_key =
            aether::innovation::splitmix64(packed ^ (static_cast<std::uint64_t>(std::lround((1.0f - detail) * 7.0f)) << 58u));

        auto cell_it = best_by_cell.find(cell_key);
        if (cell_it == best_by_cell.end() || score > cell_it->second.score) {
            best_by_cell[cell_key] = ParsedCandidate{i, score};
        }
    }

    for (const auto& item : best_by_cell) {
        const std::size_t index = item.second.index;
        if (index < tri_count) {
            selected_mask[index] = 1u;
        }
    }

    std::size_t selected_count = 0u;
    for (std::size_t i = 0u; i < tri_count; ++i) {
        if (selected_mask[i] != 0u) {
            ++selected_count;
        }
    }

    const std::size_t min_keep = std::min<std::size_t>(tri_count, 96u);
    if (selected_count < min_keep) {
        std::sort(
            scored_candidates.begin(),
            scored_candidates.end(),
            [](const ParsedCandidate& a, const ParsedCandidate& b) {
                if (a.score != b.score) {
                    return a.score > b.score;
                }
                return a.index < b.index;
            });
        for (const ParsedCandidate& candidate : scored_candidates) {
            if (selected_count >= min_keep) {
                break;
            }
            if (candidate.index >= tri_count || selected_mask[candidate.index] != 0u) {
                continue;
            }
            selected_mask[candidate.index] = 1u;
            ++selected_count;
        }
    }

    std::vector<aether::innovation::ScaffoldVertex> cpp_vertices;
    std::vector<aether::innovation::ScaffoldUnit> cpp_units;
    std::vector<float> displays;
    std::vector<float> depths;
    std::vector<std::uint64_t> unit_patch_keys;
    std::vector<std::uint32_t> unit_parent_indices;
    cpp_vertices.reserve(selected_count * 3u);
    cpp_units.reserve(selected_count);
    displays.reserve(selected_count);
    depths.reserve(selected_count);
    unit_patch_keys.reserve(selected_count);
    unit_parent_indices.reserve(selected_count);

    for (std::size_t i = 0u; i < tri_count; ++i) {
        if (selected_mask[i] == 0u) {
            continue;
        }
        const aether_fracture_input_triangle_t& in = triangles[i];
        const aether::innovation::Float3 v0 = to_cpp_float3(in.v0);
        const aether::innovation::Float3 v1 = to_cpp_float3(in.v1);
        const aether::innovation::Float3 v2 = to_cpp_float3(in.v2);
        float area = in.area_sq_m;
        if (!std::isfinite(area) || area <= 1e-12f) {
            area = aether::innovation::triangle_area(v0, v1, v2);
        }
        if (!std::isfinite(area) || area <= 1e-12f) {
            continue;
        }

        aether::innovation::Float3 normal = to_cpp_float3(in.normal);
        if (!std::isfinite(normal.x) || !std::isfinite(normal.y) || !std::isfinite(normal.z) ||
            aether::innovation::length_sq(normal) <= 1e-12f) {
            normal = aether::innovation::triangle_normal(v0, v1, v2);
        }
        if (!std::isfinite(normal.x) || !std::isfinite(normal.y) || !std::isfinite(normal.z) ||
            aether::innovation::length_sq(normal) <= 1e-12f) {
            normal = aether::innovation::make_float3(0.0f, 0.0f, 1.0f);
        }

        const std::size_t base = cpp_vertices.size();
        if (base > static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max() - 3u)) {
            return -1;
        }
        cpp_vertices.push_back(aether::innovation::ScaffoldVertex{
            static_cast<std::uint32_t>(base + 0u), v0});
        cpp_vertices.push_back(aether::innovation::ScaffoldVertex{
            static_cast<std::uint32_t>(base + 1u), v1});
        cpp_vertices.push_back(aether::innovation::ScaffoldVertex{
            static_cast<std::uint32_t>(base + 2u), v2});

        const std::uint64_t seed = in.patch_key != 0u
            ? in.patch_key
            : static_cast<std::uint64_t>(i + 1u);
        const std::uint64_t unit_id = aether::innovation::splitmix64(
            seed ^ (static_cast<std::uint64_t>(i + 1u) * 0x9E3779B97F4A7C15ULL));

        aether::innovation::ScaffoldUnit unit{};
        unit.unit_id = unit_id;
        unit.generation = 0u;
        unit.v0 = static_cast<std::uint32_t>(base + 0u);
        unit.v1 = static_cast<std::uint32_t>(base + 1u);
        unit.v2 = static_cast<std::uint32_t>(base + 2u);
        unit.area = area;
        unit.normal = normal;
        unit.confidence = std::max(0.0f, std::min(1.0f, in.display));
        unit.view_count = 1u;
        unit.lod_level = 0u;

        cpp_units.push_back(unit);
        displays.push_back(std::max(0.0f, std::min(1.0f, in.display)));
        depths.push_back((std::isfinite(in.depth) && in.depth > 0.0f) ? in.depth : 1.0f);
        unit_patch_keys.push_back(in.patch_key);
        unit_parent_indices.push_back(static_cast<std::uint32_t>(i));
    }

    if (cpp_units.empty()) {
        *inout_triangle_count = 0;
        return 0;
    }

    std::vector<aether::innovation::DisplayFragment> fragments;
    const Status fracture_status = aether::render::generate_fracture_fragments(
        cpp_units.data(),
        cpp_units.size(),
        cpp_vertices.data(),
        cpp_vertices.size(),
        displays.data(),
        depths.data(),
        &fragments);
    if (fracture_status != Status::kOk && fracture_status != Status::kOutOfRange) {
        return to_rc(fracture_status);
    }

    std::unordered_map<std::uint64_t, std::size_t> unit_index;
    unit_index.reserve(cpp_units.size());
    for (std::size_t i = 0u; i < cpp_units.size(); ++i) {
        unit_index[cpp_units[i].unit_id] = i;
    }

    int required = 0;
    for (const aether::innovation::DisplayFragment& fragment : fragments) {
        if (fragment.vertex_count < 3u) {
            continue;
        }
        if (unit_index.find(fragment.parent_unit_id) == unit_index.end()) {
            continue;
        }
        required += static_cast<int>(fragment.vertex_count) - 2;
    }

    if (out_triangles == nullptr || *inout_triangle_count < required) {
        *inout_triangle_count = required;
        return -3;
    }

    int write_index = 0;
    for (const aether::innovation::DisplayFragment& fragment : fragments) {
        if (fragment.vertex_count < 3u) {
            continue;
        }
        const auto unit_it = unit_index.find(fragment.parent_unit_id);
        if (unit_it == unit_index.end()) {
            continue;
        }
        const std::size_t unit_slot = unit_it->second;
        const std::uint64_t patch_key = unit_patch_keys[unit_slot];
        const std::uint32_t parent_index = unit_parent_indices[unit_slot];
        const std::uint8_t vcount = fragment.vertex_count;
        for (std::uint8_t i = 1u; i + 1u < vcount; ++i) {
            const aether::innovation::Float3 a = fragment.vertices[0];
            const aether::innovation::Float3 b = fragment.vertices[i];
            const aether::innovation::Float3 c = fragment.vertices[i + 1u];
            const float area = aether::innovation::triangle_area(a, b, c);
            if (!std::isfinite(area) || area <= 1e-12f) {
                continue;
            }

            aether::innovation::Float3 normal = fragment.normal;
            if (!std::isfinite(normal.x) || !std::isfinite(normal.y) || !std::isfinite(normal.z) ||
                aether::innovation::length_sq(normal) <= 1e-12f) {
                normal = aether::innovation::triangle_normal(a, b, c);
            }
            if (!std::isfinite(normal.x) || !std::isfinite(normal.y) || !std::isfinite(normal.z) ||
                aether::innovation::length_sq(normal) <= 1e-12f) {
                normal = aether::innovation::make_float3(0.0f, 0.0f, 1.0f);
            }

            aether_fracture_output_triangle_t out{};
            out.patch_key = patch_key;
            out.parent_triangle_index = parent_index;
            out.fragment_index = static_cast<std::uint32_t>(fragment.sub_index * 8u + i - 1u);
            out.v0 = to_c_float3(a);
            out.v1 = to_c_float3(b);
            out.v2 = to_c_float3(c);
            out.normal = to_c_float3(normal);
            out.display = std::max(0.0f, std::min(1.0f, fragment.display));
            out.area_sq_m = area;
            out.gap_shrink = std::max(0.0f, std::min(1.0f, fragment.gap_shrink));
            out.crack_seed = std::max(0.0f, std::min(1.0f, fragment.crack_seed));
            out_triangles[write_index++] = out;
        }
    }

    *inout_triangle_count = write_index;
    return 0;
}

int aether_generate_wedge_geometry(
    const aether_wedge_input_triangle_t* triangles,
    int triangle_count,
    int lod_level,
    aether_wedge_vertex_t* out_vertices,
    int* inout_vertex_count,
    uint32_t* out_indices,
    int* inout_index_count) {
    std::size_t tri_count = 0u;
    if (!checked_count(triangle_count, &tri_count) ||
        inout_vertex_count == nullptr ||
        inout_index_count == nullptr ||
        (tri_count > 0u && triangles == nullptr)) {
        return -1;
    }
    const aether::render::WedgeLodLevel lod = to_cpp_wedge_lod_level(lod_level);
    if (static_cast<int>(lod) < 0) {
        return -1;
    }

    std::vector<aether::render::WedgeTriangleInput> cpp_triangles;
    cpp_triangles.reserve(tri_count);
    for (std::size_t i = 0u; i < tri_count; ++i) {
        cpp_triangles.push_back(to_cpp_wedge_triangle(triangles[i]));
    }
    std::vector<aether::render::WedgeVertex> vertices;
    std::vector<std::uint32_t> indices;
    const Status st = aether::render::generate_wedge_geometry(
        cpp_triangles.data(),
        cpp_triangles.size(),
        lod,
        &vertices,
        &indices);
    if (st != Status::kOk) {
        return to_rc(st);
    }

    const int required_vertices = static_cast<int>(vertices.size());
    const int required_indices = static_cast<int>(indices.size());
    if (out_vertices == nullptr || out_indices == nullptr ||
        *inout_vertex_count < required_vertices ||
        *inout_index_count < required_indices) {
        *inout_vertex_count = required_vertices;
        *inout_index_count = required_indices;
        return -3;
    }
    for (int i = 0; i < required_vertices; ++i) {
        to_c_wedge_vertex(vertices[static_cast<std::size_t>(i)], &out_vertices[i]);
    }
    std::copy(indices.begin(), indices.end(), out_indices);
    *inout_vertex_count = required_vertices;
    *inout_index_count = required_indices;
    return 0;
}

int aether_compute_fragment_visual_params(
    float display,
    float depth,
    float triangle_area,
    float median_area,
    aether_fragment_visual_params_t* out_params) {
    if (out_params == nullptr) {
        return -1;
    }
    const aether::render::FragmentVisualParams params =
        aether::render::compute_visual_params(display, depth, triangle_area, median_area);
    out_params->edge_length = params.edge_length;
    out_params->gap_width = params.gap_width;
    out_params->fill_opacity = params.fill_opacity;
    out_params->fill_gray = params.fill_gray;
    out_params->border_width_px = params.border_width_px;
    out_params->border_alpha = params.border_alpha;
    out_params->metallic = params.metallic;
    out_params->roughness = params.roughness;
    out_params->wedge_thickness = params.wedge_thickness;
    return 0;
}

int aether_compute_bevel_normals(
    aether_float3_t top_face_normal,
    aether_float3_t side_face_normal,
    int segments,
    aether_float3_t* out_normals,
    int* inout_normal_count) {
    if (segments < 0 || inout_normal_count == nullptr) {
        return -1;
    }
    const int required = segments + 1;
    if (out_normals == nullptr || *inout_normal_count < required) {
        *inout_normal_count = required;
        return -3;
    }
    const float tx = top_face_normal.x;
    const float ty = top_face_normal.y;
    const float tz = top_face_normal.z;
    const float sx = side_face_normal.x;
    const float sy = side_face_normal.y;
    const float sz = side_face_normal.z;
    const int denom = std::max(1, segments);
    for (int i = 0; i <= segments; ++i) {
        const float t = static_cast<float>(i) / static_cast<float>(denom);
        float nx = tx + (sx - tx) * t;
        float ny = ty + (sy - ty) * t;
        float nz = tz + (sz - tz) * t;
        const float len = std::sqrt(nx * nx + ny * ny + nz * nz);
        if (len > 1e-8f && std::isfinite(len)) {
            nx /= len;
            ny /= len;
            nz /= len;
        } else {
            nx = 0.0f;
            ny = 0.0f;
            nz = 1.0f;
        }
        out_normals[i] = aether_float3_t{nx, ny, nz};
    }
    *inout_normal_count = required;
    return 0;
}

float aether_flip_easing(float t, const aether_flip_easing_config_t* config_or_null) {
    return aether::render::flip_easing(t, to_cpp_flip_easing_config(config_or_null));
}

int aether_compute_flip_states(
    const aether_flip_animation_state_t* active_flips,
    int flip_count,
    float current_time,
    const aether_flip_easing_config_t* config_or_null,
    const aether_float3_t* rest_normals_or_null,
    aether_flip_animation_state_t* out_states) {
    std::size_t count = 0u;
    if (!checked_count(flip_count, &count) ||
        active_flips == nullptr ||
        out_states == nullptr) {
        return -1;
    }
    std::vector<aether::render::FlipAnimationState> in(count);
    std::vector<aether::render::FlipAnimationState> out(count);
    std::vector<aether::innovation::Float3> rest_normals;
    if (rest_normals_or_null != nullptr) {
        rest_normals.resize(count);
    }
    for (std::size_t i = 0u; i < count; ++i) {
        in[i] = to_cpp_flip_state(active_flips[i]);
        if (rest_normals_or_null != nullptr) {
            rest_normals[i] = aether::innovation::make_float3(
                rest_normals_or_null[i].x,
                rest_normals_or_null[i].y,
                rest_normals_or_null[i].z);
        }
    }
    aether::render::compute_flip_states(
        in.data(),
        count,
        current_time,
        to_cpp_flip_easing_config(config_or_null),
        rest_normals_or_null != nullptr ? rest_normals.data() : nullptr,
        out.data());
    for (std::size_t i = 0u; i < count; ++i) {
        to_c_flip_state(out[i], &out_states[i]);
    }
    return 0;
}

int aether_flip_runtime_default_config(aether_flip_runtime_config_t* out_config) {
    if (out_config == nullptr) {
        return -1;
    }
    *out_config = flip_runtime_default_config();
    return 0;
}

int aether_flip_runtime_create(
    const aether_flip_runtime_config_t* config_or_null,
    aether_flip_runtime_t** out_runtime) {
    if (out_runtime == nullptr) {
        return -1;
    }
    const aether_flip_runtime_config_t config = sanitize_flip_runtime_config(config_or_null);
    aether_flip_runtime_t* runtime = new (std::nothrow) aether_flip_runtime_t(config);
    if (runtime == nullptr) {
        return -2;
    }
    *out_runtime = runtime;
    return 0;
}

int aether_flip_runtime_destroy(aether_flip_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    delete runtime;
    return 0;
}

int aether_flip_runtime_reset(aether_flip_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    runtime->active.clear();
    return 0;
}

int aether_flip_runtime_ingest(
    aether_flip_runtime_t* runtime,
    const aether_flip_runtime_observation_t* observations,
    int observation_count,
    double now_s,
    int32_t* out_crossed_triangle_ids,
    int* inout_crossed_count) {
    std::size_t count = 0u;
    if (!checked_count(observation_count, &count) ||
        runtime == nullptr ||
        observations == nullptr ||
        inout_crossed_count == nullptr ||
        !std::isfinite(now_s)) {
        return -1;
    }

    std::vector<int32_t> crossed;
    crossed.reserve(count);
    for (std::size_t i = 0u; i < count; ++i) {
        const aether_flip_runtime_observation_t& obs = observations[i];
        if (obs.triangle_id < 0) {
            continue;
        }
        if (runtime->active.find(obs.triangle_id) != runtime->active.end()) {
            continue;
        }
        const float previous_display = clamp01(obs.previous_display);
        const float current_display = clamp01(obs.current_display);
        if (current_display - previous_display < runtime->config.min_display_delta) {
            continue;
        }
        if (!flip_runtime_crossed_threshold(runtime->config, previous_display, current_display)) {
            continue;
        }
        const aether::innovation::Float3 axis_origin = aether::innovation::make_float3(
            obs.axis_start.x, obs.axis_start.y, obs.axis_start.z);
        const aether::innovation::Float3 axis_end = aether::innovation::make_float3(
            obs.axis_end.x, obs.axis_end.y, obs.axis_end.z);
        const aether::innovation::Float3 axis_dir = normalize_direction_or_default(
            aether::innovation::sub(axis_end, axis_origin),
            aether::innovation::make_float3(1.0f, 0.0f, 0.0f));
        runtime->active[obs.triangle_id] = aether_flip_runtime_t::ActiveFlip{
            now_s,
            axis_origin,
            axis_dir};
        crossed.push_back(obs.triangle_id);
    }

    if (out_crossed_triangle_ids == nullptr || *inout_crossed_count < static_cast<int>(crossed.size())) {
        *inout_crossed_count = static_cast<int>(crossed.size());
        return -3;
    }
    for (std::size_t i = 0u; i < crossed.size(); ++i) {
        out_crossed_triangle_ids[i] = crossed[i];
    }
    *inout_crossed_count = static_cast<int>(crossed.size());
    return 0;
}

int aether_flip_runtime_sample(
    const aether_flip_runtime_t* runtime,
    const int32_t* triangle_ids,
    int triangle_count,
    double now_s,
    float* out_angles,
    aether_float3_t* out_axis_origins,
    aether_float3_t* out_axis_directions) {
    std::size_t count = 0u;
    if (!checked_count(triangle_count, &count) ||
        runtime == nullptr ||
        triangle_ids == nullptr ||
        out_angles == nullptr ||
        !std::isfinite(now_s)) {
        return -1;
    }
    const float duration = flip_runtime_duration_s(runtime->config);
    for (std::size_t i = 0u; i < count; ++i) {
        const auto it = runtime->active.find(triangle_ids[i]);
        if (it == runtime->active.end()) {
            out_angles[i] = 0.0f;
            if (out_axis_origins != nullptr) {
                out_axis_origins[i] = aether_float3_t{0.0f, 0.0f, 0.0f};
            }
            if (out_axis_directions != nullptr) {
                out_axis_directions[i] = aether_float3_t{1.0f, 0.0f, 0.0f};
            }
            continue;
        }
        const aether_flip_runtime_t::ActiveFlip& active = it->second;
        const float progress = static_cast<float>((now_s - active.start_time_s) / duration);
        const float eased = aether::render::flip_easing(progress, to_cpp_flip_easing_config(&runtime->config.easing));
        const float angle = std::max(0.0f, std::min(kPiF, std::max(0.0f, std::min(1.0f, eased)) * kPiF));
        out_angles[i] = angle;
        if (out_axis_origins != nullptr) {
            out_axis_origins[i] = aether_float3_t{active.axis_origin.x, active.axis_origin.y, active.axis_origin.z};
        }
        if (out_axis_directions != nullptr) {
            out_axis_directions[i] = aether_float3_t{active.axis_direction.x, active.axis_direction.y, active.axis_direction.z};
        }
    }
    return 0;
}

int aether_flip_runtime_tick(
    aether_flip_runtime_t* runtime,
    double now_s,
    float* out_active_angles,
    int* inout_active_count) {
    if (runtime == nullptr || inout_active_count == nullptr || !std::isfinite(now_s)) {
        return -1;
    }
    const int required = static_cast<int>(runtime->active.size());
    if (out_active_angles == nullptr || *inout_active_count < required) {
        *inout_active_count = required;
        return -3;
    }
    std::vector<std::int32_t> ids;
    ids.reserve(runtime->active.size());
    for (const auto& entry : runtime->active) {
        ids.push_back(entry.first);
    }
    std::sort(ids.begin(), ids.end());
    const float duration = flip_runtime_duration_s(runtime->config);
    std::vector<std::int32_t> to_remove;
    for (std::size_t i = 0u; i < ids.size(); ++i) {
        const auto it = runtime->active.find(ids[i]);
        const aether_flip_runtime_t::ActiveFlip& active = it->second;
        const float progress = static_cast<float>((now_s - active.start_time_s) / duration);
        const float eased = aether::render::flip_easing(progress, to_cpp_flip_easing_config(&runtime->config.easing));
        const float angle = std::max(0.0f, std::min(kPiF, std::max(0.0f, std::min(1.0f, eased)) * kPiF));
        out_active_angles[i] = angle;
        if ((now_s - active.start_time_s) >= duration && angle >= (kPiF - 1e-4f)) {
            to_remove.push_back(ids[i]);
        }
    }
    for (std::int32_t id : to_remove) {
        runtime->active.erase(id);
    }
    *inout_active_count = required;
    return 0;
}

int aether_ripple_build_adjacency(
    const uint32_t* triangle_indices,
    int triangle_count,
    uint32_t* out_offsets,
    uint32_t* out_neighbors,
    int neighbor_capacity,
    int* out_neighbor_count) {
    std::size_t tri_count = 0u;
    if (!checked_count(triangle_count, &tri_count) ||
        triangle_indices == nullptr ||
        out_offsets == nullptr ||
        out_neighbor_count == nullptr ||
        neighbor_capacity < 0) {
        return -1;
    }
    std::vector<std::uint32_t> tmp_offsets(tri_count + 1u, 0u);
    std::vector<std::uint32_t> tmp_neighbors(std::max<std::size_t>(1u, tri_count * 8u), 0u);
    std::size_t tmp_neighbor_count = 0u;
    aether::render::build_adjacency(
        triangle_indices,
        tri_count,
        tmp_offsets.data(),
        tmp_neighbors.data(),
        &tmp_neighbor_count);
    if (out_neighbors == nullptr || neighbor_capacity < static_cast<int>(tmp_neighbor_count)) {
        *out_neighbor_count = static_cast<int>(tmp_neighbor_count);
        std::copy(tmp_offsets.begin(), tmp_offsets.end(), out_offsets);
        return -2;
    }
    std::copy(tmp_offsets.begin(), tmp_offsets.end(), out_offsets);
    std::copy(tmp_neighbors.begin(), tmp_neighbors.begin() + static_cast<std::ptrdiff_t>(tmp_neighbor_count), out_neighbors);
    *out_neighbor_count = static_cast<int>(tmp_neighbor_count);
    return 0;
}

int aether_compute_ripple_amplitudes(
    const uint32_t* adjacency_offsets,
    const uint32_t* adjacency_neighbors,
    int triangle_count,
    const uint32_t* trigger_triangle_ids,
    int trigger_count,
    const float* trigger_start_times,
    float current_time,
    const aether_ripple_config_t* config_or_null,
    float* out_amplitudes) {
    std::size_t tri_count = 0u;
    std::size_t trigger_size = 0u;
    if (!checked_count(triangle_count, &tri_count) ||
        !checked_count(trigger_count, &trigger_size) ||
        adjacency_offsets == nullptr ||
        adjacency_neighbors == nullptr ||
        trigger_triangle_ids == nullptr ||
        trigger_start_times == nullptr ||
        out_amplitudes == nullptr) {
        return -1;
    }
    aether::render::RippleConfig config = to_cpp_ripple_config(config_or_null);
    aether::render::compute_ripple_amplitudes(
        adjacency_offsets,
        adjacency_neighbors,
        tri_count,
        trigger_triangle_ids,
        trigger_size,
        trigger_start_times,
        current_time,
        config,
        out_amplitudes);
    return 0;
}

int aether_ripple_runtime_default_config(aether_ripple_runtime_config_t* out_config) {
    if (out_config == nullptr) {
        return -1;
    }
    *out_config = ripple_runtime_default_config();
    return 0;
}

int aether_ripple_runtime_create(
    const aether_ripple_runtime_config_t* config_or_null,
    aether_ripple_runtime_t** out_runtime) {
    if (out_runtime == nullptr) {
        return -1;
    }
    const aether_ripple_runtime_config_t config = sanitize_ripple_runtime_config(config_or_null);
    aether_ripple_runtime_t* runtime = new (std::nothrow) aether_ripple_runtime_t(config);
    if (runtime == nullptr) {
        return -2;
    }
    *out_runtime = runtime;
    return 0;
}

int aether_ripple_runtime_destroy(aether_ripple_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    delete runtime;
    return 0;
}

int aether_ripple_runtime_reset(aether_ripple_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    runtime->active_waves.clear();
    runtime->last_spawn_times.clear();
    return 0;
}

int aether_ripple_runtime_set_adjacency(
    aether_ripple_runtime_t* runtime,
    const uint32_t* offsets,
    const uint32_t* neighbors,
    int triangle_count) {
    std::size_t tri_count = 0u;
    if (!checked_count(triangle_count, &tri_count) ||
        runtime == nullptr ||
        offsets == nullptr ||
        (tri_count > 0u && neighbors == nullptr)) {
        return -1;
    }
    runtime->triangle_count = triangle_count;
    runtime->offsets.assign(offsets, offsets + tri_count + 1u);
    const std::size_t neighbor_count = runtime->offsets.empty() ? 0u : runtime->offsets.back();
    runtime->neighbors.assign(neighbors, neighbors + neighbor_count);
    runtime->active_waves.clear();
    runtime->last_spawn_times.clear();
    return 0;
}

int aether_ripple_runtime_spawn(
    aether_ripple_runtime_t* runtime,
    int32_t source_triangle,
    double spawn_time_s,
    int* out_spawned) {
    if (runtime == nullptr || out_spawned == nullptr || !std::isfinite(spawn_time_s)) {
        return -1;
    }
    *out_spawned = 0;
    if (source_triangle < 0 || source_triangle >= runtime->triangle_count) {
        return -1;
    }
    const auto it = runtime->last_spawn_times.find(source_triangle);
    if (it != runtime->last_spawn_times.end() &&
        (spawn_time_s - it->second) < runtime->config.min_spawn_interval_s) {
        return 0;
    }
    if (static_cast<int>(runtime->active_waves.size()) >= runtime->config.max_concurrent_waves) {
        return 0;
    }
    const int max_hop = ripple_runtime_compute_max_hop(runtime, source_triangle);
    runtime->active_waves.push_back(aether_ripple_runtime_t::Wave{source_triangle, spawn_time_s, max_hop});
    runtime->last_spawn_times[source_triangle] = spawn_time_s;
    *out_spawned = 1;
    return 0;
}

int aether_ripple_runtime_sample(
    const aether_ripple_runtime_t* runtime,
    const int32_t* triangle_ids,
    int triangle_count,
    double current_time_s,
    float* out_amplitudes) {
    std::size_t count = 0u;
    if (!checked_count(triangle_count, &count) ||
        runtime == nullptr ||
        triangle_ids == nullptr ||
        out_amplitudes == nullptr ||
        !std::isfinite(current_time_s)) {
        return -1;
    }
    std::vector<float> all_amplitudes;
    if (!ripple_runtime_compute_amplitudes(runtime, current_time_s, &all_amplitudes)) {
        return -1;
    }
    for (std::size_t i = 0u; i < count; ++i) {
        const int32_t tri = triangle_ids[i];
        if (tri < 0 || tri >= runtime->triangle_count) {
            out_amplitudes[i] = 0.0f;
        } else {
            out_amplitudes[i] = all_amplitudes[static_cast<std::size_t>(tri)];
        }
    }
    return 0;
}

int aether_ripple_runtime_tick(
    aether_ripple_runtime_t* runtime,
    double current_time_s,
    float* out_amplitudes,
    int* inout_amplitude_count) {
    if (runtime == nullptr || inout_amplitude_count == nullptr || !std::isfinite(current_time_s)) {
        return -1;
    }

    std::vector<aether_ripple_runtime_t::Wave> filtered_waves;
    filtered_waves.reserve(runtime->active_waves.size());
    for (const aether_ripple_runtime_t::Wave& wave : runtime->active_waves) {
        const double max_duration =
            static_cast<double>(std::max(0, wave.max_hop)) * runtime->config.ripple.delay_per_hop_s + 1.0;
        if ((current_time_s - wave.spawn_time_s) <= max_duration) {
            filtered_waves.push_back(wave);
        }
    }
    runtime->active_waves.swap(filtered_waves);

    const int required = runtime->triangle_count;
    if (out_amplitudes == nullptr || *inout_amplitude_count < required) {
        *inout_amplitude_count = required;
        return -3;
    }
    std::vector<float> all_amplitudes;
    if (!ripple_runtime_compute_amplitudes(runtime, current_time_s, &all_amplitudes)) {
        return -1;
    }
    for (int i = 0; i < required; ++i) {
        out_amplitudes[i] = all_amplitudes[static_cast<std::size_t>(i)];
    }
    *inout_amplitude_count = required;
    return 0;
}

int aether_decay_confidence(
    aether_gaussian_t* gaussians,
    int count,
    const int* in_current_frustum,
    uint64_t current_frame,
    const aether_confidence_decay_config_t* config) {
    if (config == nullptr) {
        return -1;
    }
    std::size_t n = 0u;
    if (!checked_count(count, &n)) {
        return -1;
    }
    if (n > 0u && gaussians == nullptr) {
        return -1;
    }
    if (config->decay_per_frame < 0.0f ||
        config->observation_boost < 0.0f ||
        config->min_confidence < 0.0f ||
        config->max_confidence < config->min_confidence) {
        return -1;
    }
    const float retention = std::max(0.0f, std::min(1.0f, config->peak_retention_floor));
    auto& frame_map = gaussian_last_seen_frames();
    auto& peak_map = gaussian_peak_confidence_map();
    for (std::size_t i = 0u; i < n; ++i) {
        const bool observed = (in_current_frustum == nullptr) ? true : (in_current_frustum[i] != 0);
        auto it = frame_map.find(gaussians[i].id);
        std::uint64_t last_seen = (it == frame_map.end()) ? current_frame : it->second;
        const bool frame_valid = (last_seen <= current_frame);
        const std::uint64_t unseen = frame_valid ? (current_frame - last_seen) : 0u;
        const bool should_decay = (!observed) &&
                                  frame_valid &&
                                  (unseen > static_cast<std::uint64_t>(config->grace_frames));

        float confidence = gaussians[i].opacity;

        // Track per-Gaussian peak confidence.
        float& peak = peak_map[gaussians[i].id];
        peak = std::max(peak, confidence);

        if (observed) {
            confidence += config->observation_boost;
            last_seen = current_frame;
        } else if (should_decay) {
            confidence -= config->decay_per_frame;
        }

        // Peak retention floor: never decay below fraction of historical peak.
        const float peak_floor = retention * peak;
        const float effective_min = std::max(config->min_confidence, peak_floor);
        confidence = std::max(effective_min, std::min(config->max_confidence, confidence));
        gaussians[i].opacity = confidence;
        frame_map[gaussians[i].id] = last_seen;
    }
    return 0;
}

int aether_match_patch_identities(
    const aether_patch_identity_sample_t* observations,
    int observation_count,
    const aether_patch_identity_sample_t* anchors,
    int anchor_count,
    float lock_threshold,
    float snap_radius,
    float display_threshold,
    uint64_t* out_resolved_keys) {
    std::size_t obs_n = 0u;
    std::size_t anc_n = 0u;
    if (!checked_count(observation_count, &obs_n) ||
        !checked_count(anchor_count, &anc_n)) {
        return -1;
    }
    if (obs_n > 0u && (observations == nullptr || out_resolved_keys == nullptr)) {
        return -1;
    }
    // For each observation: if display >= lock_threshold, keep its own key.
    // Otherwise, find closest anchor within snap_radius whose display >= lock_threshold,
    // and whose display - observation.display > display_threshold, then adopt anchor's key.
    for (std::size_t i = 0u; i < obs_n; ++i) {
        const aether_patch_identity_sample_t& obs = observations[i];
        if (obs.display >= lock_threshold) {
            out_resolved_keys[i] = obs.patch_key;
            continue;
        }
        float best_dist_sq = snap_radius * snap_radius;
        std::uint64_t best_key = obs.patch_key;
        for (std::size_t j = 0u; j < anc_n; ++j) {
            const aether_patch_identity_sample_t& anc = anchors[j];
            if (anc.display < lock_threshold) {
                continue;
            }
            if (anc.display - obs.display < display_threshold) {
                continue;
            }
            const float dx = obs.centroid.x - anc.centroid.x;
            const float dy = obs.centroid.y - anc.centroid.y;
            const float dz = obs.centroid.z - anc.centroid.z;
            const float dist_sq = dx * dx + dy * dy + dz * dz;
            if (dist_sq < best_dist_sq) {
                best_dist_sq = dist_sq;
                best_key = anc.patch_key;
            }
        }
        out_resolved_keys[i] = best_key;
    }
    return 0;
}

int aether_scan_state_can_transition(
    int32_t from_state,
    int32_t to_state,
    int32_t* out_allowed) {
    if (out_allowed == nullptr) {
        return -1;
    }
    int32_t allowed = 0;
    switch (from_state) {
        case AETHER_SCAN_STATE_INITIALIZING:
            allowed = (to_state == AETHER_SCAN_STATE_READY || to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_READY:
            allowed = (to_state == AETHER_SCAN_STATE_CAPTURING || to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_CAPTURING:
            allowed = (to_state == AETHER_SCAN_STATE_PAUSED ||
                       to_state == AETHER_SCAN_STATE_FINISHING ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_PAUSED:
            allowed = (to_state == AETHER_SCAN_STATE_CAPTURING ||
                       to_state == AETHER_SCAN_STATE_READY ||
                       to_state == AETHER_SCAN_STATE_FINISHING ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_FINISHING:
            allowed = (to_state == AETHER_SCAN_STATE_COMPLETED ||
                       to_state == AETHER_SCAN_STATE_FAILED) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_COMPLETED:
            allowed = (to_state == AETHER_SCAN_STATE_READY) ? 1 : 0;
            break;
        case AETHER_SCAN_STATE_FAILED:
            allowed = (to_state == AETHER_SCAN_STATE_READY) ? 1 : 0;
            break;
        default:
            allowed = 0;
            break;
    }
    *out_allowed = allowed;
    return 0;
}

int aether_scan_state_is_active(
    int32_t state,
    int32_t* out_active) {
    if (out_active == nullptr) {
        return -1;
    }
    *out_active = (state == AETHER_SCAN_STATE_CAPTURING || state == AETHER_SCAN_STATE_FINISHING) ? 1 : 0;
    return 0;
}

int aether_scan_state_can_finish(
    int32_t state,
    int32_t* out_can_finish) {
    if (out_can_finish == nullptr) {
        return -1;
    }
    *out_can_finish = (state == AETHER_SCAN_STATE_CAPTURING || state == AETHER_SCAN_STATE_PAUSED) ? 1 : 0;
    return 0;
}

int aether_scan_state_recommended_abort_state(
    int32_t state,
    int32_t* out_state) {
    if (out_state == nullptr) {
        return -1;
    }
    switch (state) {
        case AETHER_SCAN_STATE_COMPLETED:
            *out_state = AETHER_SCAN_STATE_COMPLETED;
            break;
        default:
            *out_state = AETHER_SCAN_STATE_FAILED;
            break;
    }
    return 0;
}

int aether_scan_state_action_plan(
    int32_t state,
    int32_t reason,
    aether_scan_action_plan_t* out_plan) {
    if (out_plan == nullptr) {
        return -1;
    }
    std::memset(out_plan, 0, sizeof(*out_plan));

    if (reason == AETHER_SCAN_ACTION_REASON_ABORT) {
        out_plan->action_mask = AETHER_SCAN_ACTION_APPLY_TRANSITION;
        out_plan->overlay_clear_alpha = 0.0f;
        out_plan->transition_target_state = AETHER_SCAN_STATE_FAILED;
        return 0;
    }

    const bool force_black =
        (state == AETHER_SCAN_STATE_CAPTURING ||
         state == AETHER_SCAN_STATE_PAUSED ||
         state == AETHER_SCAN_STATE_FINISHING);
    out_plan->action_mask = AETHER_SCAN_ACTION_SET_BORDER_DEPTH_LESS_EQUAL;
    if (force_black) {
        out_plan->action_mask |= AETHER_SCAN_ACTION_SET_BLACK_BACKGROUND;
        out_plan->action_mask |= AETHER_SCAN_ACTION_SET_OVERLAY_OPAQUE;
    }
    out_plan->overlay_clear_alpha = force_black ? 1.0f : 0.0f;
    out_plan->transition_target_state = state;
    return 0;
}

int aether_scan_state_render_presentation_policy(
    int32_t state,
    aether_scan_render_presentation_policy_t* out_policy) {
    if (out_policy == nullptr) {
        return -1;
    }
    std::memset(out_policy, 0, sizeof(*out_policy));
    const bool force_black =
        (state == AETHER_SCAN_STATE_CAPTURING ||
         state == AETHER_SCAN_STATE_PAUSED ||
         state == AETHER_SCAN_STATE_FINISHING);
    out_policy->force_black_background = force_black ? 1 : 0;
    out_policy->overlay_opaque = force_black ? 1 : 0;
    out_policy->overlay_clear_alpha = force_black ? 1.0f : 0.0f;
    out_policy->border_depth_mode = AETHER_SCAN_BORDER_DEPTH_LESS_EQUAL;
    return 0;
}

int aether_select_stable_render_triangles(
    const aether_render_triangle_candidate_t* candidates,
    int candidate_count,
    const aether_render_selection_config_t* config,
    int32_t* out_selected_indices,
    int* inout_selected_count) {
    std::size_t n = 0u;
    if (!checked_count(candidate_count, &n) ||
        config == nullptr ||
        out_selected_indices == nullptr ||
        inout_selected_count == nullptr) {
        return -1;
    }
    if (n == 0u) {
        *inout_selected_count = 0;
        return 0;
    }
    if (candidates == nullptr) {
        return -1;
    }

    struct ScoredTriangle {
        float score;
        std::uint64_t patch_key;
        int original_index;
        bool is_resident;
        float distance;
    };
    struct PatchAggregate {
        float sum_score{0.0f};
        float best_score{-std::numeric_limits<float>::infinity()};
        float min_distance{std::numeric_limits<float>::infinity()};
        int resident_count{0};
        int count{0};
        std::vector<ScoredTriangle> triangles;
    };

    std::unordered_map<std::uint64_t, PatchAggregate> patch_map;
    patch_map.reserve(n);
    std::vector<ScoredTriangle> global_sorted;
    global_sorted.reserve(n);

    for (std::size_t i = 0u; i < n; ++i) {
        const aether_render_triangle_candidate_t& c = candidates[i];
        const float dx = c.centroid.x - config->camera_position.x;
        const float dy = c.centroid.y - config->camera_position.y;
        const float dz = c.centroid.z - config->camera_position.z;
        const float dist = std::sqrt(dx * dx + dy * dy + dz * dz);
        const float display_clamped = std::max(0.0f, std::min(1.0f, c.display));
        const bool is_resident = c.residency_until_frame >= config->current_frame;

        // Favor already-covered regions first (anti-regression), then frontier growth.
        float score = (0.10f + 0.90f * display_clamped) * config->display_weight;
        score += c.stability_fade_alpha * config->stability_weight * 1.15f;
        score -= dist * config->distance_bias * 1.25f;
        if (!is_resident && display_clamped < 0.06f) {
            score -= 0.18f;
        }
        if (display_clamped >= config->completion_threshold) {
            score += config->completion_boost * 1.15f;
        }
        if (is_resident) {
            const float hold_frames =
                static_cast<float>(c.residency_until_frame - config->current_frame);
            const float hold_scale = 1.0f + std::min(3.0f, hold_frames / 35.0f);
            score += config->residency_boost * hold_scale * 1.15f;
        }

        ScoredTriangle tri{
            score,
            c.patch_key,
            static_cast<int>(i),
            is_resident,
            dist};
        PatchAggregate& agg = patch_map[c.patch_key];
        agg.sum_score += score;
        agg.best_score = std::max(agg.best_score, score);
        agg.min_distance = std::min(agg.min_distance, dist);
        agg.resident_count += is_resident ? 1 : 0;
        agg.count += 1;
        agg.triangles.push_back(tri);
        global_sorted.push_back(tri);
    }

    struct PatchRank {
        float score;
        std::uint64_t patch_key;
    };
    std::vector<PatchRank> patch_ranks;
    patch_ranks.reserve(patch_map.size());
    for (const auto& entry : patch_map) {
        const std::uint64_t patch_key = entry.first;
        const PatchAggregate& agg = entry.second;
        const float count_f = std::max(1.0f, static_cast<float>(agg.count));
        const float avg = agg.sum_score / count_f;
        const float resident_ratio =
            static_cast<float>(agg.resident_count) / count_f;
        float patch_score = avg * 0.60f + agg.best_score * 0.40f;
        patch_score += resident_ratio * config->residency_boost * 2.4f;
        if (agg.resident_count > 0) {
            patch_score += config->stability_weight * 0.8f;
        }
        patch_score -= agg.min_distance * config->distance_bias * 0.65f;
        patch_ranks.push_back(PatchRank{patch_score, patch_key});
    }

    std::sort(patch_ranks.begin(), patch_ranks.end(), [](const PatchRank& a, const PatchRank& b) {
        if (a.score != b.score) {
            return a.score > b.score;
        }
        return a.patch_key < b.patch_key;
    });

    std::sort(global_sorted.begin(), global_sorted.end(), [](const ScoredTriangle& a, const ScoredTriangle& b) {
        if (a.is_resident != b.is_resident) {
            return a.is_resident && !b.is_resident;
        }
        if (a.score != b.score) {
            return a.score > b.score;
        }
        return a.original_index < b.original_index;
    });

    const int max_tri = std::min(config->max_triangles, static_cast<int>(n));
    if (max_tri <= 0) {
        *inout_selected_count = 0;
        return 0;
    }
    if (max_tri >= static_cast<int>(n)) {
        for (int i = 0; i < static_cast<int>(n); ++i) {
            out_selected_indices[i] = static_cast<int32_t>(i);
        }
        *inout_selected_count = static_cast<int>(n);
        return 0;
    }

    std::vector<uint8_t> selected_mask(n, 0u);
    int selected_count = 0;

    for (const PatchRank& rank : patch_ranks) {
        auto it = patch_map.find(rank.patch_key);
        if (it == patch_map.end()) {
            continue;
        }
        std::vector<ScoredTriangle>& tris = it->second.triangles;
        std::sort(tris.begin(), tris.end(), [](const ScoredTriangle& a, const ScoredTriangle& b) {
            if (a.is_resident != b.is_resident) {
                return a.is_resident && !b.is_resident;
            }
            if (a.score != b.score) {
                return a.score > b.score;
            }
            return a.original_index < b.original_index;
        });
        for (const ScoredTriangle& tri : tris) {
            if (selected_count >= max_tri) {
                break;
            }
            if (tri.original_index < 0 ||
                static_cast<std::size_t>(tri.original_index) >= n ||
                selected_mask[static_cast<std::size_t>(tri.original_index)] != 0u) {
                continue;
            }
            out_selected_indices[selected_count++] = static_cast<int32_t>(tri.original_index);
            selected_mask[static_cast<std::size_t>(tri.original_index)] = 1u;
        }
        if (selected_count >= max_tri) {
            break;
        }
    }

    if (selected_count < max_tri) {
        for (const ScoredTriangle& tri : global_sorted) {
            if (selected_count >= max_tri) {
                break;
            }
            if (tri.original_index < 0 ||
                static_cast<std::size_t>(tri.original_index) >= n ||
                selected_mask[static_cast<std::size_t>(tri.original_index)] != 0u) {
                continue;
            }
            out_selected_indices[selected_count++] = static_cast<int32_t>(tri.original_index);
            selected_mask[static_cast<std::size_t>(tri.original_index)] = 1u;
        }
    }

    *inout_selected_count = selected_count;
    return 0;
}

int aether_render_selection_runtime_create(
    const aether_render_selection_config_t* /*config_or_null*/,
    int32_t hold_frames,
    aether_render_selection_runtime_t** out_runtime) {
    if (out_runtime == nullptr) {
        return -1;
    }
    aether_render_selection_runtime_t* runtime =
        new (std::nothrow) aether_render_selection_runtime_t(hold_frames);
    if (runtime == nullptr) {
        return -2;
    }
    *out_runtime = runtime;
    return 0;
}

int aether_render_selection_runtime_destroy(aether_render_selection_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    delete runtime;
    return 0;
}

int aether_render_selection_runtime_reset(aether_render_selection_runtime_t* runtime) {
    if (runtime == nullptr) {
        return -1;
    }
    runtime->residency_until_by_patch.clear();
    return 0;
}

int aether_render_selection_runtime_select(
    aether_render_selection_runtime_t* runtime,
    const aether_render_triangle_candidate_t* candidates,
    int candidate_count,
    const aether_render_selection_config_t* config,
    int32_t* out_selected_indices,
    int* inout_selected_count) {
    std::size_t n = 0u;
    if (!checked_count(candidate_count, &n) ||
        runtime == nullptr ||
        config == nullptr ||
        out_selected_indices == nullptr ||
        inout_selected_count == nullptr) {
        return -1;
    }
    if (n == 0u) {
        *inout_selected_count = 0;
        return 0;
    }
    if (candidates == nullptr) {
        return -1;
    }

    std::vector<aether_render_triangle_candidate_t> local(candidates, candidates + n);
    for (std::size_t i = 0u; i < n; ++i) {
        const std::uint64_t patch_key = local[i].patch_key;
        const auto it = runtime->residency_until_by_patch.find(patch_key);
        if (it == runtime->residency_until_by_patch.end()) {
            continue;
        }
        local[i].residency_until_frame = std::max(local[i].residency_until_frame, it->second);
        if (local[i].residency_until_frame >= config->current_frame) {
            local[i].stability_fade_alpha = std::max(local[i].stability_fade_alpha, 1.0f);
        }
    }

    int rc = aether_select_stable_render_triangles(
        local.data(),
        candidate_count,
        config,
        out_selected_indices,
        inout_selected_count);
    if (rc != 0) {
        return rc;
    }

    const int safe_selected = std::max(0, std::min(*inout_selected_count, candidate_count));
    const int32_t until_frame = config->current_frame + runtime->hold_frames;
    for (int i = 0; i < safe_selected; ++i) {
        const int32_t idx = out_selected_indices[i];
        if (idx < 0 || static_cast<std::size_t>(idx) >= n) {
            continue;
        }
        const std::uint64_t patch_key = local[static_cast<std::size_t>(idx)].patch_key;
        runtime->residency_until_by_patch[patch_key] = until_frame;
    }

    const int32_t prune_floor = config->current_frame - runtime->hold_frames;
    for (auto it = runtime->residency_until_by_patch.begin();
         it != runtime->residency_until_by_patch.end();) {
        if (it->second < prune_floor) {
            it = runtime->residency_until_by_patch.erase(it);
        } else {
            ++it;
        }
    }

    return 0;
}

int aether_compute_render_snapshot(
    const aether_render_snapshot_input_t* inputs,
    int input_count,
    const aether_render_snapshot_config_t* config,
    float* out_rendered_display) {
    std::size_t n = 0u;
    if (!checked_count(input_count, &n) || config == nullptr || out_rendered_display == nullptr) {
        return -1;
    }
    if (n > 0u && inputs == nullptr) {
        return -1;
    }
    for (std::size_t i = 0u; i < n; ++i) {
        const aether_render_snapshot_input_t& inp = inputs[i];
        // If has_stability and base_display exceeds s4_to_s5_threshold,
        // use confidence_display; otherwise use base_display.
        // Ensure monotonic: rendered >= base_display.
        float rendered = inp.base_display;
        if (inp.has_stability && inp.base_display >= config->s4_to_s5_threshold) {
            rendered = std::max(inp.base_display, inp.confidence_display);
        } else if (!inp.has_stability) {
            rendered = inp.confidence_display;
        }
        out_rendered_display[i] = rendered;
    }
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Innovation F1: Progressive Compression
// ═══════════════════════════════════════════════════════════════════════

int aether_f1_default_config(aether_f1_progressive_config_t* out_config) {
    if (!out_config) return -1;
    out_config->level_count = 4;
    out_config->area_gamma = 1.0f;
    out_config->capture_order_priority = 0.5f;
    out_config->quant_bits_position = 16;
    out_config->quant_bits_scale = 16;
    out_config->quant_bits_opacity = 12;
    out_config->quant_bits_uncertainty = 12;
    out_config->quant_bits_sh = 8;
    out_config->sh_coeff_count = 16;
    return 0;
}


// ═══════════════════════════════════════════════════════════════════════
// Innovation F1: Time Mirror Animation — default config
// ═══════════════════════════════════════════════════════════════════════

int aether_f1_default_time_mirror_config(aether_f1_time_mirror_config_t* out_config) {
    if (!out_config) return -1;
    aether::innovation::F1TimeMirrorConfig def{};
    out_config->start_offset_meters = def.start_offset_meters;
    out_config->min_flight_duration_s = def.min_flight_duration_s;
    out_config->max_flight_duration_s = def.max_flight_duration_s;
    out_config->appear_stagger_s = def.appear_stagger_s;
    out_config->appear_jitter_ratio = def.appear_jitter_ratio;
    out_config->priority_boost_appear_gain = def.priority_boost_appear_gain;
    out_config->priority_boost_cap = def.priority_boost_cap;
    out_config->area_duration_power = def.area_duration_power;
    out_config->flight_distance_normalizer_m = def.flight_distance_normalizer_m;
    out_config->flight_distance_factor_min = def.flight_distance_factor_min;
    out_config->flight_distance_factor_max = def.flight_distance_factor_max;
    out_config->flight_duration_distance_blend_base = def.flight_duration_distance_blend_base;
    out_config->flight_duration_distance_blend_gain = def.flight_duration_distance_blend_gain;
    out_config->opacity_ramp_ratio = def.opacity_ramp_ratio;
    out_config->min_opacity_ramp_ratio = def.min_opacity_ramp_ratio;
    out_config->sh_crossfade_start_ratio = def.sh_crossfade_start_ratio;
    out_config->min_sh_crossfade_span = def.min_sh_crossfade_span;
    out_config->arc_height_base_m = def.arc_height_base_m;
    out_config->arc_height_distance_gain = def.arc_height_distance_gain;
    out_config->arc_area_normalizer = def.arc_area_normalizer;
    out_config->arc_area_factor_min = def.arc_area_factor_min;
    out_config->spin_degrees_min = def.spin_degrees_min;
    out_config->spin_degrees_range = def.spin_degrees_range;
    out_config->min_progress_denominator_s = def.min_progress_denominator_s;
    out_config->safe_total_time_epsilon_s = def.safe_total_time_epsilon_s;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Innovation F1: Build Fragment Queue + Animate Frame
// ═══════════════════════════════════════════════════════════════════════

int aether_f1_build_fragment_queue(
    const aether_scaffold_unit_t* units, int unit_count,
    const aether_scaffold_vertex_t* vertices, int vertex_count,
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_camera_trajectory_entry_t* trajectory, int trajectory_count,
    const aether_f1_time_mirror_config_t* config,
    aether_f1_fragment_flight_t* out_flights, int* inout_count) {
    if (!config || !inout_count) return -1;
    if (unit_count > 0 && !units) return -1;
    if (vertex_count > 0 && !vertices) return -1;
    if (gaussian_count > 0 && !gaussians) return -1;
    if (trajectory_count > 0 && !trajectory) return -1;

    using namespace aether::innovation;

    // Convert units
    std::vector<ScaffoldUnit> cpp_units(static_cast<std::size_t>(unit_count));
    for (int i = 0; i < unit_count; ++i) {
        cpp_units[i].unit_id = units[i].unit_id;
        cpp_units[i].generation = units[i].generation;
        cpp_units[i].v0 = units[i].v0;
        cpp_units[i].v1 = units[i].v1;
        cpp_units[i].v2 = units[i].v2;
        cpp_units[i].area = units[i].area;
        cpp_units[i].normal = to_cpp_float3(units[i].normal);
        cpp_units[i].confidence = units[i].confidence;
        cpp_units[i].view_count = units[i].view_count;
        cpp_units[i].lod_level = units[i].lod_level;
        if (units[i].patch_id) cpp_units[i].patch_id = units[i].patch_id;
    }

    // Convert vertices
    std::vector<ScaffoldVertex> cpp_verts(static_cast<std::size_t>(vertex_count));
    for (int i = 0; i < vertex_count; ++i) {
        cpp_verts[i].id = vertices[i].id;
        cpp_verts[i].position = to_cpp_float3(vertices[i].position);
    }

    // Convert gaussians
    std::vector<GaussianPrimitive> cpp_gs;
    cpp_gs.reserve(static_cast<std::size_t>(gaussian_count));
    for (int i = 0; i < gaussian_count; ++i) {
        cpp_gs.push_back(to_cpp_gaussian(gaussians[i]));
    }

    // Convert trajectory
    std::vector<CameraTrajectoryEntry> cpp_traj(static_cast<std::size_t>(trajectory_count));
    for (int i = 0; i < trajectory_count; ++i) {
        cpp_traj[i].frame_id = trajectory[i].frame_id;
        cpp_traj[i].pose.position = to_cpp_float3(trajectory[i].position);
        cpp_traj[i].pose.forward = to_cpp_float3(trajectory[i].forward);
        cpp_traj[i].pose.up = to_cpp_float3(trajectory[i].up);
        cpp_traj[i].timestamp_ms = static_cast<std::int64_t>(trajectory[i].timestamp_ms);
    }

    // Convert config
    F1TimeMirrorConfig cfg{};
    cfg.start_offset_meters = config->start_offset_meters;
    cfg.min_flight_duration_s = config->min_flight_duration_s;
    cfg.max_flight_duration_s = config->max_flight_duration_s;
    cfg.appear_stagger_s = config->appear_stagger_s;
    cfg.appear_jitter_ratio = config->appear_jitter_ratio;
    cfg.priority_boost_appear_gain = config->priority_boost_appear_gain;
    cfg.priority_boost_cap = config->priority_boost_cap;
    cfg.area_duration_power = config->area_duration_power;
    cfg.flight_distance_normalizer_m = config->flight_distance_normalizer_m;
    cfg.flight_distance_factor_min = config->flight_distance_factor_min;
    cfg.flight_distance_factor_max = config->flight_distance_factor_max;
    cfg.flight_duration_distance_blend_base = config->flight_duration_distance_blend_base;
    cfg.flight_duration_distance_blend_gain = config->flight_duration_distance_blend_gain;
    cfg.opacity_ramp_ratio = config->opacity_ramp_ratio;
    cfg.min_opacity_ramp_ratio = config->min_opacity_ramp_ratio;
    cfg.sh_crossfade_start_ratio = config->sh_crossfade_start_ratio;
    cfg.min_sh_crossfade_span = config->min_sh_crossfade_span;
    cfg.arc_height_base_m = config->arc_height_base_m;
    cfg.arc_height_distance_gain = config->arc_height_distance_gain;
    cfg.arc_area_normalizer = config->arc_area_normalizer;
    cfg.arc_area_factor_min = config->arc_area_factor_min;
    cfg.spin_degrees_min = config->spin_degrees_min;
    cfg.spin_degrees_range = config->spin_degrees_range;
    cfg.min_progress_denominator_s = config->min_progress_denominator_s;
    cfg.safe_total_time_epsilon_s = config->safe_total_time_epsilon_s;

    std::vector<FragmentFlightParams> params;
    auto rc = f1_build_fragment_queue(
        cpp_units.data(), cpp_units.size(),
        cpp_verts.data(), cpp_verts.size(),
        cpp_gs.data(), cpp_gs.size(),
        patch_map ? &patch_map->impl : nullptr,
        cpp_traj.data(), cpp_traj.size(),
        cfg, &params);
    if (rc != aether::core::Status::kOk) return -1;

    int capacity = *inout_count;
    int written = std::min(capacity, static_cast<int>(params.size()));
    if (out_flights) {
        for (int i = 0; i < written; ++i) {
            out_flights[i].unit_id = params[i].unit_id;
            out_flights[i].start_position = {params[i].start_position.x, params[i].start_position.y, params[i].start_position.z};
            out_flights[i].end_position = {params[i].end_position.x, params[i].end_position.y, params[i].end_position.z};
            out_flights[i].start_normal = {params[i].start_normal.x, params[i].start_normal.y, params[i].start_normal.z};
            out_flights[i].end_normal = {params[i].end_normal.x, params[i].end_normal.y, params[i].end_normal.z};
            out_flights[i].first_observed_frame_id = params[i].first_observed_frame_id;
            out_flights[i].first_observed_ms = params[i].first_observed_ms;
            out_flights[i].priority_boost = static_cast<float>(params[i].priority_boost);
            out_flights[i].appear_offset_s = params[i].appear_offset_s;
            out_flights[i].flight_duration_s = params[i].flight_duration_s;
            out_flights[i].earliest_capture_sequence = params[i].earliest_capture_sequence;
            out_flights[i].gaussian_count = params[i].gaussian_count;
        }
    }
    *inout_count = written;
    return 0;
}

int aether_f1_animate_frame(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f1_fragment_flight_t* flights, int flight_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_f1_time_mirror_config_t* config,
    float elapsed_s, float dt_s,
    aether_gaussian_t* out_animated, int* inout_animated_count,
    aether_f1_animation_metrics_t* out_metrics) {
    if (!config || !inout_animated_count) return -1;
    if (gaussian_count > 0 && !gaussians) return -1;
    if (flight_count > 0 && !flights) return -1;

    using namespace aether::innovation;

    // Convert gaussians
    std::vector<GaussianPrimitive> cpp_gs;
    cpp_gs.reserve(static_cast<std::size_t>(gaussian_count));
    for (int i = 0; i < gaussian_count; ++i) {
        cpp_gs.push_back(to_cpp_gaussian(gaussians[i]));
    }

    // Convert flights
    std::vector<FragmentFlightParams> cpp_flights(static_cast<std::size_t>(flight_count));
    for (int i = 0; i < flight_count; ++i) {
        cpp_flights[i].unit_id = flights[i].unit_id;
        cpp_flights[i].start_position = to_cpp_float3(flights[i].start_position);
        cpp_flights[i].end_position = to_cpp_float3(flights[i].end_position);
        cpp_flights[i].start_normal = to_cpp_float3(flights[i].start_normal);
        cpp_flights[i].end_normal = to_cpp_float3(flights[i].end_normal);
        cpp_flights[i].first_observed_frame_id = flights[i].first_observed_frame_id;
        cpp_flights[i].first_observed_ms = flights[i].first_observed_ms;
        cpp_flights[i].priority_boost = static_cast<std::uint16_t>(flights[i].priority_boost);
        cpp_flights[i].earliest_capture_sequence = flights[i].earliest_capture_sequence;
        cpp_flights[i].appear_offset_s = flights[i].appear_offset_s;
        cpp_flights[i].flight_duration_s = flights[i].flight_duration_s;
        cpp_flights[i].gaussian_count = flights[i].gaussian_count;
    }

    // Convert config
    F1TimeMirrorConfig cfg{};
    cfg.start_offset_meters = config->start_offset_meters;
    cfg.min_flight_duration_s = config->min_flight_duration_s;
    cfg.max_flight_duration_s = config->max_flight_duration_s;
    cfg.appear_stagger_s = config->appear_stagger_s;
    cfg.appear_jitter_ratio = config->appear_jitter_ratio;
    cfg.priority_boost_appear_gain = config->priority_boost_appear_gain;
    cfg.priority_boost_cap = config->priority_boost_cap;
    cfg.area_duration_power = config->area_duration_power;
    cfg.flight_distance_normalizer_m = config->flight_distance_normalizer_m;
    cfg.flight_distance_factor_min = config->flight_distance_factor_min;
    cfg.flight_distance_factor_max = config->flight_distance_factor_max;
    cfg.flight_duration_distance_blend_base = config->flight_duration_distance_blend_base;
    cfg.flight_duration_distance_blend_gain = config->flight_duration_distance_blend_gain;
    cfg.opacity_ramp_ratio = config->opacity_ramp_ratio;
    cfg.min_opacity_ramp_ratio = config->min_opacity_ramp_ratio;
    cfg.sh_crossfade_start_ratio = config->sh_crossfade_start_ratio;
    cfg.min_sh_crossfade_span = config->min_sh_crossfade_span;
    cfg.arc_height_base_m = config->arc_height_base_m;
    cfg.arc_height_distance_gain = config->arc_height_distance_gain;
    cfg.arc_area_normalizer = config->arc_area_normalizer;
    cfg.arc_area_factor_min = config->arc_area_factor_min;
    cfg.spin_degrees_min = config->spin_degrees_min;
    cfg.spin_degrees_range = config->spin_degrees_range;
    cfg.min_progress_denominator_s = config->min_progress_denominator_s;
    cfg.safe_total_time_epsilon_s = config->safe_total_time_epsilon_s;

    std::vector<GaussianPrimitive> animated;
    F1AnimationMetrics metrics{};
    auto rc = f1_animate_frame(
        cpp_gs.data(), cpp_gs.size(),
        cpp_flights.data(), cpp_flights.size(),
        patch_map ? &patch_map->impl : nullptr,
        cfg, elapsed_s, dt_s,
        &animated, &metrics);
    if (rc != aether::core::Status::kOk) return -1;

    if (out_metrics) {
        out_metrics->visible_gaussian_count = static_cast<uint32_t>(metrics.visible_gaussian_count);
        out_metrics->hidden_gaussian_count = static_cast<uint32_t>(metrics.hidden_gaussian_count);
        out_metrics->active_fragment_count = static_cast<uint32_t>(metrics.active_fragment_count);
        out_metrics->completion_ratio = metrics.completion_ratio;
    }

    // Copy animated gaussians to output buffer if provided.
    int capacity = *inout_animated_count;
    int written = std::min(capacity, static_cast<int>(animated.size()));
    if (out_animated) {
        for (int i = 0; i < written; ++i) {
            const auto& g = animated[i];
            out_animated[i] = {};
            out_animated[i].id = g.id;
            out_animated[i].position = {g.position.x, g.position.y, g.position.z};
            out_animated[i].scale = {g.scale.x, g.scale.y, g.scale.z};
            out_animated[i].opacity = g.opacity;
            for (std::size_t j = 0u; j < g.sh_coeffs.size(); ++j) {
                out_animated[i].sh_coeffs[j] = g.sh_coeffs[j];
            }
            out_animated[i].host_unit_id = g.host_unit_id;
            out_animated[i].flags = g.flags;
        }
    }
    *inout_animated_count = written;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Innovation F3: Evidence Constrained Compression — default plan config
// ═══════════════════════════════════════════════════════════════════════

int aether_f3_default_plan_config(aether_f3_plan_config_t* out_config) {
    if (!out_config) return -1;
    aether::innovation::F3PlanConfig def{};
    out_config->preserve_threshold = def.preserve_threshold;
    out_config->aggressive_threshold = def.aggressive_threshold;
    out_config->target_byte_budget = static_cast<uint32_t>(def.target_byte_budget);
    out_config->min_observation_keep = static_cast<uint32_t>(def.min_observation_keep);
    out_config->patch_priority_boost = def.patch_priority_boost;
    out_config->score_weight_opacity = def.score_weight_opacity;
    out_config->score_weight_observation = def.score_weight_observation;
    out_config->score_weight_certainty = def.score_weight_certainty;
    out_config->preserve_quant_bits = static_cast<uint8_t>(def.preserve_quant_bits);
    out_config->balanced_quant_bits = static_cast<uint8_t>(def.balanced_quant_bits);
    out_config->aggressive_quant_bits = static_cast<uint8_t>(def.aggressive_quant_bits);
    return 0;
}

int aether_f3_plan_compression(
    const aether_gaussian_t* gaussians, int gaussian_count,
    const aether_f3_belief_record_t* beliefs, int belief_count,
    const aether_scaffold_patch_map_t* patch_map,
    const aether_f1_progressive_config_t* compression_config,
    const aether_f3_plan_config_t* plan_config,
    aether_f3_gaussian_decision_t* out_decisions, int* inout_count,
    aether_f3_compression_plan_t* out_plan) {
    if (!plan_config || !out_plan) return -1;
    if (gaussian_count > 0 && !gaussians) return -1;
    if (belief_count > 0 && !beliefs) return -1;

    using namespace aether::innovation;

    // Convert gaussians
    std::vector<GaussianPrimitive> cpp_gs;
    cpp_gs.reserve(static_cast<std::size_t>(gaussian_count));
    for (int i = 0; i < gaussian_count; ++i) {
        cpp_gs.push_back(to_cpp_gaussian(gaussians[i]));
    }

    // Convert belief records
    std::vector<F3BeliefRecord> cpp_beliefs;
    cpp_beliefs.reserve(static_cast<std::size_t>(belief_count));
    for (int i = 0; i < belief_count; ++i) {
        F3BeliefRecord b{};
        b.unit_id = beliefs[i].unit_id;
        if (beliefs[i].patch_id) b.patch_id = beliefs[i].patch_id;
        b.mass = to_cpp_ds_mass(beliefs[i].mass);
        cpp_beliefs.push_back(std::move(b));
    }

    // Convert compression config
    ProgressiveCompressionConfig base{};
    if (compression_config) {
        base.level_count = compression_config->level_count;
        base.area_gamma = compression_config->area_gamma;
        base.capture_order_priority = (compression_config->capture_order_priority > 0.5f);
        base.quant_bits_position = compression_config->quant_bits_position;
        base.quant_bits_scale = compression_config->quant_bits_scale;
        base.quant_bits_opacity = compression_config->quant_bits_opacity;
        base.quant_bits_uncertainty = compression_config->quant_bits_uncertainty;
        base.quant_bits_sh = compression_config->quant_bits_sh;
        base.sh_coeff_count = compression_config->sh_coeff_count;
    }

    // Convert plan config
    F3PlanConfig cfg{};
    cfg.preserve_threshold = plan_config->preserve_threshold;
    cfg.aggressive_threshold = plan_config->aggressive_threshold;
    cfg.target_byte_budget = static_cast<std::size_t>(plan_config->target_byte_budget);
    cfg.min_observation_keep = static_cast<std::uint16_t>(plan_config->min_observation_keep);
    cfg.patch_priority_boost = plan_config->patch_priority_boost;
    cfg.score_weight_opacity = plan_config->score_weight_opacity;
    cfg.score_weight_observation = plan_config->score_weight_observation;
    cfg.score_weight_certainty = plan_config->score_weight_certainty;
    cfg.preserve_quant_bits = plan_config->preserve_quant_bits;
    cfg.balanced_quant_bits = plan_config->balanced_quant_bits;
    cfg.aggressive_quant_bits = plan_config->aggressive_quant_bits;

    F3CompressionPlan plan{};
    auto rc = f3_plan_evidence_constrained_compression(
        cpp_gs.data(), cpp_gs.size(),
        cpp_beliefs.data(), cpp_beliefs.size(),
        patch_map ? &patch_map->impl : nullptr,
        base, cfg, &plan);
    if (rc != aether::core::Status::kOk) return -1;

    // Write output decisions
    if (out_decisions && inout_count) {
        int capacity = *inout_count;
        int written = std::min(capacity, static_cast<int>(plan.decisions.size()));
        for (int i = 0; i < written; ++i) {
            out_decisions[i].gaussian_index = plan.decisions[i].gaussian_index;
            out_decisions[i].gaussian_id = plan.decisions[i].gaussian_id;
            out_decisions[i].patch_id = nullptr;  // string owned by plan
            out_decisions[i].tier = static_cast<int>(plan.decisions[i].tier);
            out_decisions[i].keep = plan.decisions[i].keep ? 1 : 0;
            out_decisions[i].score = static_cast<double>(plan.decisions[i].score);
            out_decisions[i].belief = plan.decisions[i].belief;
            out_decisions[i].target_quant_bits = static_cast<uint8_t>(plan.decisions[i].target_quant_bits);
        }
        *inout_count = written;
    }

    out_plan->kept_count = static_cast<uint32_t>(plan.kept_count);
    out_plan->estimated_bytes = static_cast<uint32_t>(plan.estimated_bytes);
    out_plan->coverage_binding_sha256_hex = nullptr;  // owned by plan
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Innovation F5: Delta Patch Chain
// ═══════════════════════════════════════════════════════════════════════

aether_f5_chain_t* aether_f5_chain_create(void) {
    return new (std::nothrow) aether_f5_chain_t;
}

void aether_f5_chain_destroy(aether_f5_chain_t* chain) {
    delete chain;
}

int aether_f5_chain_reset(aether_f5_chain_t* chain) {
    if (!chain) return -1;
    auto rc = chain->impl.reset();
    return rc == aether::core::Status::kOk ? 0 : -1;
}

int aether_f5_chain_append_patch(
    aether_f5_chain_t* chain,
    const aether_gaussian_t* added_gaussians, int add_count,
    const uint32_t* removed_gaussian_ids, int remove_count,
    const aether_scaffold_unit_t* added_units, int add_unit_count,
    const uint64_t* removed_unit_ids, int remove_unit_count,
    double timestamp_ms,
    aether_f5_patch_receipt_t* out_receipt) {
    if (!chain || !out_receipt) return -1;
    if (add_count > 0 && !added_gaussians) return -1;
    if (remove_count > 0 && !removed_gaussian_ids) return -1;
    if (add_unit_count > 0 && !added_units) return -1;
    if (remove_unit_count > 0 && !removed_unit_ids) return -1;

    using namespace aether::innovation;
    F5DeltaPatch patch{};
    patch.parent_version = chain->impl.latest_version();
    patch.timestamp_ms = static_cast<std::int64_t>(timestamp_ms);

    // Build operations from the flat arrays.
    for (int i = 0; i < add_count; ++i) {
        F5PatchOperation op{};
        op.type = F5PatchOpType::kUpsertGaussian;
        op.gaussian = to_cpp_gaussian(added_gaussians[i]);
        patch.operations.push_back(std::move(op));
        patch.added_gaussians.push_back(to_cpp_gaussian(added_gaussians[i]));
    }
    for (int i = 0; i < remove_count; ++i) {
        F5PatchOperation op{};
        op.type = F5PatchOpType::kRemoveGaussian;
        op.gaussian_id = static_cast<GaussianId>(removed_gaussian_ids[i]);
        patch.operations.push_back(std::move(op));
        patch.removed_gaussian_ids.push_back(static_cast<GaussianId>(removed_gaussian_ids[i]));
    }
    for (int i = 0; i < add_unit_count; ++i) {
        F5PatchOperation op{};
        op.type = F5PatchOpType::kUpsertScaffoldUnit;
        ScaffoldUnit u{};
        u.unit_id = added_units[i].unit_id;
        u.generation = added_units[i].generation;
        u.v0 = added_units[i].v0;
        u.v1 = added_units[i].v1;
        u.v2 = added_units[i].v2;
        u.area = added_units[i].area;
        u.normal = to_cpp_float3(added_units[i].normal);
        u.confidence = added_units[i].confidence;
        u.view_count = added_units[i].view_count;
        u.lod_level = added_units[i].lod_level;
        if (added_units[i].patch_id) {
            u.patch_id = added_units[i].patch_id;
        }
        op.scaffold_unit = u;
        patch.operations.push_back(std::move(op));
    }
    for (int i = 0; i < remove_unit_count; ++i) {
        F5PatchOperation op{};
        op.type = F5PatchOpType::kRemoveScaffoldUnit;
        op.scaffold_unit_id = removed_unit_ids[i];
        patch.operations.push_back(std::move(op));
    }

    F5PatchReceipt receipt{};
    auto rc = chain->impl.append_patch(patch, &receipt);
    if (rc != aether::core::Status::kOk) return -1;

    out_receipt->version = receipt.version;
    out_receipt->leaf_index = receipt.leaf_index;
    out_receipt->patch_id = nullptr;  // receipt patch_id is a string; caller should not free

    // Convert hex strings to raw bytes.
    auto hex_to_bytes = [](const std::string& hex, uint8_t* out, std::size_t out_len) {
        std::memset(out, 0, out_len);
        std::size_t n = hex.size() / 2u;
        if (n > out_len) n = out_len;
        for (std::size_t i = 0u; i < n; ++i) {
            auto h = [](char c) -> uint8_t {
                if (c >= '0' && c <= '9') return static_cast<uint8_t>(c - '0');
                if (c >= 'a' && c <= 'f') return static_cast<uint8_t>(c - 'a' + 10);
                if (c >= 'A' && c <= 'F') return static_cast<uint8_t>(c - 'A' + 10);
                return 0u;
            };
            out[i] = static_cast<uint8_t>((h(hex[i * 2]) << 4) | h(hex[i * 2 + 1]));
        }
    };

    hex_to_bytes(receipt.patch_sha256_hex, out_receipt->patch_sha256, 32u);
    hex_to_bytes(receipt.merkle_root_hex, out_receipt->merkle_root, 32u);
    return 0;
}

int aether_f5_chain_patch_count(
    const aether_f5_chain_t* chain,
    uint64_t* out_count) {
    if (!chain || !out_count) return -1;
    *out_count = static_cast<uint64_t>(chain->impl.patch_count());
    return 0;
}

int aether_f5_chain_latest_version(
    const aether_f5_chain_t* chain,
    uint64_t* out_version) {
    if (!chain || !out_version) return -1;
    *out_version = chain->impl.latest_version();
    return 0;
}

int aether_f5_chain_merkle_root(
    const aether_f5_chain_t* chain,
    uint8_t out_hash[32]) {
    if (!chain || !out_hash) return -1;
    const auto& root = chain->impl.merkle_root();
    std::memcpy(out_hash, root.data(), 32u);
    return 0;
}

int aether_f5_chain_verify_receipt(
    const aether_f5_chain_t* chain,
    const aether_f5_patch_receipt_t* receipt,
    int* out_valid) {
    if (!chain || !receipt || !out_valid) return -1;
    // Simplified verification: check that the receipt's merkle root matches current root.
    const auto& current_root = chain->impl.merkle_root();
    bool match = (std::memcmp(receipt->merkle_root, current_root.data(), 32u) == 0);
    *out_valid = match ? 1 : 0;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Innovation F6: Conflict Dynamic Rejection
// ═══════════════════════════════════════════════════════════════════════

int aether_f6_default_config(aether_f6_config_t* out_config) {
    if (!out_config) return -1;
    aether::innovation::F6RejectorConfig def{};
    out_config->conflict_threshold = def.conflict_threshold;
    out_config->release_ratio = def.release_ratio;
    out_config->sustain_frames = def.sustain_frames;
    out_config->recover_frames = def.recover_frames;
    out_config->ema_alpha = def.ema_alpha;
    out_config->score_gain = def.score_gain;
    out_config->score_decay = def.score_decay;
    return 0;
}

aether_f6_rejector_t* aether_f6_create(const aether_f6_config_t* config) {
    if (!config) return nullptr;
    aether::innovation::F6RejectorConfig cfg{};
    cfg.conflict_threshold = config->conflict_threshold;
    cfg.release_ratio = config->release_ratio;
    cfg.sustain_frames = config->sustain_frames;
    cfg.recover_frames = config->recover_frames;
    cfg.ema_alpha = config->ema_alpha;
    cfg.score_gain = config->score_gain;
    cfg.score_decay = config->score_decay;
    return new (std::nothrow) aether_f6_rejector(cfg);
}

void aether_f6_destroy(aether_f6_rejector_t* rejector) {
    delete rejector;
}

int aether_f6_reset(aether_f6_rejector_t* rejector) {
    if (!rejector) return -1;
    rejector->impl.reset();
    return 0;
}

int aether_f6_process_frame(
    aether_f6_rejector_t* rejector,
    const aether_f6_observation_pair_t* observations, int obs_count,
    aether_gaussian_t* gaussians, int gaussian_count,
    aether_f6_frame_metrics_t* out_metrics) {
    if (!rejector || !out_metrics) return -1;
    if (obs_count > 0 && !observations) return -1;
    if (gaussian_count > 0 && !gaussians) return -1;

    // Convert observation pairs
    std::vector<aether::innovation::F6ObservationPair> cpp_pairs;
    cpp_pairs.reserve(static_cast<std::size_t>(obs_count));
    for (int i = 0; i < obs_count; ++i) {
        aether::innovation::F6ObservationPair p{};
        p.gaussian_id = observations[i].gaussian_id;
        p.host_unit_id = observations[i].host_unit_id;
        p.predicted = to_cpp_ds_mass(observations[i].predicted);
        p.observed = to_cpp_ds_mass(observations[i].observed);
        cpp_pairs.push_back(p);
    }

    // Convert gaussians
    std::vector<aether::innovation::GaussianPrimitive> cpp_gs;
    cpp_gs.reserve(static_cast<std::size_t>(gaussian_count));
    for (int i = 0; i < gaussian_count; ++i) {
        cpp_gs.push_back(to_cpp_gaussian(gaussians[i]));
    }

    aether::innovation::F6FrameMetrics metrics{};
    auto rc = rejector->impl.process_frame(
        cpp_pairs.data(), cpp_pairs.size(),
        cpp_gs.data(), cpp_gs.size(),
        &metrics);
    if (rc != aether::core::Status::kOk) return -1;

    // Write back modified flags to C gaussians
    for (int i = 0; i < gaussian_count && i < static_cast<int>(cpp_gs.size()); ++i) {
        gaussians[i].flags = cpp_gs[i].flags;
    }

    out_metrics->evaluated_count = static_cast<uint32_t>(metrics.evaluated_count);
    out_metrics->marked_dynamic_count = static_cast<uint32_t>(metrics.marked_dynamic_count);
    out_metrics->restored_static_count = static_cast<uint32_t>(metrics.restored_static_count);
    out_metrics->mean_conflict = metrics.mean_conflict;
    return 0;
}

int aether_f6_collect_static_indices(
    const aether_gaussian_t* gaussians, int gaussian_count,
    uint32_t* out_indices, int* inout_count) {
    if (!gaussians || !out_indices || !inout_count) return -1;
    // Collect indices of gaussians that do NOT have the dynamic flag set.
    // Convention: flag bit 0 = dynamic.
    int capacity = *inout_count;
    int written = 0;
    for (int i = 0; i < gaussian_count && written < capacity; ++i) {
        if ((gaussians[i].flags & 1u) == 0u) {
            out_indices[written++] = static_cast<uint32_t>(i);
        }
    }
    *inout_count = written;
    return 0;
}


// ═══════════════════════════════════════════════════════════════════════
// DGRUT: Default scoring config
// ═══════════════════════════════════════════════════════════════════════

int aether_dgrut_default_scoring_config(aether_dgrut_scoring_config_t* out_config) {
    if (!out_config) return -1;
    aether::render::DGRUTScoringConfig def{};
    out_config->weight_confidence = def.weight_confidence;
    out_config->weight_opacity = def.weight_opacity;
    out_config->weight_radius = def.weight_radius;
    out_config->weight_view_angle = def.weight_view_angle;
    out_config->weight_screen_coverage = def.weight_screen_coverage;
    out_config->newborn_boost = def.newborn_boost;
    out_config->newborn_frames = def.newborn_frames;
    out_config->depth_penalty_scale = def.depth_penalty_scale;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Meshlet: Default build config
// ═══════════════════════════════════════════════════════════════════════

int aether_meshlet_default_config(aether_meshlet_build_config_t* out_config) {
    if (!out_config) return -1;
    aether::render::MeshletBuildConfig def{};
    out_config->min_triangles_per_meshlet = static_cast<uint32_t>(def.min_triangles_per_meshlet);
    out_config->max_triangles_per_meshlet = static_cast<uint32_t>(def.max_triangles_per_meshlet);
    out_config->lod_activation_threshold = static_cast<uint32_t>(def.lod_activation_meshlet_threshold);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Two-Pass Culler: Select tier
// ═══════════════════════════════════════════════════════════════════════

int aether_two_pass_select_tier(
    const aether_two_pass_runtime_t* runtime,
    int* out_tier) {
    if (!runtime || !out_tier) return -1;
    aether::render::TwoPassRuntime rt{};
    rt.caps.mesh_shader_supported = (runtime->mesh_shader_supported != 0);
    rt.caps.gpu_hzb_supported = (runtime->gpu_hzb_supported != 0);
    rt.caps.compute_supported = (runtime->compute_supported != 0);
    auto tier = aether::render::select_two_pass_tier(rt);
    *out_tier = static_cast<int>(tier);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Mesh Extraction Scheduler
// ═══════════════════════════════════════════════════════════════════════

aether_mesh_extraction_scheduler_t* aether_mesh_extraction_scheduler_create(void) {
    return new (std::nothrow) aether_mesh_extraction_scheduler;
}

void aether_mesh_extraction_scheduler_destroy(aether_mesh_extraction_scheduler_t* scheduler) {
    delete scheduler;
}

int aether_mesh_extraction_next_budget(
    aether_mesh_extraction_scheduler_t* scheduler,
    int* out_budget) {
    if (!scheduler || !out_budget) return -1;
    *out_budget = scheduler->impl.next_block_budget();
    return 0;
}

int aether_mesh_extraction_report_cycle(
    aether_mesh_extraction_scheduler_t* scheduler,
    double elapsed_ms) {
    if (!scheduler) return -1;
    scheduler->impl.report_cycle(elapsed_ms);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// Morton code / Spatial Quantizer
// ═══════════════════════════════════════════════════════════════════════

uint64_t aether_morton_encode(int32_t x, int32_t y, int32_t z) {
    return aether::tsdf::SpatialQuantizer::morton_encode(x, y, z);
}

void aether_morton_decode(uint64_t code, int32_t* out_x, int32_t* out_y, int32_t* out_z) {
    if (!out_x || !out_y || !out_z) return;
    aether::tsdf::SpatialQuantizer::morton_decode(code, *out_x, *out_y, *out_z);
}

uint64_t aether_spatial_morton_code(
    const aether_spatial_quantizer_config_t* config,
    float wx, float wy, float wz) {
    if (!config) return 0u;
    aether::tsdf::SpatialQuantizer sq{};
    sq.origin_x = config->origin_x;
    sq.origin_y = config->origin_y;
    sq.origin_z = config->origin_z;
    sq.cell_size = config->cell_size;
    return sq.morton_code(wx, wy, wz);
}

// ═══════════════════════════════════════════════════════════════════════
// Hilbert code / Spatial Quantizer
// ═══════════════════════════════════════════════════════════════════════

uint64_t aether_hilbert_encode(int32_t x, int32_t y, int32_t z) {
    return aether::tsdf::SpatialQuantizer::hilbert_encode(x, y, z);
}

void aether_hilbert_decode(uint64_t code, int32_t* out_x, int32_t* out_y, int32_t* out_z) {
    if (!out_x || !out_y || !out_z) return;
    aether::tsdf::SpatialQuantizer::hilbert_decode(code, *out_x, *out_y, *out_z);
}

uint64_t aether_spatial_hilbert_code(
    const aether_spatial_quantizer_config_t* config,
    float wx, float wy, float wz) {
    if (!config) return 0u;
    aether::tsdf::SpatialQuantizer sq{};
    sq.origin_x = config->origin_x;
    sq.origin_y = config->origin_y;
    sq.origin_z = config->origin_z;
    sq.cell_size = config->cell_size;
    return sq.hilbert_code(wx, wy, wz);
}

// ═══════════════════════════════════════════════════════════════════════
// PRMath: Mathematical utilities
// ═══════════════════════════════════════════════════════════════════════

double aether_sigmoid(double x) {
    return aether::evidence::PRMath::sigmoid(x);
}

double aether_sigmoid01_from_threshold(double value, double threshold, double transition_width) {
    return aether::evidence::PRMath::sigmoid01_from_threshold(value, threshold, transition_width);
}

double aether_sigmoid_inverted01(double value, double threshold, double transition_width) {
    return aether::evidence::PRMath::sigmoid_inverted01_from_threshold(value, threshold, transition_width);
}

double aether_exp_safe(double x) {
    return aether::evidence::PRMath::exp_safe(x);
}

double aether_atan2_safe(double y, double x) {
    return aether::evidence::PRMath::atan2_safe(y, x);
}

double aether_asin_safe(double x) {
    return aether::evidence::PRMath::asin_safe(x);
}

double aether_sqrt_safe(double x) {
    return aether::evidence::PRMath::sqrt_safe(x);
}

double aether_clamp01(double x) {
    return aether::evidence::PRMath::clamp01(x);
}

int aether_is_usable(double x) {
    return aether::evidence::PRMath::is_usable(x) ? 1 : 0;
}

double aether_log_sigmoid(double x) {
    return aether::evidence::PRMath::log_sigmoid(x);
}

double aether_log_complement_sigmoid(double x) {
    return aether::evidence::PRMath::log_complement_sigmoid(x);
}

double aether_softplus(double x) {
    return aether::evidence::PRMath::softplus(x);
}

// ═══════════════════════════════════════════════════════════════════════
// Noise-Aware Training: compute weight and batch loss
// ═══════════════════════════════════════════════════════════════════════

int aether_noise_aware_compute_weight(
    const aether_noise_aware_sample_t* sample,
    float* out_weight) {
    if (!sample || !out_weight) return -1;
    aether::trainer::NoiseAwareSample s{};
    s.photometric_residual = sample->photometric_residual;
    s.depth_residual = sample->depth_residual;
    s.sigma2 = sample->sigma2;
    s.confidence = sample->confidence;
    s.tri_tet_class = to_cpp_tri_tet_class(sample->tri_tet_class);
    *out_weight = aether::trainer::compute_noise_aware_weight(s);
    return 0;
}

int aether_noise_aware_batch_loss(
    const aether_noise_aware_sample_t* samples, int count,
    aether_noise_aware_result_t* out_result) {
    if (!out_result) return -1;
    if (count > 0 && !samples) return -1;
    std::vector<aether::trainer::NoiseAwareSample> cpp_samples;
    cpp_samples.reserve(static_cast<std::size_t>(count));
    for (int i = 0; i < count; ++i) {
        aether::trainer::NoiseAwareSample s{};
        s.photometric_residual = samples[i].photometric_residual;
        s.depth_residual = samples[i].depth_residual;
        s.sigma2 = samples[i].sigma2;
        s.confidence = samples[i].confidence;
        s.tri_tet_class = to_cpp_tri_tet_class(samples[i].tri_tet_class);
        cpp_samples.push_back(s);
    }
    aether::trainer::NoiseAwareAccumulator acc{};
    auto rc = aether::trainer::accumulate_noise_aware_batch(
        cpp_samples.data(), cpp_samples.size(), &acc);
    if (rc != aether::core::Status::kOk) return -1;
    out_result->weighted_loss = aether::trainer::finalize_noise_aware_loss(acc);
    out_result->weight_sum = static_cast<float>(acc.weight_sum);
    out_result->sample_count = static_cast<uint32_t>(acc.sample_count);
    return 0;
}


// ═══════════════════════════════════════════════════════════════════════
// TriTet Mapping: Parity + Decompose + Map Single
// ═══════════════════════════════════════════════════════════════════════

int aether_tri_tet_parity(int32_t bx, int32_t by, int32_t bz) {
    return aether::tsdf::TriTetMapping::parity(bx, by, bz);
}

int aether_tri_tet_decompose(
    int32_t bx, int32_t by, int32_t bz,
    aether_tri_tet_cell_t out_cells[5]) {
    if (!out_cells) return -1;
    aether::tsdf::TriTetMappedCell cpp_cells[5];
    int n = aether::tsdf::TriTetMapping::decompose(bx, by, bz, cpp_cells);
    for (int i = 0; i < n; ++i) {
        out_cells[i].vertex_indices[0] = cpp_cells[i].vertex_indices[0];
        out_cells[i].vertex_indices[1] = cpp_cells[i].vertex_indices[1];
        out_cells[i].vertex_indices[2] = cpp_cells[i].vertex_indices[2];
        out_cells[i].vertex_indices[3] = cpp_cells[i].vertex_indices[3];
        out_cells[i].tet_index = cpp_cells[i].tet_index;
    }
    return n;
}

int aether_tri_tet_map_single(
    int32_t bx, int32_t by, int32_t bz,
    int local_tet_index,
    aether_tri_tet_cell_t* out_cell) {
    if (!out_cell) return -1;
    aether::tsdf::TriTetMappedCell cpp_cell{};
    bool ok = aether::tsdf::TriTetMapping::map_single(bx, by, bz, local_tet_index, cpp_cell);
    if (!ok) return -1;
    out_cell->vertex_indices[0] = cpp_cell.vertex_indices[0];
    out_cell->vertex_indices[1] = cpp_cell.vertex_indices[1];
    out_cell->vertex_indices[2] = cpp_cell.vertex_indices[2];
    out_cell->vertex_indices[3] = cpp_cell.vertex_indices[3];
    out_cell->tet_index = cpp_cell.tet_index;
    return 0;
}


}  // extern "C"

// ═══════════════════════════════════════════════════════════════════════
// GPU Abstraction Layer — C API implementation
// ═══════════════════════════════════════════════════════════════════════



using namespace aether::render;

// ─── Null implementations for command objects (no-op, for headless/testing) ───

namespace {

class NullComputeEncoder final : public GPUComputeEncoder {
public:
    NullComputeEncoder() = default;
    void set_pipeline(GPUComputePipelineHandle) noexcept override {}
    void set_buffer(GPUBufferHandle, std::uint32_t, std::uint32_t) noexcept override {}
    void set_texture(GPUTextureHandle, std::uint32_t) noexcept override {}
    void set_bytes(const void*, std::uint32_t, std::uint32_t) noexcept override {}
    void dispatch(std::uint32_t, std::uint32_t, std::uint32_t,
                  std::uint32_t, std::uint32_t, std::uint32_t) noexcept override {}
    void end_encoding() noexcept override { ended_ = true; }
    bool ended() const noexcept { return ended_; }
private:
    bool ended_{false};
};

class NullRenderEncoder final : public GPURenderEncoder {
public:
    NullRenderEncoder() = default;
    void set_pipeline(GPURenderPipelineHandle) noexcept override {}
    void set_vertex_buffer(GPUBufferHandle, std::uint32_t, std::uint32_t) noexcept override {}
    void set_fragment_buffer(GPUBufferHandle, std::uint32_t, std::uint32_t) noexcept override {}
    void set_vertex_bytes(const void*, std::uint32_t, std::uint32_t) noexcept override {}
    void set_fragment_bytes(const void*, std::uint32_t, std::uint32_t) noexcept override {}
    void set_vertex_texture(GPUTextureHandle, std::uint32_t) noexcept override {}
    void set_fragment_texture(GPUTextureHandle, std::uint32_t) noexcept override {}
    void set_viewport(const GPUViewport&) noexcept override {}
    void set_scissor(const GPUScissorRect&) noexcept override {}
    void set_cull_mode(GPUCullMode) noexcept override {}
    void set_winding(GPUWindingOrder) noexcept override {}
    void draw(GPUPrimitiveType, std::uint32_t, std::uint32_t) noexcept override {}
    void draw_indexed(GPUPrimitiveType, std::uint32_t, GPUBufferHandle, std::uint32_t) noexcept override {}
    void draw_instanced(GPUPrimitiveType, std::uint32_t, std::uint32_t) noexcept override {}
    void end_encoding() noexcept override { ended_ = true; }
    bool ended() const noexcept { return ended_; }
private:
    bool ended_{false};
};

class NullCommandBuffer final : public GPUCommandBuffer {
public:
    NullCommandBuffer() = default;
    ~NullCommandBuffer() override {
        delete compute_enc_;
        delete render_enc_;
    }
    GPUComputeEncoder* make_compute_encoder() noexcept override {
        delete compute_enc_;
        compute_enc_ = new (std::nothrow) NullComputeEncoder();
        return compute_enc_;
    }
    GPURenderEncoder* make_render_encoder(const GPURenderTargetDesc&) noexcept override {
        delete render_enc_;
        render_enc_ = new (std::nothrow) NullRenderEncoder();
        return render_enc_;
    }
    void commit() noexcept override { committed_ = true; }
    void wait_until_completed() noexcept override {}
    GPUTimestamp timestamp() const noexcept override { return GPUTimestamp{}; }
    bool had_error() const noexcept override { return false; }
    bool committed() const noexcept { return committed_; }
    NullComputeEncoder* current_compute() noexcept { return compute_enc_; }
    NullRenderEncoder* current_render() noexcept { return render_enc_; }
private:
    bool committed_{false};
    NullComputeEncoder* compute_enc_{nullptr};
    NullRenderEncoder* render_enc_{nullptr};
};

}  // anonymous namespace

// Wrapper structs for opaque C types
struct aether_gpu_device {
    GPUDevice* impl;  // owned
};

struct aether_gpu_command_buffer {
    GPUCommandBuffer* impl;  // owned
    aether_gpu_device* device;
};

struct aether_gpu_compute_encoder {
    GPUComputeEncoder* impl;  // NOT owned; lifetime managed by command buffer
    aether_gpu_command_buffer* cmd_buf;
};

struct aether_gpu_render_encoder {
    GPURenderEncoder* impl;  // NOT owned; lifetime managed by command buffer
    aether_gpu_command_buffer* cmd_buf;
};

// Helper: map C storage mode to C++
static GPUStorageMode map_c_storage_mode(int mode) {
    switch (mode) {
        case AETHER_GPU_STORAGE_PRIVATE: return GPUStorageMode::kPrivate;
        case AETHER_GPU_STORAGE_MANAGED: return GPUStorageMode::kManaged;
        default: return GPUStorageMode::kShared;
    }
}

// Helper: map C shader stage to C++
static GPUShaderStage map_c_shader_stage(int stage) {
    switch (stage) {
        case AETHER_GPU_SHADER_FRAGMENT: return GPUShaderStage::kFragment;
        case AETHER_GPU_SHADER_COMPUTE: return GPUShaderStage::kCompute;
        default: return GPUShaderStage::kVertex;
    }
}

// Helper: map C++ GraphicsBackend to C enum
static int map_backend_to_c(GraphicsBackend b) {
    switch (b) {
        case GraphicsBackend::kMetal: return AETHER_GPU_BACKEND_METAL;
        case GraphicsBackend::kVulkan: return AETHER_GPU_BACKEND_VULKAN;
        case GraphicsBackend::kOpenGLES: return AETHER_GPU_BACKEND_OPENGLES;
        default: return AETHER_GPU_BACKEND_UNKNOWN;
    }
}

// Helper: map C primitive to C++
static GPUPrimitiveType map_c_primitive(int prim) {
    switch (prim) {
        case AETHER_GPU_PRIMITIVE_TRIANGLE_STRIP: return GPUPrimitiveType::kTriangleStrip;
        case AETHER_GPU_PRIMITIVE_LINE: return GPUPrimitiveType::kLine;
        case AETHER_GPU_PRIMITIVE_POINT: return GPUPrimitiveType::kPoint;
        default: return GPUPrimitiveType::kTriangle;
    }
}

// Helper: map C cull mode to C++
static GPUCullMode map_c_cull_mode(int mode) {
    switch (mode) {
        case AETHER_GPU_CULL_FRONT: return GPUCullMode::kFront;
        case AETHER_GPU_CULL_BACK: return GPUCullMode::kBack;
        default: return GPUCullMode::kNone;
    }
}

// Helper: build C++ GPURenderTargetDesc from C desc
static GPURenderTargetDesc make_cpp_render_target(const aether_gpu_render_target_desc_t* desc) {
    GPURenderTargetDesc rt{};
    if (desc) {
        rt.clear_color[0] = desc->clear_color[0];
        rt.clear_color[1] = desc->clear_color[1];
        rt.clear_color[2] = desc->clear_color[2];
        rt.clear_color[3] = desc->clear_color[3];
        rt.clear_depth = desc->clear_depth;
        // Map load/store actions
        switch (desc->color_load_action) {
            case AETHER_GPU_LOAD_CLEAR:     rt.color_load = GPULoadAction::kClear; break;
            case AETHER_GPU_LOAD_LOAD:      rt.color_load = GPULoadAction::kLoad; break;
            case AETHER_GPU_LOAD_DONT_CARE: rt.color_load = GPULoadAction::kDontCare; break;
            default: break;
        }
        switch (desc->color_store_action) {
            case AETHER_GPU_STORE_STORE:     rt.color_store = GPUStoreAction::kStore; break;
            case AETHER_GPU_STORE_DONT_CARE: rt.color_store = GPUStoreAction::kDontCare; break;
            default: break;
        }
        switch (desc->depth_load_action) {
            case AETHER_GPU_LOAD_CLEAR:     rt.depth_load = GPULoadAction::kClear; break;
            case AETHER_GPU_LOAD_LOAD:      rt.depth_load = GPULoadAction::kLoad; break;
            case AETHER_GPU_LOAD_DONT_CARE: rt.depth_load = GPULoadAction::kDontCare; break;
            default: break;
        }
        switch (desc->depth_store_action) {
            case AETHER_GPU_STORE_STORE:     rt.depth_store = GPUStoreAction::kStore; break;
            case AETHER_GPU_STORE_DONT_CARE: rt.depth_store = GPUStoreAction::kDontCare; break;
            default: break;
        }
    }
    return rt;
}

// ═══════════════════════════════════════════════════════════════════════

extern "C" {

// GPU Device
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_device_t* aether_gpu_device_create_null(void) {
    auto* dev = new (std::nothrow) aether_gpu_device_t();
    if (!dev) return nullptr;
    dev->impl = new (std::nothrow) NullGPUDevice();
    if (!dev->impl) {
        delete dev;
        return nullptr;
    }
    return dev;
}

void aether_gpu_device_destroy(aether_gpu_device_t* device) {
    if (!device) return;
    delete device->impl;
    delete device;
}

int aether_gpu_device_get_backend(const aether_gpu_device_t* device) {
    if (!device || !device->impl) return AETHER_GPU_BACKEND_UNKNOWN;
    return map_backend_to_c(device->impl->backend());
}

int aether_gpu_device_get_caps(const aether_gpu_device_t* device, aether_gpu_caps_t* out) {
    if (!device || !device->impl || !out) return -1;
    GPUCaps caps = device->impl->capabilities();
    out->backend = map_backend_to_c(caps.backend);
    out->max_buffer_size = caps.max_buffer_size;
    out->max_texture_size = caps.max_texture_size;
    out->max_compute_workgroup_size = caps.max_compute_workgroup_size;
    out->max_threadgroup_memory = caps.max_threadgroup_memory;
    out->supports_compute = caps.supports_compute ? 1 : 0;
    out->supports_indirect_draw = caps.supports_indirect_draw ? 1 : 0;
    out->supports_shared_memory = caps.supports_shared_memory ? 1 : 0;
    out->supports_half_precision = caps.supports_half_precision ? 1 : 0;
    out->supports_simd_group = caps.supports_simd_group ? 1 : 0;
    out->simd_width = caps.simd_width;
    return 0;
}

int aether_gpu_device_get_memory_stats(const aether_gpu_device_t* device, aether_gpu_memory_stats_t* out) {
    if (!device || !device->impl || !out) return -1;
    GPUMemoryStats stats = device->impl->memory_stats();
    out->allocated_bytes = static_cast<uint64_t>(stats.allocated_bytes);
    out->peak_bytes = static_cast<uint64_t>(stats.peak_bytes);
    out->buffer_count = stats.buffer_count;
    out->texture_count = stats.texture_count;
    return 0;
}

int aether_gpu_device_wait_idle(aether_gpu_device_t* device) {
    if (!device || !device->impl) return -1;
    device->impl->wait_idle();
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Buffer
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_buffer_handle_t aether_gpu_buffer_create(aether_gpu_device_t* device, const aether_gpu_buffer_desc_t* desc) {
    if (!device || !device->impl || !desc) return 0;
    GPUBufferDesc cpp_desc{};
    cpp_desc.size_bytes = static_cast<std::size_t>(desc->size);
    cpp_desc.storage = map_c_storage_mode(desc->storage_mode);
    cpp_desc.usage_mask = static_cast<std::uint8_t>(desc->usage);
    GPUBufferHandle h = device->impl->create_buffer(cpp_desc);
    return h.id;
}

void aether_gpu_buffer_destroy(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->destroy_buffer(GPUBufferHandle{handle});
}

void* aether_gpu_buffer_map(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle) {
    if (!device || !device->impl) return nullptr;
    return device->impl->map_buffer(GPUBufferHandle{handle});
}

void aether_gpu_buffer_unmap(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->unmap_buffer(GPUBufferHandle{handle});
}

int aether_gpu_buffer_update(aether_gpu_device_t* device, aether_gpu_buffer_handle_t handle, const void* data, uint32_t offset, uint32_t size) {
    if (!device || !device->impl) return -1;
    device->impl->update_buffer(GPUBufferHandle{handle}, data, static_cast<std::size_t>(offset), static_cast<std::size_t>(size));
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Texture
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_texture_handle_t aether_gpu_texture_create(aether_gpu_device_t* device, const aether_gpu_texture_desc_t* desc) {
    if (!device || !device->impl || !desc) return 0;
    GPUTextureDesc cpp_desc{};
    cpp_desc.width = desc->width;
    cpp_desc.height = desc->height;
    cpp_desc.depth = desc->depth;
    // Map C format enum to C++ GPUTextureFormat
    switch (desc->format) {
        case AETHER_GPU_FORMAT_RGBA8:    cpp_desc.format = GPUTextureFormat::kRGBA8Unorm; break;
        case AETHER_GPU_FORMAT_RGBA16F:  cpp_desc.format = GPUTextureFormat::kRGBA16Float; break;
        case AETHER_GPU_FORMAT_RGBA32F:  cpp_desc.format = GPUTextureFormat::kRGBA32Float; break;
        case AETHER_GPU_FORMAT_R32F:     cpp_desc.format = GPUTextureFormat::kR32Float; break;
        case AETHER_GPU_FORMAT_DEPTH32F: cpp_desc.format = GPUTextureFormat::kDepth32Float; break;
        case AETHER_GPU_FORMAT_R8:       cpp_desc.format = GPUTextureFormat::kR8Unorm; break;
        case AETHER_GPU_FORMAT_RG16F:    cpp_desc.format = GPUTextureFormat::kRG16Float; break;
        default: cpp_desc.format = GPUTextureFormat::kRGBA8Unorm; break;
    }
    cpp_desc.usage_mask = static_cast<std::uint8_t>(desc->usage);
    cpp_desc.storage = map_c_storage_mode(desc->storage_mode);
    GPUTextureHandle h = device->impl->create_texture(cpp_desc);
    return h.id;
}

void aether_gpu_texture_destroy(aether_gpu_device_t* device, aether_gpu_texture_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->destroy_texture(GPUTextureHandle{handle});
}

int aether_gpu_texture_update(aether_gpu_device_t* device, aether_gpu_texture_handle_t handle, const void* data, uint32_t width, uint32_t height, uint32_t bytes_per_row) {
    if (!device || !device->impl) return -1;
    device->impl->update_texture(GPUTextureHandle{handle}, data, width, height, bytes_per_row);
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Shader & Pipeline
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_shader_handle_t aether_gpu_shader_load(aether_gpu_device_t* device, const char* name, int stage) {
    if (!device || !device->impl || !name) return 0;
    GPUShaderHandle h = device->impl->load_shader(name, map_c_shader_stage(stage));
    return h.id;
}

void aether_gpu_shader_destroy(aether_gpu_device_t* device, aether_gpu_shader_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->destroy_shader(GPUShaderHandle{handle});
}

aether_gpu_render_pipeline_handle_t aether_gpu_render_pipeline_create(
    aether_gpu_device_t* device,
    aether_gpu_shader_handle_t vs,
    aether_gpu_shader_handle_t fs,
    const aether_gpu_render_target_desc_t* target) {
    if (!device || !device->impl) return 0;
    GPURenderTargetDesc rt = make_cpp_render_target(target);
    GPURenderPipelineHandle h = device->impl->create_render_pipeline(
        GPUShaderHandle{vs}, GPUShaderHandle{fs}, rt);
    return h.id;
}

void aether_gpu_render_pipeline_destroy(aether_gpu_device_t* device, aether_gpu_render_pipeline_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->destroy_render_pipeline(GPURenderPipelineHandle{handle});
}

aether_gpu_compute_pipeline_handle_t aether_gpu_compute_pipeline_create(aether_gpu_device_t* device, aether_gpu_shader_handle_t cs) {
    if (!device || !device->impl) return 0;
    GPUComputePipelineHandle h = device->impl->create_compute_pipeline(GPUShaderHandle{cs});
    return h.id;
}

void aether_gpu_compute_pipeline_destroy(aether_gpu_device_t* device, aether_gpu_compute_pipeline_handle_t handle) {
    if (!device || !device->impl) return;
    device->impl->destroy_compute_pipeline(GPUComputePipelineHandle{handle});
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Command Buffer
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_command_buffer_t* aether_gpu_command_buffer_create(aether_gpu_device_t* device) {
    if (!device || !device->impl) return nullptr;
    auto* cmd = new (std::nothrow) NullCommandBuffer();
    if (!cmd) return nullptr;
    auto* wrapper = new (std::nothrow) aether_gpu_command_buffer_t();
    if (!wrapper) {
        delete cmd;
        return nullptr;
    }
    wrapper->impl = cmd;
    wrapper->device = device;
    return wrapper;
}

void aether_gpu_command_buffer_destroy(aether_gpu_command_buffer_t* buf) {
    if (!buf) return;
    delete buf->impl;
    delete buf;
}

int aether_gpu_command_buffer_commit(aether_gpu_command_buffer_t* buf) {
    if (!buf || !buf->impl) return -1;
    buf->impl->commit();
    return 0;
}

int aether_gpu_command_buffer_wait(aether_gpu_command_buffer_t* buf) {
    if (!buf || !buf->impl) return -1;
    buf->impl->wait_until_completed();
    return 0;
}

int aether_gpu_command_buffer_had_error(const aether_gpu_command_buffer_t* buf) {
    if (!buf || !buf->impl) return -1;
    return buf->impl->had_error() ? 1 : 0;
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Compute Encoder
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_compute_encoder_t* aether_gpu_compute_encoder_create(aether_gpu_command_buffer_t* buf) {
    if (!buf || !buf->impl) return nullptr;
    GPUComputeEncoder* enc = buf->impl->make_compute_encoder();
    if (!enc) return nullptr;
    auto* wrapper = new (std::nothrow) aether_gpu_compute_encoder_t();
    if (!wrapper) return nullptr;
    wrapper->impl = enc;
    wrapper->cmd_buf = buf;
    return wrapper;
}

void aether_gpu_compute_encoder_destroy(aether_gpu_compute_encoder_t* enc) {
    if (!enc) return;
    // impl is owned by command buffer, do NOT delete it
    delete enc;
}

int aether_gpu_compute_set_pipeline(aether_gpu_compute_encoder_t* enc, aether_gpu_compute_pipeline_handle_t p) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_pipeline(GPUComputePipelineHandle{p});
    return 0;
}

int aether_gpu_compute_set_buffer(aether_gpu_compute_encoder_t* enc, aether_gpu_buffer_handle_t buf, uint32_t offset, uint32_t index) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_buffer(GPUBufferHandle{buf}, offset, index);
    return 0;
}

int aether_gpu_compute_set_texture(aether_gpu_compute_encoder_t* enc, aether_gpu_texture_handle_t tex, uint32_t index) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_texture(GPUTextureHandle{tex}, index);
    return 0;
}

int aether_gpu_compute_dispatch(aether_gpu_compute_encoder_t* enc, uint32_t gx, uint32_t gy, uint32_t gz, uint32_t tx, uint32_t ty, uint32_t tz) {
    if (!enc || !enc->impl) return -1;
    enc->impl->dispatch(gx, gy, gz, tx, ty, tz);
    return 0;
}

int aether_gpu_compute_end(aether_gpu_compute_encoder_t* enc) {
    if (!enc || !enc->impl) return -1;
    enc->impl->end_encoding();
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════
// GPU Render Encoder
// ═══════════════════════════════════════════════════════════════════════

aether_gpu_render_encoder_t* aether_gpu_render_encoder_create(aether_gpu_command_buffer_t* buf, const aether_gpu_render_target_desc_t* target) {
    if (!buf || !buf->impl) return nullptr;
    GPURenderTargetDesc rt = make_cpp_render_target(target);
    GPURenderEncoder* enc = buf->impl->make_render_encoder(rt);
    if (!enc) return nullptr;
    auto* wrapper = new (std::nothrow) aether_gpu_render_encoder_t();
    if (!wrapper) return nullptr;
    wrapper->impl = enc;
    wrapper->cmd_buf = buf;
    return wrapper;
}

void aether_gpu_render_encoder_destroy(aether_gpu_render_encoder_t* enc) {
    if (!enc) return;
    // impl is owned by command buffer, do NOT delete it
    delete enc;
}

int aether_gpu_render_set_pipeline(aether_gpu_render_encoder_t* enc, aether_gpu_render_pipeline_handle_t p) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_pipeline(GPURenderPipelineHandle{p});
    return 0;
}

int aether_gpu_render_set_vertex_buffer(aether_gpu_render_encoder_t* enc, aether_gpu_buffer_handle_t buf, uint32_t offset, uint32_t index) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_vertex_buffer(GPUBufferHandle{buf}, offset, index);
    return 0;
}

int aether_gpu_render_set_viewport(aether_gpu_render_encoder_t* enc, const aether_gpu_viewport_t* vp) {
    if (!enc || !enc->impl || !vp) return -1;
    GPUViewport cpp_vp{};
    cpp_vp.origin_x = vp->x;
    cpp_vp.origin_y = vp->y;
    cpp_vp.width = vp->width;
    cpp_vp.height = vp->height;
    cpp_vp.near_depth = vp->near_depth;
    cpp_vp.far_depth = vp->far_depth;
    enc->impl->set_viewport(cpp_vp);
    return 0;
}

int aether_gpu_render_set_scissor(aether_gpu_render_encoder_t* enc, const aether_gpu_scissor_rect_t* r) {
    if (!enc || !enc->impl || !r) return -1;
    GPUScissorRect cpp_rect{};
    cpp_rect.x = r->x;
    cpp_rect.y = r->y;
    cpp_rect.width = r->width;
    cpp_rect.height = r->height;
    enc->impl->set_scissor(cpp_rect);
    return 0;
}

int aether_gpu_render_set_cull_mode(aether_gpu_render_encoder_t* enc, int mode) {
    if (!enc || !enc->impl) return -1;
    enc->impl->set_cull_mode(map_c_cull_mode(mode));
    return 0;
}

int aether_gpu_render_draw(aether_gpu_render_encoder_t* enc, int primitive, uint32_t vertex_start, uint32_t vertex_count) {
    if (!enc || !enc->impl) return -1;
    enc->impl->draw(map_c_primitive(primitive), vertex_start, vertex_count);
    return 0;
}

int aether_gpu_render_draw_indexed(aether_gpu_render_encoder_t* enc, int primitive, uint32_t index_count, aether_gpu_buffer_handle_t index_buf, uint32_t offset) {
    if (!enc || !enc->impl) return -1;
    enc->impl->draw_indexed(map_c_primitive(primitive), index_count, GPUBufferHandle{index_buf}, offset);
    return 0;
}

int aether_gpu_render_draw_instanced(aether_gpu_render_encoder_t* enc, int primitive, uint32_t vertex_count, uint32_t instance_count) {
    if (!enc || !enc->impl) return -1;
    enc->impl->draw_instanced(map_c_primitive(primitive), vertex_count, instance_count);
    return 0;
}

int aether_gpu_render_end(aether_gpu_render_encoder_t* enc) {
    if (!enc || !enc->impl) return -1;
    enc->impl->end_encoding();
    return 0;
}

// ===========================================================================
// Evidence State Machine (S0-S5)
// ===========================================================================

struct aether_evidence_state_machine {
    explicit aether_evidence_state_machine(
        const aether::evidence::EvidenceStateMachineConfig& config)
        : impl(config) {}
    aether::evidence::EvidenceStateMachine impl;
};

namespace {

aether_color_state_t to_c_color_state(aether::evidence::ColorState s) {
    switch (s) {
        case aether::evidence::ColorState::kBlack:     return AETHER_COLOR_STATE_BLACK;
        case aether::evidence::ColorState::kDarkGray:  return AETHER_COLOR_STATE_DARK_GRAY;
        case aether::evidence::ColorState::kLightGray: return AETHER_COLOR_STATE_LIGHT_GRAY;
        case aether::evidence::ColorState::kWhite:     return AETHER_COLOR_STATE_WHITE;
        case aether::evidence::ColorState::kOriginal:  return AETHER_COLOR_STATE_ORIGINAL;
        case aether::evidence::ColorState::kUnknown:   return AETHER_COLOR_STATE_UNKNOWN;
    }
    return AETHER_COLOR_STATE_UNKNOWN;
}

}  // anonymous namespace

int aether_evidence_state_machine_default_config(
    aether_evidence_state_machine_config_t* out_config) {
    if (out_config == nullptr) return -1;
    std::memset(out_config, 0, sizeof(*out_config));
    const aether::evidence::EvidenceStateMachineConfig cpp{};
    out_config->s0_to_s1_threshold       = cpp.s0_to_s1_threshold;
    out_config->s1_to_s2_threshold       = cpp.s1_to_s2_threshold;
    out_config->s2_to_s3_threshold       = cpp.s2_to_s3_threshold;
    out_config->s3_to_s4_threshold       = cpp.s3_to_s4_threshold;
    out_config->s4_to_s5_threshold       = cpp.s4_to_s5_threshold;
    out_config->s5_min_choquet           = cpp.s5_min_choquet;
    out_config->s5_min_dimension_score   = cpp.s5_min_dimension_score;
    out_config->s5_max_uncertainty_width = cpp.s5_max_uncertainty_width;
    out_config->s5_min_high_obs_ratio    = cpp.s5_min_high_obs_ratio;
    out_config->s5_max_lyapunov_rate     = cpp.s5_max_lyapunov_rate;
    return 0;
}

int aether_evidence_state_machine_create(
    const aether_evidence_state_machine_config_t* config_or_null,
    aether_evidence_state_machine_t** out_machine) {
    if (out_machine == nullptr) return -1;
    aether::evidence::EvidenceStateMachineConfig cpp_config{};
    if (config_or_null != nullptr) {
        auto valid01 = [](double v) { return v >= 0.0 && v <= 1.0 && v == v; };
        if (valid01(config_or_null->s0_to_s1_threshold)) {
            cpp_config.s0_to_s1_threshold = config_or_null->s0_to_s1_threshold;
        }
        if (valid01(config_or_null->s1_to_s2_threshold)) {
            cpp_config.s1_to_s2_threshold = config_or_null->s1_to_s2_threshold;
        }
        if (valid01(config_or_null->s2_to_s3_threshold)) {
            cpp_config.s2_to_s3_threshold = config_or_null->s2_to_s3_threshold;
        }
        if (valid01(config_or_null->s3_to_s4_threshold)) {
            cpp_config.s3_to_s4_threshold = config_or_null->s3_to_s4_threshold;
        }
        if (valid01(config_or_null->s4_to_s5_threshold)) {
            cpp_config.s4_to_s5_threshold = config_or_null->s4_to_s5_threshold;
        }
        // S5 information-theoretic gate thresholds
        if (valid01(config_or_null->s5_min_choquet)) {
            cpp_config.s5_min_choquet = config_or_null->s5_min_choquet;
        }
        if (valid01(config_or_null->s5_min_dimension_score)) {
            cpp_config.s5_min_dimension_score = config_or_null->s5_min_dimension_score;
        }
        if (valid01(config_or_null->s5_max_uncertainty_width)) {
            cpp_config.s5_max_uncertainty_width = config_or_null->s5_max_uncertainty_width;
        }
        if (valid01(config_or_null->s5_min_high_obs_ratio)) {
            cpp_config.s5_min_high_obs_ratio = config_or_null->s5_min_high_obs_ratio;
        }
        // Lyapunov rate is not [0,1] — just needs to be positive finite
        if (config_or_null->s5_max_lyapunov_rate > 0.0 &&
            config_or_null->s5_max_lyapunov_rate == config_or_null->s5_max_lyapunov_rate) {
            cpp_config.s5_max_lyapunov_rate = config_or_null->s5_max_lyapunov_rate;
        }
    }
    auto* machine = new (std::nothrow) aether_evidence_state_machine_t(cpp_config);
    if (machine == nullptr) return -2;
    *out_machine = machine;
    return 0;
}

int aether_evidence_state_machine_destroy(
    aether_evidence_state_machine_t* machine) {
    if (machine == nullptr) return -1;
    delete machine;
    return 0;
}

int aether_evidence_state_machine_reset(
    aether_evidence_state_machine_t* machine) {
    if (machine == nullptr) return -1;
    machine->impl.reset();
    return 0;
}

int aether_evidence_state_machine_evaluate(
    aether_evidence_state_machine_t* machine,
    const aether_evidence_state_machine_input_t* input,
    aether_evidence_state_machine_result_t* out_result) {
    if (machine == nullptr || input == nullptr || out_result == nullptr) return -1;
    std::memset(out_result, 0, sizeof(*out_result));

    aether::evidence::EvidenceStateMachineInput cpp_input{};
    cpp_input.coverage                = input->coverage;
    cpp_input.plausibility_coverage   = input->plausibility_coverage;
    cpp_input.uncertainty_width       = input->uncertainty_width;
    cpp_input.high_observation_ratio  = input->high_observation_ratio;
    cpp_input.lyapunov_rate           = input->lyapunov_rate;
    for (int i = 0; i < 10; ++i) {
        cpp_input.dim_scores[i] = input->dim_scores[i];
    }

    const auto result = machine->impl.evaluate(cpp_input);
    out_result->state                = to_c_color_state(result.state);
    out_result->previous_state       = to_c_color_state(result.previous_state);
    out_result->transitioned         = result.transitioned ? 1 : 0;
    out_result->coverage_cert        = static_cast<int>(result.coverage_cert);
    out_result->choquet_cert         = static_cast<int>(result.choquet_cert);
    out_result->choquet_value        = result.choquet_value;
    out_result->min_super_dim        = result.min_super_dim;
    out_result->certification_margin = result.certification_margin;
    return 0;
}

int aether_evidence_state_machine_current_state(
    const aether_evidence_state_machine_t* machine,
    aether_color_state_t* out_state) {
    if (machine == nullptr || out_state == nullptr) return -1;
    *out_state = to_c_color_state(machine->impl.current_state());
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Mesh Topology Diagnostics
// ═══════════════════════════════════════════════════════════════════════════

int aether_compute_mesh_topology(
    const uint32_t* indices,
    uint64_t index_count,
    uint64_t vertex_count,
    aether_mesh_topology_diagnostics_t* out) {
    if (out == nullptr) return -1;
    std::memset(out, 0, sizeof(*out));

    const auto diag = aether::tsdf::compute_mesh_topology_from_indices(
        indices,
        static_cast<std::size_t>(index_count),
        static_cast<std::size_t>(vertex_count));

    out->vertex_count = diag.vertex_count;
    out->edge_count = diag.edge_count;
    out->face_count = diag.face_count;
    out->euler_characteristic = diag.euler_characteristic;
    out->expected_euler = diag.expected_euler;
    out->topology_ok = diag.topology_ok ? 1 : 0;
    out->boundary_edge_count = diag.boundary_edge_count;
    return 0;
}

// ═══════════════════════════════════════════════════════════════════════════
// Fiedler Value (algebraic connectivity)
// ═══════════════════════════════════════════════════════════════════════════

int aether_compute_fiedler_value(
    const uint32_t* indices,
    uint64_t index_count,
    uint64_t vertex_count,
    int max_iterations,
    aether_fiedler_result_t* out) {
    if (out == nullptr) return -1;
    std::memset(out, 0, sizeof(*out));

    const auto r = aether::tsdf::compute_fiedler_value(
        indices,
        static_cast<std::size_t>(index_count),
        static_cast<std::size_t>(vertex_count),
        max_iterations > 0 ? max_iterations : 100);

    out->fiedler_value = r.fiedler_value;
    out->computed = r.computed ? 1 : 0;
    out->iterations_used = r.iterations_used;
    return 0;
}

}  // extern "C"
