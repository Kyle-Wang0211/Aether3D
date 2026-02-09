//
// ScanGuidanceConstants.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Constants
// 65+ constants in 9 sections, all SSOT-registered
// NO platform imports — Foundation only
//

import Foundation

public enum ScanGuidanceConstants {

    // MARK: - Section 1: Grayscale Mapping (8 constants)
    // Colors read from CoverageVisualizationConstants — NOT redefined here
    // NOTE: PR7 uses CONTINUOUS grayscale from display [0,1],
    //       NOT discrete ColorState (S1/S2 both map to .darkGray in EvidenceStateMachine).
    //       GrayscaleMapper.swift converts display→RGB directly.

    /// S0→S1 threshold (display value)
    public static let s0ToS1Threshold: Double = 0.10
    /// S1→S2 threshold
    public static let s1ToS2Threshold: Double = 0.25
    /// S2→S3 threshold
    public static let s2ToS3Threshold: Double = 0.50
    /// S3→S4 threshold
    public static let s3ToS4Threshold: Double = 0.75
    /// S4→S5 threshold (white threshold from EvidenceStateMachine)
    public static let s4ToS5Threshold: Double = 0.88
    /// S5 minimum soft evidence
    public static let s5MinSoftEvidence: Double = 0.75
    /// Continuous grayscale interpolation gamma
    public static let grayscaleGamma: Double = 1.0
    /// S4 transparency alpha (original color shows through)
    public static let s4TransparencyAlpha: Double = 0.0

    // MARK: - Section 2: Border System (8 constants)

    /// Base border width (pixels)
    public static let borderBaseWidthPx: Double = 6.0
    /// Minimum border width (pixels)
    public static let borderMinWidthPx: Double = 1.0
    /// Maximum border width (pixels)
    public static let borderMaxWidthPx: Double = 12.0
    /// Display factor weight in border calculation
    public static let borderDisplayWeight: Double = 0.6
    /// Area factor weight in border calculation
    public static let borderAreaWeight: Double = 0.4
    /// Border gamma (Stevens' Power Law for brightness perception)
    public static let borderGamma: Double = 1.4
    /// Border color: white RGB(255,255,255)
    /// v7.0.3: Changed from UInt8 to Int for SystemConstantSpec registration
    public static let borderColorR: Int = 255
    /// Border alpha at S0 (fully opaque)
    public static let borderAlphaAtS0: Double = 1.0

    // MARK: - Section 3: Wedge Geometry (8 constants)

    /// Base wedge thickness (meters) at display=0
    public static let wedgeBaseThicknessM: Double = 0.008
    /// Minimum wedge thickness (meters) at display≈1
    public static let wedgeMinThicknessM: Double = 0.0005
    /// Thickness decay exponent: thickness = base * (1-display)^exponent
    public static let thicknessDecayExponent: Double = 0.7
    /// Area factor reference (median area normalization)
    public static let areaFactorReference: Double = 1.0
    /// Bevel segments for LOD0
    public static let bevelSegmentsLOD0: Int = 2
    /// Bevel segments for LOD1
    public static let bevelSegmentsLOD1: Int = 1
    /// Bevel radius ratio (fraction of thickness)
    public static let bevelRadiusRatio: Double = 0.15
    /// LOD0 triangles per prism
    public static let lod0TrianglesPerPrism: Int = 44

    // MARK: - Section 4: Metallic Material (6 constants)

    /// Base metallic value
    public static let metallicBase: Double = 0.3
    /// Metallic increase at S3+
    public static let metallicS3Bonus: Double = 0.4
    /// Base roughness
    public static let roughnessBase: Double = 0.6
    /// Roughness decrease at S3+
    public static let roughnessS3Reduction: Double = 0.3
    /// Fresnel F0 for dielectric
    public static let fresnelF0: Double = 0.04
    /// Fresnel F0 for metallic
    public static let fresnelF0Metallic: Double = 0.7

    // MARK: - Section 5: Flip Animation (8 constants)

