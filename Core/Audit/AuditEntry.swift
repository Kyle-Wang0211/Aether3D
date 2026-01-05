//
//  AuditEntry.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// 审计日志条目
/// BuildMeta is intentionally not included in Phase 1 (PR12 will introduce it)
struct AuditEntry: Codable, Sendable {
    let timestamp: Date
    let eventType: String
    let detailsJson: String?
    let detailsSchemaVersion: String
    
    init(
        timestamp: Date,
        eventType: String,
        detailsJson: String? = nil,
        detailsSchemaVersion: String = AuditSchema.version
    ) {
        self.timestamp = timestamp
        self.eventType = eventType
        self.detailsJson = detailsJson
        self.detailsSchemaVersion = detailsSchemaVersion
    }
}

