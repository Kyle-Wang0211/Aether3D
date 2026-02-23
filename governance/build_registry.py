#!/usr/bin/env python3
"""
Build complete contract_registry.json covering ALL Aether3D constants.
Preserves existing contracts and feature_flags, and expands K-* coverage.
"""
import json
from pathlib import Path

# Read existing registry to preserve contracts and feature_flags
ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = ROOT / "contract_registry.json"

with REGISTRY_PATH.open("r", encoding="utf-8") as f:
    registry = json.load(f)

# Build complete constants list
# Keep existing 18 K-* entries
existing_ids = {c["id"] for c in registry["constants"]}

# All new constants organized by domain
new_constants = []

def add(kid, vtype, value, desc):
    if kid not in existing_ids:
        new_constants.append({
            "id": kid,
            "status": "active",
            "track": "P",
            "value_type": vtype,
            "value": value,
            "description": desc
        })

# ═══════════════════════════════════════════════════════════════
# DOMAIN: EVIDENCE (EvidenceConstants.swift) — Phase 2, Tier 0
# ═══════════════════════════════════════════════════════════════
add("K-EVIDENCE-PATCH-DISPLAY-ALPHA", "float", 0.2, "EMA smoothing coefficient for display evidence [0.1-0.3]")
add("K-EVIDENCE-LOCKED-ACCELERATION", "float", 1.5, "Display growth multiplier for locked patches [1.2-2.0]")
add("K-EVIDENCE-COLOR-LOCAL-WEIGHT", "float", 0.70, "Local patch contribution to color evidence (Rule F)")
add("K-EVIDENCE-COLOR-GLOBAL-WEIGHT", "float", 0.30, "Global display contribution to color evidence (Rule F)")
add("K-EVIDENCE-BASE-PENALTY", "float", 0.05, "Base penalty for error observations")
add("K-EVIDENCE-MAX-PENALTY-PER-UPDATE", "float", 0.15, "Maximum penalty per update cycle")
add("K-EVIDENCE-ERROR-COOLDOWN-SEC", "float", 1.0, "Error cooldown period in seconds")
add("K-EVIDENCE-MAX-ERROR-STREAK", "int", 5, "Maximum error streak to consider")
add("K-EVIDENCE-SOFT-WRITE-GATE-MIN", "float", 0.30, "Min gate quality for soft ledger write (B1 policy) [0.25-0.35]")
add("K-EVIDENCE-WEIGHT-CAP-DENOM", "float", 8.0, "Observation count weight cap denominator")
add("K-EVIDENCE-PATCH-LOCAL-WEIGHT", "float", 0.7, "Patch color blend local weight")
add("K-EVIDENCE-PATCH-GLOBAL-WEIGHT", "float", 0.3, "Patch color blend global weight")
add("K-EVIDENCE-DYN-GATE-EARLY", "float", 0.65, "Early stage gate weight (geometry dominates) [0.60-0.70]")
add("K-EVIDENCE-DYN-GATE-LATE", "float", 0.35, "Late stage gate weight (quality dominates) [0.30-0.40]")
add("K-EVIDENCE-DYN-TRANSITION-START", "float", 0.45, "Weight transition start (normalized progress) [0.40-0.50]")
add("K-EVIDENCE-DYN-TRANSITION-END", "float", 0.75, "Weight transition end (normalized progress) [0.70-0.80]")
add("K-EVIDENCE-DYN-EPSILON", "float", 1e-9, "Epsilon for weight sum validation (gate+soft≈1.0)")
add("K-EVIDENCE-BLACK-THRESHOLD", "float", 0.20, "S0 black threshold for grayscale mapping")
add("K-EVIDENCE-DARK-GRAY-THRESHOLD", "float", 0.45, "S1 dark gray threshold")
add("K-EVIDENCE-LIGHT-GRAY-THRESHOLD", "float", 0.70, "S3 light gray threshold")
add("K-EVIDENCE-WHITE-THRESHOLD", "float", 0.88, "S5 total evidence requirement (white)")
add("K-EVIDENCE-S5-MIN-SOFT", "float", 0.75, "S5 minimum soft evidence requirement")
add("K-EVIDENCE-PATCH-STALE-SEC", "float", 300.0, "Stale patch threshold in seconds (5 min)")
add("K-EVIDENCE-TOKEN-REFILL-RATE", "float", 2.0, "Token refill rate per second [0.5-5.0]")
add("K-EVIDENCE-TOKEN-BUCKET-MAX", "float", 10.0, "Maximum tokens per patch bucket [5.0-20.0]")
add("K-EVIDENCE-TOKEN-COST-PER-OBS", "float", 1.0, "Token cost per observation [0.5-2.0]")
add("K-EVIDENCE-DIVERSITY-BUCKET-DEG", "float", 15.0, "View angle bucket size in degrees [10-30]")
add("K-EVIDENCE-DIVERSITY-MAX-BUCKETS", "int", 16, "Maximum buckets tracked per patch [8-24]")
add("K-EVIDENCE-MIN-UPDATE-INTERVAL-MS", "float", 120.0, "Time density minimum interval (ms)")
add("K-EVIDENCE-MIN-NOVELTY-LEDGER", "float", 0.1, "Minimum novelty to write to ledger")
add("K-EVIDENCE-QUARANTINE-THRESHOLD", "int", 3, "Consecutive suspect frames for quarantine")
add("K-EVIDENCE-QUARANTINE-TIMEOUT-SEC", "float", 1.0, "Quarantine entry timeout (seconds)")
add("K-EVIDENCE-CONFIDENCE-HALFLIFE-SEC", "float", 60.0, "Confidence decay half-life (seconds)")
add("K-EVIDENCE-LOCK-THRESHOLD", "float", 0.85, "Evidence threshold for locking")
add("K-EVIDENCE-MIN-OBS-FOR-LOCK", "int", 20, "Minimum observations for locking")
add("K-EVIDENCE-HUBER-DELTA", "float", 0.1, "Huber loss delta for robust statistics")
add("K-EVIDENCE-DEFAULT-TILE-SIZE", "int", 32, "PR2 tile size (pixels)")
add("K-EVIDENCE-DEFAULT-VOXEL-SIZE", "float", 0.03, "PR3 voxel size (meters)")
add("K-EVIDENCE-FLOAT-PRECISION", "int", 4, "Float quantization precision")
add("K-EVIDENCE-MIN-SOFT-SCALE", "float", 0.25, "Minimum soft penalty scale (guaranteed throughput)")
add("K-EVIDENCE-NO-TOKEN-PENALTY", "float", 0.6, "Soft penalty when token unavailable")
add("K-EVIDENCE-LOW-NOVELTY-THRESHOLD", "float", 0.2, "Low novelty threshold")
add("K-EVIDENCE-LOW-NOVELTY-PENALTY", "float", 0.7, "Soft penalty for low novelty")
add("K-EVIDENCE-DS-CONFLICT-SWITCH", "float", 0.85, "D-S conflict switch to Yager rule threshold")
add("K-EVIDENCE-DS-EPSILON", "float", 1e-9, "D-S epsilon for invariant checks")
add("K-EVIDENCE-DS-OCCUPIED-GOOD", "float", 0.8, "Default occupied mass for good observation")
add("K-EVIDENCE-DS-UNKNOWN-GOOD", "float", 0.2, "Default unknown mass for good observation")
add("K-EVIDENCE-DS-FREE-BAD", "float", 0.3, "Default free mass for bad observation")
add("K-EVIDENCE-MAX-REFINEMENTS-FRAME", "int", 16, "Maximum refinements per frame")
add("K-EVIDENCE-BATCH-MAX-CAPACITY", "int", 1024, "Batch maximum capacity")
add("K-EVIDENCE-COMPACTION-TRIGGER-FRAMES", "int", 100, "Compaction trigger frame count")
add("K-EVIDENCE-COMPACTION-TOMBSTONE-RATIO", "float", 0.3, "Compaction trigger tombstone ratio")
add("K-EVIDENCE-INITIAL-MAP-CAPACITY", "int", 1024, "Initial map capacity (power of 2)")
add("K-EVIDENCE-MAX-LOAD-FACTOR", "float", 0.75, "Maximum load factor for open-addressing map")
add("K-EVIDENCE-MAX-PROBE-ATTEMPTS", "int", 1024, "Maximum probe attempts")
add("K-EVIDENCE-MIN-CELLS", "int", 1000, "Minimum evidence grid cells")
add("K-EVIDENCE-HARD-CAP-CELLS", "int", 1000000, "Hard cap evidence grid cells")
add("K-EVIDENCE-AGING-TABLE-MAX-DELTA-SEC", "float", 86400.0, "Aging table maximum delta (24 hours)")
add("K-EVIDENCE-AGING-TABLE-BIN-SIZE-SEC", "float", 60.0, "Aging table bin size (1 minute)")
add("K-EVIDENCE-MIN-OCCLUSION-VIEWS", "int", 3, "Minimum occlusion view directions")
add("K-EVIDENCE-OCCLUSION-FREEZE-SEC", "float", 60.0, "Occlusion freeze window (seconds)")
add("K-EVIDENCE-MAX-EXCLUSION-DELTA-SEC", "float", 0.05, "Maximum exclusion delta per second")
add("K-EVIDENCE-COVERAGE-EMA-ALPHA", "float", 0.15, "Coverage EMA alpha")
add("K-EVIDENCE-MAX-COVERAGE-DELTA-SEC", "float", 0.10, "Maximum coverage delta per second")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: GUIDANCE (ScanGuidanceConstants.swift) — Phase 7, Tier 0/3
# ═══════════════════════════════════════════════════════════════
add("K-GUIDANCE-S0-S1-THRESHOLD", "float", 0.10, "S0→S1 display value threshold")
add("K-GUIDANCE-S1-S2-THRESHOLD", "float", 0.25, "S1→S2 display value threshold")
add("K-GUIDANCE-S2-S3-THRESHOLD", "float", 0.50, "S2→S3 display value threshold")
add("K-GUIDANCE-S3-S4-THRESHOLD", "float", 0.75, "S3→S4 display value threshold")
add("K-GUIDANCE-S4-S5-THRESHOLD", "float", 0.88, "S4→S5 display value threshold (white)")
add("K-GUIDANCE-S5-MIN-SOFT", "float", 0.75, "S5 minimum soft evidence for guidance")
add("K-GUIDANCE-GRAYSCALE-GAMMA", "float", 1.0, "Continuous grayscale interpolation gamma")
add("K-GUIDANCE-S4-TRANSPARENCY-ALPHA", "float", 0.0, "S4 transparency alpha")
add("K-GUIDANCE-BORDER-BASE-WIDTH-PX", "float", 6.0, "Base border width (pixels)")
add("K-GUIDANCE-BORDER-MIN-WIDTH-PX", "float", 1.0, "Minimum border width (pixels)")
add("K-GUIDANCE-BORDER-MAX-WIDTH-PX", "float", 12.0, "Maximum border width (pixels)")
add("K-GUIDANCE-BORDER-DISPLAY-WEIGHT", "float", 0.6, "Display factor weight in border calc")
add("K-GUIDANCE-BORDER-AREA-WEIGHT", "float", 0.4, "Area factor weight in border calc")
add("K-GUIDANCE-BORDER-GAMMA", "float", 1.4, "Stevens Power Law gamma for border brightness")
add("K-GUIDANCE-BORDER-COLOR-R", "int", 255, "Border color red component (white)")
add("K-GUIDANCE-BORDER-ALPHA-S0", "float", 1.0, "Border alpha at S0 (fully opaque)")
add("K-GUIDANCE-WEDGE-BASE-THICKNESS-M", "float", 0.008, "Base wedge thickness at display=0 (m)")
add("K-GUIDANCE-WEDGE-MIN-THICKNESS-M", "float", 0.0005, "Min wedge thickness at display≈1 (m)")
add("K-GUIDANCE-THICKNESS-DECAY-EXP", "float", 0.7, "Thickness decay exponent")
add("K-GUIDANCE-AREA-FACTOR-REF", "float", 1.0, "Area factor reference (median normalization)")
add("K-GUIDANCE-BEVEL-SEGMENTS-LOD0", "int", 2, "Bevel segments for LOD0")
add("K-GUIDANCE-BEVEL-SEGMENTS-LOD1", "int", 1, "Bevel segments for LOD1")
add("K-GUIDANCE-BEVEL-RADIUS-RATIO", "float", 0.15, "Bevel radius as fraction of thickness")
add("K-GUIDANCE-LOD0-TRI-PER-PRISM", "int", 44, "LOD0 triangles per prism")
add("K-GUIDANCE-METALLIC-BASE", "float", 0.3, "Base metallic value for PBR")
add("K-GUIDANCE-METALLIC-S3-BONUS", "float", 0.4, "Metallic increase at S3+")
add("K-GUIDANCE-ROUGHNESS-BASE", "float", 0.6, "Base roughness for PBR")
add("K-GUIDANCE-ROUGHNESS-S3-REDUCTION", "float", 0.3, "Roughness decrease at S3+")
add("K-GUIDANCE-FRESNEL-F0", "float", 0.04, "Fresnel F0 for dielectric")
add("K-GUIDANCE-FRESNEL-F0-METALLIC", "float", 0.7, "Fresnel F0 for metallic")
add("K-GUIDANCE-FLIP-DURATION-S", "float", 0.5, "Flip animation duration (seconds)")
add("K-GUIDANCE-FLIP-CP1X", "float", 0.34, "Flip easing control point 1 X")
add("K-GUIDANCE-FLIP-CP1Y", "float", 1.56, "Flip easing control point 1 Y (overshoot)")
add("K-GUIDANCE-FLIP-CP2X", "float", 0.64, "Flip easing control point 2 X")
add("K-GUIDANCE-FLIP-CP2Y", "float", 1.0, "Flip easing control point 2 Y")
add("K-GUIDANCE-FLIP-MAX-CONCURRENT", "int", 20, "Maximum concurrent flip animations")
add("K-GUIDANCE-FLIP-STAGGER-DELAY-S", "float", 0.03, "Flip stagger delay between triangles (s)")
add("K-GUIDANCE-FLIP-MIN-DISPLAY-DELTA", "float", 0.05, "Min display delta to trigger flip")
add("K-GUIDANCE-RIPPLE-DELAY-PER-HOP-S", "float", 0.06, "Delay per BFS hop (seconds)")
add("K-GUIDANCE-RIPPLE-MAX-HOPS", "int", 8, "Maximum BFS hops")
add("K-GUIDANCE-RIPPLE-DAMPING-PER-HOP", "float", 0.85, "Amplitude damping per hop")
add("K-GUIDANCE-RIPPLE-INITIAL-AMPLITUDE", "float", 1.0, "Initial ripple amplitude")
add("K-GUIDANCE-RIPPLE-THICKNESS-MULT", "float", 0.3, "Ripple thickness multiplier")
add("K-GUIDANCE-RIPPLE-MAX-WAVES", "int", 5, "Maximum concurrent ripple waves")
add("K-GUIDANCE-RIPPLE-MIN-SPAWN-S", "float", 0.5, "Min interval between ripple spawns (s)")
add("K-GUIDANCE-HAPTIC-DEBOUNCE-S", "float", 5.0, "Haptic debounce interval (seconds)")
add("K-GUIDANCE-HAPTIC-MAX-PER-MIN", "int", 4, "Maximum haptic events per minute")
add("K-GUIDANCE-HAPTIC-BLUR-THRESHOLD", "float", 100.0, "Haptic blur threshold (Laplacian variance)")
add("K-GUIDANCE-HAPTIC-MOTION-THRESHOLD", "float", 0.7, "Haptic motion threshold")
add("K-GUIDANCE-HAPTIC-EXPOSURE-THRESHOLD", "float", 0.2, "Haptic exposure threshold")
add("K-GUIDANCE-TOAST-DURATION-S", "float", 2.0, "Toast display duration (seconds)")
add("K-GUIDANCE-TOAST-A11Y-DURATION-S", "float", 5.0, "Toast accessibility duration (seconds)")
add("K-GUIDANCE-TOAST-BG-ALPHA", "float", 0.85, "Toast background color alpha")
add("K-GUIDANCE-TOAST-CORNER-RADIUS", "float", 12.0, "Toast corner radius (points)")
add("K-GUIDANCE-TOAST-FONT-SIZE", "float", 15.0, "Toast font size (points)")
add("K-GUIDANCE-MAX-INFLIGHT-BUFFERS", "int", 3, "Maximum inflight Metal buffers")
add("K-GUIDANCE-THERMAL-NOMINAL-TRI", "int", 5000, "Thermal nominal max triangles")
add("K-GUIDANCE-THERMAL-FAIR-TRI", "int", 3000, "Thermal fair max triangles")
add("K-GUIDANCE-THERMAL-SERIOUS-TRI", "int", 1500, "Thermal serious max triangles")
add("K-GUIDANCE-THERMAL-CRITICAL-TRI", "int", 500, "Thermal critical max triangles")
add("K-GUIDANCE-THERMAL-HYSTERESIS-S", "float", 10.0, "Thermal hysteresis duration (seconds)")
add("K-GUIDANCE-FRAME-BUDGET-OVERSHOOT", "float", 1.2, "Frame budget overshoot ratio threshold")
add("K-GUIDANCE-FRAME-BUDGET-WINDOW", "int", 30, "Frame budget measurement window (frames)")
add("K-GUIDANCE-MIN-CONTRAST-RATIO", "float", 17.4, "WCAG 2.1 AAA minimum contrast ratio")
add("K-GUIDANCE-VOICEOVER-DELAY-S", "float", 0.3, "VoiceOver announcement delay (seconds)")
add("K-GUIDANCE-REDUCE-MOTION-FLIP", "bool", True, "Reduce motion disables flip animation")
add("K-GUIDANCE-REDUCE-MOTION-RIPPLE", "bool", True, "Reduce motion disables ripple animation")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: TSDF (TSDFConstants.swift) — Phase 3, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-TSDF-VOXEL-SIZE-NEAR", "float", 0.005, "Near-range voxel size (m, depth<1m)")
add("K-TSDF-VOXEL-SIZE-MID", "float", 0.01, "Mid-range voxel size (m, 1-3m)")
add("K-TSDF-VOXEL-SIZE-FAR", "float", 0.02, "Far-range voxel size (m, depth>3m)")
add("K-TSDF-DEPTH-NEAR-THRESHOLD", "float", 1.0, "Near→mid voxel size transition (m)")
add("K-TSDF-DEPTH-FAR-THRESHOLD", "float", 3.0, "Mid→far voxel size transition (m)")
add("K-TSDF-TRUNCATION-MULTIPLIER", "float", 3.0, "Truncation band = multiplier × voxel_size")
add("K-TSDF-TRUNCATION-MINIMUM", "float", 0.01, "Absolute minimum truncation distance (m)")
add("K-TSDF-WEIGHT-MAX", "int", 64, "Maximum accumulated weight per voxel (UInt8)")
add("K-TSDF-CONFIDENCE-WEIGHT-LOW", "float", 0.1, "ARKit confidence level 0 weight")
add("K-TSDF-CONFIDENCE-WEIGHT-MID", "float", 0.5, "ARKit confidence level 1 weight")
add("K-TSDF-CONFIDENCE-WEIGHT-HIGH", "float", 1.0, "ARKit confidence level 2 weight")
add("K-TSDF-DISTANCE-DECAY-ALPHA", "float", 0.1, "Quadratic depth weight decay alpha")
add("K-TSDF-VIEWING-ANGLE-WEIGHT-FLOOR", "float", 0.1, "Minimum weight at grazing angles")
add("K-TSDF-CARVING-DECAY-RATE", "int", 2, "Weight decay per frame for space carving")
add("K-TSDF-DEPTH-MIN", "float", 0.1, "Minimum reliable depth (m, hardware floor)")
add("K-TSDF-DEPTH-MAX", "float", 5.0, "Maximum reliable depth (m)")
add("K-TSDF-MIN-VALID-PIXEL-RATIO", "float", 0.3, "Min fraction valid depth pixels to accept frame")
add("K-TSDF-MAX-VOXELS-PER-FRAME", "int", 500000, "Maximum voxels updated per GPU frame")
add("K-TSDF-MAX-TRIANGLES-PER-CYCLE", "int", 50000, "Hard safety cap on triangles per meshing cycle")
add("K-TSDF-INTEGRATION-TIMEOUT-MS", "float", 10.0, "Max CPU+GPU time for integration pass (ms)")
add("K-TSDF-METAL-THREADGROUP-SIZE", "int", 8, "Threadgroup edge size (8x8=64 threads)")
add("K-TSDF-METAL-INFLIGHT-BUFFERS", "int", 3, "Triple-buffer count for TSDF data")
add("K-TSDF-MAX-TOTAL-VOXEL-BLOCKS", "int", 100000, "Maximum voxel blocks across all resolutions")
add("K-TSDF-HASH-TABLE-INITIAL-SIZE", "int", 65536, "Initial hash table capacity (power of 2)")
add("K-TSDF-HASH-TABLE-MAX-LOAD", "float", 0.7, "Load factor threshold triggering rehash")
add("K-TSDF-HASH-MAX-PROBE-LENGTH", "int", 128, "Maximum linear probe before giving up")
add("K-TSDF-DIRTY-THRESHOLD-MULT", "float", 0.5, "Block dirty threshold = mult × voxelSize")
add("K-TSDF-STALE-BLOCK-EVICT-AGE", "float", 30.0, "Age threshold for low-priority eviction (s)")
add("K-TSDF-STALE-BLOCK-FORCE-EVICT", "float", 60.0, "Age threshold for forced eviction (s)")
add("K-TSDF-BLOCK-SIZE", "int", 8, "Voxels per block edge (8³=512, IMMUTABLE)")
add("K-TSDF-MAX-POSE-DELTA-PER-FRAME", "float", 0.1, "Position delta threshold for teleport rejection (m)")
add("K-TSDF-MAX-ANGULAR-VELOCITY", "float", 2.0, "Angular velocity threshold for rejection (rad/s)")
add("K-TSDF-POSE-REJECT-WARN-COUNT", "int", 30, "Consecutive rejected frames before warning")
add("K-TSDF-POSE-REJECT-FAIL-COUNT", "int", 180, "Consecutive rejected frames before fail")
add("K-TSDF-LOOP-CLOSURE-DRIFT", "float", 0.02, "Anchor shift threshold to mark blocks stale (m)")
add("K-TSDF-KEYFRAME-INTERVAL", "int", 6, "Every Nth integrated frame is keyframe candidate")
add("K-TSDF-KEYFRAME-ANGULAR-DEG", "float", 15.0, "Viewpoint angular change for keyframe (deg)")
add("K-TSDF-KEYFRAME-TRANSLATION", "float", 0.3, "Camera movement threshold for keyframe (m)")
add("K-TSDF-MAX-KEYFRAMES-SESSION", "int", 30, "Memory budget cap for retained keyframes")
add("K-TSDF-SEMAPHORE-WAIT-TIMEOUT-MS", "float", 100.0, "GPU fence timeout before frame skip (ms)")
add("K-TSDF-GPU-MEM-PROACTIVE-EVICT", "int", 500000000, "GPU memory proactive eviction threshold (bytes)")
add("K-TSDF-GPU-MEM-AGGRESSIVE-EVICT", "int", 800000000, "GPU memory aggressive eviction threshold (bytes)")
add("K-TSDF-WORLD-ORIGIN-RECENTER-DIST", "float", 100.0, "Camera distance from origin before recenter (m)")
add("K-TSDF-THERMAL-DEGRADE-HYSTERESIS", "float", 10.0, "Cooldown before worse thermal ceiling (s)")
add("K-TSDF-THERMAL-RECOVER-HYSTERESIS", "float", 5.0, "Cooldown before better thermal ceiling (s)")
add("K-TSDF-THERMAL-RECOVER-GOOD-FRAMES", "int", 30, "Good frames before AIMD additive-increase")
add("K-TSDF-THERMAL-GOOD-FRAME-RATIO", "float", 0.8, "GPU time/timeout ratio for 'good' frame")
add("K-TSDF-THERMAL-MAX-INTEGRATION-SKIP", "int", 12, "Max frame skip count (floor=5fps)")
add("K-TSDF-MIN-TRIANGLE-AREA", "float", 1e-8, "Degenerate triangle area rejection (m²)")
add("K-TSDF-MAX-TRIANGLE-ASPECT-RATIO", "float", 100.0, "Degenerate triangle needle rejection")
add("K-TSDF-INTEGRATION-RECORD-CAPACITY", "int", 300, "Ring buffer size for IntegrationRecord")
add("K-TSDF-SDF-DEADZONE-BASE", "float", 0.001, "SDF update dead zone for fresh voxels (m)")
add("K-TSDF-SDF-DEADZONE-WEIGHT-SCALE", "float", 0.004, "Additional dead zone at max weight (m)")
add("K-TSDF-VERTEX-QUANTIZATION-STEP", "float", 0.0005, "Grid snap step for vertices (m)")
add("K-TSDF-MESH-EXTRACTION-TARGET-HZ", "float", 10.0, "Target mesh extraction rate (Hz)")
add("K-TSDF-MESH-EXTRACTION-BUDGET-MS", "float", 5.0, "Max wall-clock time per meshing cycle (ms)")
add("K-TSDF-MC-INTERPOLATION-MIN", "float", 0.1, "Lower clamp for MC zero-crossing t")
add("K-TSDF-MC-INTERPOLATION-MAX", "float", 0.9, "Upper clamp for MC zero-crossing t")
add("K-TSDF-POSE-JITTER-GATE-TRANS", "float", 0.001, "Min camera movement to trigger integration (m)")
add("K-TSDF-POSE-JITTER-GATE-ROT", "float", 0.002, "Min camera rotation to trigger integration (rad)")
add("K-TSDF-MIN-OBS-BEFORE-MESH", "int", 3, "Min integration touches before mesh extraction")
add("K-TSDF-MESH-FADE-IN-FRAMES", "int", 7, "Fade-in duration after min observations met")
add("K-TSDF-MESH-BUDGET-TARGET-MS", "float", 4.0, "Target meshing cycle time for congestion ctrl (ms)")
add("K-TSDF-MESH-BUDGET-GOOD-MS", "float", 3.0, "Good cycle threshold for additive increase (ms)")
add("K-TSDF-MESH-BUDGET-OVERRUN-MS", "float", 5.0, "Overrun threshold for multiplicative decrease (ms)")
add("K-TSDF-MIN-BLOCKS-PER-EXTRACT", "int", 50, "Floor: always make meshing progress")
add("K-TSDF-MAX-BLOCKS-PER-EXTRACT", "int", 250, "Ceiling: per-device max blocks per cycle")
add("K-TSDF-BLOCK-RAMP-PER-CYCLE", "int", 15, "Additive increase per good meshing cycle")
add("K-TSDF-GOOD-CYCLES-BEFORE-RAMP", "int", 3, "Good cycles required before block count increase")
add("K-TSDF-FORGIVENESS-WINDOW-CYCLES", "int", 5, "Cooldown cycles after overrun")
add("K-TSDF-SLOW-START-RATIO", "float", 0.25, "Recovery start ratio after overrun")
add("K-TSDF-NORMAL-AVG-BOUNDARY-DIST", "float", 0.001, "Distance from block edge for normal averaging (m)")
add("K-TSDF-MOTION-DEFER-TRANS-SPEED", "float", 0.5, "Translation speed above which meshing defers (m/s)")
add("K-TSDF-MOTION-DEFER-ANGULAR-SPEED", "float", 1.0, "Angular speed above which meshing defers (rad/s)")
add("K-TSDF-IDLE-TRANS-SPEED", "float", 0.01, "Speed below which camera is idle (m/s)")
add("K-TSDF-IDLE-ANGULAR-SPEED", "float", 0.05, "Angular speed below which camera is idle (rad/s)")
add("K-TSDF-ANTICIPATORY-PREALLOC-DIST", "float", 0.5, "Look-ahead distance for idle preallocation (m)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: FRAME (FrameQualityConstants.swift) — Phase 5, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-FRAME-DARK-THRESHOLD", "float", 60.0, "Dark threshold (brightness 0-255)")
add("K-FRAME-BRIGHT-THRESHOLD", "float", 200.0, "Bright threshold (brightness 0-255)")
add("K-FRAME-MAX-SIMILARITY", "float", 0.92, "Max frame similarity (redundant frame)")
add("K-FRAME-MIN-SIMILARITY", "float", 0.50, "Min frame similarity (jump frame)")
add("K-FRAME-TENENGRAD-THRESHOLD", "float", 50.0, "Tenengrad (Sobel) backup sharpness threshold")
add("K-FRAME-TENENGRAD-WARN", "float", 40.0, "Tenengrad warning threshold")
add("K-FRAME-MIN-ORB-FEATURES", "int", 500, "Minimum ORB features for SfM")
add("K-FRAME-WARN-ORB-FEATURES", "int", 800, "Warning ORB features for SfM")
add("K-FRAME-OPTIMAL-ORB-FEATURES", "int", 1500, "Optimal ORB features for SfM")
add("K-FRAME-MIN-FEATURE-SPATIAL-DIST", "float", 0.30, "Min feature spatial distribution")
add("K-FRAME-WARN-FEATURE-SPATIAL-DIST", "float", 0.45, "Warning feature spatial distribution")
add("K-FRAME-SPECULAR-MAX-PERCENT", "float", 5.0, "Specular highlight max percent")
add("K-FRAME-SPECULAR-WARN-PERCENT", "float", 3.0, "Specular highlight warning percent")
add("K-FRAME-SPECULAR-MIN-PIXELS", "int", 500, "Specular region minimum pixels")
add("K-FRAME-TRANSPARENT-WARN-PERCENT", "float", 10.0, "Transparent region warning percent")
add("K-FRAME-TEXTURELESS-MAX-PERCENT", "float", 25.0, "Textureless region max percent")
add("K-FRAME-TEXTURELESS-WARN-PERCENT", "float", 15.0, "Textureless region warning percent")
add("K-FRAME-MIN-LOCAL-VARIANCE", "float", 10.0, "Min local variance for texture")
add("K-FRAME-MAX-ANGULAR-VEL-DEG-SEC", "float", 30.0, "Max angular velocity (deg/s)")
add("K-FRAME-WARN-ANGULAR-VEL-DEG-SEC", "float", 20.0, "Warning angular velocity (deg/s)")
add("K-FRAME-MOTION-BLUR-RISK", "float", 0.6, "Motion blur risk threshold")
add("K-FRAME-MOTION-BLUR-RISK-WARN", "float", 0.4, "Motion blur risk warning threshold")
add("K-FRAME-MIN-STABLE-FRAMES-COMMIT", "int", 5, "Min stable frames before commit")
add("K-FRAME-STABILITY-VARIANCE", "float", 0.05, "Stability variance threshold")
add("K-FRAME-MAX-LUMINANCE-VAR-NERF", "float", 0.08, "Max luminance variance for NeRF")
add("K-FRAME-WARN-LUMINANCE-VAR-NERF", "float", 0.05, "Warning luminance variance for NeRF")
add("K-FRAME-MAX-LAB-VAR-NERF", "float", 15.0, "Max LAB variance for NeRF")
add("K-FRAME-WARN-LAB-VAR-NERF", "float", 10.0, "Warning LAB variance for NeRF")
add("K-FRAME-MIN-EXPOSURE-CONSISTENCY", "float", 0.85, "Min exposure consistency ratio")
add("K-FRAME-WARN-EXPOSURE-CONSISTENCY", "float", 0.90, "Warning exposure consistency ratio")
add("K-FRAME-LAPLACIAN-MULT-PRO-MACRO", "float", 1.25, "Laplacian multiplier for pro macro profile")
add("K-FRAME-LAPLACIAN-MULT-LARGE-SCENE", "float", 0.90, "Laplacian multiplier for large scene")
add("K-FRAME-LAPLACIAN-MULT-CINEMATIC", "float", 0.90, "Laplacian multiplier for cinematic")
add("K-FRAME-FEATURE-MULT-CINEMATIC", "float", 0.70, "Feature multiplier for cinematic")
add("K-FRAME-FEATURE-MULT-PRO-MACRO", "float", 1.20, "Feature multiplier for pro macro")
add("K-FRAME-MIN-DEPTH-CONFIDENCE", "float", 0.7, "Min depth confidence")
add("K-FRAME-MAX-DEPTH-VAR-NORMALIZED", "float", 0.15, "Max depth variance normalized")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: JOB (ContractConstants.swift) — Phase 4, Tier 0/1
# ═══════════════════════════════════════════════════════════════
add("K-JOB-STATE-COUNT", "int", 9, "Total number of job states")
add("K-JOB-LEGAL-TRANSITION-COUNT", "int", 15, "Number of legal state transitions")
add("K-JOB-FAILURE-REASON-COUNT", "int", 17, "Total number of failure reasons")
add("K-JOB-CANCEL-REASON-COUNT", "int", 3, "Total number of cancel reasons")
add("K-JOB-ID-MIN-LENGTH", "int", 15, "Minimum job ID length (sonyflake)")
add("K-JOB-ID-MAX-LENGTH", "int", 20, "Maximum job ID length")
add("K-JOB-CANCEL-WINDOW-SEC", "int", 30, "Cancel window duration (PROCESSING state)")
add("K-JOB-PROGRESS-REPORT-INTERVAL-SEC", "int", 3, "Progress report interval (seconds)")
add("K-JOB-HEALTH-CHECK-INTERVAL-SEC", "int", 10, "Health check interval (seconds)")
add("K-JOB-HEARTBEAT-INTERVAL-SEC", "int", 30, "Processing heartbeat interval (seconds)")
add("K-JOB-HEARTBEAT-MAX-MISSED", "int", 3, "Maximum missed heartbeats before auto-failure")
add("K-JOB-CHUNK-SIZE-BYTES", "int", 5242880, "Upload chunk size (5MB)")
add("K-JOB-MAX-VIDEO-DURATION-SEC", "int", 900, "Maximum video duration (15 min)")
add("K-JOB-MIN-VIDEO-DURATION-SEC", "int", 5, "Minimum video duration (5 sec)")
add("K-JOB-MAX-AUTO-RETRY-COUNT", "int", 5, "Maximum automatic retry count")
add("K-JOB-RETRY-BASE-INTERVAL-SEC", "int", 2, "Base retry interval (seconds)")
add("K-JOB-RETRY-MAX-DELAY-SEC", "int", 60, "Maximum retry delay (seconds)")
add("K-JOB-RETRY-JITTER-MAX-MS", "int", 1000, "Maximum jitter in milliseconds")
add("K-JOB-RETRY-DECORRELATED-MULT", "float", 3.0, "Decorrelated jitter multiplier")
add("K-JOB-DLQ-RETENTION-DAYS", "int", 7, "DLQ retention period (days)")
add("K-JOB-DLQ-ALERT-THRESHOLD", "int", 100, "DLQ entries before alert")
add("K-JOB-QUEUED-TIMEOUT-SEC", "int", 3600, "Queued timeout (1 hour)")
add("K-JOB-QUEUED-WARNING-SEC", "int", 900, "Queued warning threshold (15 min)")
add("K-JOB-CB-FAILURE-THRESHOLD", "int", 5, "Circuit breaker failure threshold")
add("K-JOB-CB-SUCCESS-THRESHOLD", "int", 3, "Circuit breaker success threshold (half-open→closed)")
add("K-JOB-CB-OPEN-TIMEOUT-SEC", "float", 30.0, "Circuit breaker open timeout (seconds)")
add("K-JOB-CB-SLIDING-WINDOW", "int", 10, "Circuit breaker sliding window size")
add("K-JOB-MIN-PROGRESS-INCREMENT-PCT", "float", 2.0, "Min progress increment to report (%)")
add("K-JOB-INITIAL-PROGRESS-BOOST-PCT", "float", 5.0, "Initial progress boost (%)")
add("K-JOB-PROGRESS-SLOWDOWN-PCT", "float", 90.0, "Progress slowdown threshold (%)")
add("K-JOB-MAX-CONCURRENT-UPLOADS", "int", 3, "Max concurrent uploads (bulkhead)")
add("K-JOB-MAX-CONCURRENT-PROCESSING", "int", 5, "Max concurrent processing jobs")
add("K-JOB-QUEUE-OVERFLOW-THRESHOLD", "int", 100, "Queue overflow threshold (reject new)")
add("K-JOB-FALLBACK-ETA-SEC", "float", 120.0, "Default ETA when estimation unavailable (s)")
add("K-JOB-FALLBACK-STALE-SEC", "float", 30.0, "Cached progress stale threshold (s)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: UPLOAD (UploadConstants.swift) — Phase 4, Tier 1/2
# ═══════════════════════════════════════════════════════════════
add("K-UPLOAD-CHUNK-MIN-BYTES", "int", 262144, "Minimum chunk size (256KB)")
add("K-UPLOAD-CHUNK-DEFAULT-BYTES", "int", 2097152, "Default chunk size (2MB)")
add("K-UPLOAD-CHUNK-STEP-BYTES", "int", 524288, "Chunk size adjustment step (512KB)")
add("K-UPLOAD-NET-SLOW-MBPS", "float", 3.0, "Slow network threshold (Mbps)")
add("K-UPLOAD-NET-NORMAL-MBPS", "float", 30.0, "Normal network threshold (Mbps)")
add("K-UPLOAD-NET-FAST-MBPS", "float", 100.0, "Fast network threshold (Mbps)")
add("K-UPLOAD-NET-MIN-SAMPLES", "int", 5, "Min samples before speed estimation reliable")
add("K-UPLOAD-NET-WINDOW-SEC", "float", 60.0, "Speed measurement rolling window (s)")
add("K-UPLOAD-NET-MAX-SAMPLES", "int", 30, "Maximum speed samples to retain")
add("K-UPLOAD-MIN-PARALLEL", "int", 1, "Minimum concurrent chunk uploads")
add("K-UPLOAD-RAMP-UP-DELAY-SEC", "float", 0.01, "Ramp-up delay between parallel requests (s)")
add("K-UPLOAD-PARALLELISM-ADJUST-SEC", "float", 3.0, "Parallelism adjustment interval (s)")
add("K-UPLOAD-SESSION-MAX-AGE-SEC", "float", 172800.0, "Maximum upload session age (48h)")
add("K-UPLOAD-SESSION-CLEANUP-SEC", "float", 1800.0, "Session cleanup interval (30min)")
add("K-UPLOAD-SESSION-MAX-CONCURRENT", "int", 3, "Max concurrent sessions per user")
add("K-UPLOAD-CHUNK-TIMEOUT-SEC", "float", 45.0, "Individual chunk upload timeout (s)")
add("K-UPLOAD-CONNECTION-TIMEOUT-SEC", "float", 8.0, "Connection establishment timeout (s)")
add("K-UPLOAD-STALL-DETECT-TIMEOUT-SEC", "float", 10.0, "Stall detection timeout (s)")
add("K-UPLOAD-STALL-MIN-RATE-BPS", "int", 4096, "Min progress rate before stall (bytes/s)")
add("K-UPLOAD-CHUNK-MAX-RETRIES", "int", 7, "Maximum retries per chunk")
add("K-UPLOAD-RETRY-BASE-DELAY-SEC", "float", 0.5, "Retry base delay (seconds)")
add("K-UPLOAD-RETRY-MAX-DELAY-SEC", "float", 15.0, "Maximum retry delay (seconds)")
add("K-UPLOAD-RETRY-JITTER-FACTOR", "float", 1.0, "Retry jitter range (±100%)")
add("K-UPLOAD-PROGRESS-THROTTLE-SEC", "float", 0.05, "Progress update throttle interval (s)")
add("K-UPLOAD-PROGRESS-MIN-BYTES-DELTA", "int", 32768, "Min bytes delta before progress update (32KB)")
add("K-UPLOAD-PROGRESS-SMOOTHING", "float", 0.2, "Progress EMA smoothing factor")
add("K-UPLOAD-PROGRESS-MIN-INCREMENT-PCT", "float", 1.0, "Min progress increment percentage")
add("K-UPLOAD-MAX-FILE-SIZE-BYTES", "int", 53687091200, "Maximum file size for upload (50GB)")
add("K-UPLOAD-MIN-CHUNKED-SIZE-BYTES", "int", 2097152, "Min file size for chunked upload (2MB)")
add("K-UPLOAD-IDEMPOTENCY-MAX-AGE-SEC", "float", 86400.0, "Idempotency key max age (24h)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: RETRY (RetryConstants.swift) — Phase 4, Tier 2
# ═══════════════════════════════════════════════════════════════
add("K-RETRY-MAX-COUNT", "int", 10, "Auto retry count maximum")
add("K-RETRY-INTERVAL-SEC", "float", 10.0, "Retry interval (seconds)")
add("K-RETRY-DOWNLOAD-MAX-COUNT", "int", 3, "Download retry count maximum")
add("K-RETRY-ARTIFACT-TTL-SEC", "float", 1800.0, "Artifact TTL (30 min)")
add("K-RETRY-HEARTBEAT-INTERVAL-SEC", "float", 30.0, "Heartbeat interval (seconds)")
add("K-RETRY-POLLING-INTERVAL-SEC", "float", 3.0, "Polling interval (seconds)")
add("K-RETRY-STALL-DETECT-SEC", "float", 300.0, "Stall detection seconds (5 min)")
add("K-RETRY-STALL-HEARTBEAT-FAIL-COUNT", "int", 10, "Stall heartbeat failure count")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: BUNDLE (BundleConstants.swift) — Phase 8, Tier 0
# ═══════════════════════════════════════════════════════════════
add("K-BUNDLE-HASH-STREAM-CHUNK-BYTES", "int", 262144, "Hash stream chunk size (256KB)")
add("K-BUNDLE-MAX-TOTAL-BYTES", "int", 5000000000, "Max bundle total bytes (5GB decimal)")
add("K-BUNDLE-MAX-ASSET-COUNT", "int", 10000, "Max asset count per bundle")
add("K-BUNDLE-MAX-MANIFEST-BYTES", "int", 4194304, "Max manifest bytes (4MB)")
add("K-BUNDLE-PROB-VERIFY-DELTA", "float", 0.001, "Probabilistic verification delta")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: CAPACITY (CapacityLimitConstants.swift) — Phase 1, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-CAPACITY-SOFT-LIMIT-PATCHES", "int", 5000, "Soft limit patch count")
add("K-CAPACITY-HARD-LIMIT-PATCHES", "int", 8000, "Hard limit patch count")
add("K-CAPACITY-EEB-BASE-BUDGET", "float", 10000.0, "EEB base budget")
add("K-CAPACITY-EEB-MIN-QUANTUM", "float", 1.0, "EEB minimum quantum")
add("K-CAPACITY-SOFT-BUDGET-THRESHOLD", "float", 2000.0, "Soft budget threshold")
add("K-CAPACITY-HARD-BUDGET-THRESHOLD", "float", 500.0, "Hard budget threshold")
add("K-CAPACITY-POSE-EPS", "float", 0.01, "Pose epsilon for duplicate detection")
add("K-CAPACITY-COVERAGE-CELL-SIZE", "float", 0.1, "Coverage cell size (m)")
add("K-CAPACITY-RADIANCE-BINNING", "int", 16, "Radiance binning count")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: COLOR (ColorSpaceConstants.swift) — Phase 1, Tier 0 IMMUTABLE
# ═══════════════════════════════════════════════════════════════
add("K-COLOR-XYZ-WHITE-XN", "float", 0.95047, "D65 white point XN (IMMUTABLE physics)")
add("K-COLOR-XYZ-WHITE-YN", "float", 1.00000, "D65 white point YN (IMMUTABLE physics)")
add("K-COLOR-XYZ-WHITE-ZN", "float", 1.08883, "D65 white point ZN (IMMUTABLE physics)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: COMPLIANCE (ComplianceConstants.swift) — Phase 1, Tier 0
# ═══════════════════════════════════════════════════════════════
add("K-COMPLIANCE-PIPL-BIOMETRIC-CONSENT", "bool", True, "PIPL biometric consent required (GB/T 35273-2020)")
add("K-COMPLIANCE-SENSITIVE-PI-RETENTION-DAYS", "int", 180, "Sensitive PI retention period (days)")
add("K-COMPLIANCE-SENSITIVE-PI-ENCRYPTION", "bool", True, "Sensitive PI encryption required (GB/T 45574-2025)")
add("K-COMPLIANCE-PHOTOGRAMMETRY-ACCURACY", "float", 0.015, "Photogrammetry accuracy (mm/m, CH/T 1001-2005)")
add("K-COMPLIANCE-GDPR-RETENTION-DAYS", "int", 365, "GDPR data retention (days)")
add("K-COMPLIANCE-GDPR-RIGHT-TO-DELETE", "bool", True, "GDPR right to deletion enabled")
add("K-COMPLIANCE-EIDAS-QUALIFIED-SIG", "bool", False, "eIDAS qualified signature required")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: CONTINUITY (ContinuityConstants.swift) — Phase 1, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-CONTINUITY-MAX-DELTA-THETA-DEG", "float", 30.0, "Max angular delta per frame (degrees)")
add("K-CONTINUITY-MAX-DELTA-TRANS-M", "float", 0.25, "Max translation delta per frame (m)")
add("K-CONTINUITY-FREEZE-WINDOW-FRAMES", "int", 20, "Freeze window frames")
add("K-CONTINUITY-RECOVERY-STABLE-FRAMES", "int", 15, "Recovery stable frames")
add("K-CONTINUITY-RECOVERY-MAX-DELTA-DEG", "float", 15.0, "Recovery max angular delta (degrees)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: COVERAGE (CoverageVisualizationConstants.swift) — Phase 2, Tier 0
# ═══════════════════════════════════════════════════════════════
add("K-COVERAGE-S4-MIN-THETA-SPAN-DEG", "float", 16.0, "S4 minimum theta span (degrees)")
add("K-COVERAGE-S4-MIN-L2-PLUS-COUNT", "int", 7, "S4 minimum L2+ count")
add("K-COVERAGE-S4-MIN-L3-COUNT", "int", 3, "S4 minimum L3 count")
add("K-COVERAGE-S4-MAX-REPROJ-RMS-PX", "float", 1.0, "S4 max reprojection RMS (pixels)")
add("K-COVERAGE-S4-MAX-EDGE-RMS-PX", "float", 0.5, "S4 max edge RMS (pixels)")
add("K-COVERAGE-PATCH-SIZE-MIN-M", "float", 0.005, "Patch size minimum (m)")
add("K-COVERAGE-PATCH-SIZE-MAX-M", "float", 0.5, "Patch size maximum (m)")
add("K-COVERAGE-PATCH-SIZE-FALLBACK-M", "float", 0.05, "Patch size fallback (m)")
add("K-COVERAGE-L1-MIN-DELTA-THETA-DEG", "float", 1.5, "L1 minimum angular separation (degrees)")
add("K-COVERAGE-L2-MIN-DELTA-THETA-DEG", "float", 5.0, "L2 minimum angular separation (degrees)")
add("K-COVERAGE-L3-MIN-DELTA-THETA-DEG", "float", 10.0, "L3 minimum angular separation (degrees)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: XPLAT (CrossPlatformConstants.swift) — Phase 1, Tier 0 IMMUTABLE
# ═══════════════════════════════════════════════════════════════
add("K-XPLAT-QUANT-POS-GEOM-ID", "float", 1e-3, "Quantization step for geometry ID (1mm)")
add("K-XPLAT-QUANT-POS-PATCH-ID", "float", 1e-4, "Quantization step for patch ID (0.1mm)")
add("K-XPLAT-TOL-COVERAGE-RATIO", "float", 1e-4, "Coverage ratio relative tolerance")
add("K-XPLAT-TOL-LAB-COLOR-ABS", "float", 1e-3, "LAB color absolute tolerance")
add("K-XPLAT-RELATIVE-ERROR-EPS", "float", 1e-12, "Relative error epsilon")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: MATH (MathSafetyConstants.swift) — Phase 1, Tier 0 IMMUTABLE
# ═══════════════════════════════════════════════════════════════
add("K-MATH-RATIO-MIN", "float", 0.0, "Ratio minimum (IMMUTABLE)")
add("K-MATH-RATIO-MAX", "float", 1.0, "Ratio maximum (IMMUTABLE)")
add("K-MATH-SCORE-MIN", "float", 0.0, "Score minimum (IMMUTABLE)")
add("K-MATH-SCORE-MAX", "float", 1.0, "Score maximum (IMMUTABLE)")
add("K-MATH-WEIGHT-MIN", "float", 0.0, "Weight minimum (IMMUTABLE)")
add("K-MATH-COUNT-MIN", "int", 0, "Count minimum (IMMUTABLE)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: METAL (MetalConstants.swift) — Phase 6, Tier 0 IMMUTABLE
# ═══════════════════════════════════════════════════════════════
add("K-METAL-INFLIGHT-BUFFER-COUNT", "int", 3, "Triple-buffer count (Apple WWDC recommendation)")
add("K-METAL-DEFAULT-THREADGROUP-SIZE", "int", 8, "Default compute threadgroup edge size (8x8=64)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: THERMAL (ThermalConstants.swift) — Phase 6, Tier 2
# ═══════════════════════════════════════════════════════════════
add("K-THERMAL-SAFE-AMBIENT-MAX-C", "float", 35.0, "Safe ambient max temperature (°C)")
add("K-THERMAL-WARNING-C", "float", 40.0, "Thermal warning temperature (°C)")
add("K-THERMAL-CRITICAL-C", "float", 45.0, "Thermal critical temperature (°C)")
add("K-THERMAL-SHUTDOWN-C", "float", 50.0, "Thermal shutdown temperature (°C)")
add("K-THERMAL-MAX-4K60-CONTINUOUS-SEC", "int", 1800, "Max 4K60 continuous seconds (30 min)")
add("K-THERMAL-MAX-PRORES-CONTINUOUS-SEC", "int", 900, "Max ProRes continuous seconds (15 min)")
add("K-THERMAL-COOLDOWN-SEC", "int", 120, "Thermal cooldown seconds (2 min)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: OBSERVE (ObservationConstants.swift) — Phase 2, Tier 0/1
# ═══════════════════════════════════════════════════════════════
add("K-OBSERVE-MIN-OVERLAP-AREA", "float", 1e-6, "L1 minimum overlap area")
add("K-OBSERVE-MIN-PARALLAX-RATIO", "float", 0.02, "L2 minimum parallax ratio")
add("K-OBSERVE-MAX-REPROJ-ERROR-PX", "float", 2.0, "L2 max reprojection error (px)")
add("K-OBSERVE-MAX-GEOMETRIC-VAR", "float", 1e-4, "L2 max geometric variance")
add("K-OBSERVE-MAX-DEPTH-VAR", "float", 1e-3, "L3 max depth variance")
add("K-OBSERVE-MAX-LUMINANCE-VAR", "float", 1e-2, "L3 max luminance variance")
add("K-OBSERVE-MAX-LAB-VAR", "float", 1e-2, "L3 max LAB variance")
add("K-OBSERVE-MIN-ANGULAR-SEP-RAD", "float", 0.0872664626, "Min angular separation (5 degrees, rad)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: DIM (DimensionalConstants.swift) — Phase 2, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-DIM-TRACKING-STABLE", "float", 0.95, "Reliability coefficient: tracking stable")
add("K-DIM-MOTION-BLUR", "float", 0.60, "Reliability coefficient: motion blur")
add("K-DIM-LOW-FEATURES", "float", 0.70, "Reliability coefficient: low features")
add("K-DIM-HIGH-CONFIDENCE", "float", 1.0, "Reliability coefficient: high confidence")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: PIZ (PIZConstants.swift) — Phase 2, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-PIZ-PERSISTENCE-WINDOW-SEC", "float", 30.0, "PIZ persistence window (seconds)")
add("K-PIZ-IMPROVEMENT-THRESHOLD", "float", 0.01, "PIZ improvement threshold")
add("K-PIZ-MIN-AREA-SQ-M", "float", 0.001, "PIZ minimum area (m²)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: SAMPLE (SamplingConstants.swift) — Phase 4, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-SAMPLE-MIN-VIDEO-DURATION-SEC", "float", 2.0, "Min video duration (seconds)")
add("K-SAMPLE-MAX-VIDEO-DURATION-SEC", "float", 900.0, "Max video duration (15 min)")
add("K-SAMPLE-MIN-FRAME-COUNT", "int", 30, "Min frame count")
add("K-SAMPLE-MAX-FRAME-COUNT", "int", 1800, "Max frame count")
add("K-SAMPLE-JPEG-QUALITY", "float", 0.85, "JPEG quality")
add("K-SAMPLE-MAX-IMAGE-LONG-EDGE", "int", 1920, "Max image long edge (px)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: SESSION (SessionBoundaryConstants.swift) — Phase 1, Tier 2
# ═══════════════════════════════════════════════════════════════
add("K-SESSION-TIME-GAP-THRESHOLD-MIN", "int", 30, "Session time gap threshold (minutes)")
add("K-SESSION-BG-THRESHOLD-MIN", "int", 5, "Session background threshold (minutes)")
add("K-SESSION-ANCHOR-SEARCH-MAX-FRAMES", "int", 15, "Session anchor search max frames")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: STORAGE (StorageConstants.swift) — Phase 2, Tier 2
# ═══════════════════════════════════════════════════════════════
add("K-STORAGE-LOW-WARNING-BYTES", "int", 1610612736, "Low storage warning threshold (1.5GB)")
add("K-STORAGE-AUTO-CLEANUP-ENABLED", "bool", False, "Auto cleanup enabled")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: SYSTEM (SystemConstants.swift) — Phase 1, Tier 1
# ═══════════════════════════════════════════════════════════════
add("K-SYSTEM-MAX-FRAMES", "int", 5000, "System max frames")
add("K-SYSTEM-MIN-FRAMES", "int", 10, "System min frames")
add("K-SYSTEM-MAX-GAUSSIANS", "int", 1000000, "System max gaussians")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: PIPELINE (PipelineTimeoutConstants.swift) — Phase 4, Tier 2
# ═══════════════════════════════════════════════════════════════
add("K-PIPELINE-STALL-TIMEOUT-SEC", "float", 300.0, "Pipeline stall timeout (5 min)")
add("K-PIPELINE-ABSOLUTE-MAX-TIMEOUT-SEC", "float", 7200.0, "Pipeline absolute max timeout (2h)")
add("K-PIPELINE-POLL-INTERVAL-SEC", "float", 3.0, "Pipeline poll interval (seconds)")
add("K-PIPELINE-POLL-QUEUED-SEC", "float", 5.0, "Pipeline poll queued interval (seconds)")
add("K-PIPELINE-BG-POLL-INTERVAL-SEC", "float", 30.0, "Background poll interval (seconds)")
add("K-PIPELINE-BG-GRACE-PERIOD-SEC", "float", 180.0, "Background grace period (seconds)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: CONVERT (ConversionConstants.swift) — Phase 1, Tier 0 IMMUTABLE
# ═══════════════════════════════════════════════════════════════
add("K-CONVERT-BYTES-PER-KB", "int", 1024, "Bytes per kilobyte (IMMUTABLE)")
add("K-CONVERT-BYTES-PER-MB", "int", 1048576, "Bytes per megabyte (IMMUTABLE)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: PRECHECK (QualityPreCheckConstants.swift) — Phase 5, Tier 1/2
# ═══════════════════════════════════════════════════════════════
add("K-PRECHECK-CONFIDENCE-FULL", "float", 0.80, "Confidence threshold full tier")
add("K-PRECHECK-CONFIDENCE-DEGRADED", "float", 0.90, "Confidence threshold degraded tier")
add("K-PRECHECK-WHITE-STABILITY-MAX", "float", 0.15, "Full white stability max (15% variance)")
add("K-PRECHECK-WHITE-STABILITY-DEGRADED", "float", 0.12, "Degraded white stability max (12%)")
add("K-PRECHECK-DIR-ENTER-STABLE-MS", "int", 500, "Direction enter stable (ms)")
add("K-PRECHECK-DIR-NO-PROGRESS-MS", "int", 2000, "Direction no progress (ms)")
add("K-PRECHECK-DIR-MIN-LIFETIME-MS", "int", 1000, "Direction min lifetime (ms)")
add("K-PRECHECK-DIR-COOLDOWN-MS", "int", 500, "Direction cooldown (ms)")
add("K-PRECHECK-TREND-WINDOW-MS", "int", 300, "Trend confirmation window (ms)")
add("K-PRECHECK-MAX-FIRST-FEEDBACK-MS", "int", 500, "Max time to first feedback (ms)")
add("K-PRECHECK-FREEZE-HYSTERESIS-MS", "int", 200, "Freeze hysteresis (ms)")
add("K-PRECHECK-NO-PROGRESS-WARN-MS", "int", 2000, "No progress warning (ms)")
add("K-PRECHECK-SPEED-SMOOTH-WINDOW-MS", "int", 200, "Speed smoothing window (ms)")
add("K-PRECHECK-SPEED-MAX-CHANGE-RATE", "float", 0.30, "Speed max change rate (30% per 200ms)")
add("K-PRECHECK-HINT-COOLDOWN-MS", "int", 2000, "Hint cooldown (ms)")
add("K-PRECHECK-EDGE-PULSE-COOLDOWN-MS", "int", 200, "Edge pulse cooldown (ms)")
add("K-PRECHECK-EDGE-PULSE-DEBOUNCE-MS", "int", 50, "Edge pulse debounce (ms)")
add("K-PRECHECK-DEGRADE-HYSTERESIS-MS", "int", 500, "Degradation hysteresis (ms)")
add("K-PRECHECK-EMERGENCY-EXIT-HYST-MS", "int", 1500, "Emergency exit hysteresis (ms)")
add("K-PRECHECK-FPS-FULL-THRESHOLD", "float", 30.0, "FPS full tier threshold")
add("K-PRECHECK-FPS-DEGRADED-THRESHOLD", "float", 20.0, "FPS degraded tier threshold")
add("K-PRECHECK-FPS-EMERGENCY-EXIT", "float", 25.0, "FPS emergency exit threshold")
add("K-PRECHECK-PERF-BUDGET-P50-MS", "float", 14.0, "Performance budget P50 (ms)")
add("K-PRECHECK-PERF-BUDGET-P95-MS", "float", 22.0, "Performance budget P95 (ms)")
add("K-PRECHECK-PERF-BUDGET-EMRG-P50-MS", "float", 2.0, "Emergency performance budget P50 (ms)")
add("K-PRECHECK-MAX-TREND-BUFFER", "int", 100, "Max trend buffer size")
add("K-PRECHECK-MAX-MOTION-BUFFER", "int", 50, "Max motion buffer size")
add("K-PRECHECK-MAX-COMMIT-RETRIES", "int", 3, "Max commit retries")
add("K-PRECHECK-MAX-COMMIT-RETRY-MS", "int", 300, "Max commit retry total (ms)")
add("K-PRECHECK-COMMIT-RETRY-INIT-MS", "int", 10, "Commit retry initial delay (ms)")
add("K-PRECHECK-COMMIT-RETRY-MAX-MS", "int", 100, "Commit retry max delay (ms)")
add("K-PRECHECK-MAX-AUDIT-PAYLOAD-BYTES", "int", 65536, "Max audit payload (64KB)")
add("K-PRECHECK-MAX-COVERAGE-DELTA-BYTES", "int", 262144, "Max coverage delta payload (256KB)")
add("K-PRECHECK-MAX-COMMITS-PER-SESSION", "int", 100000, "Max commits per session")
add("K-PRECHECK-MAX-DELTA-CHANGED-COUNT", "int", 16384, "Max delta changed count")
add("K-PRECHECK-MAX-CELL-INDEX", "int", 16383, "Max cell index (128*128-1)")
add("K-PRECHECK-HINT-MAX-STRONG", "int", 4, "Hint max strong per session")
add("K-PRECHECK-HINT-MAX-SUBTLE", "int", 1, "Hint max subtle per direction")
add("K-PRECHECK-MIN-PROGRESS-INCREMENT", "int", 10, "Min progress increment (cells)")
add("K-PRECHECK-MIN-VISIBLE-PROGRESS", "int", 30, "Min visible progress increment (cells)")
add("K-PRECHECK-FLOAT-EPSILON", "float", 1e-6, "Float comparison epsilon")
add("K-PRECHECK-STOPPED-ANIM-HZ", "float", 0.5, "Stopped animation frequency (Hz)")

# ═══════════════════════════════════════════════════════════════
# DOMAIN: CAPTURE (CaptureRecordingConstants.swift) — Phase 4, Tier 2/3
# (Selected key constants — excluding format strings, model arrays, codec arrays)
# ═══════════════════════════════════════════════════════════════
add("K-CAPTURE-MIN-DURATION-SEC", "float", 2.0, "Min recording duration (seconds)")
add("K-CAPTURE-MAX-DURATION-SEC", "float", 900.0, "Max recording duration (15 min)")
add("K-CAPTURE-DURATION-TOLERANCE", "float", 0.1, "Duration validation tolerance (seconds)")
add("K-CAPTURE-MIN-RECOMMENDED-3D-SEC", "float", 15.0, "Min recommended 3D duration (seconds)")
add("K-CAPTURE-OPTIMAL-3D-SEC", "float", 60.0, "Optimal 3D scanning duration (seconds)")
add("K-CAPTURE-MAX-RECOMMENDED-3D-SEC", "float", 300.0, "Max recommended 3D duration (seconds)")
add("K-CAPTURE-CMTIME-TIMESCALE", "int", 600, "CMTime preferred timescale")
add("K-CAPTURE-MIN-FREE-SPACE-BYTES", "int", 2147483648, "Min free space (2GB)")
add("K-CAPTURE-MIN-FREE-SPACE-BUFFER-SEC", "float", 30.0, "Min free space seconds buffer")
add("K-CAPTURE-LOW-STORAGE-WARN-BYTES", "int", 5368709120, "Low storage warning (5GB)")
add("K-CAPTURE-CRITICAL-STORAGE-BYTES", "int", 1073741824, "Critical storage (1GB)")
add("K-CAPTURE-MIN-BITRATE-3D-BPS", "int", 50000000, "Min bitrate for 3D (50 Mbps)")
add("K-CAPTURE-FINALIZE-TIMEOUT-SEC", "float", 15.0, "Finalize timeout (seconds)")
add("K-CAPTURE-ASSET-CHECK-TIMEOUT-SEC", "float", 1.5, "Asset check timeout budget (seconds)")
add("K-CAPTURE-RECONFIGURE-DELAY-SEC", "float", 0.3, "Reconfigure delay (seconds)")
add("K-CAPTURE-RECONFIGURE-DEBOUNCE-SEC", "float", 2.0, "Reconfigure debounce (seconds)")
add("K-CAPTURE-SESSION-START-TIMEOUT-SEC", "float", 5.0, "Session start timeout (seconds)")
add("K-CAPTURE-DEVICE-LOCK-TIMEOUT-SEC", "float", 2.0, "Device lock timeout (seconds)")
add("K-CAPTURE-FORMAT-VALIDATION-TIMEOUT-SEC", "float", 3.0, "Format validation timeout (seconds)")
add("K-CAPTURE-FPS-MATCH-TOLERANCE", "float", 0.1, "FPS matching tolerance")
add("K-CAPTURE-MAX-FORMAT-ATTEMPTS", "int", 5, "Max format attempts")
add("K-CAPTURE-FORMAT-WARMUP-DELAY-SEC", "float", 0.3, "Format warmup delay (seconds)")
add("K-CAPTURE-SCORE-WEIGHT-FPS", "int", 1000, "Format scoring FPS weight")
add("K-CAPTURE-SCORE-WEIGHT-RESOLUTION", "int", 100, "Format scoring resolution weight")
add("K-CAPTURE-SCORE-WEIGHT-HDR", "int", 500, "Format scoring HDR weight")
add("K-CAPTURE-SCORE-WEIGHT-HEVC", "int", 200, "Format scoring HEVC weight")
add("K-CAPTURE-SCORE-WEIGHT-PRORES", "int", 800, "Format scoring ProRes weight")
add("K-CAPTURE-MAX-FILENAME-LENGTH", "int", 120, "Max filename length")
add("K-CAPTURE-ORPHAN-TMP-MAX-AGE-SEC", "float", 14400.0, "Orphan tmp max age (4h)")
add("K-CAPTURE-MAX-RETAINED-FAILURE-FILES", "int", 10, "Max retained failure files")
add("K-CAPTURE-MAX-RETAINED-FAILURE-BYTES", "int", 524288000, "Max retained failure bytes (500MB)")
add("K-CAPTURE-MAX-RETAINED-FAILURE-DAYS", "int", 7, "Max retained failure age (days)")
add("K-CAPTURE-UPDATE-INTERVAL-SEC", "float", 1.0, "Recording update interval (seconds)")
add("K-CAPTURE-HDR-MAX-CONTENT-LIGHT-NITS", "int", 1000, "HDR max content light level (nits)")
add("K-CAPTURE-HDR-MAX-FRAME-AVG-NITS", "int", 200, "HDR max frame average light level (nits)")
add("K-CAPTURE-PRORES-MIN-WRITE-SPEED-MBPS", "int", 220, "ProRes min storage write speed (MB/s)")
add("K-CAPTURE-MIN-FRAMES-3D", "int", 30, "Min frames for 3D reconstruction")
add("K-CAPTURE-RECOMMENDED-FRAMES-3D", "int", 200, "Recommended frames for 3D")
add("K-CAPTURE-OPTIMAL-FRAMES-3D", "int", 500, "Optimal frames for 3D")
add("K-CAPTURE-MAX-MOTION-BLUR-MS", "float", 16.67, "Max acceptable motion blur (ms)")
add("K-CAPTURE-FOCUS-HYSTERESIS-SEC", "float", 0.5, "Focus hysteresis seconds")
add("K-CAPTURE-EXPOSURE-STABILIZE-SEC", "float", 0.3, "Exposure stabilization delay (seconds)")

# Merge and write
all_constants = registry["constants"] + new_constants
registry["constants"] = all_constants

# Update metadata
registry["metadata"]["last_updated"] = "2026-02-16"
registry["metadata"]["schema_version"] = "2.0.0"

# Write
with REGISTRY_PATH.open("w", encoding="utf-8") as f:
    json.dump(registry, f, indent=2, ensure_ascii=False)

# Stats
print(f"Total constants: {len(all_constants)}")
print(f"Existing preserved: {len(existing_ids)}")
print(f"New added: {len(new_constants)}")
print(f"Total contracts: {len(registry['contracts'])}")
print(f"Total feature flags: {len(registry['feature_flags'])}")

# Validate all IDs unique
all_ids = [c["id"] for c in all_constants]
dups = [x for x in all_ids if all_ids.count(x) > 1]
if dups:
    print(f"WARNING: Duplicate IDs: {set(dups)}")
else:
    print("All K-* IDs are unique")

# Validate JSON schema compliance
for c in all_constants:
    assert c["id"].startswith("K-"), f"Invalid ID: {c['id']}"
    assert c["value_type"] in ("int", "float", "string", "bool"), f"Invalid type: {c['value_type']}"
    assert c["status"] in ("active", "blocked", "planned", "deprecated"), f"Invalid status: {c['status']}"
    assert c["track"] in ("P", "X", "PX"), f"Invalid track: {c['track']}"
print("Schema validation passed")
