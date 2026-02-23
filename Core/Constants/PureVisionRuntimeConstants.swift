// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// PureVisionRuntimeConstants.swift
// Aether3D
//
// Runtime binding source for constants previously anchored only in CURSOR_MEGA_PROMPT_V2.md.
// This file is intentionally generated from governance registry to keep SSOT binding deterministic.
//

import Foundation

public enum PureVisionRuntimeConstants {

    // MARK: - ADAM
    public static let K_ADAM_BETA2: Double = 0.99
    public static let K_ADAM_EPSILON: Double = 1e-10
    public static let K_ADAM_EPSILON_MAX: Double = 1e-08
    public static let K_ADAM_EPSILON_SCALE: Double = 0.01
    public static let K_ADAM_POCKETGS_CACHE_ENABLED: Int = 0
    public static let K_ADAM_WARMUP_ITERS: Int = 300

    // MARK: - ANCHOR
    public static let K_ANCHOR_CONSISTENCY_RATIO: Double = 0.05
    public static let K_ANCHOR_EMA_ALPHA: Double = 0.05
    public static let K_ANCHOR_HUBER_DELTA_SIGMA: Double = 2.5
    public static let K_ANCHOR_MIN_OBJECTS: Int = 3
    public static let K_ANCHOR_OUTLIER_RATIO: Double = 0.08

    // MARK: - AUDIT
    public static let K_AUDIT_HASH_BATCH_FRAMES: Int = 4
    public static let K_AUDIT_RFC3161_ANCHOR_SEC: Int = 60
    public static let K_AUDIT_TIME_DRIFT_MAX_SEC: Int = 300

    // MARK: - BGCACHE
    public static let K_BGCACHE_ALPHA_DOMINANT: Double = 0.6
    public static let K_BGCACHE_MIN_CONFIDENCE: Int = 128
    public static let K_BGCACHE_MIN_OBSERVATIONS: Int = 3

    // MARK: - COST
    public static let K_COST_ABUSE_THRESHOLD: Double = 0.8
    public static let K_COST_CIRCUIT_BREAK_USD: Double = 2
    public static let K_COST_GPU_SEC_USD: Double = 0.000125
    public static let K_COST_MAX_COMPUTE_SEC_DAY: Int = 10800
    public static let K_COST_MAX_JOBS_DAY: Int = 8
    public static let K_COST_STORAGE_GB_MO_USD: Double = 0.023
    public static let K_COST_TOKEN_BURST: Int = 8
    public static let K_COST_UPLOAD_GB_USD: Double = 0.085

    // MARK: - DPC
    public static let K_DPC_ANGULAR_COHERENCE_SKIP: Double = 0.3
    public static let K_DPC_ANGULAR_COHERENCE_SPLIT: Double = 0.7
    public static let K_DPC_ISOTROPY_LAMBDA: Double = 0.005
    public static let K_DPC_MH_ENABLED: Int = 0
    public static let K_DPC_MH_PROPOSAL_COUNT: Int = 128
    public static let K_DPC_MH_TEMPERATURE_DECAY: Double = 0.9997
    public static let K_DPC_MH_TEMPERATURE_INIT: Double = 1
    public static let K_DPC_MV_CONSISTENCY_THRESH: Double = 0.02
    public static let K_DPC_OPACITY_RESET_INTERVAL: Int = 2500
    public static let K_DPC_STALL_WINDOW: Int = 300

    // MARK: - FUSED
    public static let K_FUSED_CHARB_EPSILON: Double = 0.001
    public static let K_FUSED_CONF_MAP_FLOOR: Double = 0.01
    public static let K_FUSED_CONF_MONO_GRAD_MAX: Double = 0.5
    public static let K_FUSED_CONF_SFM_SIGMA: Double = 8
    public static let K_FUSED_DROPGS_RATE: Double = 0.1
    public static let K_FUSED_DUAL_OPACITY_ENABLED: Int = 1
    public static let K_FUSED_LAMBDA_DEPTH_SELF: Double = 0.3
    public static let K_FUSED_LAMBDA_FLOATER: Double = 0.05
    public static let K_FUSED_LAMBDA_NORMAL: Double = 0.2
    public static let K_FUSED_LAMBDA_OPACITY_ALIGN: Double = 0.02

