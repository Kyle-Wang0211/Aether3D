//
// AdaptiveBorderCalculator.swift
// Aether3D
//
// PR#7 Scan Guidance UI — Adaptive Border Calculator
// Border formula + persistent non-rollback state are resolved in core C++ runtime.
//

import Foundation
import CAetherNativeBridge

/// Calculates adaptive border widths based on display value and triangle area.
public final class AdaptiveBorderCalculator {
    private let nativeStyleRuntime: OpaquePointer?

    public init() {
        var config = aether_capture_style_runtime_config_t()
        var runtime: OpaquePointer?
        if aether_capture_style_runtime_default_config(&config) == 0 {
            config.smoothing_alpha = 0.2
            config.freeze_threshold = Float(ScanGuidanceConstants.s3ToS4Threshold)
            config.min_thickness = Float(ScanGuidanceConstants.wedgeMinThicknessM)
            config.max_thickness = Float(ScanGuidanceConstants.wedgeBaseThicknessM)
            config.min_border_width = Float(ScanGuidanceConstants.borderMinWidthPx)
            config.max_border_width = Float(ScanGuidanceConstants.borderMaxWidthPx)
            if aether_capture_style_runtime_create(&config, &runtime) == 0 {
                self.nativeStyleRuntime = runtime
            } else {
                self.nativeStyleRuntime = nil
            }
        } else {
            self.nativeStyleRuntime = nil
        }
    }

    deinit {
        if let nativeStyleRuntime {
            _ = aether_capture_style_runtime_destroy(nativeStyleRuntime)
        }
    }

    public func resetPersistentBorderState() {
        if let nativeStyleRuntime {
            _ = aether_capture_style_runtime_reset(nativeStyleRuntime)
        }
    }

    public func calculate(
        displayValues: [String: Double],
        triangles: [ScanTriangle],
        medianArea: Float
    ) -> [Float] {
        guard !triangles.isEmpty else {
            return []
        }

        let minWidth = Float(ScanGuidanceConstants.borderMinWidthPx)
        let maxWidth = Float(ScanGuidanceConstants.borderMaxWidthPx)

        guard let nativeStyleRuntime else {
            return triangles.map { triangle in
                calculate(
                    display: displayValues[triangle.patchId] ?? 0.0,
                    areaSqM: triangle.areaSqM,
                    medianArea: medianArea
                )
            }
        }

        var styleInputs = [aether_capture_style_input_t](
            repeating: aether_capture_style_input_t(),
            count: triangles.count
        )
        for (index, triangle) in triangles.enumerated() {
            styleInputs[index].patch_key = stablePatchKey(triangle.patchId)
            styleInputs[index].display = Float(min(max(displayValues[triangle.patchId] ?? 0.0, 0.0), 1.0))
            styleInputs[index].area_sq_m = max(triangle.areaSqM, 1e-8)
        }

        var styleOutputs = [aether_capture_style_output_t](
            repeating: aether_capture_style_output_t(),
            count: triangles.count
        )
        let rc = styleInputs.withUnsafeBufferPointer { inputBuffer in
            styleOutputs.withUnsafeMutableBufferPointer { outputBuffer in
                aether_capture_style_runtime_resolve(
                    nativeStyleRuntime,
                    inputBuffer.baseAddress,
                    Int32(styleInputs.count),
                    outputBuffer.baseAddress
                )
            }
        }
        guard rc == 0 else {
            return triangles.map { triangle in
                calculate(
                    display: displayValues[triangle.patchId] ?? 0.0,
                    areaSqM: triangle.areaSqM,
                    medianArea: medianArea
                )
            }
        }

        return styleOutputs.map { output in
            min(max(output.border_width, minWidth), maxWidth)
        }
    }

    public func calculate(
        display: Double,
        areaSqM: Float,
        medianArea: Float
    ) -> Float {
        let clampedDisplay = Float(min(max(display, 0.0), 1.0))
        if let native = calculateNative(
            display: clampedDisplay,
            areaSqM: areaSqM,
            medianArea: medianArea
        ) {
            return native
        }
        return Float(ScanGuidanceConstants.borderMinWidthPx)
    }

    private func calculateNative(
        display: Float,
        areaSqM: Float,
        medianArea: Float
    ) -> Float? {
        var params = aether_fragment_visual_params_t()
        let rc = aether_compute_fragment_visual_params(
            display,
            1.0,
            max(areaSqM, 1e-8),
            max(medianArea, 1e-6),
            &params
        )
        guard rc == 0, params.border_width_px.isFinite else {
            return nil
        }

        let minWidth = Float(ScanGuidanceConstants.borderMinWidthPx)
        let maxWidth = Float(ScanGuidanceConstants.borderMaxWidthPx)
        return min(max(params.border_width_px, minWidth), maxWidth)
    }

    private func stablePatchKey(_ patchId: String) -> UInt64 {
        let bytes = Array(patchId.utf8)
        let count = Int32(min(bytes.count, Int(Int32.max)))
        var hash: UInt64 = 0
        let rc = bytes.withUnsafeBufferPointer { buffer in
            aether_hash_fnv1a64(
                buffer.baseAddress,
                count,
                &hash
            )
        }
        if rc == 0 {
            return hash
        }
        var fallback: UInt64 = BridgeInteropConstants.fnv1a64OffsetBasis
        for byte in bytes {
            fallback ^= UInt64(byte)
            fallback &*= BridgeInteropConstants.fnv1a64Prime
        }
        return fallback
    }
}
