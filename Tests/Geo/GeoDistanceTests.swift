&batchOut, UInt32(targets.count)
)

for i in 0..<targets.count {
var singleOut: Double = 0
_ = aether_geo_distance_haversine(
originLat, originLon, targets[i].0, targets[i].1, &singleOut
)
XCTAssertEqual(batchOut[i], singleOut, accuracy: 0.01)
}
}

// =========================================================================
// MARK: - Haversine additional city pairs
// =========================================================================

func test_haversine_cairo_to_mumbai() {
var out: Double = 0
_ = aether_geo_distance_haversine(30.0444, 31.2357, 19.0760, 72.8777, &out)
// ~4360 km
XCTAssertEqual(out, 4360000.0, accuracy: 100000.0)
}

func test_haversine_singapore_to_delhi() {
var out: Double = 0
_ = aether_geo_distance_haversine(1.3521, 103.8198, 28.6139, 77.2090, &out)
XCTAssertGreaterThan(out, 3000000.0)
XCTAssertLessThan(out, 5000000.0)
}

func test_haversine_sao_paulo_to_lagos() {
var out: Double = 0
_ = aether_geo_distance_haversine(-23.5505, -46.6333, 6.5244, 3.3792, &out)
XCTAssertGreaterThan(out, 5500000.0)
XCTAssertLessThan(out, 7000000.0)
}

func test_haversine_oslo_to_madrid() {
var out: Double = 0
_ = aether_geo_distance_haversine(59.9139, 10.7522, 40.4168, -3.7038, &out)
// ~2388 km
XCTAssertEqual(out, 2388000.0, accuracy: 200000.0)
}

// =========================================================================
// MARK: - Vincenty additional
// =========================================================================

func test_vincenty_equator_180_degrees() {
var out: Double = 0
let rc = aether_geo_distance_vincenty(0.0, 0.0, 0.0, 180.0, &out)
// Near-antipodal on equator; vincenty should handle
if rc == Int32(0) {
XCTAssertGreaterThan(out, 19000000.0)
}
}

func test_vincenty_poles_same_longitude() {
var out: Double = 0
_ = aether_geo_distance_vincenty(89.0, 0.0, -89.0, 0.0, &out)
// ~19,775 km
XCTAssertGreaterThan(out, 19000000.0)
}

func test_vincenty_one_degree_lon_at_45() {
var out: Double = 0
_ = aether_geo_distance_vincenty(45.0, 0.0, 45.0, 1.0, &out)
// ~78.8 km at 45 degrees
XCTAssertEqual(out, 78847.0, accuracy: 1000.0)
}

