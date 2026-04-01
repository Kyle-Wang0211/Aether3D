// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// AuditEntry.swift
// Aether3D
//
// Minimal plain audit record for the whitebox closed loop.
//

import Foundation

public struct AuditEntry: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let eventType: String
    public let detailsJson: String?
    public let detailsSchemaVersion: String

    public init(
        timestamp: Date,
        eventType: String,
        detailsJson: String? = nil,
        detailsSchemaVersion: String = "1.0"
    ) {
        self.timestamp = timestamp
        self.eventType = eventType
        self.detailsJson = detailsJson
        self.detailsSchemaVersion = detailsSchemaVersion
    }
}
