// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation
import CAetherNativeBridge

public struct TSDFRuntimeStateSnapshot: Sendable, Equatable {
    public var frameCount: UInt64
    public var hasLastPose: Bool
    public var lastPose: [Float]  // 16 floats, column-major
    public var lastTimestamp: Double
    public var systemThermalCeiling: Int
    public var currentIntegrationSkip: Int
    public var consecutiveGoodFrames: Int
    public var consecutiveRejections: Int
    public var lastThermalChangeTimeS: Double
    public var hashTableSize: Int
    public var hashTableCapacity: Int
    public var currentMaxBlocksPerExtraction: Int
    public var consecutiveGoodMeshingCycles: Int
    public var forgivenessWindowRemaining: Int
    public var consecutiveTeleportCount: Int
    public var lastAngularVelocity: Float
    public var recentPoseCount: Int
    public var lastIdleCheckTimeS: Double
    public var memoryWaterLevel: Int
    public var memoryPressureRatio: Float
    public var lastMemoryPressureChangeTimeS: Double
    public var freeBlockSlotCount: Int
    public var lastEvictedBlocks: Int

    public init(
        frameCount: UInt64 = 0,
        hasLastPose: Bool = false,
        lastPose: [Float] = Array(repeating: 0, count: 16),
        lastTimestamp: Double = 0,
        systemThermalCeiling: Int = 1,
        currentIntegrationSkip: Int = 1,
        consecutiveGoodFrames: Int = 0,
        consecutiveRejections: Int = 0,
        lastThermalChangeTimeS: Double = 0,
        hashTableSize: Int = 0,
        hashTableCapacity: Int = 0,
        currentMaxBlocksPerExtraction: Int = 0,
        consecutiveGoodMeshingCycles: Int = 0,
        forgivenessWindowRemaining: Int = 0,
        consecutiveTeleportCount: Int = 0,
        lastAngularVelocity: Float = 0,
        recentPoseCount: Int = 0,
        lastIdleCheckTimeS: Double = 0,
        memoryWaterLevel: Int = 0,
        memoryPressureRatio: Float = 0,
        lastMemoryPressureChangeTimeS: Double = 0,
        freeBlockSlotCount: Int = 0,
        lastEvictedBlocks: Int = 0
    ) {
        self.frameCount = frameCount
        self.hasLastPose = hasLastPose
        self.lastPose = lastPose.count == 16 ? lastPose : Array(lastPose.prefix(16)) + Array(repeating: 0, count: max(0, 16 - lastPose.count))
        self.lastTimestamp = lastTimestamp
        self.systemThermalCeiling = systemThermalCeiling
        self.currentIntegrationSkip = currentIntegrationSkip
        self.consecutiveGoodFrames = consecutiveGoodFrames
        self.consecutiveRejections = consecutiveRejections
        self.lastThermalChangeTimeS = lastThermalChangeTimeS
        self.hashTableSize = hashTableSize
        self.hashTableCapacity = hashTableCapacity
        self.currentMaxBlocksPerExtraction = currentMaxBlocksPerExtraction
        self.consecutiveGoodMeshingCycles = consecutiveGoodMeshingCycles
        self.forgivenessWindowRemaining = forgivenessWindowRemaining
        self.consecutiveTeleportCount = consecutiveTeleportCount
        self.lastAngularVelocity = lastAngularVelocity
        self.recentPoseCount = recentPoseCount
        self.lastIdleCheckTimeS = lastIdleCheckTimeS
        self.memoryWaterLevel = memoryWaterLevel
        self.memoryPressureRatio = memoryPressureRatio
        self.lastMemoryPressureChangeTimeS = lastMemoryPressureChangeTimeS
        self.freeBlockSlotCount = freeBlockSlotCount
        self.lastEvictedBlocks = lastEvictedBlocks
    }
}

final class NativeTSDFRuntimeBridge {
    private let handle: OpaquePointer

    init?() {
        var volume: OpaquePointer?
        let rc = aether_tsdf_volume_create(&volume)
        guard rc == 0, let volume else {
            return nil
        }
        self.handle = volume
    }

    deinit {
        _ = aether_tsdf_volume_destroy(handle)
    }

    func reset() {
        _ = aether_tsdf_volume_reset(handle)
    }

    func applyThermalState(_ state: Int) {
        _ = aether_tsdf_volume_handle_thermal_state(handle, Int32(state))
    }

    func applyMemoryPressure(_ level: Int) {
        _ = aether_tsdf_volume_handle_memory_pressure(handle, Int32(level))
    }

    func applyMemoryPressureRatio(_ ratio: Float) {
        _ = aether_tsdf_volume_handle_memory_pressure_ratio(handle, ratio)
    }

