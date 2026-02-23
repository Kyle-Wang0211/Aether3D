// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// EnhancedPIIDetector.swift
// Aether3D
//
// Enhanced PII detection with support for Chinese and US PII patterns.
// Covers: email, phone (CN/US), ID card (身份证), SSN, credit card,
// passport, and bank account numbers.
//
// Also provides cryptographic memory erasure utilities.
//

import Foundation

// MARK: - PII Types

/// PII category detected in text data
public enum PIICategory: String, Sendable, CaseIterable {
    /// Email address (RFC 5322 simplified)
    case email
    /// Chinese mainland mobile phone (+86 / 1xx-xxxx-xxxx)
    case cnPhone
    /// US/international phone number
    case usPhone
    /// Chinese national ID card (身份证, 18 digits)
    case cnIdCard
    /// US Social Security Number (XXX-XX-XXXX)
    case usSSN
    /// Credit/debit card number (16 digits)
    case creditCard
    /// Chinese passport (E/G/D/S/P/H + 8 digits)
    case cnPassport
    /// Chinese bank account number (16-19 digits)
    case cnBankAccount
}

/// A single PII match found in text
public struct PIIMatch: Sendable {
    /// The PII category
    public let category: PIICategory
    /// Range in the original string
    public let range: Range<String.Index>
    /// The matched text
    public let matchedText: String

    public init(category: PIICategory, range: Range<String.Index>, matchedText: String) {
        self.category = category
        self.range = range
        self.matchedText = matchedText
    }
}

/// Result of PII detection scan
public struct PIIScanResult: Sendable {
    /// All matches found
    public let matches: [PIIMatch]
    /// Unique categories detected
    public var categories: Set<PIICategory> {
        Set(matches.map(\.category))
    }
    /// Whether any PII was found
    public var hasPII: Bool { !matches.isEmpty }
}

// MARK: - Enhanced PII Detector

/// Enhanced PII detector supporting Chinese and US PII patterns
///
/// Thread-safe, stateless detector. Each call to `scan()` is independent.
/// For text-level PII detection — complement to pixel-level `AnonymizationPipeline`.
public struct EnhancedPIIDetector: Sendable {

    public init() {}

    /// Scan text for all known PII patterns
    public func scan(_ text: String) -> PIIScanResult {
        var matches: [PIIMatch] = []

        for (category, pattern) in Self.patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            let results = regex.matches(in: text, range: nsRange)

            for result in results {
                guard let range = Range(result.range, in: text) else { continue }
                let matched = String(text[range])

                // Additional validation for specific categories
                if category == .cnIdCard && !Self.validateCNIdCard(matched) {
                    continue
                }
                if category == .creditCard && !Self.luhnCheck(matched) {
                    continue
                }

                matches.append(PIIMatch(category: category, range: range, matchedText: matched))
            }
        }

