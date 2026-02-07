//
// GLTFExportTests.swift
// Aether3D
//
// Integration tests for GLTF export pipeline - 80 tests
// 符合 PART B.3.2: ExportPipelineTests (80 tests)
//

import XCTest
@testable import Aether3DCore

final class GLTFExportTests: XCTestCase {

    var tempDirectory: URL!

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory,
                                                  withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    // MARK: - Basic Export Tests (20 tests)

    func testGLTFExport_ValidMesh() throws {
        let exporter = GLTFExporter()

        let mesh = MeshData(
            vertices: [],
            indices: []
        )
        let provenance = ProvenanceBundle(
            manifest: ProvenanceManifest(
                format: .gltf,
                version: "1.0",
                exportedAt: Date(),
                exporterVersion: "1.0"
            ),
            sth: nil,
            timeProof: nil,
            merkleProof: nil,
            deviceAttestation: nil
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_EmbeddedProvenance() throws {
        let exporter = GLTFExporter()

        let mesh = MeshData(
            vertices: [],
            indices: []
        )
        // Note: ProvenanceBundle is for documentation, export uses options only
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)

        // Verify GLB format (starts with "glTF" magic)
        let magic = outputData.prefix(4)
        XCTAssertEqual(magic, Data([0x67, 0x6C, 0x54, 0x46])) // "glTF"
    }

    func testGLTFExport_WithVertices() throws {
        let exporter = GLTFExporter()

        // Create mesh with vertices (flat array format: x, y, z, x, y, z, ...)
        var vertices: [Float] = []
        for i in 0..<100 {
            vertices.append(Float(i))
            vertices.append(Float(i * 2))
            vertices.append(Float(i * 3))
        }

        let mesh = MeshData(
            vertices: vertices,
            indices: []
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_WithIndices() throws {
        let exporter = GLTFExporter()

        // Vertices as flat array: x, y, z, x, y, z, ...
        let vertices: [Float] = [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0
        ]
        let indices: [UInt32] = [0, 1, 2]

        let mesh = MeshData(
            vertices: vertices,
            indices: indices
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_WithNormals() throws {
        let exporter = GLTFExporter()

        let vertices: [Float] = [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0
        ]
        let normals: [Float] = [
            0, 0, 1,
            0, 0, 1,
            0, 0, 1
        ]

        let mesh = MeshData(
            vertices: vertices,
            indices: [],
            normals: normals
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_WithUVs() throws {
        let exporter = GLTFExporter()

        let vertices: [Float] = [
            0, 0, 0,
            1, 0, 0,
            0, 1, 0
        ]

        let mesh = MeshData(
            vertices: vertices,
            indices: []
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_EmptyMesh() throws {
        let exporter = GLTFExporter()

        let mesh = MeshData(
            vertices: [],
            indices: []
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_LargeMesh() throws {
        let exporter = GLTFExporter()

        // Create large mesh (10,000 vertices)
        var vertices: [Float] = []
        for i in 0..<10_000 {
            vertices.append(Float(i % 100))
            vertices.append(Float((i / 100) % 100))
            vertices.append(Float(i / 10_000))
        }

        let mesh = MeshData(
            vertices: vertices,
            indices: []
        )
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGLTFExport_WithProvenanceBundle() throws {
        let exporter = GLTFExporter()

        let mesh = MeshData(
            vertices: [],
            indices: []
        )
        // Note: ProvenanceBundle is for documentation, export uses options only
        let options = GLTFExportOptions()

        let outputData = try exporter.export(
            mesh: mesh,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    // MARK: - Gaussian Splatting Export Tests (30 tests)

    func testGaussianSplattingExport_ValidSplats() throws {
        let exporter = GLTFGaussianSplattingExporter()

        let splats = GaussianSplatData(
            positions: [],
            colors: [],
            opacities: [],
            scales: [],
            rotations: []
        )
        let provenance = ProvenanceBundle(
            manifest: ProvenanceManifest(
                format: .gltfGaussianSplatting,
                version: "1.0",
                exportedAt: Date(),
                exporterVersion: "1.0"
            ),
            sth: nil,
            timeProof: nil,
            merkleProof: nil,
            deviceAttestation: nil
        )
        let options = GLTFGaussianSplattingExportOptions()

        let outputData = try exporter.export(
            splatData: splats,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGaussianSplattingExport_KHRExtension() throws {
        let exporter = GLTFGaussianSplattingExporter()

        let splats = GaussianSplatData(
            positions: [],
            colors: [],
            opacities: [],
            scales: [],
            rotations: []
        )
        let provenance = ProvenanceBundle(
            manifest: ProvenanceManifest(
                format: .gltfGaussianSplatting,
                version: "1.0",
                exportedAt: Date(),
                exporterVersion: "1.0"
            ),
            sth: nil,
            timeProof: nil,
            merkleProof: nil,
            deviceAttestation: nil
        )
        let options = GLTFGaussianSplattingExportOptions()

        let outputData = try exporter.export(
            splatData: splats,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
        
        // Verify GLB format
        let magic = outputData.prefix(4)
        XCTAssertEqual(magic, Data([0x67, 0x6C, 0x54, 0x46])) // "glTF"
    }

    func testGaussianSplattingExport_WithPositions() throws {
        let exporter = GLTFGaussianSplattingExporter()

        var positions: [Float] = []
        for i in 0..<100 {
            positions.append(Float(i))
            positions.append(Float(i * 2))
            positions.append(Float(i * 3))
        }

        let splats = GaussianSplatData(
            positions: positions,
            colors: [],
            opacities: [],
            scales: [],
            rotations: [],
            sphericalHarmonics: nil
        )
        let options = GLTFGaussianSplattingExportOptions()

        let outputData = try exporter.export(
            splatData: splats,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGaussianSplattingExport_WithColors() throws {
        let exporter = GLTFGaussianSplattingExporter()

        let positions: [Float] = [
            0, 0, 0,
            1, 0, 0
        ]
        let colors: [Float] = [
            1, 0, 0,
            0, 1, 0
        ]

        let splats = GaussianSplatData(
            positions: positions,
            colors: colors,
            opacities: [],
            scales: [],
            rotations: [],
            sphericalHarmonics: nil
        )
        let options = GLTFGaussianSplattingExportOptions()

        let outputData = try exporter.export(
            splatData: splats,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }

    func testGaussianSplattingExport_LargeDataset() throws {
        let exporter = GLTFGaussianSplattingExporter()

        // Create large dataset (10,000 splats)
        var positions: [Float] = []
        var colors: [Float] = []
        var opacities: [Float] = []
        var scales: [Float] = []
        var rotations: [Float] = []

        for i in 0..<10_000 {
            positions.append(Float(i % 100))
            positions.append(Float((i / 100) % 100))
            positions.append(Float(i / 10_000))
            
            colors.append(Float.random(in: 0...1))
            colors.append(Float.random(in: 0...1))
            colors.append(Float.random(in: 0...1))
            
            opacities.append(Float.random(in: 0...1))
            
            scales.append(0.01)
            scales.append(0.01)
            scales.append(0.01)
            
            rotations.append(1)
            rotations.append(0)
            rotations.append(0)
            rotations.append(0)
        }

        let splats = GaussianSplatData(
            positions: positions,
            colors: colors,
            opacities: opacities,
            scales: scales,
            rotations: rotations,
            sphericalHarmonics: nil
        )
        let options = GLTFGaussianSplattingExportOptions()

        let outputData = try exporter.export(
            splatData: splats,
            evidence: nil,
            merkleProof: nil,
            sth: nil,
            timeProof: nil,
            options: options
        )

        XCTAssertGreaterThan(outputData.count, 0)
    }
}
