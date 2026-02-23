4. GPU-driven temporal filtering integrated with existing culling pipeline

Aether3D fills all four gaps simultaneously. The altitude engine (G15) gives vertical precision. The temporal index (G16) gives time-axis queries. The temporal cluster (G17) gives map-level visualization. The change detector (G18) gives Gaussian-level scene comparison across time.

### Phase 5 Prerequisite — PlatformSignals Altitude Extension (v3.0)

**Critical dependency:** G15 binding #26 (`tsdf::volume_controller` — altitude feeds `PlatformSignals`) requires altitude fields that **do not currently exist** in `tsdf::volume_controller.h`. The current `PlatformSignals` struct (lines 29-50) contains 13 fields covering thermal, memory, battery, and network state — but zero altitude fields.

**Required extension to `PlatformSignals` (must be implemented before G15):**
```cpp
// Append to existing PlatformSignals struct in tsdf/volume_controller.h:
float    altitude_meters;        // Orthometric altitude from G15 EKF (NaN if unavailable)
int32_t  floor_level;            // Floor detection from G15 (INT32_MIN if unavailable)
uint32_t altitude_source_mask;   // Bitmask: bit0=GNSS, bit1=baro, bit2=VIO, bit3=DEM
float    altitude_confidence;    // [0,1] posterior confidence from G15 EKF
```

**Rationale:** Without these fields, the volume controller cannot throttle TSDF integration based on altitude context (e.g., indoor floor detection → different voxel resolution strategy). The 4 new fields add 16 bytes to PlatformSignals — within acceptable padding for the existing 64-byte-aligned struct.

**Implementation order:** PlatformSignals extension is a Phase 5 **prerequisite task** (before G15 implementation begins), gated by:
- Gate-P5-PRE-1: New fields compile on all three platforms (iOS/Android/HarmonyOS)
- Gate-P5-PRE-2: Default values (`NaN`, `INT32_MIN`, `0`, `0.0f`) do not affect existing volume_controller behavior
- Gate-P5-PRE-3: Existing `PlatformSignals` unit tests pass unchanged

---

### Step 5.1 — G15: `altitude_engine.h/cpp`

**Files:**
- `aether/geo/altitude_engine.h`
- `aether_cpp/src/geo/altitude_engine.cpp` (~800 lines)
- `aether_cpp/tests/geo/altitude_engine_test.cpp`

**Algorithm — Multi-sensor Altitude Fusion via EKF:**

The altitude engine fuses 4 independent altitude sources into a single high-confidence vertical estimate using a 5-state Extended Kalman Filter. This is Aether3D's self-developed altitude stack — no existing mobile geo engine performs this fusion on-device.

**1. Altitude Sources (4 independent signals):**

| Source | Raw Accuracy | Update Rate | Availability |
|--------|-------------|-------------|--------------|
| GNSS vertical | 5-15m (L1), 3-8m (L1+L5) | 1-10 Hz | Outdoor only |
| Barometric pressure | 0.1-0.3m relative, 0.36 hPa/floor (~3m) | 25-100 Hz | Everywhere |
| Visual-Inertial Odometry (VIO) | 0.01-0.05m relative (drift ~0.5%/s) | 30-60 Hz | Everywhere (with camera) |
| DEM ground truth (EGM2008 + SRTM/Copernicus) | 4-10m absolute | Static | Precomputed |

**2. EKF State Vector (5 states):**
```
x = [h, v_h, b_baro, b_gnss, sigma_vio]

h       = orthometric altitude (meters above MSL)
v_h     = vertical velocity (m/s)
b_baro  = barometric bias (Pa, slow-varying)
b_gnss  = GNSS vertical bias (m, satellite geometry dependent)
sigma_vio = VIO cumulative drift estimate (m)
```

**3. State Transition (Prediction):**
```
h(k+1) = h(k) + v_h(k) * dt
v_h(k+1) = v_h(k)  (constant velocity model)
b_baro(k+1) = b_baro(k) * decay + w_baro  (first-order Gauss-Markov, tau=300s)
b_gnss(k+1) = b_gnss(k) * decay + w_gnss  (tau=600s)
sigma_vio(k+1) = sigma_vio(k)
+ (ALTITUDE_VIO_BASE_DRIFT_MPS + |v_h(k)| * ALTITUDE_VIO_DRIFT_RATE) * dt
```

Process noise Q is diagonal:
- `q_h = 0.01 m² * dt` (altitude random walk)
- `q_vh = 0.1 m²/s² * dt` (velocity random walk)
- `q_baro = 0.001 Pa² * dt / tau_baro`
- `q_gnss = 0.01 m² * dt / tau_gnss`
- `q_vio = ((ALTITUDE_VIO_BASE_DRIFT_MPS + |v_h| * ALTITUDE_VIO_DRIFT_RATE) * dt)²`

