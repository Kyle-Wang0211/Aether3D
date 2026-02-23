var geo = aether_geo_geodetic_coord_t(lat_deg: 90.0, lon_deg: 0.0, alt_m: 0.0)
var ecef = aether_geo_ecef_coord_t()
_ = aether_geo_geodetic_to_ecef(&geo, &ecef)

var geoOut = aether_geo_geodetic_coord_t()
_ = aether_geo_ecef_to_geodetic(&ecef, &geoOut)
XCTAssertEqual(geoOut.lat_deg, 90.0, accuracy: 0.01)
}

func test_ecef_to_geodetic_equator_roundtrip() {
var geo = aether_geo_geodetic_coord_t(lat_deg: 0.0, lon_deg: 45.0, alt_m: 500.0)
var ecef = aether_geo_ecef_coord_t()
_ = aether_geo_geodetic_to_ecef(&geo, &ecef)

var geoOut = aether_geo_geodetic_coord_t()
_ = aether_geo_ecef_to_geodetic(&ecef, &geoOut)
XCTAssertEqual(geoOut.lat_deg, 0.0, accuracy: 0.01)
XCTAssertEqual(geoOut.lon_deg, 45.0, accuracy: 0.01)
XCTAssertEqual(geoOut.alt_m, 500.0, accuracy: 1.0)
}

// =========================================================================
// MARK: - Roundtrip additional cities
// =========================================================================

func test_roundtrip_london() {
var geo = aether_geo_geodetic_coord_t(lat_deg: 51.5074, lon_deg: -0.1278, alt_m: 0.0)
var ecef = aether_geo_ecef_coord_t()
_ = aether_geo_geodetic_to_ecef(&geo, &ecef)
var geoOut = aether_geo_geodetic_coord_t()
_ = aether_geo_ecef_to_geodetic(&ecef, &geoOut)
XCTAssertEqual(geoOut.lat_deg, 51.5074, accuracy: 0.001)
XCTAssertEqual(geoOut.lon_deg, -0.1278, accuracy: 0.001)
}

func test_roundtrip_tokyo_with_altitude() {
var geo = aether_geo_geodetic_coord_t(lat_deg: 35.6762, lon_deg: 139.6503, alt_m: 100.0)
var ecef = aether_geo_ecef_coord_t()
_ = aether_geo_geodetic_to_ecef(&geo, &ecef)
var geoOut = aether_geo_geodetic_coord_t()
_ = aether_geo_ecef_to_geodetic(&ecef, &geoOut)
XCTAssertEqual(geoOut.lat_deg, 35.6762, accuracy: 0.001)
XCTAssertEqual(geoOut.lon_deg, 139.6503, accuracy: 0.001)
XCTAssertEqual(geoOut.alt_m, 100.0, accuracy: 1.0)
}

func test_roundtrip_sydney() {
var geo = aether_geo_geodetic_coord_t(lat_deg: -33.8688, lon_deg: 151.2093, alt_m: 0.0)
var ecef = aether_geo_ecef_coord_t()
_ = aether_geo_geodetic_to_ecef(&geo, &ecef)
var geoOut = aether_geo_geodetic_coord_t()
_ = aether_geo_ecef_to_geodetic(&ecef, &geoOut)
XCTAssertEqual(geoOut.lat_deg, -33.8688, accuracy: 0.001)
XCTAssertEqual(geoOut.lon_deg, 151.2093, accuracy: 0.001)
}

// =========================================================================
// MARK: - Horizon cull additional
// =========================================================================

func test_horizon_cull_camera_far_away() {
var camera = aether_geo_ecef_coord_t(x: 10_000_000.0, y: 0.0, z: 0.0)
var point = aether_geo_ecef_coord_t(x: 6378137.0, y: 0.0, z: 0.0)
var culled: Int32 = -1
let rc = aether_geo_horizon_cull(&camera, &point, 6378137.0, &culled)
XCTAssertEqual(rc, Int32(0))
XCTAssertEqual(culled, Int32(0)) // Point facing camera, not culled
}

func test_horizon_cull_point_behind_earth() {
var camera = aether_geo_ecef_coord_t(x: 10_000_000.0, y: 0.0, z: 0.0)
var point = aether_geo_ecef_coord_t(x: -6378137.0, y: 0.0, z: 0.0)
var culled: Int32 = -1
let rc = aether_geo_horizon_cull(&camera, &point, 6378137.0, &culled)
XCTAssertEqual(rc, Int32(0))
XCTAssertEqual(culled, Int32(1)) // Behind Earth, culled
}

// =========================================================================
// MARK: - RTE split additional
// =========================================================================

func test_rte_split_small_value() {
var high: Float = 0
var low: Float = 0
aether_geo_rte_split(0.123456789, &high, &low)
let reconstructed = Double(high) + Double(low)
XCTAssertEqual(reconstructed, 0.123456789, accuracy: 1e-6)
}

func test_rte_split_very_large_value() {
var high: Float = 0
var low: Float = 0
aether_geo_rte_split(1.0e15, &high, &low)
XCTAssertTrue(high.isFinite)
XCTAssertTrue(low.isFinite)
}

func test_rte_split_zero() {
var high: Float = 0
var low: Float = 0
aether_geo_rte_split(0.0, &high, &low)
XCTAssertEqual(high, 0.0)
XCTAssertEqual(low, 0.0)
}
}
