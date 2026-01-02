//
//  Frame.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation
import CoreGraphics

struct Frame: Sendable {
    let index: Int
    let timestamp: TimeInterval
    let image: CGImage
}

