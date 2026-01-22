// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Aether3D",
  platforms: [
    .macOS(.v13),
    .iOS(.v16)
  ],
  products: [
    .library(name: "Aether3DCore", targets: ["Aether3DCore"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
  ],
  targets: [
    .systemLibrary(
      name: "CSQLite",
      path: "Sources/CSQLite",
      pkgConfig: "sqlite3",
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
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants", "Audit/COVERAGE_GAPS_ANALYSIS.md"],
      resources: [
        .process("QualityPreCheck/Fixtures/CoverageDeltaEndiannessFixture.json"),
        .process("QualityPreCheck/Fixtures/CoverageGridPackingFixture.json"),
        .process("QualityPreCheck/Fixtures/CanonicalJSONFloatFixture.json")
      ]
    ),
    .testTarget(
      name: "ConstantsTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Constants"
    )
  ]
)