    // MARK: - GATE
    public static let K_GATE_RELAX_MAX_FACTOR: Double = 1.5
    public static let K_GATE_RELAX_MIN_FACTOR: Double = 0.5

    // MARK: - GRAPH
    public static let K_GRAPH_CONTACT_COPLANAR_M: Double = 0.01
    public static let K_GRAPH_MAX_EDGES: Int = 2048
    public static let K_GRAPH_SUPPORT_DOT: Double = 0.8

    // MARK: - INST
    public static let K_INST_BOUNDARY_NORMAL_DOT: Double = 0.8
    public static let K_INST_CONTACT_DISTANCE_M: Double = 0.01
    public static let K_INST_MAX_INSTANCES: Int = 1024

    // MARK: - MC
    public static let K_MC_DIFFMC_ENABLED: Int = 0
    public static let K_MC_TOPO_NONMANIFOLD_MAX: Int = 0

    // MARK: - NOISE
    public static let K_NOISE_GYRO_BLUR_THRESHOLD: Double = 1.2
    public static let K_NOISE_SATURATION_RATIO: Double = 0.03

    // MARK: - OBS
    public static let K_OBS_INFO_GAIN_THRESHOLD: Double = 0.01
    public static let K_OBS_MIN_BASELINE_PIXELS: Double = 3
    public static let K_OBS_OVERLAP_MAX: Double = 0.85
    public static let K_OBS_OVERLAP_MIN: Double = 0.7
    public static let K_OBS_REQ_PARALLAX_RATIO: Double = 0.2
    public static let K_OBS_SIGMA_Z_TARGET_M: Double = 0.015

    // MARK: - OIT
    public static let K_OIT_K_S_DEFAULT: Int = 8
    public static let K_OIT_K_U_DEFAULT: Int = 24
    public static let K_OIT_MOMENT_ENABLED: Int = 0
    public static let K_OIT_MOMENT_ORDER: Int = 4
    public static let K_OIT_X_MEM_LIMIT_MB: Int = 96

    // MARK: - STREAM
    public static let K_STREAM_S5_ARRIVAL_RATIO: Double = 0.99
    public static let K_STREAM_UTILITY_ERROR_W: Double = 0.25
    public static let K_STREAM_UTILITY_EVIDENCE_W: Double = 0.4
    public static let K_STREAM_UTILITY_VIEW_W: Double = 0.35

    // MARK: - TIMEWARP
    public static let K_TIMEWARP_DISOCCLUSION_BG: Double = 0.18
    public static let K_TIMEWARP_MAX_AGE: Int = 3

    // MARK: - TRINITY
    public static let K_TRINITY_COS_THRESH_FP16: Double = 0.999
    public static let K_TRINITY_COS_THRESH_FP32: Double = 0.9999

    // MARK: - TSDF
    public static let K_TSDF_CAUTION_THRESHOLD: Double = 2.5
    public static let K_TSDF_EVIDENCE_EMA_BETA: Double = 0.93
    public static let K_TSDF_QUALITY_EXP_VISION: Double = 1.5
    public static let K_TSDF_REJECT_THRESHOLD: Double = 5
    public static let K_TSDF_ROBUST_NU: Double = 4
    public static let K_TSDF_TRUNC_K_SIGMA: Double = 3.5
    public static let K_TSDF_TRUNC_MAX_VOXELS: Double = 6
    public static let K_TSDF_TRUNC_MIN_VOXELS: Double = 1.5
    public static let K_TSDF_W_MAX: Int = 64

    // MARK: - VOLUME
    public static let K_VOLUME_CLOSURE_RATIO_MIN: Double = 0.97
    public static let K_VOLUME_INTERVAL_WIDTH_ABS_M3: Double = 0.002
    public static let K_VOLUME_INTERVAL_WIDTH_RATIO: Double = 0.02
    public static let K_VOLUME_MAX_COMPONENTS: Int = 2
    public static let K_VOLUME_UNKNOWN_VOXEL_MAX: Double = 0.03
}
