//
//  BuildPlan+Display.swift
//  progect2
//
//  Created by Kaidong Wang on 12/18/25.
//

import Foundation

extension BuildPlan {
    var displaySummary: String {
        if !self.debugSummary.isEmpty {
            return self.debugSummary
        }
        return String(describing: self)
    }
}

