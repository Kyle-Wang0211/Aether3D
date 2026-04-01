// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

import Foundation

/// Minimal evidence visualization state kept for closed-loop serialization.
public enum ColorState: String, Codable, Sendable {
    case black
    case darkGray
    case lightGray
    case white
    case original
    case unknown

    public var isS5: Bool { self == .original }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = ColorState(rawValue: rawValue) ?? .unknown
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .unknown ? "unknown" : self.rawValue)
    }
}