**4. Measurement Updates (4 independent observations):**

**GNSS altitude observation:**
```
z_gnss = h_ellipsoidal - N(lat, lon)     // Ellipsoidal → orthometric via EGM2008
H_gnss = [1, 0, 0, 1, 0]                 // Observes h + b_gnss
R_gnss = sigma_gnss²
* max(1.0, VDOP / 2.0)
* (satellites_visible < 6 ? 4.0 : 1.0)
// Adaptive trust scaling for urban canyon / low-satellite conditions
```

**Barometric altitude observation:**
```
z_baro = ((T_celsius + 273.15) / ISA_LAPSE_RATE)
* (1.0 - pow(P / P_ref, (ISA_GAS_CONSTANT * ISA_LAPSE_RATE) / 9.80665))
// Temperature-compensated ISA hypsometric formula
H_baro = [1, 0, -dh/dP, 0, 0]           // Observes h, affected by b_baro
R_baro = 0.3²                            // ~0.3m noise floor
```

**VIO relative altitude observation:**
```
z_vio = h_vio_current - h_vio_reference + h_reference
H_vio = [1, 0, 0, 0, -1]                // Observes h, affected by sigma_vio
R_vio = sigma_vio² + 0.01²              // Grows with accumulated drift
```

**VIO reference-frame reset policy (drift control):**
```
if sigma_vio > ALTITUDE_VIO_RESET_SIGMA_M or vio_relocalized:
h_reference = h_posterior_ekf
h_vio_reference = h_vio_current
sigma_vio = 0
```
This keeps relative-VIO useful while bounding long-session drift accumulation.

**DEM ground level observation (static, on GNSS update only):**
```
z_dem = lookup_dem(lat, lon)              // SRTM/Copernicus bilinear interp
H_dem = [1, 0, 0, 0, 0]                 // Direct altitude observation
R_dem = sigma_dem²                       // 4-10m depending on source
```

**5. EGM2008 Geoid Undulation Lookup — Mobile Implementation:**

Full EGM2008 at 2.5' resolution is ~740MB — far too large for mobile. Aether3D uses a **regional tile grid** approach:

```
Structure: AetherGeoidTile
lat_min, lat_max     (degrees)
lon_min, lon_max     (degrees)
grid_step            (arc-minutes, 2.5' = 0.04167°)
data[rows][cols]     (int16_t, mm precision, zigzag encoded)
crc32                (integrity check)
```

- **Tile size:** 10° × 10° tile at 2.5' resolution = 240 × 240 × 2 bytes = ~115 KB per tile
- **Global coverage:** 36 × 18 = 648 tiles, ~75 MB total (shipped as asset bundle)
- **On-device:** Load only tiles within ±2° of user position = ~4-6 tiles = ~500-700 KB active memory
- **Lookup:** O(1) bilinear interpolation, 4 table reads + 3 multiplies
- **Accuracy:** < 0.1m undulation error (vs full spherical harmonic at degree 2190)
- **Integrity:** Each tile verified via `crypto::sha256()` on first load

```cpp
float geoid_undulation(double lat, double lon) {
// 1. Find tile containing (lat, lon)
// 2. Compute fractional grid indices
// 3. Bilinear interpolation of 4 nearest grid values
// 4. Return N in meters (geoid height above WGS-84 ellipsoid)
}
```

**6. Floor-Level Detection Algorithm:**

```
floor_level(h_orthometric, h_dem_ground) → int32_t floor

delta_h = h_orthometric - h_dem_ground
if delta_h < ALTITUDE_OUTDOOR_THRESHOLD:
return 0   // Ground level / outdoor
floor = round((delta_h - ALTITUDE_GROUND_OFFSET) / ALTITUDE_FLOOR_HEIGHT)
return clamp(floor, ALTITUDE_MIN_FLOOR, ALTITUDE_MAX_FLOOR)

Confidence scoring:
c_floor = min(
c_altitude_ekf,           // EKF posterior confidence
1.0 - sigma_vio / 3.0,   // VIO drift penalty
barometer_available ? 0.9 : 0.4   // Baro availability bonus
)
```

**7. NumericGuard Integration:**

All EKF states pass through `core::guard_finite_scalar()` after each predict/update cycle. The 5×5 covariance matrix P is checked via `core::guard_finite_vector(P_flat, 25)` every frame. If any state goes non-finite, the EKF resets to the last known-good state and emits `NumericalHealthSnapshot` telemetry.

