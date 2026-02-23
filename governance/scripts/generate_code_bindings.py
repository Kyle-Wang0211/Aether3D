#!/usr/bin/env python3
"""Generate full code_bindings.json coverage for active K-* constants.

This generator maps each active constant in contract_registry.json to exactly one
source binding check, then emits code_bindings.json with
coverage_policy.mode=all_active_constants.
"""

from __future__ import annotations

import argparse
import ast
import datetime as dt
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[2]
GOV_DIR = ROOT / "governance"

DEFAULT_CONTRACT_ID = "C-TRACK-P-LEGAL-BASELINE"

DOMAIN_CONTRACT_OVERRIDES: Dict[str, str] = {
    "BLUR": "C-BLUR-SSOT-SINGLE-VALUE",
    "SCAN": "C-SCAN-PATCHDISPLAY-MIGRATION",
    "TIMEWARP": "C-PIT1-TIMEWARP-PURITY",
    "GATE": "C-TRACK-X-FEATURE-ISOLATION",
    "COST": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    "UPLOAD": "C-UPLOAD-CHUNK-HASH-VERIFY",
}

DOMAIN_SOURCE_FILES: Dict[str, List[str]] = {
    "BLUR": [
        "Core/Constants/CoreBlurThresholds.swift",
        "Core/Constants/FrameQualityConstants.swift",
        "Core/Constants/QualityThresholds.swift",
        "Core/Constants/ScanGuidanceConstants.swift",
    ],
    "SCAN": ["Core/Constants/ScanGuidanceConstants.swift"],
    "GUIDANCE": ["Core/Constants/ScanGuidanceConstants.swift"],
    "EVIDENCE": ["Core/Constants/EvidenceConstants.swift"],
    "TSDF": [
        "Core/TSDF/TSDFConstants.swift",
        "Core/Constants/PureVisionRuntimeConstants.swift",
        "../CURSOR_MEGA_PROMPT_V2.md",
    ],
    "FRAME": ["Core/Constants/FrameQualityConstants.swift"],
    "JOB": ["Core/Jobs/ContractConstants.swift"],
    "UPLOAD": [
        "Core/Constants/UploadConstants.swift",
        "server/app/api/contract_constants.py",
        "Core/Constants/APIContractConstants.swift",
        "Core/Network/IdempotencyHandler.swift",
    ],
    "RETRY": ["Core/Constants/RetryConstants.swift"],
    "BUNDLE": ["Core/Constants/BundleConstants.swift"],
    "CAPACITY": ["Core/Constants/CapacityLimitConstants.swift"],
    "COLOR": ["Core/Constants/ColorSpaceConstants.swift"],
    "COMPLIANCE": ["Core/Constants/ComplianceConstants.swift"],
    "CONTINUITY": ["Core/Constants/ContinuityConstants.swift"],
    "COVERAGE": ["Core/Constants/CoverageVisualizationConstants.swift"],
    "XPLAT": ["Core/Constants/CrossPlatformConstants.swift"],
    "MATH": ["Core/Constants/MathSafetyConstants.swift"],
    "METAL": ["Core/Constants/MetalConstants.swift"],
    "THERMAL": ["Core/Constants/ThermalConstants.swift"],
    "OBSERVE": ["Core/Constants/ObservationConstants.swift"],
    "DIM": ["Core/Constants/DimensionalConstants.swift"],
    "PIZ": ["Core/Constants/PIZConstants.swift"],
    "SAMPLE": ["Core/Constants/SamplingConstants.swift"],
    "SESSION": ["Core/Constants/SessionBoundaryConstants.swift"],
    "STORAGE": ["Core/Constants/StorageConstants.swift"],
    "SYSTEM": ["Core/Constants/SystemConstants.swift"],
    "PIPELINE": ["Core/Constants/PipelineTimeoutConstants.swift"],
    "CONVERT": ["Core/Constants/ConversionConstants.swift"],
    "PRECHECK": ["Core/Constants/QualityPreCheckConstants.swift"],
    "CAPTURE": ["Core/Constants/CaptureRecordingConstants.swift"],
    "INST": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "GRAPH": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "BGCACHE": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "TIMEWARP": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "GATE": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "COST": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    # §6.64 AetherPureVision™ domains
    "OBS": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "ANCHOR": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "FUSED": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "ADAM": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "DPC": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "TRINITY": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "AUDIT": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "VOLUME": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "STREAM": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "NOISE": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "MC": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
    "OIT": ["Core/Constants/PureVisionRuntimeConstants.swift", "../CURSOR_MEGA_PROMPT_V2.md"],
}

