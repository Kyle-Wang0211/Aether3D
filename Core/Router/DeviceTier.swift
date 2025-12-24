//
//  DeviceTier.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 设备层级（按能力不按机型）
enum DeviceTier {
    case low      // L
    case medium   // M
    case high     // H
}

extension DeviceTier {
    /// 基于设备内存和 SoC 型号的简单 heuristics 判定设备层级
    /// - Returns: 设备层级
    static func detect() -> DeviceTier {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let memoryGB = Double(physicalMemory) / (1024 * 1024 * 1024)
        
        // 基于内存的简单判定
        // L: < 4GB
        // M: 4-8GB
        // H: > 8GB
        if memoryGB < 4.0 {
            return .low
        } else if memoryGB <= 8.0 {
            return .medium
        } else {
            return .high
        }
        
        // Phase 1-5 补充：基于 SoC 型号的 micro-benchmark 接口
        // 当前使用内存作为主要判定依据，后续可通过性能测试优化
    }
    
    /// 设备层级描述
    var description: String {
        switch self {
        case .low:
            return "L"
        case .medium:
            return "M"
        case .high:
            return "H"
        }
    }
}

