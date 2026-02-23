// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge
#if canImport(simd)
import simd
#endif

#if canImport(simd)
struct NativePoseGraphNode: Sendable {
    var id: UInt32
    var pose: simd_float4x4
    var fixed: Bool
}

struct NativePoseGraphEdge: Sendable {
    var fromId: UInt32
    var toId: UInt32
    var transform: simd_float4x4
    var isLoop: Bool
}

struct NativePoseGraphResult: Sendable {
    var iterations: Int
    var initialError: Float
    var finalError: Float
    var converged: Bool
}

enum NativePoseGraphOptimizer {
    static func optimize(
        nodes: inout [NativePoseGraphNode],
        edges: [NativePoseGraphEdge]
    ) -> NativePoseGraphResult? {
        guard !nodes.isEmpty, !edges.isEmpty else {
            return nil
        }

        var cNodes = nodes.map { node in
            var pose = [Float](repeating: 0, count: 16)
            for c in 0..<4 {
                for r in 0..<4 {
                    pose[c * 4 + r] = node.pose[c][r]
                }
            }
            return aether_pose_graph_node_t(
                id: node.id,
                pose: (
                    pose[0], pose[1], pose[2], pose[3],
                    pose[4], pose[5], pose[6], pose[7],
                    pose[8], pose[9], pose[10], pose[11],
                    pose[12], pose[13], pose[14], pose[15]
                ),
                fixed: node.fixed ? 1 : 0
            )
        }

        let zeroInfo = Array(repeating: Float(0), count: 36)
        let cEdges = edges.map { edge in
            var tf = [Float](repeating: 0, count: 16)
            for c in 0..<4 {
                for r in 0..<4 {
                    tf[c * 4 + r] = edge.transform[c][r]
                }
            }
            return aether_pose_graph_edge_t(
                from_id: edge.fromId,
                to_id: edge.toId,
                transform: (
                    tf[0], tf[1], tf[2], tf[3],
                    tf[4], tf[5], tf[6], tf[7],
                    tf[8], tf[9], tf[10], tf[11],
                    tf[12], tf[13], tf[14], tf[15]
                ),
                information: (
                    zeroInfo[0], zeroInfo[1], zeroInfo[2], zeroInfo[3], zeroInfo[4], zeroInfo[5],
                    zeroInfo[6], zeroInfo[7], zeroInfo[8], zeroInfo[9], zeroInfo[10], zeroInfo[11],
                    zeroInfo[12], zeroInfo[13], zeroInfo[14], zeroInfo[15], zeroInfo[16], zeroInfo[17],
                    zeroInfo[18], zeroInfo[19], zeroInfo[20], zeroInfo[21], zeroInfo[22], zeroInfo[23],
                    zeroInfo[24], zeroInfo[25], zeroInfo[26], zeroInfo[27], zeroInfo[28], zeroInfo[29],
                    zeroInfo[30], zeroInfo[31], zeroInfo[32], zeroInfo[33], zeroInfo[34], zeroInfo[35]
                ),
                is_loop: edge.isLoop ? 1 : 0
            )
        }

        var config = aether_pose_graph_config_t(
            max_iterations: 20,
            step_size: 0.2,
            huber_delta: 0.02,
            stop_translation: 1e-4,
            stop_rotation: 1e-4,
            watchdog_max_diag_ratio: 1_000,
            watchdog_max_residual_rise: 2
        )
        var result = aether_pose_graph_result_t(
            iterations: 0,
            initial_error: 0,
            final_error: 0,
            watchdog_diag_ratio: 1,
            watchdog_tripped: 0,
            converged: 0
        )

        let nodeCount = Int32(cNodes.count)
        let edgeCount = Int32(cEdges.count)
        let rc = cNodes.withUnsafeMutableBufferPointer { nodePtr in
            cEdges.withUnsafeBufferPointer { edgePtr in
                aether_pose_graph_optimize(
                    nodePtr.baseAddress,
                    nodeCount,
                    edgePtr.baseAddress,
                    edgeCount,
                    &config,
                    &result
                )
            }
        }

        guard rc == 0 else {
            return nil
        }

        for i in 0..<nodes.count {
            let poseValues = withUnsafeBytes(of: cNodes[i].pose) { raw in
                Array(raw.bindMemory(to: Float.self).prefix(16))
            }
            var pose = matrix_identity_float4x4
            for c in 0..<4 {
                for r in 0..<4 {
                    pose[c][r] = poseValues[c * 4 + r]
                }
            }
            nodes[i].pose = pose
        }

        return NativePoseGraphResult(
            iterations: Int(result.iterations),
            initialError: result.initial_error,
            finalError: result.final_error,
            converged: result.converged != 0
        )
    }
}
#endif
