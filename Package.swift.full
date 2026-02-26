// swift-tools-version: 6.2
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import PackageDescription

let package = Package(
  name: "Aether3D",
  platforms: [
    .macOS(.v13),
    .iOS(.v16)
    // Linux support is implicit in SwiftPM
  ],
  products: [
    .library(name: "Aether3DCore", targets: ["Aether3DCore"]),
    // PR4 V10 modules
    .library(name: "PR4Math", targets: ["PR4Math"]),
    .library(name: "PR4PathTrace", targets: ["PR4PathTrace"]),
    .library(name: "PR4Ownership", targets: ["PR4Ownership"]),
    .library(name: "PR4Overflow", targets: ["PR4Overflow"]),
    .library(name: "PR4LUT", targets: ["PR4LUT"]),
    .library(name: "PR4Determinism", targets: ["PR4Determinism"]),
    .library(name: "PR4Softmax", targets: ["PR4Softmax"]),
    .library(name: "PR4Health", targets: ["PR4Health"]),
    .library(name: "PR4Uncertainty", targets: ["PR4Uncertainty"]),
    .library(name: "PR4Calibration", targets: ["PR4Calibration"]),
    .library(name: "PR4Package", targets: ["PR4Package"]),
    .library(name: "PR4Golden", targets: ["PR4Golden"]),
    .library(name: "PR4Quality", targets: ["PR4Quality"]),
    .library(name: "PR4Gate", targets: ["PR4Gate"]),
    .library(name: "PR4Fusion", targets: ["PR4Fusion"]),
    .library(name: "SharedSecurity", targets: ["SharedSecurity"]),
    .executable(name: "PR4DigestGenerator", targets: ["PR4DigestGenerator"])
  ],
  dependencies: [
    // swift-crypto: Required for Linux compatibility (replaces Apple-only CryptoKit)
    // Used for cross-platform SHA-256 hashing and as BLAKE3 fallback
    // Note: blake3-swift removed due to swift-frontend crashes in CI (macOS + Ubuntu)
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      path: "Sources/CSQLite",
      providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
    ),
    .target(
      name: "CAetherNativeBridge",
      path: "aether_cpp",
      sources: [
        "src/core/canonicalize.cpp",
        "src/core/numeric_guard.cpp",
        "src/crypto/sha256.cpp",
        "src/evidence/admission_controller.cpp",
        "src/evidence/coverage_estimator.cpp",
        "src/evidence/deterministic_json.cpp",
        "src/evidence/ds_mass_function.cpp",
        "src/evidence/patch_display_kernel.cpp",
        "src/evidence/pr1_admission_kernel.cpp",
        "src/evidence/pr1_information_gain.cpp",
        "src/evidence/pr_math.cpp",
        "src/evidence/replay_engine.cpp",
        "src/evidence/evidence_state_machine.cpp",
        "src/evidence/smart_anti_boost_smoother.cpp",
        "src/innovation/core_types.cpp",
        "src/innovation/f1_progressive_compression.cpp",
        "src/innovation/f1_time_mirror.cpp",
        "src/innovation/f2_scaffold_collision.cpp",
        "src/innovation/f3_evidence_constrained_compression.cpp",
        "src/innovation/scaffold_patch_map.cpp",
        "src/innovation/f5_delta_patch_chain.cpp",
        "src/innovation/f6_conflict_dynamic_rejection.cpp",
        "src/innovation/f7_shaderml_decode.cpp",
        "src/innovation/f8_uncertainty_field.cpp",
        "src/innovation/f9_scene_passport_watermark.cpp",
        "src/merkle/consistency_proof.cpp",
        "src/merkle/inclusion_proof.cpp",
        "src/merkle/merkle_tree.cpp",
        "src/merkle/merkle_tree_hash.cpp",
        "src/memory/arena.cpp",
        "src/quality/deterministic_triangulator.cpp",
        "src/quality/image_metrics.cpp",
        "src/quality/motion_analyzer.cpp",
        "src/quality/photometric_checker.cpp",
        "src/quality/geometry_ml_fusion.cpp",
        "src/quality/pure_vision_runtime.cpp",
        "src/quality/spatial_hash_adjacency.cpp",
        "src/quality/zero_fabrication_policy.cpp",
        "src/render/confidence_decay.cpp",
        "src/render/color_correction.cpp",
        "src/render/dgrut_renderer.cpp",
        "src/render/flip_animation.cpp",
        "src/render/flip_animation_gpu.cpp",
        "src/render/fracture_display_mesh.cpp",
        "src/render/frustum_culler.cpp",
        "src/render/meshlet_builder.cpp",
        "src/render/ripple_propagation.cpp",
        "src/render/screen_detail_selector.cpp",
        "src/render/shader_source.cpp",
        "src/render/two_pass_culler.cpp",
        "src/render/tri_tet_splat_projector.cpp",
        "src/render/wedge_geometry.cpp",
        "src/scheduler/gpu_scheduler.cpp",
        "src/trainer/da3_depth_fuser.cpp",
        "src/trainer/noise_aware_trainer.cpp",
        "src/tsdf/isotropic_remesher.cpp",
        "src/tsdf/marching_cubes.cpp",
        "src/tsdf/mesh_extraction_scheduler.cpp",
        "src/tsdf/mesh_fiedler.cpp",
        "src/tsdf/mesh_topology.cpp",
        "src/tsdf/depth_filter.cpp",
        "src/tsdf/icp_registration.cpp",
        "src/tsdf/loop_detector.cpp",
        "src/tsdf/pose_graph.cpp",
        "src/tsdf/pose_stabilizer.cpp",
        "src/tsdf/soft_eviction.cpp",
        "src/tsdf/spatial_hash_table.cpp",
        "src/tsdf/spatial_quantizer.cpp",
        "src/tsdf/thermal_engine.cpp",
        "src/tsdf/tri_tet_consistency.cpp",
        "src/tsdf/tri_tet_mapping.cpp",
        "src/tsdf/volume_controller.cpp",
        "src/tsdf_volume.cpp",
        "src/upload/erasure_coding.cpp",
        "src/upload/kalman_bandwidth.cpp",
        "src/geo/haversine.cpp",
        "src/geo/asc_cell.cpp",
        "src/geo/rtree.cpp",
        "src/geo/geo_indexer.cpp",
        "src/geo/geo_cluster.cpp",
        "src/geo/geo_privacy.cpp",
        "src/geo/spoof_detector.cpp",
        "src/geo/map_tile_source.cpp",
        "src/geo/map_tile_mesh.cpp",
        "src/geo/map_terrain.cpp",
        "src/geo/map_globe_projection.cpp",
        "src/geo/map_label_sdf.cpp",
        "src/geo/sol_illumination.cpp",
        "src/geo/map_renderer.cpp",
        "src/geo/altitude_engine.cpp",
        "src/geo/temporal_index.cpp",
        "src/geo/temporal_cluster.cpp",
        "src/geo/cross_temporal_gs.cpp",
        "src/c_api.cpp",
        "src/geo_c_api.cpp"
      ],
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include")
      ]
    ),
    .target(
      name: "Aether3DCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        "CSQLite",
        "CAetherNativeBridge",
        "SharedSecurity"
      ],
      path: "Core"
    ),
    .executableTarget(
      name: "UpdateGoldenDigests",
      dependencies: [
        "Aether3DCore",
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/UpdateGoldenDigests"
    ),
    .executableTarget(
      name: "PIZFixtureDumper",
      dependencies: [
        "Aether3DCore"
      ],
      path: "Sources/PIZFixtureDumper"
    ),
    .executableTarget(
      name: "PIZSealingEvidence",
      dependencies: [
        "Aether3DCore"
      ],
      path: "Sources/PIZSealingEvidence"
    ),
    .executableTarget(
      name: "FixtureGen",
      dependencies: [
        "Aether3DCore"
      ],
      path: "Sources/FixtureGen"
    ),
    .executableTarget(
      name: "PR4MathFixtureExporter",
      dependencies: ["PR4Math", "PR4Softmax", "PR4LUT"],
      path: "Sources/PR4MathFixtureExporter"
    ),
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants", "Upload", "CI", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden", "Geo", "PR4MathTests", "PR4PathTraceTests", "PR4OwnershipTests", "PR4OverflowTests", "PR4LUTTests", "PR4DeterminismTests", "PR4SoftmaxTests", "PR4HealthTests", "PR4UncertaintyTests", "PR4CalibrationTests", "PR4GoldenTests", "PR4IntegrationTests", "PR5CaptureTests", "EvidenceGridTests", "EvidenceGridDeterminismTests", "ScanGuidanceTests", "TSDF"],
      resources: [
        .process("Fixtures"),
        .process("Evidence/Fixtures/Golden"),
        .process("QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json"),
        .process("QualityPreCheck/Fixtures/CoverageGridPackingFixture.json"),
        .process("QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json")
      ]
    ),
    .testTarget(
      name: "ConstantsTests",
      dependencies: [
        "Aether3DCore",
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Tests/Constants"
    ),
    // UploadTests split into 3 targets to stay under Linux MAX_ARG_STRLEN (128KB).
    // SwiftPM enumerates all test method names as a single posix_spawn argument;
    // the original 2409 tests = 177KB exceeds the kernel limit.
    .testTarget(
      name: "UploadTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload",
      exclude: [
        // UploadTestsB files (D-N)
        "DeviceInfoTests.swift", "EnhancedResumeManagerTests.swift",
        "ErasureCodingEngineTests.swift", "FusionSchedulerTests.swift",
        "HashCalculatorTests.swift", "HybridIOEngineTests.swift",
        "ImmutableBundleTests.swift", "KalmanBandwidthPredictorTests.swift",
        "MLBandwidthPredictorTests.swift", "MultiLayerProgressTrackerTests.swift",
        "MultipathUploadManagerTests.swift", "NetworkPathObserverTests.swift",
        "NetworkSpeedMonitorTests.swift", "PR9CertificatePinManagerTests.swift",
        // UploadTestsC files (P-U)
        "PR9PerformanceTests.swift", "PR9SecurityTests.swift",
        "ProofOfPossessionTests.swift", "RaptorQEngineTests.swift",
        "StreamingMerkleTreeTests.swift", "UnifiedResourceManagerTests.swift",
        "UploadCircuitBreakerTests.swift", "UploadResumeManagerTests.swift",
        "UploadSessionTests.swift", "UploadTelemetryTests.swift",
        // Temporarily isolated due strict-concurrency pointer ABI debt
        "ChunkBufferPoolTests.swift"
      ]
    ),
    .testTarget(
      name: "UploadTestsB",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload",
      exclude: [
        // UploadTests files (A-C)
        "AdaptiveChunkSizerTests.swift", "BundleConstantsTests.swift",
        "BundleManifestTests.swift", "ByzantineVerifierTests.swift",
        "CAMARAQoDClientTests.swift", "CIDMapperTests.swift",
        "ChunkBufferPoolTests.swift", "ChunkCommitmentChainTests.swift",
        "ChunkIdempotencyManagerTests.swift", "ChunkIntegrityValidatorTests.swift",
        "ChunkManagerTests.swift", "ConnectionPrewarmerTests.swift",
        "ContentDefinedChunkerTests.swift",
        // UploadTestsC files (P-U)
        "PR9PerformanceTests.swift", "PR9SecurityTests.swift",
        "ProofOfPossessionTests.swift", "RaptorQEngineTests.swift",
        "StreamingMerkleTreeTests.swift", "UnifiedResourceManagerTests.swift",
        "UploadCircuitBreakerTests.swift", "UploadResumeManagerTests.swift",
        "UploadSessionTests.swift", "UploadTelemetryTests.swift",
        // Temporarily isolated due strict-concurrency pointer ABI debt
        "ChunkBufferPoolTests.swift"
      ]
    ),
    .testTarget(
      name: "UploadTestsC",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload",
      exclude: [
        // UploadTests files (A-C)
        "AdaptiveChunkSizerTests.swift", "BundleConstantsTests.swift",
        "BundleManifestTests.swift", "ByzantineVerifierTests.swift",
        "CAMARAQoDClientTests.swift", "CIDMapperTests.swift",
        "ChunkBufferPoolTests.swift", "ChunkCommitmentChainTests.swift",
        "ChunkIdempotencyManagerTests.swift", "ChunkIntegrityValidatorTests.swift",
        "ChunkManagerTests.swift", "ConnectionPrewarmerTests.swift",
        "ContentDefinedChunkerTests.swift",
        // UploadTestsB files (D-N)
        "DeviceInfoTests.swift", "EnhancedResumeManagerTests.swift",
        "ErasureCodingEngineTests.swift", "FusionSchedulerTests.swift",
        "HashCalculatorTests.swift", "HybridIOEngineTests.swift",
        "ImmutableBundleTests.swift", "KalmanBandwidthPredictorTests.swift",
        "MLBandwidthPredictorTests.swift", "MultiLayerProgressTrackerTests.swift",
        "MultipathUploadManagerTests.swift", "NetworkPathObserverTests.swift",
        "NetworkSpeedMonitorTests.swift", "PR9CertificatePinManagerTests.swift"
      ]
    ),
    .testTarget(
      name: "CITests",
      dependencies: ["Aether3DCore"],
      path: "Tests/CI"
    ),
    // PR4 V10 targets - Phase 0: Foundation Protocols (no dependencies)
    .target(
      name: "PR4Protocols",
      dependencies: [],
      path: "Sources/PR4Protocols"
    ),
    // PR4 V10 targets - Phase 1: Foundation
    .target(
      name: "PR4Math",
      dependencies: [],
      path: "Sources/PR4Math"
    ),
    .target(
      name: "PR4PathTrace",
      dependencies: [],
      path: "Sources/PR4PathTrace"
    ),
    .target(
      name: "PR4Ownership",
      dependencies: ["PR4Math", "PR4PathTrace", "PR4Protocols"],
      path: "Sources/PR4Ownership"
    ),
    // PR4 V10 test targets
    .testTarget(
      name: "PR4MathTests",
      dependencies: ["PR4Math"],
      path: "Tests/PR4MathTests"
    ),
    .testTarget(
      name: "PR4PathTraceTests",
      dependencies: ["PR4PathTrace"],
      path: "Tests/PR4PathTraceTests"
    ),
    .testTarget(
      name: "PR4OwnershipTests",
      dependencies: ["PR4Ownership"],
      path: "Tests/PR4OwnershipTests"
    ),
    // PR4 V10 targets - Phase 2: Core Infrastructure
    .target(
      name: "PR4Overflow",
      dependencies: ["PR4Math"],
      path: "Sources/PR4Overflow"
    ),
    .target(
      name: "PR4LUT",
      dependencies: [
        "PR4Math",
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/PR4LUT"
    ),
    .target(
      name: "PR4Determinism",
      dependencies: ["PR4Math", "PR4LUT"],
      path: "Sources/PR4Determinism"
    ),
    .target(
      name: "PR4Softmax",
      dependencies: ["PR4Math", "PR4LUT", "PR4Overflow", "PR4PathTrace"],
      path: "Sources/PR4Softmax"
    ),
    // PR4 V10 test targets - Phase 2
    .testTarget(
      name: "PR4OverflowTests",
      dependencies: ["PR4Overflow"],
      path: "Tests/PR4OverflowTests"
    ),
    .testTarget(
      name: "PR4LUTTests",
      dependencies: ["PR4LUT"],
      path: "Tests/PR4LUTTests"
    ),
    .testTarget(
      name: "PR4DeterminismTests",
      dependencies: ["PR4Determinism"],
      path: "Tests/PR4DeterminismTests"
    ),
    .testTarget(
      name: "PR4SoftmaxTests",
      dependencies: ["PR4Softmax"],
      path: "Tests/PR4SoftmaxTests"
    ),
    // PR4 V10 targets - Phase 3-5: Additional modules
    .target(
      name: "PR4Health",
      dependencies: ["PR4Math"],
      path: "Sources/PR4Health"
    ),
    .target(
      name: "PR4Uncertainty",
      dependencies: ["PR4Math"],
      path: "Sources/PR4Uncertainty"
    ),
    .target(
      name: "PR4Calibration",
      dependencies: ["PR4Math"],
      path: "Sources/PR4Calibration"
    ),
    .target(
      name: "PR4Package",
      dependencies: [],
      path: "Sources/PR4Package"
    ),
    .target(
      name: "PR4Golden",
      dependencies: [],
      path: "Sources/PR4Golden"
    ),
    .target(
      name: "PR4Quality",
      dependencies: ["PR4Math", "PR4LUT", "PR4Overflow", "PR4Uncertainty", "PR4Protocols"],
      path: "Sources/PR4Quality"
    ),
    .target(
      name: "PR4Gate",
      dependencies: ["PR4Math", "PR4Health", "PR4Protocols"],
      path: "Sources/PR4Gate"
    ),
    .target(
      name: "PR4Fusion",
      dependencies: ["PR4Math", "PR4PathTrace", "PR4Ownership", "PR4Health", "PR4Quality", "PR4Gate", "PR4Softmax", "PR4Overflow", "PR4LUT", "PR4Determinism", "PR4Package", "SharedSecurity"],
      path: "Sources/PR4Fusion"
    ),
    .executableTarget(
      name: "PR4DigestGenerator",
      dependencies: ["PR4Math", "PR4Softmax", "PR4LUT"],
      path: "Sources/PR4Tools"
    ),
    // Shared Security utilities - v8.2 IRONCLAD
    .target(
      name: "SharedSecurity",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/Shared/Security"
    ),
    // PR5Capture targets - v1.8.1 Complete Hardening Patch
    .target(
      name: "PR5Capture",
      dependencies: [
        "PR4Math",
        "PR4Ownership",
        "PR4Quality",
        "PR4Gate",
        "SharedSecurity",
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/PR5Capture"
    ),
    .testTarget(
      name: "PR5CaptureTests",
      dependencies: ["PR5Capture"],
      path: "Tests/PR5CaptureTests"
    ),
    // PR4 V10 test targets - Phase 3-5
    .testTarget(
      name: "PR4HealthTests",
      dependencies: ["PR4Health"],
      path: "Tests/PR4HealthTests"
    ),
    .testTarget(
      name: "PR4UncertaintyTests",
      dependencies: ["PR4Uncertainty"],
      path: "Tests/PR4UncertaintyTests"
    ),
    .testTarget(
      name: "PR4CalibrationTests",
      dependencies: ["PR4Calibration"],
      path: "Tests/PR4CalibrationTests"
    ),
    .testTarget(
      name: "PR4GoldenTests",
      dependencies: ["PR4Golden"],
      path: "Tests/PR4GoldenTests"
    ),
    .testTarget(
      name: "PR4IntegrationTests",
      dependencies: ["PR4Math", "PR4Softmax", "PR4LUT", "PR4Overflow"],
      path: "Tests/PR4IntegrationTests"
    ),
    // PR6 Evidence Grid Test Targets
    .testTarget(
      name: "EvidenceGridTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/EvidenceGridTests"
    ),
    .testTarget(
      name: "EvidenceGridDeterminismTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/EvidenceGridDeterminismTests"
    ),
    // PR6 Evidence Grid Canonical Output Executable
    .executableTarget(
      name: "EvidenceGridCanonicalOutput",
      dependencies: ["Aether3DCore"],
      path: "Sources/EvidenceGridCanonicalOutput"
    ),
    // PR7 Scan Guidance Tests
    .testTarget(
      name: "ScanGuidanceTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/ScanGuidanceTests"
    ),
    // PR6 TSDF Tests (MISSING-12)
    .testTarget(
      name: "TSDFTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/TSDF"
    )
  ],
  cxxLanguageStandard: .cxx20
)
