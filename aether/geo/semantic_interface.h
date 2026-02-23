// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 6: Semantic Interface Definitions (abstract, no implementation)
// These interfaces define the contract for future semantic segmentation
// integration with the GeoEngine.  Track-A implementations will be
// provided by SAGOnline, UniC-Lift, and LatentAM modules.

#ifndef AETHER_GEO_SEMANTIC_INTERFACE_H
#define AETHER_GEO_SEMANTIC_INTERFACE_H

#include "aether/core/status.h"

#include <cstddef>
#include <cstdint>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Semantic class definitions
// ---------------------------------------------------------------------------
enum class SemanticClass : std::uint8_t {
    kUnknown       = 0,
    kBuilding      = 1,
    kVegetation    = 2,
    kGround        = 3,
    kRoad          = 4,
    kWater         = 5,
    kVehicle       = 6,
    kPerson        = 7,
    kSky           = 8,
    kInfrastructure = 9,
    kFurniture     = 10,
    kCount         = 11,
};

// ---------------------------------------------------------------------------
// SAGOnline: Online Semantic-Aware Gaussian Segmentation
// ---------------------------------------------------------------------------
struct SAGOnlineConfig {
    std::uint32_t max_gaussians{100000};
    float confidence_threshold{0.7f};
    bool enable_temporal_consistency{true};
};

/// Abstract interface for SAGOnline segmentation.
/// Implementors provide per-Gaussian semantic class prediction.
struct SAGOnlineInterface {
    virtual ~SAGOnlineInterface() = default;

    /// Predict semantic class for a Gaussian given its color/position features.
    virtual core::Status predict(const float* position,  // [3]
                                 const float* color,     // [3]
                                 const float* scale,     // [3]
                                 SemanticClass* out_class,
                                 float* out_confidence) = 0;

    /// Batch predict for multiple Gaussians.
    virtual core::Status predict_batch(const float* positions,
                                       const float* colors,
                                       const float* scales,
                                       std::size_t count,
                                       SemanticClass* out_classes,
                                       float* out_confidences) = 0;
};

// ---------------------------------------------------------------------------
// UniC-Lift: Lifting 2D Semantics to 3D Gaussians
// ---------------------------------------------------------------------------
struct UniCLiftConfig {
    std::uint32_t image_width{0};
    std::uint32_t image_height{0};
    float projection_matrix[16]{};    // 4x4 camera projection
};

/// Abstract interface for UniC-Lift 2D→3D semantic lifting.
struct UniCLiftInterface {
    virtual ~UniCLiftInterface() = default;

    /// Lift 2D semantic mask to 3D Gaussian labels.
    virtual core::Status lift(const SemanticClass* mask_2d,
                              std::uint32_t width, std::uint32_t height,
                              const float* projection,       // [16]
                              const float* gaussian_positions, // [N*3]
                              std::size_t gaussian_count,
                              SemanticClass* out_labels) = 0;
};

// ---------------------------------------------------------------------------
// LatentAM: Latent Appearance Model for appearance-based segmentation
// ---------------------------------------------------------------------------
struct LatentAMConfig {
    std::uint32_t latent_dim{32};
    float regularization{0.01f};
};

/// Abstract interface for LatentAM appearance model.
struct LatentAMInterface {
    virtual ~LatentAMInterface() = default;

    /// Encode Gaussian appearance to latent space.
    virtual core::Status encode(const float* color,    // [3]
                                const float* opacity,   // [1]
                                float* out_latent,      // [latent_dim]
                                std::uint32_t latent_dim) = 0;

    /// Cluster latent vectors into semantic groups.
    virtual core::Status cluster(const float* latent_vectors,   // [N * latent_dim]
                                 std::size_t count,
                                 std::uint32_t latent_dim,
                                 SemanticClass* out_labels) = 0;
};

// ---------------------------------------------------------------------------
// Semantic physics discount lookup
// ---------------------------------------------------------------------------
inline float semantic_physics_discount(SemanticClass cls) {
    switch (cls) {
        case SemanticClass::kBuilding:       return 0.1f;   // Buildings don't move
        case SemanticClass::kVegetation:     return 0.3f;   // Seasonal color changes
        case SemanticClass::kVehicle:        return 0.05f;  // Vehicles are transient
        case SemanticClass::kPerson:         return 0.01f;  // People are transient
        case SemanticClass::kGround:         return 0.15f;
        case SemanticClass::kRoad:           return 0.12f;
        case SemanticClass::kInfrastructure: return 0.1f;
        default:                             return 0.5f;   // Unknown → moderate discount
    }
}

}  // namespace geo
}  // namespace aether

#endif  // AETHER_GEO_SEMANTIC_INTERFACE_H
