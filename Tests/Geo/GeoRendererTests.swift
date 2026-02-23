// =========================================================================
// MARK: - Multiple renderers
// =========================================================================

func test_two_renderers_independent() {
let r1 = aether_geo_renderer_create()!
let r2 = aether_geo_renderer_create()!
defer {
aether_geo_renderer_destroy(r1)
aether_geo_renderer_destroy(r2)
}

aether_geo_renderer_set_quality(r1, 0)
aether_geo_renderer_set_quality(r2, 2)

XCTAssertEqual(aether_geo_renderer_get_quality(r1), Int32(0))
XCTAssertEqual(aether_geo_renderer_get_quality(r2), Int32(2))
}

func test_create_destroy_many_renderers() {
for _ in 0..<20 {
let r = aether_geo_renderer_create()
XCTAssertNotNil(r)
aether_geo_renderer_destroy(r)
}
}

// =========================================================================
// MARK: - Render frame null handling
// =========================================================================

func test_render_frame_null_renderer() {
var input = makeDefaultInput()
var stats = aether_geo_render_stats_t()
let rc = aether_geo_renderer_frame(nil, &input, &stats)
XCTAssertEqual(rc, Int32(-1))
}

func test_render_frame_null_input() {
let renderer = aether_geo_renderer_create()!
defer { aether_geo_renderer_destroy(renderer) }
var stats = aether_geo_render_stats_t()
let rc = aether_geo_renderer_frame(renderer, nil, &stats)
XCTAssertEqual(rc, Int32(-1))
}

func test_render_frame_null_stats() {
let renderer = aether_geo_renderer_create()!
defer { aether_geo_renderer_destroy(renderer) }
var input = makeDefaultInput()
let rc = aether_geo_renderer_frame(renderer, &input, nil)
XCTAssertEqual(rc, Int32(-1))
}

// =========================================================================
// MARK: - Quality edge cases
// =========================================================================

func test_quality_set_then_get_all_presets() {
let renderer = aether_geo_renderer_create()!
defer { aether_geo_renderer_destroy(renderer) }

for preset: Int32 in 0...2 {
aether_geo_renderer_set_quality(renderer, preset)
XCTAssertEqual(aether_geo_renderer_get_quality(renderer), preset)
}
}

func test_quality_null_renderer_get() {
let q = aether_geo_renderer_get_quality(nil)
// Should return a default or -1
XCTAssertTrue(q >= -1 && q <= 2)
}

// =========================================================================
// MARK: - Feature flags edge cases
// =========================================================================

func test_enable_feature_null_renderer() {
let rc = aether_geo_renderer_enable_feature(nil, 1)
XCTAssertEqual(rc, Int32(-1))
}

func test_disable_feature_null_renderer() {
let rc = aether_geo_renderer_disable_feature(nil, 1)
XCTAssertEqual(rc, Int32(-1))
}

func test_enable_then_disable_same_feature() {
let renderer = aether_geo_renderer_create()!
defer { aether_geo_renderer_destroy(renderer) }

let rc1 = aether_geo_renderer_enable_feature(renderer, 0x01)
XCTAssertEqual(rc1, Int32(0))
let rc2 = aether_geo_renderer_disable_feature(renderer, 0x01)
XCTAssertEqual(rc2, Int32(0))
}

// =========================================================================
// MARK: - Render stats validation
// =========================================================================

func test_render_stats_frame_time_nonnegative() {
let renderer = aether_geo_renderer_create()!
defer { aether_geo_renderer_destroy(renderer) }

var input = makeDefaultInput()
var stats = aether_geo_render_stats_t()
_ = aether_geo_renderer_frame(renderer, &input, &stats)
XCTAssertGreaterThanOrEqual(stats.frame_time_ms, 0.0)
}
