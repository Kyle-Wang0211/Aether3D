//
//  BuildPlan.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 构建预算：必须是"预算描述"结构体，不包含算法名或插件选择
struct BuildPlan {
    /// 设备层级（用于调试摘要）
    var deviceTier: DeviceTier
    
    /// 构建模式
    var mode: BuildMode
    
    /// 时间预算（毫秒）
    var timeBudgetMs: Int
    
    /// 帧数预算
    var frameBudget: Int
    
    /// 最大 splat 数量
    var maxSplats: Int
    
    /// LOD 级别（0-N）
    var lodLevel: Int
    
    /// 球谐函数阶数（0/1/2/3）
    var shOrder: Int
    
    /// 是否启用渐进式输出
    var progressive: Bool
    
    /// 终止策略
    var stopRules: StopRules
    
    /// 调试摘要：可解释的预算描述
    var debugSummary: String {
        let tierDesc = "Tier \(deviceTier.description)"
        let modeDesc: String
        switch mode {
        case .enter:
            modeDesc = "Enter"
        case .publish:
            modeDesc = "Publish"
        case .failSoft:
            modeDesc = "Fail-soft"
        }
        
        let splatsDesc = maxSplats >= 1000 ? "\(maxSplats / 1000)K" : "\(maxSplats)"
        let stops = stopRulesDescription
        
        return "[\(tierDesc)] \(modeDesc) mode: \(timeBudgetMs)ms, \(frameBudget) frames, \(splatsDesc) splats, LOD=\(lodLevel), SH=\(shOrder), progressive=\(progressive), stops=[\(stops)]"
    }
    
    /// 终止策略描述
    private var stopRulesDescription: String {
        var parts: [String] = []
        if stopRules.thermalThreshold != .critical {
            parts.append("thermal")
        }
        if stopRules.batteryThreshold > 0 {
            parts.append("battery")
        }
        if stopRules.memoryThresholdMB > 0 {
            parts.append("memory")
        }
        return parts.joined(separator: ", ")
    }
}

