// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class ZeroFabricationPolicyKernelTests: XCTestCase {
    func testForensicStrictBlocksGenerativeActions() {
        let kernel = ZeroFabricationPolicyKernel(mode: .forensicStrict)
        let context = ZeroFabricationContext(confidenceClass: .measured, hasDirectObservation: true)

        XCTAssertFalse(kernel.evaluate(action: .textureInpaint, context: context).allowed)
        XCTAssertFalse(kernel.evaluate(action: .holeFilling, context: context).allowed)
        XCTAssertFalse(kernel.evaluate(action: .geometryCompletion, context: context).allowed)
    }

    func testForensicStrictBlocksUnknownRegionGrowthWithoutObservation() {
        let kernel = ZeroFabricationPolicyKernel(mode: .forensicStrict)
        let context = ZeroFabricationContext(confidenceClass: .unknown, hasDirectObservation: false)
        let decision = kernel.evaluate(action: .unknownRegionGrowth, context: context)

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reasonCode, "ZERO_FAB_BLOCK_UNKNOWN_GROWTH")
    }

    func testForensicStrictBlocksCoordinateRewriteDenoise() {
        let kernel = ZeroFabricationPolicyKernel(mode: .forensicStrict, maxDenoiseDisplacementMeters: 0.02)
        let context = ZeroFabricationContext(
            confidenceClass: .measured,
            hasDirectObservation: true,
            requestedPointDisplacementMeters: 0.001
        )
        let decision = kernel.evaluate(action: .multiViewDenoise, context: context)

        XCTAssertFalse(decision.allowed)
        XCTAssertEqual(decision.reasonCode, "ZERO_FAB_BLOCK_COORDINATE_REWRITE")
    }

    func testResearchModeAllowsBoundedDenoise() {
        let kernel = ZeroFabricationPolicyKernel(mode: .researchRelaxed, maxDenoiseDisplacementMeters: 0.02)
        let context = ZeroFabricationContext(
            confidenceClass: .estimated,
            hasDirectObservation: true,
            requestedPointDisplacementMeters: 0.005
        )
        XCTAssertTrue(kernel.evaluate(action: .multiViewDenoise, context: context).allowed)
    }
}

