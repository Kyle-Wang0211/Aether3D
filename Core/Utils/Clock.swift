//
//  Clock.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 时间源，提供当前时间
/// Phase 1 直接使用 `Date()`
enum WallClock {
    /// 返回当前时间
    static func now() -> Date {
        return Date()
    }
}

