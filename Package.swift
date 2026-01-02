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
  dependencies: [],
  targets: [
    .target(
      name: "Aether3DCore",
      path: "Core"
    ),
    .testTarget(
      name: "Aether3DCoreTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Aether3DCoreTests"
    ),
    .testTarget(
      name: "InvariantTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Invariants"
    ),
    .testTarget(
      name: "GateTests",
      dependencies: ["Aether3DCore"],
      path: "Tests/Gates"
    )
  ]
)
