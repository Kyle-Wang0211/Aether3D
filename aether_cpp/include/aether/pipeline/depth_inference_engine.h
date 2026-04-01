// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_PIPELINE_DEPTH_INFERENCE_ENGINE_H
#define AETHER_PIPELINE_DEPTH_INFERENCE_ENGINE_H

#ifdef __cplusplus

#include <cstdint>
#include <cstddef>
#include <memory>
#include <vector>

#include "aether/core/status.h"

namespace aether {
namespace pipeline {

// ═══════════════════════════════════════════════════════════════════════
// DepthInferenceEngine: Neural monocular depth estimation (DAv2)
// ═══════════════════════════════════════════════════════════════════════
// Abstract interface for depth inference, implemented per-platform:
//   iOS:     CoreML + Neural Engine  (~10ms on A14, ~25ms on A16)
//   Android: TFLite + NNAPI          (future)
//   macOS:   CoreML + GPU            (development)
//
// Provides both synchronous and asynchronous inference paths.
// Asynchronous path: submit_async() + poll_result() — non-blocking.
// The async path coalesces to the latest pending frame while one inference
// is in-flight, so imported-video local preview can stay streaming without
// unbounded queue growth.
//
// Output: relative depth map ∈ [0, 1], row-major, float32.
// Relative depth must be converted to metric depth via scale alignment
// before use in 3D reconstruction (see dav2_initializer.h).
//
// Thread safety:
//   submit_async()  — any thread (internally serialized)
//   poll_result()   — any thread (atomic pointer swap)
//   infer()         — blocking, caller's thread
//   is_available()  — any thread (const, set at construction)

/// Result of depth inference.
///
/// is_metric=false (default): depth_map is relative disparity [0,1] (relative DAv2)
///   → requires affine calibration in pipeline_coordinator to convert to meters
///
/// is_metric=true: depth_map values are absolute metric depth in METERS (metric DAv2 / Metric3D)
///   → use directly as depth source with depth_is_metric=true, no affine calibration needed
///   → auto-detected when model output max > 1.5f (well above normalized [0,1] range)
///   → WildGS-SLAM: "dpt2_vitl_hypersim_20" returns 0-20m, Metric3D returns fx/1000 * raw
///
/// References: WildGS-SLAM (metric_depth_estimators.py), GigaSLAM (UniDepth V2)
struct DepthInferenceResult {
    std::vector<float> depth_map;   // Depth values: [0,1] if !is_metric, meters if is_metric
    std::uint32_t width{0};         // Output width  (model-dependent, typically 518)
    std::uint32_t height{0};        // Output height (model-dependent, typically 518)
    bool is_metric{false};          // true = values are absolute meters (metric model detected)
};

/// Abstract depth inference engine.
class DepthInferenceEngine {
public:
    virtual ~DepthInferenceEngine() = default;

    // Non-copyable
    DepthInferenceEngine(const DepthInferenceEngine&) = delete;
    DepthInferenceEngine& operator=(const DepthInferenceEngine&) = delete;

    // ─── Synchronous Inference ───

    /// Run inference synchronously on the caller's thread.
    /// Blocks for ~10-30ms depending on device.
    /// @param rgba     Input image, RGBA format, row-major.
    /// @param w        Image width in pixels.
    /// @param h        Image height in pixels.
    /// @param out      Output depth result.
    /// @return kOk on success, kResourceExhausted if model unavailable.
    virtual core::Status infer(
        const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
        DepthInferenceResult& out) noexcept = 0;

    // ─── Asynchronous Inference ───

    /// Submit a frame for asynchronous inference.
    /// Non-blocking: returns immediately. If a previous inference is still
    /// in-flight, the engine keeps only the latest pending frame and runs it
    /// next on the serial queue (latest-frame coalescing, no unbounded growth).
    /// @param rgba     Input image, RGBA format, row-major (copied internally).
    /// @param w        Image width in pixels.
    /// @param h        Image height in pixels.
    virtual void submit_async(
        const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept = 0;

    /// Poll the latest asynchronous result.
    /// Non-blocking. Returns true if a new result is available since the last poll.
    /// @param out      Filled with result if available.
    /// @return true if new result available, false otherwise.
    virtual bool poll_result(DepthInferenceResult& out) noexcept = 0;

    // ─── Queries ───

    /// Check if the inference engine is available (model loaded successfully).
    virtual bool is_available() const noexcept = 0;

    /// Model input resolution (width). Auto-detected from model spec at load time.
    virtual std::uint32_t model_input_width() const noexcept { return 518; }

    /// Model input resolution (height). Auto-detected from model spec at load time.
    virtual std::uint32_t model_input_height() const noexcept { return 518; }

    /// Model name for logging (e.g., "DAv2-Small", "DAv2-Large").
    virtual const char* model_name() const noexcept { return "DAv2"; }

    // Legacy compat
    std::uint32_t model_input_size() const noexcept {
        return std::max(model_input_width(), model_input_height());
    }

protected:
    DepthInferenceEngine() = default;
};

// ─── Factory ───

/// Create a platform-specific depth inference engine.
/// @param model_path  Path to the compiled model:
///                    iOS/macOS: .mlmodelc directory path
///                    Android:   .tflite file path (future)
/// @param name        Optional human-readable name for logging (e.g., "Small", "Large").
///                    If nullptr, auto-detected from model metadata.
/// @return Non-null engine on success; engine->is_available() may be false
///         if model loading fails. Returns nullptr only on allocation failure.
std::unique_ptr<DepthInferenceEngine> create_depth_inference_engine(
    const char* model_path, const char* name = nullptr) noexcept;

}  // namespace pipeline
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_PIPELINE_DEPTH_INFERENCE_ENGINE_H
