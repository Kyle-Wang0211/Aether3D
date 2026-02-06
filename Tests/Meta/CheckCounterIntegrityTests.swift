//
// CheckCounterIntegrityTests.swift
// Aether3D
//
// PR1 v2.4 Addendum - Check Counter Integrity Tests
//
// Verifies the verifier: ensures CheckCounter works correctly
//

import XCTest
@testable import Aether3DCore

final class CheckCounterIntegrityTests: XCTestCase {
    /// Test that CheckCounter increments correctly
    func testCheckCounter_Increment() {
        let initialCount = CheckCounter.get()
        
        CheckCounter.increment()
        let afterOne = CheckCounter.get()
        XCTAssertEqual(afterOne, initialCount + 1, "CheckCounter must increment by 1")
        
        CheckCounter.increment()
        CheckCounter.increment()
        let afterThree = CheckCounter.get()
        XCTAssertEqual(afterThree, initialCount + 3, "CheckCounter must increment correctly")
    }
    
    /// Test that CheckCounter can be reset
    func testCheckCounter_Reset() {
        let initialCount = CheckCounter.get()
        
        CheckCounter.increment()
        CheckCounter.increment()
        
        CheckCounter.reset()
        let afterReset = CheckCounter.get()
        XCTAssertEqual(afterReset, 0, "CheckCounter must reset to 0")
        
        // Restore original count for other tests
        for _ in 0..<initialCount {
            CheckCounter.increment()
        }
    }
    
    /// Test that intentionally triggering N checks increments exactly N
    func testCheckCounter_ExactIncrement() {
        let initialCount = CheckCounter.get()
        let n = 50
        
        for _ in 0..<n {
            CheckCounter.increment()
        }
        
        let finalCount = CheckCounter.get()
        XCTAssertEqual(finalCount, initialCount + n, "CheckCounter must increment exactly \(n) times")
    }
    
    /// Test thread-safety of CheckCounter
    func testCheckCounter_ThreadSafety() async {
        let initialCount = CheckCounter.get()
        let taskCount = 100
        let incrementsPerTask = 10
        
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<taskCount {
                group.addTask {
                    for _ in 0..<incrementsPerTask {
                        CheckCounter.increment()
                    }
                }
            }
            
            for await _ in group {
                // Wait for all tasks
            }
        }
        
        let finalCount = CheckCounter.get()
        let expectedCount = initialCount + (taskCount * incrementsPerTask)
        XCTAssertEqual(finalCount, expectedCount, "CheckCounter must be thread-safe (expected: \(expectedCount), got: \(finalCount))")
    }
}
