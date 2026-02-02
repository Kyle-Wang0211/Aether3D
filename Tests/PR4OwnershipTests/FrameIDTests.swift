//
// FrameIDTests.swift
// PR4OwnershipTests
//
// Tests for Frame ID
//

import XCTest
@testable import PR4Ownership

final class FrameIDTests: XCTestCase {
    
    func testUniqueIDs() {
        let id1 = FrameID.next()
        let id2 = FrameID.next()
        let id3 = FrameID.next()
        
        XCTAssertNotEqual(id1.value, id2.value)
        XCTAssertNotEqual(id2.value, id3.value)
        XCTAssertTrue(id1 < id2)
        XCTAssertTrue(id2 < id3)
    }
    
    func testMonotonic() {
        var lastId: FrameID?
        
        for _ in 0..<100 {
            let newId = FrameID.next()
            
            if let last = lastId {
                XCTAssertGreaterThan(newId, last)
            }
            
            lastId = newId
        }
    }
    
    func testCodable() throws {
        let id = FrameID.next()
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(id)
        
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FrameID.self, from: data)
        
        XCTAssertEqual(id.value, decoded.value)
    }
}