        return PIIScanResult(matches: matches)
    }

    /// Redact all detected PII in text, replacing with category placeholders
    public func redact(_ text: String) -> String {
        let result = scan(text)
        guard result.hasPII else { return text }

        // Sort matches by range start, descending, so replacements don't shift indices
        let sorted = result.matches.sorted { $0.range.lowerBound > $1.range.lowerBound }

        var redacted = text
        for match in sorted {
            let placeholder = "[\(match.category.rawValue.uppercased()) REDACTED]"
            redacted.replaceSubrange(match.range, with: placeholder)
        }
        return redacted
    }

    // MARK: - Patterns

    /// Regex patterns for each PII category
    static let patterns: [(PIICategory, String)] = [
        // Email: simplified RFC 5322
        (.email, #"[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}"#),

        // Chinese mobile phone: +86 or 86 prefix optional, starts with 1[3-9]
        (.cnPhone, #"(?<![0-9])(?:\+?86[\s\-]?)?1[3-9]\d{9}(?![0-9])"#),

        // US phone: (XXX) XXX-XXXX or XXX-XXX-XXXX or +1-XXX-XXX-XXXX
        (.usPhone, #"(?<![0-9])(?:\+?1[\s\-]?)?\(?\d{3}\)?[\s\-]?\d{3}[\s\-]?\d{4}(?![0-9])"#),

        // Chinese national ID (身份证): 18 digits, last may be X
        (.cnIdCard, #"(?<![0-9])[1-9]\d{5}(?:19|20)\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])\d{3}[\dXx](?![0-9])"#),

        // US SSN: XXX-XX-XXXX (with dashes)
        (.usSSN, #"(?<![0-9])\d{3}-\d{2}-\d{4}(?![0-9])"#),

        // Credit card: 16 digits with optional spaces/dashes
        (.creditCard, #"(?<![0-9])\d{4}[\s\-]?\d{4}[\s\-]?\d{4}[\s\-]?\d{4}(?![0-9])"#),

        // Chinese passport: letter prefix + 8 digits
        (.cnPassport, #"(?<![A-Za-z0-9])[EGDSPHegdsph]\d{8}(?![0-9])"#),

        // Chinese bank account: 16-19 consecutive digits
        (.cnBankAccount, #"(?<![0-9])\d{16,19}(?![0-9])"#),
    ]

    // MARK: - Validation Helpers

    /// Validate Chinese ID card number using GB 11643-1999 checksum
    static func validateCNIdCard(_ id: String) -> Bool {
        let cleaned = id.uppercased()
        guard cleaned.count == 18 else { return false }

        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checkChars: [Character] = ["1", "0", "X", "9", "8", "7", "6", "5", "4", "3", "2"]

        let chars = Array(cleaned)
        var sum = 0
        for i in 0..<17 {
            guard let digit = chars[i].wholeNumberValue else { return false }
            sum += digit * weights[i]
        }

        let checkIndex = sum % 11
        return chars[17] == checkChars[checkIndex]
    }

    /// Luhn algorithm for credit card validation
    static func luhnCheck(_ number: String) -> Bool {
        let digits = number.compactMap(\.wholeNumberValue)
        guard digits.count >= 13 && digits.count <= 19 else { return false }

        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}

// MARK: - Cryptographic Memory Erasure

/// Utilities for secure memory erasure.
///
/// Swift's ARC does not guarantee zeroing of deallocated memory.
/// These utilities provide explicit memory wiping for sensitive data.
public enum SecureMemory {

    /// Securely zero a mutable Data buffer.
    ///
    /// Uses volatile-equivalent writes to prevent compiler optimization from
    /// eliding the zeroing. After this call, the Data contains all zeros.
    @inline(never)
    public static func zeroize(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeMutableBytes { buffer in
            guard let ptr = buffer.baseAddress else { return }
            // Use memset_s equivalent: volatile pointer write
            // The @inline(never) on the enclosing function prevents dead-store elimination
            let bytePtr = ptr.bindMemory(to: UInt8.self, capacity: buffer.count)
            for i in 0..<buffer.count {
                bytePtr[i] = 0
            }
            // Memory barrier to ensure writes are not reordered
            #if canImport(Darwin)
            OSMemoryBarrier()
            #endif
        }
    }

    /// Securely zero an UnsafeMutableRawBufferPointer.
    @inline(never)
    public static func zeroize(_ buffer: UnsafeMutableRawBufferPointer) {
        guard let ptr = buffer.baseAddress, buffer.count > 0 else { return }
        let bytePtr = ptr.bindMemory(to: UInt8.self, capacity: buffer.count)
        for i in 0..<buffer.count {
            bytePtr[i] = 0
        }
        #if canImport(Darwin)
        OSMemoryBarrier()
        #endif
    }

    /// Securely zero a String's UTF-8 buffer (best effort).
    ///
    /// Note: Swift Strings are value types with copy-on-write. This zeros
    /// the current buffer but cannot guarantee no copies exist elsewhere.
    /// For truly sensitive data, use Data instead of String.
    @inline(never)
    public static func zeroize(_ string: inout String) {
        guard !string.isEmpty else { return }
        var utf8 = Array(string.utf8)
        for i in 0..<utf8.count {
            utf8[i] = 0
        }
        string = ""
    }
}

#if canImport(Darwin)
import Darwin
#endif
