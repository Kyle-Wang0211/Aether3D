// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import XCTest
@testable import Aether3DCore

final class TSDFMathInverseTests: XCTestCase {

    func testInverseIntrinsicsRoundTrip() {
        let k = tsdMakeIntrinsicsMatrix(fx: 845.0, fy: 832.0, cx: 321.5, cy: 241.0)
        guard let inv = tsdInverseIntrinsics(k) else {
            XCTFail("Intrinsics inverse should exist for non-degenerate K")
            return
        }

        let testPixels: [TSDFFloat3] = [
            TSDFFloat3(0, 0, 1),
            TSDFFloat3(100, 200, 1),
            TSDFFloat3(320.5, 240.0, 1),
            TSDFFloat3(640, 480, 1),
        ]

        for p in testPixels {
            let mapped = tsdTransform(inv, tsdTransform(k, p))
            XCTAssertEqual(mapped.x, p.x, accuracy: 1e-4)
            XCTAssertEqual(mapped.y, p.y, accuracy: 1e-4)
            XCTAssertEqual(mapped.z, p.z, accuracy: 1e-4)
        }
    }

    func testInverseIntrinsicsRejectsDegenerateMatrix() {
        let degenerate = tsdMakeIntrinsicsMatrix(fx: 0.0, fy: 830.0, cx: 320.0, cy: 240.0)
        XCTAssertNil(tsdInverseIntrinsics(degenerate))
    }

    func testInverseRigidTransformRoundTrip() {
        // 90-degree rotation around Z axis (column-major).
        let r0 = TSDFFloat3(0, 1, 0)
        let r1 = TSDFFloat3(-1, 0, 0)
        let r2 = TSDFFloat3(0, 0, 1)
        let t = TSDFFloat3(1.2, -3.4, 2.0)
        let m = tsdMakeRigidTransform(rotationColumns: (r0, r1, r2), translation: t)

        guard let inv = tsdInverseRigidTransform(m) else {
            XCTFail("Rigid transform inverse should exist")
            return
        }

        let p = TSDFFloat3(0.3, -0.7, 4.1)
        let p2 = tsdTransform(m, p)
        let back = tsdTransform(inv, p2)

        XCTAssertEqual(back.x, p.x, accuracy: 1e-4)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-4)
        XCTAssertEqual(back.z, p.z, accuracy: 1e-4)
    }

    func testInverseRigidTransformRejectsScaledBasis() {
        let nonRigid = tsdMakeRigidTransform(
            rotationColumns: (TSDFFloat3(2, 0, 0), TSDFFloat3(0, 1, 0), TSDFFloat3(0, 0, 1)),
            translation: TSDFFloat3(0, 0, 0)
        )
        XCTAssertNil(tsdInverseRigidTransform(nonRigid))
    }
}

