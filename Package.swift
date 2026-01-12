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
    .target(
      name: "Aether3DCore",
      dependencies: [
        .product(name: "Crypto", package: "swift-crypto")
      ],
      path: "Core"
    ),
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests",
      exclude: ["Constants"]
    ),
    .testTarget(
      name: "ConstantsTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Constants"
    )
  ]
)
