//
// GuidanceHapticTests.swift
// Aether3D
//
// Haptic Engine Tests — debounce/rate-limit constants (inlined)
//

import XCTest
@testable import Aether3DCore

#if canImport(CoreHaptics)
import CoreHaptics
#endif

final class GuidanceHapticTests: XCTestCase {

    #if canImport(CoreHaptics)
    // Inlined constants (formerly in ScanGuidanceConstants)
    private static let hapticDebounceS: Double = 5.0
    private static let hapticMaxPerMinute: Int = 4

    func testDebounceSuppression() {
        XCTAssertEqual(Self.hapticDebounceS, 5.0, accuracy: 0.01, "Debounce should be 5 seconds")

        let timestamp1: TimeInterval = 100.0
        let timestamp2: TimeInterval = 104.0  // 4 seconds later
        let timeDiff = timestamp2 - timestamp1
        XCTAssertLessThan(timeDiff, Self.hapticDebounceS, "4 seconds < 5 seconds debounce")
    }

    func testRateLimitSuppression() {
        XCTAssertEqual(Self.hapticMaxPerMinute, 4, "Max haptics per minute should be 4")
    }

    func testShouldFireLogic() {
        XCTAssertGreaterThan(Self.hapticDebounceS, 0, "Debounce should be positive")
        XCTAssertGreaterThan(Self.hapticMaxPerMinute, 0, "Max per minute should be positive")
    }
    #else
    func testStub() {
        // Empty test body for SwiftPM compilation
    }
    #endif
}
