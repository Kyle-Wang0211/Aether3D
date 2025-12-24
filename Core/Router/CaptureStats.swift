//
//  CaptureStats.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 捕获统计信息（占位结构）
struct CaptureStats {
    /// 帧数
    var frameCount: Int
    
    /// 覆盖度估计（0.0-1.0，占位）
    var coverageEstimate: Double
    
    /// 默认值（用于测试）
    static func `default`() -> CaptureStats {
        return CaptureStats(
            frameCount: 0,
            coverageEstimate: 0.0
        )
    }
}

