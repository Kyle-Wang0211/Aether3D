// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Null depth inference engine for headless / test builds.
// Returns an engine that reports is_available() == false,
// so PipelineCoordinator skips Neural-Engine depth and relies
// on LiDAR depth passed via on_frame().

#include "aether/pipeline/depth_inference_engine.h"

namespace aether {
namespace pipeline {

namespace {

class NullDepthInferenceEngine final : public DepthInferenceEngine {
public:
    NullDepthInferenceEngine() = default;

    core::Status infer(const std::uint8_t* /*rgba*/,
                       std::uint32_t /*w*/, std::uint32_t /*h*/,
                       DepthInferenceResult& /*out*/) noexcept override {
        return core::Status::kResourceExhausted;
    }

    void submit_async(const std::uint8_t* /*rgba*/,
                      std::uint32_t /*w*/,
                      std::uint32_t /*h*/) noexcept override {}

    bool poll_result(DepthInferenceResult& /*out*/) noexcept override {
        return false;
    }

    bool is_available() const noexcept override { return false; }

    const char* model_name() const noexcept override { return "Null"; }
};

}  // namespace

std::unique_ptr<DepthInferenceEngine> create_depth_inference_engine(
    const char* /*model_path*/, const char* /*name*/) noexcept {
    return std::make_unique<NullDepthInferenceEngine>();
}

}  // namespace pipeline
}  // namespace aether
