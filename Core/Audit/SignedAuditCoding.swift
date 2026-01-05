//
//  SignedAuditCoding.swift
//  progect2
//
//  Created by Kaidong Wang on 12/27/25.
//

import Foundation

/// Unified encoder/decoder for SignedAuditEntry.
/// CRITICAL: Must be used everywhere. No .iso8601 strategy allowed.
enum SignedAuditCoding {

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let s = ISO8601DateFormatter.auditFormat.string(from: date)
            try container.encode(s)
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            guard let d = ISO8601DateFormatter.auditFormat.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO8601 date: \(s)"
                )
            }
            return d
        }
        return decoder
    }
}

extension ISO8601DateFormatter {
    /// Audit-specific ISO8601 formatter (UTC, fractional seconds).
    static let auditFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f
    }()
}