**7.1 Covariance SPD (positive-definite) guard:**
```
if frame_index % ALTITUDE_EKF_JOSEPH_INTERVAL == 0:
P = (I - K*H) * P * (I - K*H)^T + K * R * K^T    // Joseph form (symmetry-preserving)
for i in 0..4:
P[i][i] = max(P[i][i], ALTITUDE_EKF_P_MIN)       // prevent variance collapse
```
This closes a NumericGuard blind spot where P can be finite but non-SPD.

**7.2 Innovation-Adaptive Q Scaling — IAQS (v3.0, self-developed):**

Static process noise Q is a fundamental EKF weakness: too small → filter trusts prediction too much (ignores sensor jumps); too large → filter trusts measurements too much (noisy output). Existing solutions (NDKF: Neural Differentiable Kalman Filter; DeepUKF-VIN; KalmanNet) all require neural networks — unacceptable for Aether3D's zero-ML-runtime constraint.

IAQS is Aether3D's self-developed zero-neural-network Q-matrix auto-tuning:

```
Algorithm: Innovation-Adaptive Q Scaling (IAQS)

1. Compute Normalized Innovation Squared (NIS) per measurement update:
innovation = z_measured - H * x_predicted
S = H * P_predicted * H^T + R
NIS = innovation^T * inv(S) * innovation

2. Maintain running NIS statistics (exponential moving average):
NIS_ema = alpha * NIS + (1 - alpha) * NIS_ema
// alpha = 0.05 (slow adaptation, 20-sample effective window)

3. Chi-squared consistency check:
// For m-dimensional measurement, NIS should follow chi²(m)
// Expected NIS = m (degrees of freedom)
// Healthy range: [m * 0.3, m * 3.0] (conservative bounds)

4. Q-scale adaptation (AIMD-like, consistent with Aether3D's AIMD patterns):
if NIS_ema > m * IAQS_OVERCONFIDENT_THRESHOLD:
// Filter is overconfident → increase Q (multiplicative increase)
Q_scale = min(Q_scale * IAQS_INCREASE_FACTOR, IAQS_Q_SCALE_MAX)
elif NIS_ema < m * IAQS_UNDERCONFIDENT_THRESHOLD:
// Filter is underconfident → decrease Q (additive decrease)
Q_scale = max(Q_scale - IAQS_DECREASE_STEP, IAQS_Q_SCALE_MIN)
// else: NIS in healthy range → hold Q_scale

5. Apply:
Q_effective = Q_nominal * Q_scale
// Q_nominal is the static diagonal from Section 3 above
// Q_scale is scalar, shared across all 5 states
```

**Why scalar Q_scale (not per-state):** Per-state Q tuning requires observability analysis per channel — complex and fragile on mobile. A single scalar is robust, interpretable, and sufficient: when NIS is high, ALL states need more process noise (the model is globally too confident). Per-state refinement is deferred to Phase 6 if telemetry shows systematic per-channel bias.

**New constants (add to Section 10 of geo_constants.h):**
```cpp
static constexpr double IAQS_Q_SCALE_MIN              = 0.1;    // Minimum Q multiplier
static constexpr double IAQS_Q_SCALE_MAX              = 10.0;   // Maximum Q multiplier
static constexpr double IAQS_INCREASE_FACTOR          = 1.3;    // Multiplicative increase
static constexpr double IAQS_DECREASE_STEP            = 0.1;    // Additive decrease
static constexpr double IAQS_OVERCONFIDENT_THRESHOLD  = 2.5;    // NIS/m above → increase Q
static constexpr double IAQS_UNDERCONFIDENT_THRESHOLD = 0.3;    // NIS/m below → decrease Q
static constexpr double IAQS_EMA_ALPHA                = 0.05;   // EMA smoothing factor
```

**Test vectors:**
- Steady-state: stable GNSS → NIS_ema ≈ 1.0 → Q_scale holds at 1.0
- GNSS jump (5m sudden offset): NIS spikes → Q_scale ramps to ~3-5 → filter absorbs jump in 2-3s → Q_scale decays back
- Sensor blackout (VIO + baro only): Q_scale rises to ~5-8, preventing filter lock-up
- NaN in NIS computation: `guard_finite_scalar(NIS)` triggers → Q_scale holds previous value

**8. Output:**
```cpp
struct AltitudeEstimate {
float orthometric_altitude_m;    // Meters above MSL
float altitude_above_ground_m;   // Meters above DEM ground
int32_t floor_level;             // 0 = ground, 1+ = floors above
float confidence;                // [0,1] posterior confidence
float vertical_velocity_mps;     // m/s
uint32_t source_mask;            // Bitmask of active sources
};
```

