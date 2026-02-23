// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_tsdf_c.h"

#include "aether/core/status.h"
#include "aether/geo/altitude_engine.h"
#include "aether/geo/asc_cell.h"
#include "aether/geo/haversine.h"
#include "aether/geo/map_globe_projection.h"
#include "aether/geo/map_renderer.h"
#include "aether/geo/rtree.h"
#include "aether/geo/sol_illumination.h"

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <new>
#include <vector>

// ---------------------------------------------------------------------------
// Opaque wrapper types
// ---------------------------------------------------------------------------
struct aether_geo_rtree {
    aether::geo::RTree* impl;
};

struct aether_geo_altitude_engine {
    aether::geo::AltitudeEngine* impl;
};

struct aether_geo_renderer {
    aether::geo::MapRenderer* impl;
};

namespace {

using aether::core::Status;

inline int to_rc(Status status) {
    return static_cast<int>(status);
}

inline aether::geo::QualityPreset to_quality_preset(std::int32_t preset) {
    if (preset <= 0) {
        return aether::geo::QualityPreset::kSaver;
    }
    if (preset >= 2) {
        return aether::geo::QualityPreset::kCinematic;
    }
    return aether::geo::QualityPreset::kBalanced;
}

inline std::int32_t from_quality_preset(aether::geo::QualityPreset preset) {
    return static_cast<std::int32_t>(preset);
}

void copy_solar_position_to_c(const aether::geo::SolarPosition& in, aether_geo_solar_position_t* out) {
    if (out == nullptr) {
        return;
    }
    out->azimuth_deg = in.azimuth_deg;
    out->elevation_deg = in.elevation_deg;
    out->declination_deg = in.declination_deg;
    out->hour_angle_deg = in.hour_angle_deg;
}

void copy_env_light_to_c(const aether::geo::SolarEnvironmentLight& in, aether_geo_env_light_t* out) {
    if (out == nullptr) {
        return;
    }
    std::memcpy(out->sh_coeffs, in.sh_coeffs, sizeof(out->sh_coeffs));
    std::memcpy(out->sun_direction, in.sun_direction, sizeof(out->sun_direction));
    std::memcpy(out->sun_color, in.sun_color, sizeof(out->sun_color));
    out->sun_intensity = in.sun_intensity;
    out->ambient_intensity = in.ambient_intensity;
    out->phase = static_cast<std::int32_t>(in.phase);
}

void copy_render_stats_to_c(const aether::geo::MapRenderStats& in, aether_geo_render_stats_t* out) {
    if (out == nullptr) {
        return;
    }
    out->tiles_rendered = in.tiles_rendered;
    out->tiles_culled = in.tiles_culled;
    out->labels_visible = in.labels_visible;
    out->labels_culled = in.labels_culled;
    out->frame_time_ms = in.frame_time_ms;
    out->budget_used.terrain_ms = in.budget_used.terrain_ms;
    out->budget_used.tiles_ms = in.budget_used.tiles_ms;
    out->budget_used.labels_ms = in.budget_used.labels_ms;
    out->budget_used.effects_ms = in.budget_used.effects_ms;
    out->budget_used.reserve_ms = in.budget_used.reserve_ms;
    out->budget_used.total_ms = in.budget_used.total_ms;
    copy_env_light_to_c(in.solar_light, &out->solar_light);
}

}  // namespace