    /// Flip duration (seconds)
    public static let flipDurationS: Double = 0.5
    /// Flip easing control point 1 X (cubic bezier)
    public static let flipEasingCP1X: Double = 0.34
    /// Flip easing control point 1 Y (overshoot)
    public static let flipEasingCP1Y: Double = 1.56
    /// Flip easing control point 2 X
    public static let flipEasingCP2X: Double = 0.64
    /// Flip easing control point 2 Y
    public static let flipEasingCP2Y: Double = 1.0
    /// Maximum concurrent flips
    public static let flipMaxConcurrent: Int = 20
    /// Flip stagger delay between adjacent triangles (seconds)
    public static let flipStaggerDelayS: Double = 0.03
    /// Minimum display delta to trigger flip
    public static let flipMinDisplayDelta: Double = 0.05

    // MARK: - Section 6: Ripple Propagation (7 constants)

    /// Delay per BFS hop (seconds)
    public static let rippleDelayPerHopS: Double = 0.06
    /// Maximum BFS hops
    public static let rippleMaxHops: Int = 8
    /// Amplitude damping per hop
    public static let rippleDampingPerHop: Double = 0.85
    /// Initial ripple amplitude
    public static let rippleInitialAmplitude: Double = 1.0
    /// Ripple thickness multiplier
    public static let rippleThicknessMultiplier: Double = 0.3
    /// Maximum concurrent ripple waves
    public static let rippleMaxConcurrentWaves: Int = 5
    /// Minimum interval between ripple spawns from same source (seconds)
    public static let rippleMinSpawnIntervalS: Double = 0.5

    // MARK: - Section 7: Haptic & Toast (10 constants)

    /// Haptic debounce interval (seconds)
    public static let hapticDebounceS: Double = 5.0
    /// Maximum haptic events per minute
    public static let hapticMaxPerMinute: Int = 4
    /// Haptic blur threshold — MUST equal QualityThresholds.laplacianBlurThreshold
    public static let hapticBlurThreshold: Double = 120.0
    /// Haptic motion threshold
    public static let hapticMotionThreshold: Double = 0.7
    /// Haptic exposure threshold
    public static let hapticExposureThreshold: Double = 0.2
    /// Toast display duration (seconds)
    public static let toastDurationS: Double = 2.0
    /// Toast accessibility duration (seconds) — VoiceOver users
    public static let toastAccessibilityDurationS: Double = 5.0
    /// Toast background color alpha
    public static let toastBackgroundAlpha: Double = 0.85
    /// Toast corner radius (points)
    public static let toastCornerRadius: Double = 12.0
    /// Toast font size (points)
    public static let toastFontSize: Double = 15.0

    // MARK: - Section 8: Performance & Thermal (8 constants)

    /// Maximum inflight Metal buffers
    public static let kMaxInflightBuffers: Int = 3
    /// Nominal tier: max triangles
    public static let thermalNominalMaxTriangles: Int = 5000
    /// Fair tier: max triangles
    public static let thermalFairMaxTriangles: Int = 3000
    /// Serious tier: max triangles
    public static let thermalSeriousMaxTriangles: Int = 1500
    /// Critical tier: max triangles
    public static let thermalCriticalMaxTriangles: Int = 500
    /// Thermal hysteresis duration (seconds)
    public static let thermalHysteresisS: Double = 10.0
    /// Frame budget overshoot threshold (ratio of target frame time)
    public static let frameBudgetOvershootRatio: Double = 1.2
    /// Frame budget measurement window (frames)
    public static let frameBudgetWindowFrames: Int = 30

    // MARK: - Section 9: Accessibility (4 constants)

    /// Minimum contrast ratio (WCAG 2.1 AAA for toast)
    public static let minContrastRatio: Double = 17.4
    /// VoiceOver announcement delay after haptic (seconds)
    public static let voiceOverDelayS: Double = 0.3
    /// Reduce motion: disable flip animation
    /// v7.0.2: Bool constants are NOT registered in allSpecs (no BoolConstantSpec)
    public static let reduceMotionDisablesFlip: Bool = true
    /// Reduce motion: disable ripple animation
    public static let reduceMotionDisablesRipple: Bool = true

    // MARK: - SSOT Specifications
    // v7.0.2: Only Double/Int constants registered. Bool constants excluded
    //         because AnyConstantSpec has no BoolConstantSpec case.
    //         65 specs registered (all Double/Int constants, 2 Bool constants excluded)