**Bindings:**
- `core::NumericGuard` — all EKF state and covariance guarded every frame
- `tsdf::SolverWatchdog` — EKF iteration count monitored, reset on divergence
- `evidence::DSMassFusion` — altitude confidence feeds evidence mass for geo entries
- `evidence::AdmissionController` — reject entries with altitude confidence < 0.1
- `crypto::sha256()` — EGM2008 tile integrity verification
- `tsdf::volume_controller` — altitude feeds `PlatformSignals` for thermal-aware throttling
- `innovation::F9 Scene Passport` — passport embeds altitude + floor level
- G8 `spoof_detector` — barometric altitude cross-validates GNSS altitude (Layer L3)

**Test vectors:**
- Sea-level calibration: baro at 101325 Pa → h ≈ 0.0m ± 0.3m
- Floor detection: delta_h = 9.0m → floor = 3 (assuming 3.0m/floor)
- EKF convergence: from cold start, < 10s to σ_h < 2.0m with GNSS+baro
- Geoid undulation: Tokyo (35.68°N, 139.77°E) → N ≈ 36.7m (known reference)
- NumericGuard: inject NaN into state[2] → auto-reset, no crash
- VIO drift: 60s of 0.5%/s drift → sigma_vio ≈ 0.3m, R_vio grows accordingly
- SPD guard: force negative eigenvalue in P via adversarial update → Joseph pass restores SPD, no divergence
- IAQS: steady GNSS → Q_scale ≈ 1.0; GNSS 5m jump → Q_scale ramps to 3-5 within 3s → decays back

**9. EKF Fault Injection Matrix (v3.0 — 9-class adversarial test suite):**

Every fault class must be tested to confirm the EKF recovers gracefully (no crash, no divergence, bounded error):

| ID | Fault Class | Injection Method | Expected EKF Response | Pass Criteria |
|----|-------------|-----------------|----------------------|---------------|
| F1 | GNSS total loss | Stop feeding `z_gnss` for 60s | Baro+VIO hold altitude; σ_h grows but bounded | σ_h < 10m after 60s blackout |
| F2 | GNSS position jump | Inject +50m step in `z_gnss` at t=30s | IAQS Q_scale increases; innovation gate rejects outlier; filter absorbs over 5s | Transient error < 5m, recovery < 10s |
| F3 | Barometric pressure surge | Inject +500 Pa step (≈ +40m equivalent) | b_baro absorbs most; altitude error bounded by GNSS/VIO cross-check | Altitude error < 3m within 5s |
| F4 | VIO relocalization event | Reset VIO reference frame mid-session | sigma_vio resets per VIO reset policy; R_vio drops; filter re-anchors | No altitude jump > 1m at relocalization |
| F5 | Temperature spike | Change ambient temperature by +30°C in baro formula | Temperature-compensated ISA formula limits impact; b_baro absorbs residual | Altitude error < 2m |
| F6 | All-sensor simultaneous loss | Stop all 4 sources for 10s | EKF prediction-only mode; σ_h grows; Q_scale maxes out via IAQS | No crash; σ_h < 20m after 10s; resumes on sensor return |
| F7 | NaN injection | Set state[3] = NaN | NumericGuard detects; full EKF reset to last known-good state | Recovery < 1 frame; emits NumericalHealthSnapshot |
| F8 | Negative eigenvalue in P | Adversarial measurement update forcing P[2][2] < 0 | Joseph-form at next ALTITUDE_EKF_JOSEPH_INTERVAL restores SPD; P_MIN floor applied | P remains SPD within 5 frames |
| F9 | System clock jump | Shift timestamps by +3600s (1 hour) suddenly | dt clamping (max 1.0s) prevents Q explosion; prediction step bounded | No altitude error > 5m from clock jump |

**Implementation:** `FaultInjector` test harness runs all 9 classes in sequence and in parallel combination (F1+F3, F2+F5, F6+F7) to verify no fault interaction causes cascading failure.

**Design choice note — EKF online, FGO offline shadow:**
- Online path remains EKF because deterministic bounded cost is required (`< 50 µs` target).
- Factor-Graph Optimization (FGO) is used as **offline shadow validator** in Workstream D to cross-check EKF drift/consistency on replay logs.

---

### Step 5.2 — G16: `temporal_index.h/cpp`

**Files:**
- `aether/geo/temporal_index.h`
- `aether_cpp/src/geo/temporal_index.cpp` (~700 lines)
- `aether_cpp/tests/geo/temporal_index_test.cpp`

**Algorithm — 4D Spatio-Temporal Index with Gorilla-Compressed Timeline:**