# Manual overrides for constants that intentionally live in docs/prompt or require
# canonical source selection.
OVERRIDES: Dict[str, Dict[str, Any]] = {
    "K-BLUR-FRAME-REJECTION": {
        "path": "Core/Constants/CoreBlurThresholds.swift",
        "regex": r"public static let frameRejection: Double = ([^\n/]+)",
        "contract_id": "C-BLUR-SSOT-SINGLE-VALUE",
    },
    "K-BLUR-GUIDANCE-HAPTIC": {
        "path": "Core/Constants/CoreBlurThresholds.swift",
        "regex": r"public static let guidanceHaptic: Double = ([^\n/]+)",
        "contract_id": "C-BLUR-SSOT-SINGLE-VALUE",
    },
    "K-SCAN-DISPLAY-INCREMENT": {
        "path": "Core/Constants/ScanGuidanceConstants.swift",
        "regex": r"public static let scanDisplayIncrementPerFrame: Double = ([^\n/]+)",
        "contract_id": "C-SCAN-PATCHDISPLAY-MIGRATION",
    },
    "K-GUIDANCE-HAPTIC-BLUR-THRESHOLD": {
        "path": "Core/Constants/ScanGuidanceConstants.swift",
        "regex": r"public static let hapticBlurThreshold: Double = ([^\n/]+)",
        "contract_id": "C-BLUR-SSOT-SINGLE-VALUE",
    },
    "K-TIMEWARP-DISOCCLUSION-BG": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"DISOCCLUSION_BG_LUMINANCE = ([0-9.]+)f",
        "optional": True,
        "contract_id": "C-PIT1-TIMEWARP-PURITY",
    },
    "K-TIMEWARP-MAX-AGE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"MAX_TIMEWARP_AGE = ([0-9]+)",
        "optional": True,
        "contract_id": "C-PIT1-TIMEWARP-PURITY",
    },
    "K-GATE-RELAX-MIN-FACTOR": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"GATE_RELAX_MIN_FACTOR = ([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-GATE-RELAX-MAX-FACTOR": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"GATE_RELAX_MAX_FACTOR = ([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-COST-GPU-SEC-USD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.price_gpu_sec_usd\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-UPLOAD-GB-USD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.price_upload_gb_usd\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-STORAGE-GB-MO-USD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.price_storage_gb_mo_usd\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-CIRCUIT-BREAK-USD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.circuit_break_cost_usd\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-MAX-COMPUTE-SEC-DAY": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.max_compute_sec_day\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-MAX-JOBS-DAY": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.max_jobs_per_day\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-TOKEN-BURST": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.token_bucket_burst\s*=\s*([0-9]+)\.0f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    "K-COST-ABUSE-THRESHOLD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"\.abuse_score_threshold\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-COSTSHIELD-SERVER-ENFORCEMENT",
    },
    # §6.63 AetherEditVolume™ — prompt-only constants (no Swift source yet)
    "K-INST-MAX-INSTANCES": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_INST_MAX_INSTANCES\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-INST-BOUNDARY-NORMAL-DOT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_INST_BOUNDARY_NORMAL_DOT\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-INST-CONTACT-DISTANCE-M": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_INST_CONTACT_DISTANCE_M\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-GRAPH-MAX-EDGES": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_GRAPH_MAX_EDGES\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-GRAPH-SUPPORT-DOT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_GRAPH_SUPPORT_DOT\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-GRAPH-CONTACT-COPLANAR-M": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_GRAPH_CONTACT_COPLANAR_M\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-BGCACHE-ALPHA-DOMINANT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_BGCACHE_ALPHA_DOMINANT\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-BGCACHE-MIN-CONFIDENCE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_BGCACHE_MIN_CONFIDENCE\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-BGCACHE-MIN-OBSERVATIONS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_BGCACHE_MIN_OBSERVATIONS\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # §6.64 AetherPureVision™ — prompt-only constants (no Swift/C++ source yet)
    # Domain: OBS
    "K-OBS-MIN-BASELINE-PIXELS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_MIN_BASELINE_PIXELS\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-REQ-PARALLAX-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_REQ_PARALLAX_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-REQ-PARALLAX-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_REQ_PARALLAX_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-REQ-PARALLAX-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_REQ_PARALLAX_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-OVERLAP-MIN": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_OVERLAP_MIN\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-OVERLAP-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_OVERLAP_MAX\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-SIGMA-Z-TARGET-M": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_SIGMA_Z_TARGET_M\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OBS-INFO-GAIN-THRESHOLD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OBS_INFO_GAIN_THRESHOLD\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: ANCHOR
    "K-ANCHOR-MIN-OBJECTS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_MIN_OBJECTS\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-CONSISTENCY-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_CONSISTENCY_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-EMA-ALPHA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_EMA_ALPHA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-OUTLIER-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_OUTLIER_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-HUBER-DELTA-SIGMA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_HUBER_DELTA_SIGMA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-HUBER-DELTA-SIGMA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_HUBER_DELTA_SIGMA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ANCHOR-HUBER-DELTA-SIGMA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ANCHOR_HUBER_DELTA_SIGMA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: TSDF (extensions for §6.64.3)
    "K-TSDF-TRUNC-K-SIGMA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_TRUNC_K_SIGMA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-TRUNC-MIN-VOXELS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_TRUNC_MIN_VOXELS\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-TRUNC-MAX-VOXELS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_TRUNC_MAX_VOXELS\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-W-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_W_MAX\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-ROBUST-NU": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_ROBUST_NU\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-ROBUST-NU": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_ROBUST_NU\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-ROBUST-NU": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_ROBUST_NU\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-CAUTION-THRESHOLD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_CAUTION_THRESHOLD\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-REJECT-THRESHOLD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_REJECT_THRESHOLD\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-EVIDENCE-EMA-BETA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_EVIDENCE_EMA_BETA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TSDF-QUALITY-EXP-VISION": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TSDF_QUALITY_EXP_VISION\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: FUSED
    "K-FUSED-LAMBDA-DEPTH-SELF": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_LAMBDA_DEPTH_SELF\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-LAMBDA-NORMAL": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_LAMBDA_NORMAL\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-LAMBDA-FLOATER": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_LAMBDA_FLOATER\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-CHARB-EPSILON": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_CHARB_EPSILON\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: ADAM
    "K-ADAM-EPSILON": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON\s*=\s*([0-9e.\-]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_MAX\s*=\s*([0-9e.\-]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-SCALE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_SCALE\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_MAX\s*=\s*([0-9e.\-]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-SCALE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_SCALE\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_MAX\s*=\s*([0-9e.\-]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-EPSILON-SCALE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_EPSILON_SCALE\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-BETA2": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_BETA2\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-ADAM-WARMUP-ITERS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_WARMUP_ITERS\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: DPC
    "K-DPC-STALL-WINDOW": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_STALL_WINDOW\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-OPACITY-RESET-INTERVAL": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_OPACITY_RESET_INTERVAL\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-ANGULAR-COHERENCE-SPLIT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_ANGULAR_COHERENCE_SPLIT\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-ANGULAR-COHERENCE-SKIP": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_ANGULAR_COHERENCE_SKIP\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: TRINITY
    "K-TRINITY-COS-THRESH-FP32": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TRINITY_COS_THRESH_FP32\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-TRINITY-COS-THRESH-FP16": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_TRINITY_COS_THRESH_FP16\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: AUDIT
    "K-AUDIT-HASH-BATCH-FRAMES": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_AUDIT_HASH_BATCH_FRAMES\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-AUDIT-RFC3161-ANCHOR-SEC": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_AUDIT_RFC3161_ANCHOR_SEC\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-AUDIT-TIME-DRIFT-MAX-SEC": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_AUDIT_TIME_DRIFT_MAX_SEC\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: VOLUME
    "K-VOLUME-INTERVAL-WIDTH-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_INTERVAL_WIDTH_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-INTERVAL-WIDTH-ABS-M3": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_INTERVAL_WIDTH_ABS_M3\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-INTERVAL-WIDTH-ABS-M3": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_INTERVAL_WIDTH_ABS_M3\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-INTERVAL-WIDTH-ABS-M3": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_INTERVAL_WIDTH_ABS_M3\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-CLOSURE-RATIO-MIN": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_CLOSURE_RATIO_MIN\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-UNKNOWN-VOXEL-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_UNKNOWN_VOXEL_MAX\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-VOLUME-MAX-COMPONENTS": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_VOLUME_MAX_COMPONENTS\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: STREAM
    "K-STREAM-UTILITY-EVIDENCE-W": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_STREAM_UTILITY_EVIDENCE_W\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-STREAM-UTILITY-VIEW-W": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_STREAM_UTILITY_VIEW_W\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-STREAM-UTILITY-ERROR-W": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_STREAM_UTILITY_ERROR_W\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-STREAM-S5-ARRIVAL-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_STREAM_S5_ARRIVAL_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: NOISE
    "K-NOISE-GYRO-BLUR-THRESHOLD": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_NOISE_GYRO_BLUR_THRESHOLD\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-NOISE-SATURATION-RATIO": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_NOISE_SATURATION_RATIO\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: MC
    "K-MC-TOPO-NONMANIFOLD-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_MC_TOPO_NONMANIFOLD_MAX\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: OIT
    "K-OIT-K-S-DEFAULT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OIT_K_S_DEFAULT\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OIT-K-U-DEFAULT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OIT_K_U_DEFAULT\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OIT-X-MEM-LIMIT-MB": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OIT_X_MEM_LIMIT_MB\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # ─── V3.5-R1 升级: +16 新常量 ───
    # Domain: FUSED (CDGS + StableGS + DropGaussian)
    "K-FUSED-CONF-SFM-SIGMA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_CONF_SFM_SIGMA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-CONF-MONO-GRAD-MAX": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_CONF_MONO_GRAD_MAX\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-CONF-MAP-FLOOR": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_CONF_MAP_FLOOR\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-LAMBDA-OPACITY-ALIGN": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_LAMBDA_OPACITY_ALIGN\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-DUAL-OPACITY-ENABLED": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_DUAL_OPACITY_ENABLED\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-FUSED-DROPGS-RATE": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_FUSED_DROPGS_RATE\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: ADAM (PocketGS)
    "K-ADAM-POCKETGS-CACHE-ENABLED": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_ADAM_POCKETGS_CACHE_ENABLED\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: DPC (Micro-splatting + FastGS + MH-3DGS)
    "K-DPC-ISOTROPY-LAMBDA": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_ISOTROPY_LAMBDA\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-MV-CONSISTENCY-THRESH": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_MV_CONSISTENCY_THRESH\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-MH-ENABLED": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_MH_ENABLED\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-MH-TEMPERATURE-INIT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_MH_TEMPERATURE_INIT\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-MH-TEMPERATURE-DECAY": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_MH_TEMPERATURE_DECAY\s*=\s*([0-9.]+)f",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-DPC-MH-PROPOSAL-COUNT": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_DPC_MH_PROPOSAL_COUNT\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: MC (DiffMC)
    "K-MC-DIFFMC-ENABLED": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_MC_DIFFMC_ENABLED\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    # Domain: OIT (Moment-Based)
    "K-OIT-MOMENT-ENABLED": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OIT_MOMENT_ENABLED\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
    "K-OIT-MOMENT-ORDER": {
        "path": "../CURSOR_MEGA_PROMPT_V2.md",
        "regex": r"K_OIT_MOMENT_ORDER\s*=\s*([0-9]+)",
        "optional": True,
        "contract_id": "C-TRACK-X-FEATURE-ISOLATION",
    },
}

TOKEN_ALIASES = {
    "sec": "seconds",
    "secs": "seconds",
    "ms": "ms",
    "min": "min",
    "mins": "min",
    "pct": "percent",
    "deg": "deg",
    "id": "id",
    "ids": "id",
}


@dataclass(frozen=True)
class SourceEntry:
    path: str
    symbol: str
    value: Any
    language: str


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate governance/code_bindings.json")
    parser.add_argument(
        "--registry",
        default="governance/contract_registry.json",
        help="Registry JSON path (workspace-relative)",
    )
    parser.add_argument(
        "--output",
        default="governance/code_bindings.json",
        help="Output bindings JSON path (workspace-relative)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Check mode: do not write, fail if output differs",
    )
    return parser.parse_args()


def normalize_expression(raw: str) -> str:
    expr = raw.strip()
    expr = expr.split("//", 1)[0]
    expr = expr.split("#", 1)[0]
    expr = expr.strip().rstrip(",")
    expr = expr.replace("_", "")
    expr = re.sub(r"(?<=\d)[fF]\b", "", expr)
    expr = re.sub(r"\btrue\b", "True", expr, flags=re.IGNORECASE)
    expr = re.sub(r"\bfalse\b", "False", expr, flags=re.IGNORECASE)
    return expr


def eval_numeric_expression(raw: str) -> Any:
    expr = normalize_expression(raw)
    if not expr:
        raise ValueError("empty expression")

    operators = {
        ast.Add: lambda a, b: a + b,
        ast.Sub: lambda a, b: a - b,
        ast.Mult: lambda a, b: a * b,
        ast.Div: lambda a, b: a / b,
        ast.FloorDiv: lambda a, b: a // b,
        ast.Mod: lambda a, b: a % b,
        ast.Pow: lambda a, b: a**b,
    }

    def walk(node: ast.AST) -> Any:
        if isinstance(node, ast.Constant) and isinstance(node.value, (int, float, bool)):
            return node.value
        if isinstance(node, ast.Num):
            return node.n
        if isinstance(node, ast.UnaryOp) and isinstance(node.op, (ast.UAdd, ast.USub)):
            operand = walk(node.operand)
            return +operand if isinstance(node.op, ast.UAdd) else -operand
        if isinstance(node, ast.BinOp) and type(node.op) in operators:
            return operators[type(node.op)](walk(node.left), walk(node.right))
        raise ValueError(f"unsupported node {type(node).__name__}")

    parsed = ast.parse(expr, mode="eval")
    return walk(parsed.body)


def parse_swift_constants(path: Path, rel_path: str) -> List[SourceEntry]:
    pattern = re.compile(
        r"(?m)^(?!\s*//)\s*(?:public|internal|private|fileprivate|open)?\s*"
        r"(?:static\s+)?let\s+([A-Za-z_][A-Za-z0-9_]*)\s*"
        r"(?::\s*[^=\n]+)?\s*=\s*([^\n]+)"
    )
    text = path.read_text(encoding="utf-8", errors="replace")
    out: List[SourceEntry] = []
    for match in pattern.finditer(text):
        symbol = match.group(1)
        raw_value = match.group(2)
        try:
            value = eval_numeric_expression(raw_value)
        except Exception:
            continue
        out.append(SourceEntry(path=rel_path, symbol=symbol, value=value, language="swift"))
    return out


def parse_python_constants(path: Path, rel_path: str) -> List[SourceEntry]:
    pattern = re.compile(r"(?m)^\s*([A-Z][A-Z0-9_]+)\s*=\s*([^\n#]+)")
    text = path.read_text(encoding="utf-8", errors="replace")
    out: List[SourceEntry] = []
    for match in pattern.finditer(text):
        symbol = match.group(1)
        raw_value = match.group(2)
        try:
            value = eval_numeric_expression(raw_value)
        except Exception:
            continue
        out.append(SourceEntry(path=rel_path, symbol=symbol, value=value, language="python"))
    return out


def normalize_tokens(raw: str) -> List[str]:
    snake = raw.replace("-", "_")
    snake = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", snake)
    parts = [p for p in re.split(r"[^A-Za-z0-9]+", snake.lower()) if p]
    normalized: List[str] = []
    for part in parts:
        normalized.append(TOKEN_ALIASES.get(part, part))
    return normalized


def values_equal(expected: Any, actual: Any, value_type: str) -> bool:
    if value_type == "bool":
        return bool(actual) == bool(expected)
    if value_type == "int":
        actual_f = float(actual)
        expected_i = int(expected)
        return abs(actual_f - float(expected_i)) <= 1e-9 and int(round(actual_f)) == expected_i
    if value_type == "float":
        return abs(float(actual) - float(expected)) <= 1e-9
    return actual == expected


def score_entry(constant_id: str, entry: SourceEntry) -> int:
    parts = constant_id.split("-")
    id_tokens = set(normalize_tokens("_".join(parts[2:])))
    symbol_tokens = set(normalize_tokens(entry.symbol))
    overlap = len(id_tokens & symbol_tokens)
    if not id_tokens:
        return 0
    return overlap * 10 - abs(len(symbol_tokens) - len(id_tokens))


def binding_regex_for_entry(entry: SourceEntry) -> str:
    escaped = re.escape(entry.symbol)
    if entry.language == "swift":
        return (
            rf"(?:public|internal|private|fileprivate|open)?\s*(?:static\s+)?let\s+{escaped}"
            rf"\s*(?::\s*[^=\n]+)?\s*=\s*([^\n/]+)"
        )
    if entry.language == "python":
        return rf"^\s*{escaped}\s*=\s*([^\n#]+)"
    raise ValueError(f"Unsupported entry language: {entry.language}")


def preferred_contract_for_constant(constant_id: str) -> str:
    parts = constant_id.split("-")
    domain = parts[1] if len(parts) > 1 else ""
    return DOMAIN_CONTRACT_OVERRIDES.get(domain, DEFAULT_CONTRACT_ID)


def gather_source_entries() -> Dict[str, List[SourceEntry]]:
    paths: set[str] = set()
    for domain_paths in DOMAIN_SOURCE_FILES.values():
        paths.update(domain_paths)

    out: Dict[str, List[SourceEntry]] = {}
    for rel in sorted(paths):
        path = ROOT / rel
        if not path.exists():
            continue
        entries: List[SourceEntry]
        if rel.endswith(".swift"):
            entries = parse_swift_constants(path, rel)
        elif rel.endswith(".py"):
            entries = parse_python_constants(path, rel)
        else:
            continue
        out[rel] = entries
    return out


def find_best_entry(
    constant_id: str,
    expected_value: Any,
    value_type: str,
    source_index: Dict[str, List[SourceEntry]],
) -> Optional[SourceEntry]:
    domain = constant_id.split("-")[1] if "-" in constant_id else ""
    preferred_paths = DOMAIN_SOURCE_FILES.get(domain, [])
    if not preferred_paths:
        preferred_paths = sorted(source_index.keys())

    candidates: List[SourceEntry] = []
    for rel in preferred_paths:
        candidates.extend(source_index.get(rel, []))

    scored: List[Tuple[int, SourceEntry]] = []
    for entry in candidates:
        if not values_equal(expected_value, entry.value, value_type):
            continue
        score = score_entry(constant_id, entry)
        scored.append((score, entry))

    if not scored:
        return None

    scored.sort(key=lambda item: (-item[0], item[1].path, item[1].symbol))
    # Ambiguity guard: if we have no lexical overlap and ties, treat as unresolved.
    if len(scored) > 1 and scored[0][0] <= 0 and scored[0][0] == scored[1][0]:
        return None
    return scored[0][1]


def build_check(constant: Dict[str, Any], source_index: Dict[str, List[SourceEntry]]) -> Optional[Dict[str, Any]]:
    constant_id = constant["id"]
    value_type = constant["value_type"]

    override = OVERRIDES.get(constant_id)
    if override is not None:
        # Runtime-first migration: if an override points to prompt markdown but
        # we can now resolve a real code symbol, prefer the code binding.
        if override.get("path") == "../CURSOR_MEGA_PROMPT_V2.md":
            entry = find_best_entry(constant_id, constant["value"], value_type, source_index)
            if entry is not None and entry.path != "../CURSOR_MEGA_PROMPT_V2.md":
                return {
                    "id": f"BIND-AUTO-{constant_id[2:]}",
                    "status": "active",
                    "contract_id": override.get("contract_id", preferred_contract_for_constant(constant_id)),
                    "path": entry.path,
                    "regex": binding_regex_for_entry(entry),
                    "value_type": value_type,
                    "expected": {"constant_id": constant_id},
                }

        check: Dict[str, Any] = {
            "id": f"BIND-AUTO-{constant_id[2:]}",
            "status": "active",
            "contract_id": override.get("contract_id", preferred_contract_for_constant(constant_id)),
            "path": override["path"],
            "regex": override["regex"],
            "value_type": value_type,
            "expected": {"constant_id": constant_id},
        }
        if override.get("optional"):
            check["optional"] = True
        return check

    entry = find_best_entry(constant_id, constant["value"], value_type, source_index)
    if entry is None:
        return None

    return {
        "id": f"BIND-AUTO-{constant_id[2:]}",
        "status": "active",
        "contract_id": preferred_contract_for_constant(constant_id),
        "path": entry.path,
        "regex": binding_regex_for_entry(entry),
        "value_type": value_type,
        "expected": {"constant_id": constant_id},
    }


def load_registry(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def generate_bindings(registry: Dict[str, Any]) -> Dict[str, Any]:
    active_constants = [
        c
        for c in registry.get("constants", [])
        if isinstance(c.get("id"), str) and c.get("status") != "deprecated"
    ]

    source_index = gather_source_entries()
    checks: List[Dict[str, Any]] = []
    unresolved: List[str] = []

    for constant in sorted(active_constants, key=lambda c: c["id"]):
        check = build_check(constant, source_index)
        if check is None:
            unresolved.append(constant["id"])
            continue
        checks.append(check)

    if unresolved:
        sys.stderr.write("unresolved constants (no binding candidate found):\n")
        for constant_id in unresolved:
            sys.stderr.write(f"  - {constant_id}\n")
        raise SystemExit(2)

    # deterministic ordering
    checks.sort(key=lambda item: item["id"])

    # check id uniqueness
    seen: set[str] = set()
    dupes: List[str] = []
    for check in checks:
        cid = check["id"]
        if cid in seen:
            dupes.append(cid)
        seen.add(cid)
    if dupes:
        raise SystemExit(f"duplicate check ids: {dupes}")

    return {
        "metadata": {
            "version": "2.0.0",
            "last_updated": dt.date.today().isoformat(),
            "coverage_policy": {"mode": "all_active_constants"},
            "generated_by": "governance/scripts/generate_code_bindings.py",
            "active_constant_count": len(active_constants),
            "check_count": len(checks),
        },
        "checks": checks,
    }


def write_or_check(output_path: Path, payload: Dict[str, Any], check_mode: bool) -> None:
    rendered = json.dumps(payload, indent=2, ensure_ascii=False) + "\n"
    if check_mode:
        current = output_path.read_text(encoding="utf-8") if output_path.exists() else ""
        if current != rendered:
            raise SystemExit("code_bindings out of date (run generator)")
        print("code-bindings-generator: check mode passed")
        return

    output_path.write_text(rendered, encoding="utf-8")
    print("code-bindings-generator: generated", output_path)


def main() -> None:
    args = parse_args()
    registry_path = ROOT / args.registry
    output_path = ROOT / args.output

    registry = load_registry(registry_path)
    payload = generate_bindings(registry)
    write_or_check(output_path, payload, args.check)


if __name__ == "__main__":
    main()
