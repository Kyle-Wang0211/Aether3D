//
//  RouterV0.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// Router v0：根据设备能力和素材特征输出预算参数
struct RouterV0 {
    /// Router 输入
    struct RouterInput {
        /// 设备层级
        var deviceTier: DeviceTier
        
        /// 捕获统计信息
        var captureStats: CaptureStats
        
        /// 运行时状态
        var runtimeState: RuntimeGuards
        
        /// 请求的模式
        var requestedMode: BuildMode
    }
    
    /// 根据输入生成构建预算
    /// - Parameter input: Router 输入
    /// - Returns: 构建预算（只包含预算数值，不包含算法名或插件选择）
    static func makePlan(input: RouterInput) -> BuildPlan {
        let tier = input.deviceTier
        let mode = input.requestedMode
        let runtimeState = input.runtimeState
        
        // 根据设备层级和模式确定预算参数
        let (timeBudget, frameBudget, maxSplats, lodLevel, shOrder, progressive) = budgetForTier(tier, mode: mode)
        
        // 根据运行时状态调整预算（如果处于危险状态，降低预算）
        let adjustedTimeBudget = adjustTimeBudget(timeBudget, for: runtimeState, tier: tier)
        let adjustedMaxSplats = adjustMaxSplats(maxSplats, for: runtimeState, tier: tier)
        
        // 生成终止策略
        let stopRules = StopRules.default(for: tier)
        
        return BuildPlan(
            deviceTier: tier,
            mode: mode,
            timeBudgetMs: adjustedTimeBudget,
            frameBudget: frameBudget,
            maxSplats: adjustedMaxSplats,
            lodLevel: lodLevel,
            shOrder: shOrder,
            progressive: progressive,
            stopRules: stopRules
        )
    }
    
    /// 根据设备层级和模式获取预算参数
    private static func budgetForTier(_ tier: DeviceTier, mode: BuildMode) -> (timeBudget: Int, frameBudget: Int, maxSplats: Int, lodLevel: Int, shOrder: Int, progressive: Bool) {
        switch (tier, mode) {
        case (.low, .enter):
            return (2000, 30, 100_000, 1, 1, true)
        case (.low, .publish):
            return (10000, 60, 200_000, 1, 1, true)
        case (.low, .failSoft):
            return (1000, 10, 50_000, 0, 0, false)
            
        case (.medium, .enter):
            return (2000, 60, 300_000, 2, 2, true)
        case (.medium, .publish):
            return (20000, 120, 500_000, 2, 2, true)
        case (.medium, .failSoft):
            return (1000, 20, 100_000, 1, 1, false)
            
        case (.high, .enter):
            return (2000, 120, 500_000, 2, 2, true)
        case (.high, .publish):
            return (30000, 200, 1_000_000, 3, 3, true)
        case (.high, .failSoft):
            return (1000, 30, 200_000, 1, 1, false)
        }
    }
    
    /// 根据运行时状态调整时间预算
    private static func adjustTimeBudget(_ base: Int, for runtimeState: RuntimeGuards, tier: DeviceTier) -> Int {
        var adjusted = base
        
        // 如果处于低电量模式，减少 30% 时间预算
        if runtimeState.isLowPowerModeEnabled {
            adjusted = Int(Double(adjusted) * 0.7)
        }
        
        // 如果热状态较高，减少时间预算
        switch runtimeState.thermalState {
        case .fair:
            adjusted = Int(Double(adjusted) * 0.9)
        case .serious:
            adjusted = Int(Double(adjusted) * 0.7)
        case .critical:
            adjusted = Int(Double(adjusted) * 0.5)
        default:
            break
        }
        
        // 如果电池电量低，减少时间预算
        if let batteryLevel = runtimeState.batteryLevel {
            if batteryLevel < 0.2 {
                adjusted = Int(Double(adjusted) * 0.8)
            }
        }
        
        return adjusted
    }
    
    /// 根据运行时状态调整最大 splat 数量
    private static func adjustMaxSplats(_ base: Int, for runtimeState: RuntimeGuards, tier: DeviceTier) -> Int {
        var adjusted = base
        
        // 如果处于低电量模式，减少 20% splat 数量
        if runtimeState.isLowPowerModeEnabled {
            adjusted = Int(Double(adjusted) * 0.8)
        }
        
        // 如果热状态较高，减少 splat 数量
        switch runtimeState.thermalState {
        case .fair:
            adjusted = Int(Double(adjusted) * 0.9)
        case .serious:
            adjusted = Int(Double(adjusted) * 0.7)
        case .critical:
            adjusted = Int(Double(adjusted) * 0.5)
        default:
            break
        }
        
        return adjusted
    }
}

