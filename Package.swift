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
    .library(name: "Aether3DCore", targets: ["Aether3DCore"])
  ],
  dependencies: [
    // swift-crypto: Required for Linux compatibility (replaces Apple-only CryptoKit)
    // Used by ConstantsTests target for cross-platform SHA-256 hashing
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
        "CSQLite"
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
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants", "Upload", "Audit/COVERAGE_GAPS_ANALYSIS.md", "Golden"],
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
    )
  ]
)
