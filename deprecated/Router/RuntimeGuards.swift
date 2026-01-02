//
//  RuntimeGuards.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import UIKit

/// 运行时守护：一次性状态快照，不包含监听、通知或异步逻辑
struct RuntimeGuards {
    /// 热状态快照
    let thermalState: ProcessInfo.ThermalState
    
    /// 是否处于低电量模式
    let isLowPowerModeEnabled: Bool
    
    /// 电池电量（0.0-1.0，如果可用）
    let batteryLevel: Double?
    
    /// 内存压力（使用保守阈值）
    let memoryPressureMB: Int
    
    /// 创建当前运行时状态快照
    static func snapshot() -> RuntimeGuards {
        let processInfo = ProcessInfo.processInfo
        let thermalState = processInfo.thermalState
        
        // 电池监控
        let device = UIDevice.current
        let isLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        var batteryLevel: Double? = nil
        
        if device.isBatteryMonitoringEnabled {
            let level = device.batteryLevel
            if level >= 0 {
                batteryLevel = Double(level)
            }
        }
        
        // 内存压力（使用保守阈值）
        // 这里使用物理内存的 80% 作为保守阈值
        let physicalMemory = processInfo.physicalMemory
        let memoryPressureMB = Int(Double(physicalMemory) / (1024 * 1024) * 0.8)
        
        return RuntimeGuards(
            thermalState: thermalState,
            isLowPowerModeEnabled: isLowPowerModeEnabled,
            batteryLevel: batteryLevel,
            memoryPressureMB: memoryPressureMB
        )
    }
    
    /// 检查是否应该停止构建
    /// - Parameter stopRules: 终止策略
    /// - Returns: 如果应该停止，返回停止原因；否则返回 nil
    func shouldStopBuilding(stopRules: StopRules) -> StopReason? {
        // 检查热状态
        if thermalState.rawValue >= stopRules.thermalThreshold.rawValue {
            return .thermal(thermalState)
        }
        
        // 检查电池电量
        if let batteryLevel = batteryLevel {
            if batteryLevel <= stopRules.batteryThreshold {
                return .battery(batteryLevel)
            }
        }
        
        // 检查内存压力
        if memoryPressureMB >= stopRules.memoryThresholdMB {
            return .memory(memoryPressureMB)
        }
        
        return nil
    }
    
    /// 创建当前运行时状态快照（Pipeline 使用的便捷方法）
    static func current() -> RuntimeGuards {
        return snapshot()
    }
}

