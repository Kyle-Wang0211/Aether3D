// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_CAPTURE_FRAME_SEQUENCE_H
#define AETHER_CAPTURE_FRAME_SEQUENCE_H

#ifdef __cplusplus

#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "aether/core/status.h"

namespace aether {
namespace capture {

// ═══════════════════════════════════════════════════════════════════════
// FrameRecord: Metadata for a selected training/test frame
// ═══════════════════════════════════════════════════════════════════════

struct FrameRecord {
    std::uint32_t index;           // Sequential frame index
    double timestamp;              // Monotonic seconds
    float transform[16];           // Column-major 4x4 camera-to-world
    float intrinsics[4];           // [fx, fy, cx, cy]
    float quality_score;           // Evidence quality [0, 1]
    float blur_score;              // Sharpness [0, 1]
    char image_path[256];          // Path to JPEG on disk
    bool is_test_frame;            // Holdout for quality evaluation
};

// ═══════════════════════════════════════════════════════════════════════
// Frame Sequence I/O: Binary serialization for checkpoint/resume
// ═══════════════════════════════════════════════════════════════════════

/// Binary format:
///   [4 bytes] magic: "AFSQ"
///   [4 bytes] version: 1
///   [4 bytes] record_count
///   [4 bytes] reserved
///   [N * sizeof(FrameRecord)] records

constexpr std::uint32_t kFrameSequenceMagic = 0x51534641u;  // "AFSQ"
constexpr std::uint32_t kFrameSequenceVersion = 1u;

struct FrameSequenceHeader {
    std::uint32_t magic;
    std::uint32_t version;
    std::uint32_t record_count;
    std::uint32_t reserved;
};

/// Write frame sequence to binary file.
inline core::Status write_frame_sequence(
    const char* path,
    const FrameRecord* records,
    std::size_t count) noexcept
{
    std::FILE* f = std::fopen(path, "wb");
    if (!f) return core::Status::kInvalidArgument;

    FrameSequenceHeader header{};
    header.magic = kFrameSequenceMagic;
    header.version = kFrameSequenceVersion;
    header.record_count = static_cast<std::uint32_t>(count);
    header.reserved = 0;

    if (std::fwrite(&header, sizeof(header), 1, f) != 1) {
        std::fclose(f);
        return core::Status::kResourceExhausted;
    }

    if (count > 0) {
        if (std::fwrite(records, sizeof(FrameRecord), count, f) != count) {
            std::fclose(f);
            return core::Status::kResourceExhausted;
        }
    }

    std::fclose(f);
    return core::Status::kOk;
}

/// Read frame sequence from binary file.
inline core::Status read_frame_sequence(
    const char* path,
    std::vector<FrameRecord>& out) noexcept
{
    out.clear();

    std::FILE* f = std::fopen(path, "rb");
    if (!f) return core::Status::kInvalidArgument;

    FrameSequenceHeader header{};
    if (std::fread(&header, sizeof(header), 1, f) != 1) {
        std::fclose(f);
        return core::Status::kInvalidArgument;
    }

    if (header.magic != kFrameSequenceMagic ||
        header.version != kFrameSequenceVersion) {
        std::fclose(f);
        return core::Status::kInvalidArgument;
    }

    if (header.record_count == 0) {
        std::fclose(f);
        return core::Status::kOk;
    }

    out.resize(header.record_count);
    if (std::fread(out.data(), sizeof(FrameRecord),
                   header.record_count, f) != header.record_count) {
        out.clear();
        std::fclose(f);
        return core::Status::kInvalidArgument;
    }

    std::fclose(f);
    return core::Status::kOk;
}

}  // namespace capture
}  // namespace aether

#endif  // __cplusplus

#endif  // AETHER_CAPTURE_FRAME_SEQUENCE_H
