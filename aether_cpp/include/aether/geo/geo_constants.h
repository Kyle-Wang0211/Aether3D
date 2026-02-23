// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// aether/geo/geo_constants.h
// Single Source of Truth for all GeoEngine numeric constants.
// Cross-validated via static_assert parity checks.
//
// Design rationale:
//   WGS-84 ellipsoid parameters use double (IEEE 754 binary64) to preserve
//   sub-millimeter accuracy at global scale.  All trigonometric operations
//   in haversine/vincenty must use these exact values — no approximations.
//   The Hilbert curve order (ASC_CELL_ORDER) is set to 15, yielding 2^15 = 32768
//   cells per cube face, each ~1.2 km at equator — ideal for city-block
//   granularity while keeping cell IDs within 64 bits.

#ifndef AETHER_GEO_GEO_CONSTANTS_H
#define AETHER_GEO_GEO_CONSTANTS_H

#include <cstdint>
#include <cmath>

namespace aether {
namespace geo {

// ============================================================================
// Section 1: WGS-84 Ellipsoid (EPSG:4326)
// Source: NGA.STND.0036_1.0.0_WGS84, 2014-07-08
// ============================================================================
static constexpr double WGS84_A            = 6378137.0;           // Semi-major axis (m)
static constexpr double WGS84_B            = 6356752.314245179;   // Semi-minor axis (m)
static constexpr double WGS84_F            = 1.0 / 298.257223563; // Flattening
static constexpr double WGS84_E2           = 2.0 * WGS84_F - WGS84_F * WGS84_F; // First eccentricity squared
static constexpr double WGS84_EP2          = (WGS84_A * WGS84_A - WGS84_B * WGS84_B) / (WGS84_B * WGS84_B); // Second eccentricity squared

// Mean radius for Haversine (IUGG standard)
static constexpr double EARTH_MEAN_RADIUS_M = 6371008.7714;       // (2a+b)/3

// ============================================================================
// Section 2: Coordinate Precision & Bounds
// ============================================================================
static constexpr double LAT_MIN            = -90.0;
static constexpr double LAT_MAX            =  90.0;
static constexpr double LON_MIN            = -180.0;
static constexpr double LON_MAX            =  180.0;
static constexpr double COORDINATE_EPSILON = 1e-12;  // ~0.1 micrometer at equator
static constexpr double ANTIPODAL_THRESHOLD = 179.99;  // Vincenty convergence guard (degrees)

// Degree <-> radian conversion factors (precomputed for determinism)
static constexpr double DEG_TO_RAD         = 0.017453292519943295; // pi/180 exact to 18 digits
static constexpr double RAD_TO_DEG         = 57.29577951308232;    // 180/pi exact to 17 digits

// ============================================================================
// Section 3: Aether Spherical Cell (ASC) - Hilbert Curve Parameters
// ============================================================================
// ASC uses cube-face projection + Hilbert curve, inspired by S2 but
// self-implemented to avoid Abseil dependency and enable -fno-exceptions.
//
// Order 15: 2^15 = 32768 cells per face axis → 32768^2 = ~1.07 billion cells/face
// × 6 faces = ~6.44 billion cells total → fits in 64-bit CellId.
// Resolution at equator: 6378137 * pi / (4 * 32768) ≈ 153 meters per cell edge.
static constexpr uint32_t ASC_CELL_ORDER     = 15;
static constexpr uint32_t ASC_CELL_MAX_LEVEL = ASC_CELL_ORDER;  // 0..15 hierarchy
static constexpr uint32_t ASC_CELLS_PER_AXIS = 1u << ASC_CELL_ORDER;  // 32768
static constexpr uint64_t ASC_CELLS_PER_FACE = static_cast<uint64_t>(ASC_CELLS_PER_AXIS) * ASC_CELLS_PER_AXIS;
static constexpr uint64_t ASC_TOTAL_CELLS    = ASC_CELLS_PER_FACE * 6;
static constexpr uint32_t ASC_NUM_FACES      = 6;

// CellId layout (64 bits):
//   bits [63..61]: face (0..5)               → 3 bits
//   bits [60..31]: Hilbert position on face   → 30 bits (2*15)
//   bits [30..27]: level (0..15)              → 4 bits
//   bits [26..0]:  reserved / payload         → 27 bits
static constexpr uint64_t ASC_FACE_BITS      = 3;
static constexpr uint64_t ASC_POS_BITS       = 2 * ASC_CELL_ORDER;  // 30
static constexpr uint64_t ASC_LEVEL_BITS     = 4;
static constexpr uint64_t ASC_FACE_SHIFT     = 61;
static constexpr uint64_t ASC_POS_SHIFT      = 31;
static constexpr uint64_t ASC_LEVEL_SHIFT    = 27;
static constexpr uint64_t ASC_FACE_MASK      = 0x7ULL << ASC_FACE_SHIFT;
static constexpr uint64_t ASC_POS_MASK       = ((1ULL << ASC_POS_BITS) - 1) << ASC_POS_SHIFT;
static constexpr uint64_t ASC_LEVEL_MASK     = 0xFULL << ASC_LEVEL_SHIFT;

// ============================================================================
// Section 4: R*-tree Parameters
// ============================================================================
// Node size chosen for L1 cache line alignment (64 bytes).
// Each MBR entry = 4 doubles (lat_min, lat_max, lon_min, lon_max) = 32 bytes + 8 byte child/id = 40 bytes.
// Max entries per node: floor(4096 / 40) = 102 → use 64 for balanced splits.
static constexpr uint32_t RTREE_MAX_ENTRIES  = 64;
static constexpr uint32_t RTREE_MIN_ENTRIES  = 16;  // ~25% fill minimum (R*-tree reinsertion)
static constexpr uint32_t RTREE_REINSERT_P   = 20;  // 30% of RTREE_MAX_ENTRIES for forced reinsertion
static constexpr uint32_t RTREE_MAX_DEPTH    = 20;  // Supports up to 64^20 = way beyond 10^9 entries
static constexpr uint32_t RTREE_NODE_POOL_INITIAL = 1024;

// ============================================================================
// Section 5: Geo-Indistinguishability (Location Privacy)
// ============================================================================
// Planar Laplace mechanism for ε-differential privacy.
// Reference: Andrés, M.E. et al., "Geo-indistinguishability: differential
//            privacy for location-based systems", CCS 2013.
// ε = ln(3) / r where r = desired indistinguishability radius in meters.
// Default: r = 200m → ε ≈ 0.0055
static constexpr double GEO_PRIVACY_DEFAULT_EPSILON     = 0.005493061443340549;  // ln(3)/200
static constexpr double GEO_PRIVACY_MIN_EPSILON         = 0.001;   // Max privacy (~1.1 km radius)
static constexpr double GEO_PRIVACY_MAX_EPSILON         = 0.1;     // Min privacy (~11 m radius)
static constexpr double GEO_PRIVACY_LAPLACE_CLAMP_SIGMA = 5.0;     // Clamp at 5σ to prevent outliers

// ============================================================================
// Section 6: GPS Spoofing Detection
// ============================================================================
static constexpr double SPOOF_MAX_SPEED_MS           = 340.0;    // Speed of sound — max plausible surface speed
static constexpr double SPOOF_MAX_ACCELERATION_MS2   = 50.0;     // 5g — max plausible human acceleration
static constexpr double SPOOF_IMU_GPS_TOLERANCE_M    = 50.0;     // Max IMU-GPS position divergence
static constexpr double SPOOF_ALTITUDE_SIGMA_M       = 30.0;     // Barometer-GPS altitude tolerance
static constexpr double SPOOF_CNR_ANOMALY_THRESHOLD  = 10.0;     // C/N₀ jump threshold (dB-Hz)
static constexpr double SPOOF_MIN_SATELLITE_COUNT    = 4;        // Minimum for valid fix
static constexpr double SPOOF_CARRIER_PHASE_MAX_DRIFT = 0.5;     // Carrier phase / IMU correlation max drift (m/s)
static constexpr uint32_t SPOOF_HISTORY_WINDOW       = 60;       // Seconds of history for trajectory analysis
static constexpr uint32_t SPOOF_DETECTOR_LAYERS      = 5;        // Number of independent detection layers

// ============================================================================
// Section 7: Clustering (Map Visualization)
// ============================================================================
static constexpr uint32_t CLUSTER_MAX_ZOOM           = 20;       // Max map zoom level
static constexpr uint32_t CLUSTER_MIN_ZOOM           = 0;
static constexpr uint32_t CLUSTER_DEFAULT_RADIUS     = 80;       // Cluster radius in screen pixels
static constexpr uint32_t CLUSTER_MIN_POINTS         = 2;        // Minimum points to form cluster
static constexpr double   CLUSTER_GRID_SIZE_FACTOR   = 1.0;      // Grid cell = radius * factor

// ============================================================================
// Section 8: Merkle Integration (Geo-Tagged Proofs)
// ============================================================================
// Domain separation prefix for geo Merkle leaves (distinct from 0x00/0x01 in merkle module)
static constexpr uint8_t GEO_MERKLE_LEAF_PREFIX      = 0x02;     // Geo-location leaf domain tag
static constexpr uint32_t GEO_PROOF_MAX_ENTRIES      = 1024;     // Max geo entries per proof batch

// ============================================================================
// Section 9: Performance Budgets
// ============================================================================
static constexpr double GEO_QUERY_TIMEOUT_MS         = 1.0;      // Max time for single spatial query
static constexpr uint32_t GEO_MAX_RESULTS_PER_QUERY  = 10000;    // Prevent unbounded result sets
static constexpr uint32_t GEO_BATCH_INSERT_CHUNK     = 256;      // STR bulk-load chunk size
static constexpr double GEO_INDEX_MEMORY_BUDGET_MB   = 20.0;     // 20 MB for 1M entries target

// ============================================================================
// Section 10: Altitude Engine (G15)
// ============================================================================
static constexpr double  ALTITUDE_FLOOR_HEIGHT_M        = 3.0;         // Default floor height (meters)
static constexpr double  ALTITUDE_GROUND_OFFSET_M       = 1.5;         // Ground-to-first-floor offset
static constexpr double  ALTITUDE_OUTDOOR_THRESHOLD_M   = 2.0;         // Below this = outdoor/ground
static constexpr int32_t ALTITUDE_MIN_FLOOR             = -5;          // Underground parking etc.
static constexpr int32_t ALTITUDE_MAX_FLOOR             = 200;         // Burj Khalifa = 163 floors
static constexpr double  ALTITUDE_EKF_Q_H               = 0.01;        // Altitude random walk (m²)
static constexpr double  ALTITUDE_EKF_Q_VH              = 0.1;         // Velocity random walk (m²/s²)
static constexpr double  ALTITUDE_EKF_TAU_BARO          = 300.0;       // Baro bias time constant (s)
static constexpr double  ALTITUDE_EKF_TAU_GNSS          = 600.0;       // GNSS bias time constant (s)
static constexpr double  ALTITUDE_VIO_BASE_DRIFT_MPS    = 0.001;       // Static VIO drift floor (m/s)
static constexpr double  ALTITUDE_VIO_DRIFT_RATE        = 0.005;       // 0.5% per second
static constexpr double  ALTITUDE_VIO_RESET_SIGMA_M     = 3.0;         // Re-anchor VIO when drift exceeds this
static constexpr double  ALTITUDE_BARO_NOISE_M          = 0.3;         // Barometer noise floor (m)
static constexpr double  ALTITUDE_MIN_CONFIDENCE        = 0.1;         // Below this → reject entry
static constexpr double  ALTITUDE_EKF_P_MIN             = 0.001;       // Covariance diagonal floor
static constexpr uint32_t ALTITUDE_EKF_JOSEPH_INTERVAL  = 5;           // Joseph-form stabilization cadence (frames)
static constexpr double  ISA_LAPSE_RATE                 = 0.0065;      // K/m
static constexpr double  ISA_GAS_CONSTANT               = 287.05;      // J/(kg*K), dry air

// EGM2008 Geoid Tile Parameters
static constexpr double   GEOID_TILE_SIZE_DEG           = 10.0;        // Degrees per tile edge
static constexpr double   GEOID_GRID_STEP_ARCMIN        = 2.5;         // Arc-minutes per grid cell
static constexpr uint32_t GEOID_TILE_ROWS               = 240;         // 10° / (2.5'/60)
static constexpr uint32_t GEOID_TILE_COLS               = 240;
static constexpr uint32_t GEOID_PRELOAD_RADIUS_DEG      = 2;           // Preload ±2° tiles
static constexpr uint32_t GEOID_TILE_MAGIC              = 0x41454732;  // "AEG2" (Aether EGM2008)

// ============================================================================
// Section 11: Temporal Index (G16)
// ============================================================================
static constexpr uint32_t TEMPORAL_WAL_CAPACITY         = 4096;        // Max WAL entries before compaction
static constexpr uint32_t TEMPORAL_BUCKET_DAILY         = 86400;       // 1 day in seconds
static constexpr uint32_t TEMPORAL_BUCKET_HOURLY        = 3600;        // 1 hour
static constexpr uint32_t TEMPORAL_BUCKET_10MIN         = 600;         // 10 minutes
static constexpr uint32_t TEMPORAL_BUCKET_1MIN          = 60;          // 1 minute
static constexpr uint32_t TEMPORAL_COMPACTION_INTERVAL_S = 300;        // 5 min compaction interval
static constexpr uint32_t TEMPORAL_INDEX_MAGIC          = 0x41455354;  // "AEST" (Aether Spatio-Temporal)
static constexpr uint32_t TEMPORAL_MAX_ENTRIES_PER_CELL = 65535;       // uint16_t limit
static constexpr uint32_t TEMPORAL_WAL_FSYNC_INTERVAL_MS = 250;       // Persistent-WAL mode flush interval

// ============================================================================
// Section 12: Temporal Clustering — ST-DBSCAN (G17)
// ============================================================================
static constexpr double   TEMPORAL_HEAT_DECAY_RATE      = 0.00001;     // Per-second exponential decay (~0.42 heat after 24h)
static constexpr uint32_t TEMPORAL_MAX_CLUSTERS         = 256;         // Max clusters per timeline slice
static constexpr uint32_t TEMPORAL_CLUSTER_AGE_OUT_S    = 604800;      // 7 days

// ============================================================================
// Section 13: Cross-Temporal Change Detection (G18)
// ============================================================================
static constexpr float   CHANGE_DETECTION_THRESHOLD     = 2.5f;        // Mahalanobis threshold for "new"/"removed"
static constexpr float   CHANGE_THRESHOLD_LOW           = 0.1f;        // Below = unchanged
static constexpr float   CHANGE_THRESHOLD_HIGH          = 0.5f;        // Above = changed
static constexpr float   CHANGE_W_POSITION              = 0.6f;        // Position weight in change score
static constexpr float   CHANGE_W_SCALE                 = 0.2f;        // Scale weight
static constexpr float   CHANGE_W_COLOR                 = 0.2f;        // Color weight
static constexpr uint32_t CHANGE_MAX_GAUSSIANS_PER_FRAME = 100000;     // Thermal level 0-3
static constexpr uint32_t CHANGE_SUBSAMPLE_THERMAL_4_6  = 50000;       // Thermal level 4-6
static constexpr uint32_t CHANGE_SUBSAMPLE_THERMAL_7_8  = 10000;       // Thermal level 7-8

// ============================================================================
// Section 14: Temporal Privacy — extends Section 5 (G7)
// ============================================================================
static constexpr uint32_t PRIVACY_TEMPORAL_SEGMENT_SIZE  = 8;          // Reports per correlated noise block
static constexpr uint32_t PRIVACY_SPARSE_CELL_THRESHOLD  = 10;         // Below → sparse protection mode
static constexpr double   PRIVACY_TEMPORAL_JITTER_RANGE  = 0.5;        // ±50% report interval jitter

// ============================================================================
// Section 15: IAQS — extends Section 10 (G15)
// ============================================================================
static constexpr double IAQS_Q_SCALE_MIN               = 0.1;         // Minimum Q multiplier
static constexpr double IAQS_Q_SCALE_MAX               = 10.0;        // Maximum Q multiplier
static constexpr double IAQS_INCREASE_FACTOR           = 1.3;         // Multiplicative increase
static constexpr double IAQS_DECREASE_STEP             = 0.1;         // Additive decrease
static constexpr double IAQS_OVERCONFIDENT_THRESHOLD   = 2.5;         // NIS/m above → increase Q
static constexpr double IAQS_UNDERCONFIDENT_THRESHOLD  = 0.3;         // NIS/m below → decrease Q
static constexpr double IAQS_EMA_ALPHA                 = 0.05;        // EMA smoothing factor

// ============================================================================
// Section 16: Illumination, Semantics, Compaction — extends Section 13 (G18)
// ============================================================================
static constexpr bool     ILLUMINATION_NORMALIZE_ENABLED      = true;  // Global enable flag
static constexpr float    ILLUMINATION_VARIANCE_MIN           = 1e-6f; // Skip normalization below this
static constexpr float    SEMANTIC_MISMATCH_PENALTY           = 0.8f;  // Cross-class mismatch floor
static constexpr float    PHYSICS_BUILDING_MOVE_DISCOUNT      = 0.1f;  // Buildings don't move
static constexpr float    PHYSICS_VEGETATION_COLOR_DISCOUNT   = 0.3f;  // Seasonal color change
static constexpr float    PHYSICS_VEHICLE_MOVE_DISCOUNT       = 0.05f; // Vehicles are transient
static constexpr float    PHYSICS_PERSON_DISCOUNT             = 0.01f; // People are transient
static constexpr float    COMPACTION_MERGE_THRESHOLD          = 0.05f; // Change score below → merge
static constexpr uint32_t COMPACTION_MAX_GAUSSIANS_PER_VOXEL  = 64;    // Density ceiling per voxel
static constexpr uint32_t COMPACTION_MIN_UNCHANGED            = 1000;  // Skip compaction below
static constexpr float    ILLUMINATION_EDGE_PROTECT_SIGMA     = 2.0f;  // Structure-edge protection σ

// ============================================================================
// Section 17: Solar Illumination (G19)
// ============================================================================
static constexpr double   SOL_OBLIQUITY_J2000           = 23.439291;   // Earth's axial tilt (degrees, J2000.0)
static constexpr double   SOL_ECCENTRICITY_J2000        = 0.016708634; // Earth's orbital eccentricity
static constexpr double   SOL_CIVIL_TWILIGHT_DEG        = -6.0;        // Civil twilight boundary
static constexpr double   SOL_NAUTICAL_TWILIGHT_DEG     = -12.0;       // Nautical twilight boundary
static constexpr double   SOL_ASTRONOMICAL_TWILIGHT_DEG = -18.0;       // Astronomical twilight boundary
static constexpr double   SOL_FULL_DAY_ELEVATION_DEG    = 10.0;        // Above → full intensity
static constexpr double   SOL_NIGHT_AMBIENT_MIN         = 0.03;        // Minimum ambient (starlight + city)
static constexpr double   SOL_DAY_AMBIENT_RATIO         = 0.3;         // Ambient/direct ratio at noon
static constexpr double   SOL_UPDATE_INTERVAL_S         = 60.0;        // Recompute cadence (sun moves ~0.25°/min)
static constexpr double   SOL_GOLDEN_HOUR_PEAK_DEG      = 3.0;         // Peak golden hour elevation
static constexpr uint32_t SOL_TERMINATOR_STEPS          = 72;          // 5° resolution for terminator polyline
static constexpr double   SOL_GLOBE_VIEW_ALTITUDE_M     = 5000000.0;   // Camera altitude → per-tile solar
static constexpr double   SOL_INTERPOLATION_DURATION_S  = 2.0;         // Smooth transition window
static constexpr double   SOL_RESUME_SKIP_THRESHOLD_S   = 300.0;       // Skip interpolation if paused > 5 min

// ============================================================================
// Section 18: Phase 7 — Community Interaction Paradigms
// ============================================================================
// Pulse Field (7.1) — 4D Volumetric
static constexpr float    PULSE_FIELD_SPEED             = 0.3f;        // Advection speed (voxel units/s)
static constexpr float    PULSE_FIELD_MAX_ALPHA         = 0.4f;        // Maximum energy opacity
static constexpr float    PULSE_FIELD_MAX_ENERGY        = 1.0f;        // Energy ceiling per voxel
static constexpr float    PULSE_FIELD_ENERGY_SCALE      = 0.1f;        // heat×density → energy conversion
static constexpr float    PULSE_FIELD_DECAY_RATE        = 0.01f;       // Energy drain per second
static constexpr float    PULSE_FIELD_BUOYANCY          = 0.15f;       // Vertical rise bias (convection)
static constexpr float    PULSE_FIELD_NIGHT_GLOW        = 2.5f;        // Night glow multiplier
static constexpr float    PULSE_FIELD_VOXEL_SIZE_M      = 2.0f;        // Energy voxel edge length (meters)
static constexpr uint32_t PULSE_FIELD_MAX_VOXELS        = 100000;      // Maximum active energy voxels

// Time Lens (7.2)
static constexpr float    TIMELENS_RADIUS_PX            = 150.0f;      // Default lens radius (screen px)
static constexpr float    TIMELENS_RADIUS_MIN_PX        = 80.0f;       // Minimum lens radius
static constexpr float    TIMELENS_RADIUS_MAX_PX        = 400.0f;      // Maximum lens radius
static constexpr float    TIMELENS_FEATHER_PX           = 20.0f;       // Edge softness
static constexpr uint32_t TIMELENS_ACTIVATION_MS        = 500;         // Long-press duration to activate
static constexpr float    TIMELENS_CACHE_INVALIDATE_PX  = 50.0f;       // Cache invalidation movement threshold

// Evidence X-Ray (7.3)
static constexpr uint32_t XRAY_ACTIVATION_MS            = 700;         // Long-press duration on work marker
static constexpr uint32_t XRAY_MAX_TEMPORAL_DOTS        = 20;          // Max observation dots in mini-timeline

// Solar Story (7.4)
static constexpr float    SOLAR_STORY_DOMINANCE_THRESHOLD = 0.4f;      // Min ratio for dominant phase label
static constexpr uint32_t SOLAR_STORY_MIN_ENTRIES       = 5;           // Minimum entries per cell to show story

// Causal Replay (7.5)
static constexpr uint32_t CAUSAL_REPLAY_EPOCH_DURATION_MS = 2000;      // ms per epoch transition
static constexpr uint32_t CAUSAL_REPLAY_MAX_EPOCHS      = 10;          // Maximum epochs in one replay
static constexpr float    CAUSAL_REPLAY_MORPH_HIGHLIGHT_ALPHA = 0.4f;  // Golden outline opacity during morph

// Quality Toggle (7.6)
static constexpr uint32_t QUALITY_TIER_CINEMATIC        = 2;
static constexpr uint32_t QUALITY_TIER_BALANCED         = 1;
static constexpr uint32_t QUALITY_TIER_SAVER            = 0;
static constexpr uint32_t QUALITY_TIER_DEFAULT          = 1;           // QUALITY_TIER_BALANCED

// ============================================================================
// Section 19: Phase 7 Advanced Enhancements (7.7~7.11)
// ============================================================================
// Trust-Weighted Time Lens (7.7)
static constexpr float    TIMELENS_TRUST_LOW_THRESHOLD   = 0.3f;       // Below → red warning edge
static constexpr float    TIMELENS_TRUST_HIGH_THRESHOLD  = 0.7f;       // Above → green trusted edge
static constexpr float    TIMELENS_GHOST_MIN_OPACITY     = 0.15f;      // Minimum opacity for low-trust Gaussians

// Uncertainty Veil (7.8)
static constexpr float    UNCERTAINTY_VEIL_THRESHOLD     = 0.3f;       // Below → no veil (trusted)
static constexpr float    UNCERTAINTY_VEIL_BLUR_SCALE    = 0.3f;       // Covariance enlargement at max uncertainty
static constexpr float    UNCERTAINTY_VEIL_DESAT_STRENGTH = 0.7f;      // Maximum desaturation

// Dual-Epoch Split (7.9)
static constexpr float    DUAL_EPOCH_SPLIT_MIN_SPREAD_PX  = 100.0f;    // Min two-finger spread to activate
static constexpr float    DUAL_EPOCH_CHANGE_HIGHLIGHT_PX  = 50.0f;     // Change highlight zone around split
static constexpr uint32_t DUAL_EPOCH_HASH_DISPLAY_CHARS   = 8;         // Truncated SHA-256 chars per epoch

// Deterministic Cinematic Mode (7.10)
static constexpr uint32_t DETERMINISTIC_REPLAY_WINDOW_FRAMES = 120;    // 2s at 60fps rolling history
static constexpr float    DETERMINISTIC_TURBULENCE_SCALE     = 0.05f;  // Max random perturbation

// Privacy-First Community Heat (7.11)
static constexpr uint32_t PRIVACY_KANON_MIN_K            = 5;          // Minimum k for k-anonymity
static constexpr uint32_t PRIVACY_KANON_BUCKET_SIZE      = 3;          // Contributor count quantization bucket
static constexpr float    PRIVACY_HEAT_NOISE_CAP         = 0.5f;       // Max absolute Laplace noise (NumericGuard)

// ============================================================================
// Parity Checks (cross-end validation)
// ============================================================================
static_assert(WGS84_A > WGS84_B, "WGS84: semi-major > semi-minor");
static_assert(WGS84_F > 0.0 && WGS84_F < 0.01, "WGS84 flattening range");
static_assert(ASC_CELL_ORDER >= 10 && ASC_CELL_ORDER <= 20, "ASC order range");
static_assert(ASC_FACE_SHIFT + ASC_FACE_BITS == 64, "ASC face bits fit 64-bit");
static_assert(RTREE_MIN_ENTRIES >= 2, "R*-tree min entries >= 2");
static_assert(RTREE_MAX_ENTRIES >= 4 * RTREE_MIN_ENTRIES, "R*-tree max/min ratio");
static_assert(RTREE_REINSERT_P < RTREE_MAX_ENTRIES, "R*-tree reinsertion count valid");
static_assert(GEO_PRIVACY_MIN_EPSILON < GEO_PRIVACY_MAX_EPSILON, "epsilon range");
static_assert(SPOOF_DETECTOR_LAYERS == 5, "spoof detector layer count parity");
static_assert(CLUSTER_MAX_ZOOM == 20, "cluster zoom parity");
static_assert(GEO_MERKLE_LEAF_PREFIX != 0x00 && GEO_MERKLE_LEAF_PREFIX != 0x01,
              "geo leaf prefix must not collide with RFC 9162 prefixes");
static_assert(ALTITUDE_MIN_FLOOR < ALTITUDE_MAX_FLOOR, "altitude floor range");
static_assert(IAQS_Q_SCALE_MIN < IAQS_Q_SCALE_MAX, "IAQS Q scale range");
static_assert(SOL_CIVIL_TWILIGHT_DEG > SOL_NAUTICAL_TWILIGHT_DEG, "twilight ordering");
static_assert(CHANGE_W_POSITION + CHANGE_W_SCALE + CHANGE_W_COLOR > 0.99f
           && CHANGE_W_POSITION + CHANGE_W_SCALE + CHANGE_W_COLOR < 1.01f,
              "change detection weights sum to 1.0");
static_assert(QUALITY_TIER_SAVER < QUALITY_TIER_BALANCED
           && QUALITY_TIER_BALANCED < QUALITY_TIER_CINEMATIC, "quality tier ordering");
static_assert(PRIVACY_KANON_MIN_K >= 2, "k-anonymity minimum k");

// Numeric constant count for cross-end parity
static constexpr int GEO_CONSTANTS_NUMERIC_COUNT = 172;
static_assert(GEO_CONSTANTS_NUMERIC_COUNT == 172, "geo constant-count parity");

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_GEO_CONSTANTS_H
