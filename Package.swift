// swift-tools-version: 5.9
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
      name: "Aether3DCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto"),
        "CSQLite",
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
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants", "Upload", "CI", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden", "PR4MathTests", "PR4PathTraceTests", "PR4OwnershipTests", "PR4OverflowTests", "PR4LUTTests", "PR4DeterminismTests", "PR4SoftmaxTests", "PR4HealthTests", "PR4UncertaintyTests", "PR4CalibrationTests", "PR4GoldenTests", "PR4IntegrationTests", "PR5CaptureTests", "EvidenceGridTests", "EvidenceGridDeterminismTests", "ScanGuidanceTests"],
      resources: [
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
    .testTarget(
      name: "UploadTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Upload"
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
    )
  ]
)
