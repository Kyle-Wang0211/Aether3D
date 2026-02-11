// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

//
// CheckCounter.swift
// Aether3D
//
// PR1 v2.4 Addendum - Check Counter Infrastructure
//
// Global atomic counter for verification suite check tracking
//

import Foundation
import XCTest

/// Global check counter for verification suite
/// 
/// **Thread-safe:** Uses serial queue for concurrent access
public final class CheckCounter {
    private static let counterQueue = DispatchQueue(label: "com.aether3d.checkcounter", attributes: .concurrent)
    private static var _counter: Int = 0
    private static let lock = NSLock()
    
    /// Increment check counter (thread-safe)
    public static func increment() {
        lock.lock()
        defer { lock.unlock() }
        _counter += 1
    }
    
    /// Get current count (thread-safe)
    public static func get() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _counter
    }
    
    /// Reset counter (for testing)
    public static func reset() {
        lock.lock()
        defer { lock.unlock() }
        _counter = 0
    }
    
    /// Check condition and increment counter
    /// 
    /// **Usage:** Wraps XCTest assertions to track check count
    public static func check(_ condition: Bool, _ message: String = "") {
        increment()
        if !condition {
            // This will be caught by XCTest framework
            preconditionFailure("Check failed: \(message)")
        }
    }
    
    /// Check equality and increment counter
    public static func checkEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "") {
        increment()
        if actual != expected {
            preconditionFailure("Check failed: \(message). Expected: \(expected), Actual: \(actual)")
        }
    }
    
    /// Check bytes equality and increment counter
    public static func checkBytesEqual(_ actual: [UInt8], _ expected: [UInt8], _ message: String = "") {
        increment()
        if actual != expected {
            let actualHex = actual.map { String(format: "%02x", $0) }.joined()
            let expectedHex = expected.map { String(format: "%02x", $0) }.joined()
            preconditionFailure("Check failed: \(message). Expected: \(expectedHex), Actual: \(actualHex)")
        }
    }
    
    /// Check bytes equality (Data) and increment counter
    public static func checkBytesEqual(_ actual: Data, _ expected: Data, _ message: String = "") {
        checkBytesEqual(Array(actual), Array(expected), message)
    }
    
    /// Check count is within range
    public static func checkInRange<T: Comparable>(_ value: T, min: T, max: T, _ message: String = "") {
        increment()
        if value < min || value > max {
            preconditionFailure("Check failed: \(message). Value: \(value), Range: [\(min), \(max)]")
        }
    }
}

/// XCTest helper to wrap assertions with check counting
public func XCTCheck(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssert(condition(), message(), file: file, line: line)
}

public func XCTCheckEqual<T: Equatable>(_ expression1: @autoclosure () -> T, _ expression2: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssertEqual(expression1(), expression2(), message(), file: file, line: line)
}

public func XCTCheckNotEqual<T: Equatable>(_ expression1: @autoclosure () -> T, _ expression2: @autoclosure () -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssertNotEqual(expression1(), expression2(), message(), file: file, line: line)
}

public func XCTCheckNil<T>(_ expression: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssertNil(expression(), message(), file: file, line: line)
}

public func XCTCheckNotNil<T>(_ expression: @autoclosure () -> T?, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssertNotNil(expression(), message(), file: file, line: line)
}

public func XCTCheckThrowsError<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line, _ errorHandler: ((Error) -> Void)? = nil) {
    CheckCounter.increment()
    if let handler = errorHandler {
        XCTAssertThrowsError(try expression(), message(), file: file, line: line, handler)
    } else {
        XCTAssertThrowsError(try expression(), message(), file: file, line: line)
    }
}

public func XCTCheckNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: @autoclosure () -> String = "", file: StaticString = #filePath, line: UInt = #line) {
    CheckCounter.increment()
    XCTAssertNoThrow(try expression(), message(), file: file, line: line)
}
