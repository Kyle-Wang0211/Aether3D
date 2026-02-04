//
// BitExactValidatorTests.swift
// PR5CaptureTests
//
// Tests for BitExactValidator
//

import XCTest
@testable import PR5Capture

@MainActor
final class BitExactValidatorTests: XCTestCase {
    
    var validator: BitExactValidator!
    var config: ExtremeProfile!
    
    override func setUp() {
        super.setUp()
        config = ExtremeProfile(profile: .standard)
        validator = BitExactValidator(config: config)
    }
    
    override func tearDown() {
        validator = nil
        config = nil
        super.tearDown()
    }
    
    func testBitExactMatch() async {
        let data1 = Data([1, 2, 3, 4])
        let data2 = Data([1, 2, 3, 4])
        let result = await validator.validateBitExact(data1, data2)
        XCTAssertTrue(result.isExact)
    }
    
    func testBitExactMismatch() async {
        let data1 = Data([1, 2, 3, 4])
        let data2 = Data([1, 2, 3, 5])
        let result = await validator.validateBitExact(data1, data2)
        XCTAssertFalse(result.isExact)
    }
}
