// swift-tools-version: 6.2
// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import PackageDescription

let package = Package(
  name: "Aether3D",
  platforms: [
    .macOS(.v13),
    .iOS(.v18)
  ],
  products: [
    .library(name: "Aether3DCore", targets: ["Aether3DCore"])
  ],
  dependencies: [
    .package(path: ".deps/MetalSplatter"),
    .package(path: ".deps/swift-crypto"),
    .package(path: ".deps/swift-ssh-client"),
    .package(url: "https://github.com/apple/swift-nio-ssh", from: "0.12.0")
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
        "src/evidence/smart_anti_boost_smoother.cpp",
        "src/memory/arena.cpp",
        "src/render/shader_source.cpp",
        "src/trainer/da3_depth_fuser.cpp",
        "src/trainer/noise_aware_trainer.cpp",
        "src/tsdf/pose_stabilizer.cpp",
        "src/tsdf/spatial_hash_table.cpp",
        "src/tsdf_volume.cpp",
        "src/mobile_whitebox_c_api.cpp",
        "src/splat/spz_decoder.cpp",
        "src/splat/splat_render_engine.cpp",
        "src/splat/splat_c_api.cpp",
        "src/pipeline/streaming_pipeline.cpp",
        "src/pipeline/streaming_c_api.cpp",
        "src/pipeline/local_preview_runtime.cpp",
        "src/pipeline/local_preview_seeding.cpp",
        "src/pipeline/pipeline_coordinator.cpp",
        "src/pipeline/coordinator_c_api.cpp",
        "src/pipeline/depth_inference_coreml.mm",
        "src/thermal/thermal_predictor.cpp",
        "src/training/gaussian_training_engine.cpp",
        "src/render/metal_gpu_device.mm",
        "src/render/metal_c_api.mm"
      ],
      publicHeadersPath: "include",
      cxxSettings: [
        .headerSearchPath("include")
      ],
      linkerSettings: [
        .linkedLibrary("z")
      ]
    ),
    .target(
      name: "SharedSecurity",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Sources/Shared/Security"
    ),
    .target(
      name: "Aether3DCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        .product(name: "MetalSplatter", package: "MetalSplatter"),
        .product(name: "SSHClient", package: "swift-ssh-client"),
        .product(name: "NIOSSH", package: "swift-nio-ssh"),
        .product(name: "SplatIO", package: "MetalSplatter"),
        "CSQLite",
        "CAetherNativeBridge",
        "SharedSecurity"
      ],
      path: "Core"
    ),
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Aether3DCoreTests"
    )
  ],
  cxxLanguageStandard: .cxx20
)