    func applyFrameFeedback(gpuTimeMs: Double) {
        _ = aether_tsdf_volume_apply_frame_feedback(handle, gpuTimeMs)
    }

    func runtimeState() -> TSDFRuntimeStateSnapshot? {
        var raw = aether_tsdf_runtime_state_t()
        let rc = aether_tsdf_volume_get_runtime_state(handle, &raw)
        guard rc == 0 else {
            return nil
        }
        let pose = withUnsafeBytes(of: raw.last_pose) { rawBytes in
            Array(rawBytes.bindMemory(to: Float.self).prefix(16))
        }
        return TSDFRuntimeStateSnapshot(
            frameCount: raw.frame_count,
            hasLastPose: raw.has_last_pose != 0,
            lastPose: pose,
            lastTimestamp: raw.last_timestamp,
            systemThermalCeiling: Int(raw.system_thermal_ceiling),
            currentIntegrationSkip: Int(raw.current_integration_skip),
            consecutiveGoodFrames: Int(raw.consecutive_good_frames),
            consecutiveRejections: Int(raw.consecutive_rejections),
            lastThermalChangeTimeS: raw.last_thermal_change_time_s,
            hashTableSize: Int(raw.hash_table_size),
            hashTableCapacity: Int(raw.hash_table_capacity),
            currentMaxBlocksPerExtraction: Int(raw.current_max_blocks_per_extraction),
            consecutiveGoodMeshingCycles: Int(raw.consecutive_good_meshing_cycles),
            forgivenessWindowRemaining: Int(raw.forgiveness_window_remaining),
            consecutiveTeleportCount: Int(raw.consecutive_teleport_count),
            lastAngularVelocity: raw.last_angular_velocity,
            recentPoseCount: Int(raw.recent_pose_count),
            lastIdleCheckTimeS: raw.last_idle_check_time_s,
            memoryWaterLevel: Int(raw.memory_water_level),
            memoryPressureRatio: raw.memory_pressure_ratio,
            lastMemoryPressureChangeTimeS: raw.last_memory_pressure_change_time_s,
            freeBlockSlotCount: Int(raw.free_block_slot_count),
            lastEvictedBlocks: Int(raw.last_evicted_blocks)
        )
    }

    func setRuntimeState(_ snapshot: TSDFRuntimeStateSnapshot) {
        var raw = aether_tsdf_runtime_state_t()
        raw.frame_count = snapshot.frameCount
        raw.has_last_pose = snapshot.hasLastPose ? 1 : 0
        withUnsafeMutableBytes(of: &raw.last_pose) { dst in
            let dstFloats = dst.bindMemory(to: Float.self)
            for i in 0..<min(16, snapshot.lastPose.count) {
                dstFloats[i] = snapshot.lastPose[i]
            }
        }
        raw.last_timestamp = snapshot.lastTimestamp
        raw.system_thermal_ceiling = Int32(snapshot.systemThermalCeiling)
        raw.current_integration_skip = Int32(snapshot.currentIntegrationSkip)
        raw.consecutive_good_frames = Int32(snapshot.consecutiveGoodFrames)
        raw.consecutive_rejections = Int32(snapshot.consecutiveRejections)
        raw.last_thermal_change_time_s = snapshot.lastThermalChangeTimeS
        raw.hash_table_size = Int32(snapshot.hashTableSize)
        raw.hash_table_capacity = Int32(snapshot.hashTableCapacity)
        raw.current_max_blocks_per_extraction = Int32(snapshot.currentMaxBlocksPerExtraction)
        raw.consecutive_good_meshing_cycles = Int32(snapshot.consecutiveGoodMeshingCycles)
        raw.forgiveness_window_remaining = Int32(snapshot.forgivenessWindowRemaining)
        raw.consecutive_teleport_count = Int32(snapshot.consecutiveTeleportCount)
        raw.last_angular_velocity = snapshot.lastAngularVelocity
        raw.recent_pose_count = Int32(snapshot.recentPoseCount)
        raw.last_idle_check_time_s = snapshot.lastIdleCheckTimeS
        raw.memory_water_level = Int32(snapshot.memoryWaterLevel)
        raw.memory_pressure_ratio = snapshot.memoryPressureRatio
        raw.last_memory_pressure_change_time_s = snapshot.lastMemoryPressureChangeTimeS
        raw.free_block_slot_count = Int32(snapshot.freeBlockSlotCount)
        raw.last_evicted_blocks = Int32(snapshot.lastEvictedBlocks)
        _ = aether_tsdf_volume_set_runtime_state(handle, &raw)
    }
}