extern "C" {

int aether_geo_distance_haversine(double lat1_deg,
                                  double lon1_deg,
                                  double lat2_deg,
                                  double lon2_deg,
                                  double* out_distance_m) {
    if (out_distance_m == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    *out_distance_m = aether::geo::distance_haversine(lat1_deg, lon1_deg, lat2_deg, lon2_deg);
    return to_rc(Status::kOk);
}

int aether_geo_distance_haversine_batch(double origin_lat_deg,
                                        double origin_lon_deg,
                                        const double* target_lats_deg,
                                        const double* target_lons_deg,
                                        double* out_distances_m,
                                        std::uint32_t count) {
    return to_rc(aether::geo::distance_haversine_batch(
        origin_lat_deg,
        origin_lon_deg,
        target_lats_deg,
        target_lons_deg,
        out_distances_m,
        static_cast<std::size_t>(count)));
}

int aether_geo_distance_vincenty(double lat1_deg,
                                 double lon1_deg,
                                 double lat2_deg,
                                 double lon2_deg,
                                 double* out_distance_m) {
    return to_rc(aether::geo::distance_vincenty(lat1_deg, lon1_deg, lat2_deg, lon2_deg, out_distance_m));
}

int aether_geo_latlon_to_cell(double lat_deg,
                              double lon_deg,
                              std::uint32_t level,
                              std::uint64_t* out_cell_id) {
    return to_rc(aether::geo::latlon_to_cell(lat_deg, lon_deg, level, out_cell_id));
}

int aether_geo_cell_to_latlon(std::uint64_t cell_id, double* out_lat_deg, double* out_lon_deg) {
    return to_rc(aether::geo::cell_to_latlon(cell_id, out_lat_deg, out_lon_deg));
}

int aether_geo_geodetic_to_ecef(const aether_geo_geodetic_coord_t* geo, aether_geo_ecef_coord_t* out) {
    if (geo == nullptr || out == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    aether::geo::GeodeticCoord in{geo->lat_deg, geo->lon_deg, geo->alt_m};
    aether::geo::ECEFCoord out_cpp{};
    const Status status = aether::geo::geodetic_to_ecef(in, &out_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out->x = out_cpp.x;
    out->y = out_cpp.y;
    out->z = out_cpp.z;
    return to_rc(Status::kOk);
}

int aether_geo_ecef_to_geodetic(const aether_geo_ecef_coord_t* ecef, aether_geo_geodetic_coord_t* out) {
    if (ecef == nullptr || out == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    aether::geo::ECEFCoord in{ecef->x, ecef->y, ecef->z};
    aether::geo::GeodeticCoord out_cpp{};
    const Status status = aether::geo::ecef_to_geodetic(in, &out_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    out->lat_deg = out_cpp.lat_deg;
    out->lon_deg = out_cpp.lon_deg;
    out->alt_m = out_cpp.alt_m;
    return to_rc(Status::kOk);
}

int aether_geo_horizon_cull(const aether_geo_ecef_coord_t* camera,
                            const aether_geo_ecef_coord_t* point,
                            double earth_radius,
                            int* out_culled) {
    if (camera == nullptr || point == nullptr || out_culled == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const aether::geo::ECEFCoord cam{camera->x, camera->y, camera->z};
    const aether::geo::ECEFCoord p{point->x, point->y, point->z};
    *out_culled = aether::geo::horizon_cull(cam, p, earth_radius) ? 1 : 0;
    return to_rc(Status::kOk);
}

void aether_geo_rte_split(double value, float* out_high, float* out_low) {
    aether::geo::rte_split(value, out_high, out_low);
}

int aether_geo_solar_position(double timestamp_utc,
                              double lat_deg,
                              double lon_deg,
                              aether_geo_solar_position_t* out) {
    if (out == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    aether::geo::SolarPosition out_cpp{};
    const Status status = aether::geo::solar_position(timestamp_utc, lat_deg, lon_deg, &out_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    copy_solar_position_to_c(out_cpp, out);
    return to_rc(Status::kOk);
}

std::int32_t aether_geo_solar_day_phase(double elevation_deg) {
    return static_cast<std::int32_t>(aether::geo::solar_day_phase(elevation_deg));
}

int aether_geo_solar_environment_light(const aether_geo_solar_position_t* pos,
                                       double lat_deg,
                                       double lon_deg,
                                       aether_geo_env_light_t* out) {
    if (pos == nullptr || out == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const aether::geo::SolarPosition in{
        pos->azimuth_deg,
        pos->elevation_deg,
        pos->declination_deg,
        pos->hour_angle_deg,
    };
    aether::geo::SolarEnvironmentLight out_cpp{};
    const Status status = aether::geo::solar_environment_light(in, lat_deg, lon_deg, &out_cpp);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    copy_env_light_to_c(out_cpp, out);
    return to_rc(Status::kOk);
}

aether_geo_rtree_t* aether_geo_rtree_create(std::uint32_t /*reserved_capacity*/) {
    auto* wrapper = new (std::nothrow) aether_geo_rtree_t{};
    if (wrapper == nullptr) {
        return nullptr;
    }
    wrapper->impl = aether::geo::rtree_create();
    if (wrapper->impl == nullptr) {
        delete wrapper;
        return nullptr;
    }
    return wrapper;
}

void aether_geo_rtree_destroy(aether_geo_rtree_t* tree) {
    if (tree == nullptr) {
        return;
    }
    aether::geo::rtree_destroy(tree->impl);
    delete tree;
}

int aether_geo_rtree_insert(aether_geo_rtree_t* tree,
                            double lat_deg,
                            double lon_deg,
                            std::uint64_t id,
                            float score) {
    if (tree == nullptr || tree->impl == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const aether::geo::RTreeEntry entry{lat_deg, lon_deg, id, score};
    return to_rc(aether::geo::rtree_insert(tree->impl, entry));
}

int aether_geo_rtree_query_range(const aether_geo_rtree_t* tree,
                                 double lat_min,
                                 double lat_max,
                                 double lon_min,
                                 double lon_max,
                                 std::uint64_t* out_ids,
                                 std::uint32_t max_results,
                                 std::uint32_t* out_count) {
    if (tree == nullptr || tree->impl == nullptr || out_count == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    if (max_results > 0 && out_ids == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }

    const aether::geo::MBR range{lat_min, lat_max, lon_min, lon_max};
    std::size_t count = 0;
    int rc = 0;

    if (max_results == 0) {
        rc = to_rc(aether::geo::rtree_query_range(tree->impl, range, nullptr, 0, &count));
    } else {
        std::vector<aether::geo::RTreeEntry> entries(static_cast<std::size_t>(max_results));
        rc = to_rc(aether::geo::rtree_query_range(
            tree->impl,
            range,
            entries.data(),
            entries.size(),
            &count));
        const std::size_t copy_count = std::min<std::size_t>(count, entries.size());
        for (std::size_t i = 0; i < copy_count; ++i) {
            out_ids[i] = entries[i].id;
        }
    }

    *out_count = static_cast<std::uint32_t>(std::min<std::size_t>(
        count,
        static_cast<std::size_t>(std::numeric_limits<std::uint32_t>::max())));
    return rc;
}

aether_geo_altitude_engine_t* aether_geo_altitude_engine_create(void) {
    auto* wrapper = new (std::nothrow) aether_geo_altitude_engine_t{};
    if (wrapper == nullptr) {
        return nullptr;
    }
    wrapper->impl = aether::geo::altitude_engine_create();
    if (wrapper->impl == nullptr) {
        delete wrapper;
        return nullptr;
    }
    return wrapper;
}

void aether_geo_altitude_engine_destroy(aether_geo_altitude_engine_t* engine) {
    if (engine == nullptr) {
        return;
    }
    aether::geo::altitude_engine_destroy(engine->impl);
    delete engine;
}

int aether_geo_altitude_engine_predict(aether_geo_altitude_engine_t* engine, double dt_s) {
    if (engine == nullptr || engine->impl == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    return to_rc(aether::geo::altitude_engine_predict(engine->impl, dt_s));
}

int aether_geo_altitude_engine_get_height(const aether_geo_altitude_engine_t* engine, double* out_height_m) {
    if (engine == nullptr || engine->impl == nullptr || out_height_m == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const aether::geo::AltitudeState* state = aether::geo::altitude_engine_state(engine->impl);
    if (state == nullptr) {
        return to_rc(Status::kResourceExhausted);
    }
    *out_height_m = state->h;
    return to_rc(Status::kOk);
}

aether_geo_renderer_t* aether_geo_renderer_create(void) {
    auto* wrapper = new (std::nothrow) aether_geo_renderer_t{};
    if (wrapper == nullptr) {
        return nullptr;
    }
    wrapper->impl = aether::geo::map_renderer_create();
    if (wrapper->impl == nullptr) {
        delete wrapper;
        return nullptr;
    }
    return wrapper;
}

void aether_geo_renderer_destroy(aether_geo_renderer_t* renderer) {
    if (renderer == nullptr) {
        return;
    }
    aether::geo::map_renderer_destroy(renderer->impl);
    delete renderer;
}

int aether_geo_renderer_frame(aether_geo_renderer_t* renderer,
                              const aether_geo_render_input_t* input,
                              aether_geo_render_stats_t* out_stats) {
    if (renderer == nullptr || renderer->impl == nullptr || input == nullptr || out_stats == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }

    aether::geo::MapRenderInput cpp_input{};
    cpp_input.camera_lat = input->camera_lat;
    cpp_input.camera_lon = input->camera_lon;
    cpp_input.camera_altitude_m = input->camera_altitude_m;
    cpp_input.camera_fov_deg = input->camera_fov_deg;
    cpp_input.viewport_width = input->viewport_width;
    cpp_input.viewport_height = input->viewport_height;
    cpp_input.timestamp_utc = input->timestamp_utc;
    cpp_input.quality = to_quality_preset(input->quality);
    cpp_input.active_phase7_features = input->active_phase7_features;
    cpp_input.thermal_level = input->thermal_level;
    cpp_input.frame_budget_ms = input->frame_budget_ms;

    aether::geo::MapRenderStats cpp_stats{};
    const Status status = aether::geo::map_renderer_frame(renderer->impl, cpp_input, &cpp_stats);
    if (status != Status::kOk) {
        return to_rc(status);
    }
    copy_render_stats_to_c(cpp_stats, out_stats);
    return to_rc(Status::kOk);
}

void aether_geo_renderer_set_quality(aether_geo_renderer_t* renderer, std::int32_t preset) {
    if (renderer == nullptr || renderer->impl == nullptr) {
        return;
    }
    aether::geo::map_renderer_set_quality(renderer->impl, to_quality_preset(preset));
}

std::int32_t aether_geo_renderer_get_quality(const aether_geo_renderer_t* renderer) {
    if (renderer == nullptr || renderer->impl == nullptr) {
        return -1;
    }
    return from_quality_preset(aether::geo::map_renderer_get_quality(renderer->impl));
}

int aether_geo_renderer_enable_feature(aether_geo_renderer_t* renderer, std::uint32_t feature_bit) {
    if (renderer == nullptr || renderer->impl == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const bool ok = aether::geo::map_renderer_enable_feature(
        renderer->impl,
        static_cast<aether::geo::Phase7Feature>(feature_bit));
    return ok ? to_rc(Status::kOk) : to_rc(Status::kOutOfRange);
}

int aether_geo_renderer_disable_feature(aether_geo_renderer_t* renderer, std::uint32_t feature_bit) {
    if (renderer == nullptr || renderer->impl == nullptr) {
        return to_rc(Status::kInvalidArgument);
    }
    const bool ok = aether::geo::map_renderer_disable_feature(
        renderer->impl,
        static_cast<aether::geo::Phase7Feature>(feature_bit));
    return ok ? to_rc(Status::kOk) : to_rc(Status::kOutOfRange);
}

}  // extern "C"
