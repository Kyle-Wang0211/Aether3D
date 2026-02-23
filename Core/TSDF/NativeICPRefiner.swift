// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge
#if canImport(simd)
import simd
#endif

#if canImport(simd)
struct NativeICPResult: Sendable {
    var pose: simd_float4x4
    var iterations: Int
    var correspondenceCount: Int
    var rmse: Float
    var converged: Bool
}

enum NativeICPRefiner {
    static func refine(
        sourcePoints: [SIMD3<Float>],
        targetPoints: [SIMD3<Float>],
        targetNormals: [SIMD3<Float>],
        initialPose: simd_float4x4,
        angularVelocity: Float
    ) -> NativeICPResult? {
        guard sourcePoints.count > 0,
              targetPoints.count == targetNormals.count,
              targetPoints.count > 0 else {
            return nil
        }

        let source = sourcePoints.map { aether_icp_point_t(x: $0.x, y: $0.y, z: $0.z) }
        let target = targetPoints.map { aether_icp_point_t(x: $0.x, y: $0.y, z: $0.z) }
        let normals = targetNormals.map { aether_icp_point_t(x: $0.x, y: $0.y, z: $0.z) }

        var poseArray = [Float](repeating: 0, count: 16)
        for c in 0..<4 {
            for r in 0..<4 {
                poseArray[c * 4 + r] = initialPose[c][r]
            }
        }

        var config = aether_icp_config_t(
            max_iterations: 20,
            distance_threshold: 0.03,
            normal_threshold_deg: 65,
            huber_delta: 0.01,
            convergence_translation: 1e-5,
            convergence_rotation: 1e-4,
            watchdog_max_diag_ratio: 1_000,
            watchdog_max_residual_rise: 2
        )
        var out = aether_icp_result_t(
            pose_out: (1, 0, 0, 0,
                       0, 1, 0, 0,
                       0, 0, 1, 0,
                       0, 0, 0, 1),
            iterations: 0,
            correspondence_count: 0,
            rmse: 0,
            watchdog_diag_ratio: 1,
            watchdog_tripped: 0,
            converged: 0
        )

        let rc = source.withUnsafeBufferPointer { srcPtr in
            target.withUnsafeBufferPointer { tgtPtr in
                normals.withUnsafeBufferPointer { nrmPtr in
                    poseArray.withUnsafeBufferPointer { posePtr in
                        aether_icp_refine(
                            srcPtr.baseAddress,
                            Int32(source.count),
                            tgtPtr.baseAddress,
                            Int32(target.count),
                            nrmPtr.baseAddress,
                            posePtr.baseAddress,
                            angularVelocity,
                            &config,
                            &out
                        )
                    }
                }
            }
        }

        guard rc == 0 else {
            return nil
        }

        let outPoseValues = withUnsafeBytes(of: out.pose_out) { raw in
            Array(raw.bindMemory(to: Float.self).prefix(16))
        }
        var outPose = matrix_identity_float4x4
        for c in 0..<4 {
            for r in 0..<4 {
                outPose[c][r] = outPoseValues[c * 4 + r]
            }
        }

        return NativeICPResult(
            pose: outPose,
            iterations: Int(out.iterations),
            correspondenceCount: Int(out.correspondence_count),
            rmse: out.rmse,
            converged: out.converged != 0
        )
    }
}
#endif