    public static let allSpecs: [AnyConstantSpec] = [
        // Section 1: Grayscale Mapping (8 constants - all Double)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s0ToS1Threshold",
            name: "S0→S1 Threshold",
            unit: .dimensionless,
            category: .quality,
            min: 0.05,
            max: 0.20,
            defaultValue: s0ToS1Threshold,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Display value threshold for S0→S1 transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s1ToS2Threshold",
            name: "S1→S2 Threshold",
            unit: .dimensionless,
            category: .quality,
            min: 0.15,
            max: 0.40,
            defaultValue: s1ToS2Threshold,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Display value threshold for S1→S2 transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s2ToS3Threshold",
            name: "S2→S3 Threshold",
            unit: .dimensionless,
            category: .quality,
            min: 0.40,
            max: 0.70,
            defaultValue: s2ToS3Threshold,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Display value threshold for S2→S3 transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s3ToS4Threshold",
            name: "S3→S4 Threshold",
            unit: .dimensionless,
            category: .quality,
            min: 0.60,
            max: 0.90,
            defaultValue: s3ToS4Threshold,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Display value threshold for S3→S4 transition"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s4ToS5Threshold",
            name: "S4→S5 Threshold",
            unit: .dimensionless,
            category: .quality,
            min: 0.80,
            max: 0.95,
            defaultValue: s4ToS5Threshold,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Display value threshold for S4→S5 transition (white threshold)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s5MinSoftEvidence",
            name: "S5 Minimum Soft Evidence",
            unit: .dimensionless,
            category: .quality,
            min: 0.50,
            max: 0.90,
            defaultValue: s5MinSoftEvidence,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum soft evidence required for S5 state"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.grayscaleGamma",
            name: "Grayscale Interpolation Gamma",
            unit: .dimensionless,
            category: .quality,
            min: 0.5,
            max: 2.5,
            defaultValue: grayscaleGamma,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Gamma correction for continuous grayscale interpolation"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.s4TransparencyAlpha",
            name: "S4 Transparency Alpha",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: s4TransparencyAlpha,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Alpha value for S4 transparency (original color shows through)"
        )),
        
        // Section 2: Border System (8 constants - 7 Double, 1 Int)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderBaseWidthPx",
            name: "Base Border Width",
            unit: .pixels,
            category: .quality,
            min: 2.0,
            max: 10.0,
            defaultValue: borderBaseWidthPx,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Base border width in pixels"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderMinWidthPx",
            name: "Minimum Border Width",
            unit: .pixels,
            category: .quality,
            min: 0.5,
            max: 3.0,
            defaultValue: borderMinWidthPx,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum border width in pixels"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderMaxWidthPx",
            name: "Maximum Border Width",
            unit: .pixels,
            category: .quality,
            min: 8.0,
            max: 20.0,
            defaultValue: borderMaxWidthPx,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Maximum border width in pixels"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderDisplayWeight",
            name: "Border Display Weight",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: borderDisplayWeight,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Weight of display factor in border calculation"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderAreaWeight",
            name: "Border Area Weight",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: borderAreaWeight,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Weight of area factor in border calculation"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderGamma",
            name: "Border Gamma",
            unit: .dimensionless,
            category: .quality,
            min: 1.0,
            max: 2.5,
            defaultValue: borderGamma,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Stevens' Power Law gamma for brightness perception in border calculation"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.borderColorR",
            name: "Border Color Red",
            unit: .dimensionless,
            value: borderColorR,
            documentation: "Border color red component (white RGB 255,255,255)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.borderAlphaAtS0",
            name: "Border Alpha at S0",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: borderAlphaAtS0,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Border alpha value at S0 state (fully opaque)"
        )),
        
        // Section 3: Wedge Geometry (8 constants - 6 Double, 2 Int)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.wedgeBaseThicknessM",
            name: "Base Wedge Thickness",
            unit: .meters,
            category: .quality,
            min: 0.001,
            max: 0.020,
            defaultValue: wedgeBaseThicknessM,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Base wedge thickness in meters at display=0"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.wedgeMinThicknessM",
            name: "Minimum Wedge Thickness",
            unit: .meters,
            category: .quality,
            min: 0.0001,
            max: 0.002,
            defaultValue: wedgeMinThicknessM,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum wedge thickness in meters at display≈1"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.thicknessDecayExponent",
            name: "Thickness Decay Exponent",
            unit: .dimensionless,
            category: .quality,
            min: 0.3,
            max: 1.5,
            defaultValue: thicknessDecayExponent,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Exponent for thickness decay: thickness = base * (1-display)^exponent"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.areaFactorReference",
            name: "Area Factor Reference",
            unit: .dimensionless,
            category: .quality,
            min: 0.5,
            max: 2.0,
            defaultValue: areaFactorReference,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Area factor reference for median area normalization"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.bevelSegmentsLOD0",
            name: "Bevel Segments LOD0",
            unit: .count,
            value: bevelSegmentsLOD0,
            documentation: "Number of bevel segments for LOD0"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.bevelSegmentsLOD1",
            name: "Bevel Segments LOD1",
            unit: .count,
            value: bevelSegmentsLOD1,
            documentation: "Number of bevel segments for LOD1"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.bevelRadiusRatio",
            name: "Bevel Radius Ratio",
            unit: .dimensionless,
            category: .quality,
            min: 0.05,
            max: 0.30,
            defaultValue: bevelRadiusRatio,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Bevel radius as fraction of thickness"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.lod0TrianglesPerPrism",
            name: "LOD0 Triangles Per Prism",
            unit: .count,
            value: lod0TrianglesPerPrism,
            documentation: "Number of triangles per prism at LOD0"
        )),
        
        // Section 4: Metallic Material (6 constants - all Double)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.metallicBase",
            name: "Base Metallic Value",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: metallicBase,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Base metallic value for PBR material"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.metallicS3Bonus",
            name: "Metallic S3 Bonus",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: metallicS3Bonus,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Metallic increase at S3+ state"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.roughnessBase",
            name: "Base Roughness",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: roughnessBase,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Base roughness value for PBR material"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.roughnessS3Reduction",
            name: "Roughness S3 Reduction",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: roughnessS3Reduction,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Roughness decrease at S3+ state"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.fresnelF0",
            name: "Fresnel F0 Dielectric",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: fresnelF0,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Fresnel F0 value for dielectric materials"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.fresnelF0Metallic",
            name: "Fresnel F0 Metallic",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: fresnelF0Metallic,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Fresnel F0 value for metallic materials"
        )),
        
        // Section 5: Flip Animation (8 constants - 6 Double, 2 Int)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipDurationS",
            name: "Flip Duration",
            unit: .seconds,
            category: .quality,
            min: 0.1,
            max: 2.0,
            defaultValue: flipDurationS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Flip animation duration in seconds"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipEasingCP1X",
            name: "Flip Easing Control Point 1 X",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: flipEasingCP1X,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "X coordinate of first easing control point (cubic bezier)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipEasingCP1Y",
            name: "Flip Easing Control Point 1 Y",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 3.0,
            defaultValue: flipEasingCP1Y,
            onExceed: .warn,
            onUnderflow: .clamp,
            documentation: "Y coordinate of first easing control point (overshoot)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipEasingCP2X",
            name: "Flip Easing Control Point 2 X",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: flipEasingCP2X,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "X coordinate of second easing control point"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipEasingCP2Y",
            name: "Flip Easing Control Point 2 Y",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: flipEasingCP2Y,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Y coordinate of second easing control point"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.flipMaxConcurrent",
            name: "Maximum Concurrent Flips",
            unit: .count,
            value: flipMaxConcurrent,
            documentation: "Maximum number of concurrent flip animations"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipStaggerDelayS",
            name: "Flip Stagger Delay",
            unit: .seconds,
            category: .quality,
            min: 0.01,
            max: 0.10,
            defaultValue: flipStaggerDelayS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Delay between adjacent triangle flips in seconds"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.flipMinDisplayDelta",
            name: "Flip Minimum Display Delta",
            unit: .dimensionless,
            category: .quality,
            min: 0.01,
            max: 0.20,
            defaultValue: flipMinDisplayDelta,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum display delta to trigger flip animation"
        )),
        
        // Section 6: Ripple Propagation (7 constants - 6 Double, 1 Int)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.rippleDelayPerHopS",
            name: "Ripple Delay Per Hop",
            unit: .seconds,
            category: .quality,
            min: 0.01,
            max: 0.20,
            defaultValue: rippleDelayPerHopS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Delay per BFS hop in seconds"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.rippleMaxHops",
            name: "Maximum Ripple Hops",
            unit: .count,
            value: rippleMaxHops,
            documentation: "Maximum BFS hops for ripple propagation"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.rippleDampingPerHop",
            name: "Ripple Damping Per Hop",
            unit: .dimensionless,
            category: .quality,
            min: 0.5,
            max: 1.0,
            defaultValue: rippleDampingPerHop,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Amplitude damping factor per hop"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.rippleInitialAmplitude",
            name: "Ripple Initial Amplitude",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 2.0,
            defaultValue: rippleInitialAmplitude,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Initial ripple amplitude"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.rippleThicknessMultiplier",
            name: "Ripple Thickness Multiplier",
            unit: .dimensionless,
            category: .quality,
            min: 0.0,
            max: 1.0,
            defaultValue: rippleThicknessMultiplier,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Thickness multiplier for ripple effect"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.rippleMaxConcurrentWaves",
            name: "Maximum Concurrent Ripple Waves",
            unit: .count,
            value: rippleMaxConcurrentWaves,
            documentation: "Maximum number of concurrent ripple waves"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.rippleMinSpawnIntervalS",
            name: "Ripple Minimum Spawn Interval",
            unit: .seconds,
            category: .quality,
            min: 0.1,
            max: 2.0,
            defaultValue: rippleMinSpawnIntervalS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum interval between ripple spawns from same source"
        )),
        
        // Section 7: Haptic & Toast (10 constants - 7 Double, 3 Int)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.hapticDebounceS",
            name: "Haptic Debounce Interval",
            unit: .seconds,
            category: .performance,
            min: 1.0,
            max: 10.0,
            defaultValue: hapticDebounceS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Haptic debounce interval in seconds"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.hapticMaxPerMinute",
            name: "Maximum Haptic Events Per Minute",
            unit: .count,
            value: hapticMaxPerMinute,
            documentation: "Maximum haptic events per minute"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.hapticBlurThreshold",
            name: "Haptic Blur Threshold",
            unit: .variance,
            category: .quality,
            min: 50.0,
            max: 200.0,
            defaultValue: hapticBlurThreshold,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Haptic blur threshold — MUST equal QualityThresholds.laplacianBlurThreshold"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.hapticMotionThreshold",
            name: "Haptic Motion Threshold",
            unit: .dimensionless,
            category: .motion,
            min: 0.3,
            max: 1.5,
            defaultValue: hapticMotionThreshold,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Haptic motion threshold"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.hapticExposureThreshold",
            name: "Haptic Exposure Threshold",
            unit: .dimensionless,
            category: .photometric,
            min: 0.1,
            max: 0.5,
            defaultValue: hapticExposureThreshold,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Haptic exposure threshold"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.toastDurationS",
            name: "Toast Display Duration",
            unit: .seconds,
            category: .quality,
            min: 1.0,
            max: 5.0,
            defaultValue: toastDurationS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Toast display duration in seconds"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.toastAccessibilityDurationS",
            name: "Toast Accessibility Duration",
            unit: .seconds,
            category: .quality,
            min: 3.0,
            max: 10.0,
            defaultValue: toastAccessibilityDurationS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Toast accessibility duration for VoiceOver users"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.toastBackgroundAlpha",
            name: "Toast Background Alpha",
            unit: .dimensionless,
            category: .quality,
            min: 0.5,
            max: 1.0,
            defaultValue: toastBackgroundAlpha,
            onExceed: .clamp,
            onUnderflow: .clamp,
            documentation: "Toast background color alpha"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.toastCornerRadius",
            name: "Toast Corner Radius",
            unit: .pixels,
            category: .quality,
            min: 4.0,
            max: 20.0,
            defaultValue: toastCornerRadius,
            onExceed: .warn,
            onUnderflow: .warn,
            documentation: "Toast corner radius in points"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.toastFontSize",
            name: "Toast Font Size",
            unit: .pixels,
            category: .quality,
            min: 12.0,
            max: 20.0,
            defaultValue: toastFontSize,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Toast font size in points"
        )),
        
        // Section 8: Performance & Thermal (8 constants - 3 Double, 5 Int)
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.kMaxInflightBuffers",
            name: "Maximum Inflight Metal Buffers",
            unit: .count,
            value: kMaxInflightBuffers,
            documentation: "Maximum inflight Metal buffers for triple buffering"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.thermalNominalMaxTriangles",
            name: "Thermal Nominal Max Triangles",
            unit: .count,
            value: thermalNominalMaxTriangles,
            documentation: "Maximum triangles at nominal thermal tier"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.thermalFairMaxTriangles",
            name: "Thermal Fair Max Triangles",
            unit: .count,
            value: thermalFairMaxTriangles,
            documentation: "Maximum triangles at fair thermal tier"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.thermalSeriousMaxTriangles",
            name: "Thermal Serious Max Triangles",
            unit: .count,
            value: thermalSeriousMaxTriangles,
            documentation: "Maximum triangles at serious thermal tier"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.thermalCriticalMaxTriangles",
            name: "Thermal Critical Max Triangles",
            unit: .count,
            value: thermalCriticalMaxTriangles,
            documentation: "Maximum triangles at critical thermal tier"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.thermalHysteresisS",
            name: "Thermal Hysteresis Duration",
            unit: .seconds,
            category: .performance,
            min: 5.0,
            max: 30.0,
            defaultValue: thermalHysteresisS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Thermal hysteresis duration in seconds"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.frameBudgetOvershootRatio",
            name: "Frame Budget Overshoot Ratio",
            unit: .dimensionless,
            category: .performance,
            min: 1.0,
            max: 2.0,
            defaultValue: frameBudgetOvershootRatio,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Frame budget overshoot threshold as ratio of target frame time"
        )),
        .systemConstant(SystemConstantSpec(
            ssotId: "ScanGuidanceConstants.frameBudgetWindowFrames",
            name: "Frame Budget Measurement Window",
            unit: .frames,
            value: frameBudgetWindowFrames,
            documentation: "Frame budget measurement window in frames"
        )),
        
        // Section 9: Accessibility (2 constants - both Double, Bool constants excluded)
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.minContrastRatio",
            name: "Minimum Contrast Ratio",
            unit: .dimensionless,
            category: .quality,
            min: 4.5,
            max: 21.0,
            defaultValue: minContrastRatio,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "Minimum contrast ratio (WCAG 2.1 AAA for toast)"
        )),
        .threshold(ThresholdSpec(
            ssotId: "ScanGuidanceConstants.voiceOverDelayS",
            name: "VoiceOver Announcement Delay",
            unit: .seconds,
            category: .quality,
            min: 0.1,
            max: 1.0,
            defaultValue: voiceOverDelayS,
            onExceed: .warn,
            onUnderflow: .reject,
            documentation: "VoiceOver announcement delay after haptic in seconds"
        ))
        // Bool constants (reduceMotionDisablesFlip, reduceMotionDisablesRipple) NOT included
        // because AnyConstantSpec has no BoolConstantSpec case.
    ]

    // MARK: - Cross-Validation

    public static func validateRelationships() -> [String] {
        var errors: [String] = []
        if hapticBlurThreshold != QualityThresholds.laplacianBlurThreshold {
            errors.append("hapticBlurThreshold (\(hapticBlurThreshold)) != QualityThresholds.laplacianBlurThreshold (\(QualityThresholds.laplacianBlurThreshold))")
        }
        let thresholds = [s0ToS1Threshold, s1ToS2Threshold, s2ToS3Threshold, s3ToS4Threshold, s4ToS5Threshold]
        for i in 1..<thresholds.count {
            if thresholds[i] <= thresholds[i-1] {
                errors.append("S-thresholds not monotonic at index \(i)")
            }
        }
        return errors
    }
}
