}
}

// =========================================================================
// MARK: - Solar position additional
// =========================================================================

func test_solar_position_oslo_winter() {
// January noon UTC at Oslo (59.9N) - low elevation
let winterNoon: Double = 1704888000.0 // Jan 10, 2024 noon UTC
var out = aether_geo_solar_position_t()
_ = aether_geo_solar_position(winterNoon, 59.9, 10.75, &out)
// Sun should be low in the sky
XCTAssertLessThan(out.elevation_deg, 20.0)
}

func test_solar_position_equator_sunset() {
// 6pm local time at equator, lon=0 => 18h UTC on equinox
let sunset = equinoxNoonUTC + 6.0 * 3600.0
var out = aether_geo_solar_position_t()
_ = aether_geo_solar_position(sunset, 0.0, 0.0, &out)
// Should be near horizon
XCTAssertEqual(out.elevation_deg, 0.0, accuracy: 10.0)
}

func test_solar_position_null_out_returns_error() {
let rc = aether_geo_solar_position(equinoxNoonUTC, 0.0, 0.0, nil)
XCTAssertEqual(rc, Int32(-1))
}

// =========================================================================
// MARK: - Day phase additional
// =========================================================================

func test_day_phase_at_exact_zero_elevation() {
let phase = aether_geo_solar_day_phase(0.0)
// Zero elevation is between golden hour and civil twilight
XCTAssertGreaterThanOrEqual(phase, Int32(0))
XCTAssertLessThanOrEqual(phase, Int32(5))
}

func test_day_phase_at_noon_high_elevation() {
let phase = aether_geo_solar_day_phase(80.0)
// Full daylight: actual phase encoding is 5
XCTAssertEqual(phase, Int32(5))
}

func test_day_phase_deep_night_astronomical() {
let phase = aether_geo_solar_day_phase(-25.0)
// Deep night: actual phase encoding is 0
XCTAssertEqual(phase, Int32(0))
}

func test_day_phase_values_always_valid() {
for elev in stride(from: -90.0, through: 90.0, by: 5.0) {
let phase = aether_geo_solar_day_phase(elev)
XCTAssertGreaterThanOrEqual(phase, Int32(0))
XCTAssertLessThanOrEqual(phase, Int32(5))
}
}

// =========================================================================
// MARK: - Environment light additional
// =========================================================================

func test_environment_light_null_out_returns_error() {
var pos = aether_geo_solar_position_t()
pos.azimuth_deg = 180.0
pos.elevation_deg = 45.0
let rc = aether_geo_solar_environment_light(&pos, 0.0, 0.0, nil)
XCTAssertEqual(rc, Int32(-1))
}

func test_environment_light_null_pos_returns_error() {
var out = aether_geo_env_light_t()
let rc = aether_geo_solar_environment_light(nil, 0.0, 0.0, &out)
XCTAssertEqual(rc, Int32(-1))
}

func test_environment_light_at_noon() {
var pos = aether_geo_solar_position_t()
