// Swift Testing smoke test to ensure CI never discovers 0 tests
// This prevents Swift Testing from returning exit code 1 on empty discovery

import Testing

@Test("Smoke: Swift Testing discovery")
func smoke_swift_testing_discovery() {
    #expect(true)
}

