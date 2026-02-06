import XCTest

final class SwiftTestingSmokeTests: XCTestCase {
    func test_smoke_xctest_discovery() {
        XCTAssertTrue(true)
    }
}

#if canImport(Testing)
import Testing

@Test("Smoke: Swift Testing discovery")
func smoke_swift_testing_discovery() async throws {
    #expect(Bool(true))
}
#endif

