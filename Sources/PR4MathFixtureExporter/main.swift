// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// PR4MathFixtureExporter
// Exports PR4Math golden vectors for C++ migration (B.1 math_tests).
// SSOT: Same canonical inputs as CrossPlatformDeterminismStrictTests.GoldenValues.
//

import Foundation
import PR4Math
import PR4Softmax
import PR4LUT

// Canonical inputs (must match CrossPlatformDeterminismStrictTests.GoldenValues)
struct CanonicalInputs {
    static let softmax3: [Int64] = [65536, 0, -65536]
    static let softmax5: [Int64] = [131072, 65536, 0, -65536, -131072]
    static let expInputs: [(x: Int64, name: String)] = [
        (0, "exp0"),
        (-65536, "expNeg1"),
        (-131072, "expNeg2"),
        (-655360, "expNeg10"),
        (-2097152, "expNeg32"),
    ]
    static let median9: [Int64] = [5, 2, 9, 1, 7, 3, 8, 4, 6]
    static let mad9: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8, 9]
    static let addA: Int64 = 98304
    static let addB: Int64 = 32768
    static let mulA: Int64 = 98304
    static let mulB: Int64 = 32768
    static let divA: Int64 = 65536
    static let divB: Int64 = 131072
}

struct PR4MathFixture: Codable {
    let schemaVersion: Int
    let exportedAt: String
    let softmax3: SoftmaxCase
    let softmax5: SoftmaxCase
    let exp: [ExpCase]
    let median: MedianCase
    let mad: MadCase
    let q16: Q16ArithmeticCase
}

struct SoftmaxCase: Codable {
    let input: [Int64]
    let output: [Int64]
    let sum: Int64
}

struct ExpCase: Codable {
    let name: String
    let input: Int64
    let output: Int64
}

struct MedianCase: Codable {
    let input: [Int64]
    let output: Int64
}

struct MadCase: Codable {
    let input: [Int64]
    let output: Int64
}

struct Q16ArithmeticCase: Codable {
    let add: AddCase
    let mul: MulCase
    let div: DivCase
}

struct AddCase: Codable { let a: Int64; let b: Int64; let result: Int64; let overflow: Bool }
struct MulCase: Codable { let a: Int64; let b: Int64; let result: Int64; let overflow: Bool }
struct DivCase: Codable { let a: Int64; let b: Int64; let result: Int64; let overflow: Bool }

func main() throws {
    let s3 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: CanonicalInputs.softmax3)
    let s5 = SoftmaxExactSumV2.softmaxExactSum(logitsQ16: CanonicalInputs.softmax5)

    let expCases: [ExpCase] = CanonicalInputs.expInputs.map { inp in
        ExpCase(
            name: inp.name,
            input: inp.x,
            output: RangeCompleteSoftmaxLUT.expQ16(inp.x)
        )
    }

    let (addR, addO) = Q16.add(CanonicalInputs.addA, CanonicalInputs.addB)
    let (mulR, mulO) = Q16.multiply(CanonicalInputs.mulA, CanonicalInputs.mulB)
    let (divR, divO) = Q16.divide(CanonicalInputs.divA, CanonicalInputs.divB)

    let fixture = PR4MathFixture(
        schemaVersion: 1,
        exportedAt: ISO8601DateFormatter().string(from: Date()),
        softmax3: SoftmaxCase(
            input: CanonicalInputs.softmax3,
            output: s3,
            sum: s3.reduce(0, +)
        ),
        softmax5: SoftmaxCase(
            input: CanonicalInputs.softmax5,
            output: s5,
            sum: s5.reduce(0, +)
        ),
        exp: expCases,
        median: MedianCase(
            input: CanonicalInputs.median9,
            output: DeterministicMedianMAD.medianQ16(CanonicalInputs.median9)
        ),
        mad: MadCase(
            input: CanonicalInputs.mad9,
            output: DeterministicMedianMAD.madQ16(CanonicalInputs.mad9)
        ),
        q16: Q16ArithmeticCase(
            add: AddCase(a: CanonicalInputs.addA, b: CanonicalInputs.addB, result: addR, overflow: addO),
            mul: MulCase(a: CanonicalInputs.mulA, b: CanonicalInputs.mulB, result: mulR, overflow: mulO),
            div: DivCase(a: CanonicalInputs.divA, b: CanonicalInputs.divB, result: divR, overflow: divO)
        )
    )

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    let data = try encoder.encode(fixture)

    let outDir = URL(fileURLWithPath: "Tests/Fixtures/PR4Math")
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    let goldenPath = outDir.appendingPathComponent("pr4math_golden_v1.json")
    try data.write(to: goldenPath)

    // Also copy to aether_cpp/golden if directory exists (for C++ migration)
    let cppGoldenDir = URL(fileURLWithPath: "aether_cpp/golden")
    if FileManager.default.fileExists(atPath: cppGoldenDir.path) {
        try data.write(to: cppGoldenDir.appendingPathComponent("pr4math_golden_v1.json"))
    }

    print("Exported PR4Math golden fixture: \(goldenPath.path)")
    if FileManager.default.fileExists(atPath: cppGoldenDir.path) {
        print("Also written to aether_cpp/golden/")
    }
}

try main()
