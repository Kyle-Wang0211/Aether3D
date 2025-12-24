//
//  BuildMode.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

/// 构建模式
enum BuildMode {
    /// Enter 模式：快速进入，T+1-2s 内显示可漫游结果
    case enter
    
    /// Publish 模式：高质量输出，10-30s 范围按 tier
    case publish
    
    /// Fail-soft 模式：降级输出照片空间
    case failSoft
}

