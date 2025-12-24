//
//  StopRules.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 终止策略：定义何时停止构建
struct StopRules {
    /// 热状态触发阈值
    var thermalThreshold: ProcessInfo.ThermalState
    
    /// 电池电量触发阈值（0.0-1.0）
    var batteryThreshold: Double
    
    /// 内存使用触发阈值（MB）
    var memoryThresholdMB: Int
    
    /// 最大持续时间（毫秒，硬超时）
    var maxDurationMs: Int
    
    /// 默认终止策略（根据设备层级）
    static func `default`(for tier: DeviceTier) -> StopRules {
        switch tier {
        case .low:
            return StopRules(
                thermalThreshold: .fair,
                batteryThreshold: 0.15,
                memoryThresholdMB: 1024,
                maxDurationMs: 5000
            )
        case .medium:
            return StopRules(
                thermalThreshold: .serious,
                batteryThreshold: 0.10,
                memoryThresholdMB: 2048,
                maxDurationMs: 10000
            )
        case .high:
            return StopRules(
                thermalThreshold: .critical,
                batteryThreshold: 0.05,
                memoryThresholdMB: 4096,
                maxDurationMs: 30000
            )
        }
    }
}

/// 停止原因
enum StopReason {
    case thermal(ProcessInfo.ThermalState)
    case battery(Double)
    case memory(Int)
    case timeout
}

extension StopReason {
    var description: String {
        switch self {
        case .thermal(let state):
            return "thermal(\(state))"
        case .battery(let level):
            return "battery(\(String(format: "%.1f%%", level * 100)))"
        case .memory(let mb):
            return "memory(\(mb)MB)"
        case .timeout:
            return "timeout"
        }
    }
}

