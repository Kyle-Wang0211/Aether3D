//
// DirectionalBitmaskTests.swift
// Aether3D
//
// PR6 Evidence Grid System - Directional Bitmask Tests
//

import XCTest
@testable import Aether3DCore

final class DirectionalBitmaskTests: XCTestCase {
    
    func testDirectionIndexDeterministic() {
        let theta1 = 0.5
        let phi1 = 1.0
        
        let index1 = DirectionalBitmask.directionIndex(theta: theta1, phi: phi1)
        let index2 = DirectionalBitmask.directionIndex(theta: theta1, phi: phi1)
        
        XCTAssertEqual(index1, index2, "Same theta/phi must produce same direction index")
    }
    
    func testPopcountCorrectness() {
        // Test known bitmask: 0b101 (bits 0 and 2 set)
        let bitmask: UInt32 = 0b101
        let count = DirectionalBitmask.popcount(bitmask)
        
        XCTAssertEqual(count, 2, "Popcount should count set bits correctly")
    }
    
    func testHasAtLeastTwoDistinctDirections() {
        // 0 bits: false
        XCTAssertFalse(DirectionalBitmask.hasAtLeastTwoDistinctDirections(0))
        
        // 1 bit: false
        XCTAssertFalse(DirectionalBitmask.hasAtLeastTwoDistinctDirections(0b1))
        
        // 2 bits: true
        XCTAssertTrue(DirectionalBitmask.hasAtLeastTwoDistinctDirections(0b11))
        
        // 3 bits: true
        XCTAssertTrue(DirectionalBitmask.hasAtLeastTwoDistinctDirections(0b111))
    }
}
