// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// Phase 0: Binary fixture replay runner.

#include "aether/crypto/sha256.h"
#include "aether/core/canonicalize.h"
#include "aether_tsdf_c.h"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr uint16_t kFixtureSchemaVersion = 1;
constexpr uint16_t kReplayPayloadVersion = 1;
constexpr uint16_t kReplayKindTsdfIntegrate = 1;
constexpr uint16_t kReplayKindSha256Input = 2;
constexpr uint16_t kReplayKindCanonicalizeBlock = 3;

struct FixtureHeader {
    uint8_t magic[4];
    uint16_t schema_version;
    uint16_t fixture_type;
    uint32_t payload_size;
    uint8_t constants_hash[8];
    uint8_t compiler_tag[4];
    uint8_t arch_tag[2];
    uint8_t reserved[2];
    uint8_t payload_hash[8];
};
static_assert(sizeof(FixtureHeader) == 36, "FixtureHeader size must be 36 bytes");

struct ReplayEnvelope {
    uint16_t version;
    uint16_t kind;
    uint32_t input_size;
    uint32_t expected_size;
};

bool read_file_bytes(const fs::path& path, std::vector<uint8_t>& out) {
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    in.seekg(0, std::ios::end);
    const std::streamoff size = in.tellg();
    if (size < 0) return false;
    in.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(size));
    if (!out.empty()) {
        in.read(reinterpret_cast<char*>(out.data()), static_cast<std::streamsize>(out.size()));
    }
    return static_cast<bool>(in);
}

bool write_file_bytes(const fs::path& path, const std::vector<uint8_t>& bytes) {
    std::error_code ec;
    fs::create_directories(path.parent_path(), ec);
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    if (!bytes.empty()) {
        out.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
    }
    return static_cast<bool>(out);
}

uint16_t load_u16_le(const uint8_t* p) {
    return static_cast<uint16_t>(p[0] | (static_cast<uint16_t>(p[1]) << 8U));
}

uint32_t load_u32_le(const uint8_t* p) {
    return static_cast<uint32_t>(p[0]) |
           (static_cast<uint32_t>(p[1]) << 8U) |
           (static_cast<uint32_t>(p[2]) << 16U) |
           (static_cast<uint32_t>(p[3]) << 24U);
}

int32_t load_i32_le(const uint8_t* p) {
    return static_cast<int32_t>(load_u32_le(p));
}

float load_f32_le(const uint8_t* p) {
    const uint32_t bits = load_u32_le(p);
    float out = 0.0f;
    std::memcpy(&out, &bits, sizeof(float));
    return out;
}

bool parse_fixture_header(const std::vector<uint8_t>& bytes, FixtureHeader& header, const uint8_t*& payload, size_t& payload_size) {
    if (bytes.size() < sizeof(FixtureHeader)) return false;
    std::memcpy(&header, bytes.data(), sizeof(FixtureHeader));
    header.schema_version = load_u16_le(reinterpret_cast<const uint8_t*>(&header.schema_version));
    header.fixture_type = load_u16_le(reinterpret_cast<const uint8_t*>(&header.fixture_type));
    header.payload_size = load_u32_le(reinterpret_cast<const uint8_t*>(&header.payload_size));
    if (bytes.size() < sizeof(FixtureHeader) + header.payload_size) return false;
    payload = bytes.data() + sizeof(FixtureHeader);
    payload_size = static_cast<size_t>(header.payload_size);
    return true;
}

std::array<uint8_t, 8> constants_hash8_from_repo(const fs::path& repo_root) {
    std::array<uint8_t, 8> out{};
    std::vector<uint8_t> bytes;
    if (!read_file_bytes(repo_root / "governance" / "code_bindings.json", bytes)) {
        return out;
    }
    aether::crypto::Sha256Digest digest{};
    if (!bytes.empty()) {
        aether::crypto::sha256(bytes.data(), bytes.size(), digest);
    } else {
        aether::crypto::sha256(nullptr, 0, digest);
    }
    for (size_t i = 0; i < out.size(); ++i) out[i] = digest.bytes[i];
    return out;
}

std::array<uint8_t, 8> hash8_payload(const uint8_t* payload, size_t size) {
    std::array<uint8_t, 8> out{};
    aether::crypto::Sha256Digest digest{};
    aether::crypto::sha256(payload, size, digest);
    for (size_t i = 0; i < out.size(); ++i) out[i] = digest.bytes[i];
    return out;
}

bool parse_replay_envelope(const uint8_t* payload, size_t payload_size, ReplayEnvelope& env, const uint8_t*& input, const uint8_t*& expected) {
    if (payload_size < 12) return false;
    env.version = load_u16_le(payload + 0);
    env.kind = load_u16_le(payload + 2);
    env.input_size = load_u32_le(payload + 4);
    env.expected_size = load_u32_le(payload + 8);

    const size_t total = 12ULL + static_cast<size_t>(env.input_size) + static_cast<size_t>(env.expected_size);
    if (payload_size != total) return false;
    input = payload + 12;
    expected = input + env.input_size;
    return true;
}

bool replay_kind_tsdf(const uint8_t* input, uint32_t input_size, const uint8_t* expected, uint32_t expected_size, std::string& err) {
    if (expected_size != 13) {
        err = "tsdf expected payload size mismatch";
        return false;
    }
    if (input_size < (4U + 4U + 4U * 5U + 4U * 16U)) {
        err = "tsdf input payload too small";
        return false;
    }

    size_t off = 0;
    const int width = static_cast<int>(load_u32_le(input + off)); off += 4;
    const int height = static_cast<int>(load_u32_le(input + off)); off += 4;
    const float voxel_size = load_f32_le(input + off); off += 4;
    const float fx = load_f32_le(input + off); off += 4;
    const float fy = load_f32_le(input + off); off += 4;
    const float cx = load_f32_le(input + off); off += 4;
    const float cy = load_f32_le(input + off); off += 4;

    if (width <= 0 || height <= 0) {
        err = "tsdf width/height invalid in fixture input";
        return false;
    }

    const size_t depth_count = static_cast<size_t>(width) * static_cast<size_t>(height);
    const size_t need = (4U + 4U + 4U * 5U + 4U * 16U + depth_count * 4U);
    if (input_size != need) {
        err = "tsdf input payload size does not match width/height";
        return false;
    }

    std::vector<float> view(16, 0.0f);
    for (size_t i = 0; i < 16; ++i) {
        view[i] = load_f32_le(input + off);
        off += 4;
    }

    std::vector<float> depth(depth_count, 0.0f);
    for (size_t i = 0; i < depth_count; ++i) {
        depth[i] = load_f32_le(input + off);
        off += 4;
    }

    const int32_t expected_rc = load_i32_le(expected + 0);
    const int32_t expected_voxels = load_i32_le(expected + 4);
    const int32_t expected_blocks = load_i32_le(expected + 8);
    const uint8_t expected_success = expected[12];

    aether_integration_input_t api_in{};
    api_in.depth_data = depth.data();
    api_in.depth_width = width;
    api_in.depth_height = height;
    api_in.voxel_size = voxel_size;
    api_in.fx = fx;
    api_in.fy = fy;
    api_in.cx = cx;
    api_in.cy = cy;
    api_in.view_matrix = view.data();

    aether_integration_result_t api_out{};
    const int rc = aether_tsdf_integrate(&api_in, &api_out);

    if (rc != expected_rc) {
        err = "tsdf replay rc mismatch";
        return false;
    }
    if (api_out.voxels_integrated != expected_voxels) {
        err = "tsdf replay voxels_integrated mismatch";
        return false;
    }
    if (api_out.blocks_updated != expected_blocks) {
        err = "tsdf replay blocks_updated mismatch";
        return false;
    }
    if (static_cast<uint8_t>(api_out.success) != expected_success) {
        err = "tsdf replay success mismatch";
        return false;
    }
    return true;
}

bool replay_kind_sha256(const uint8_t* input, uint32_t input_size, const uint8_t* expected, uint32_t expected_size, std::string& err) {
    if (expected_size != 32) {
        err = "sha256 replay expected size must be 32";
        return false;
    }
    aether::crypto::Sha256Digest digest{};
    aether::crypto::sha256(input, static_cast<size_t>(input_size), digest);
    if (std::memcmp(digest.bytes, expected, 32) != 0) {
        err = "sha256 replay digest mismatch";
        return false;
    }
    return true;
}

bool replay_kind_canonicalize(const uint8_t* input, uint32_t input_size, const uint8_t* expected, uint32_t expected_size, std::string& err) {
    if (input_size != 12 || expected_size != 12) {
        err = "canonicalize replay payload size mismatch";
        return false;
    }
    const int32_t x = load_i32_le(input + 0);
    const int32_t y = load_i32_le(input + 4);
    const int32_t z = load_i32_le(input + 8);
    int32_t ox = 0, oy = 0, oz = 0;
    aether::core::canonicalize_block(x, y, z, ox, oy, oz);
    if (ox != load_i32_le(expected + 0) || oy != load_i32_le(expected + 4) || oz != load_i32_le(expected + 8)) {
        err = "canonicalize replay output mismatch";
        return false;
    }
    return true;
}

bool run_replay_for_file(const fs::path& file, const fs::path& repo_root, const fs::path& output_dir, std::string& err) {
    std::vector<uint8_t> bytes;
    if (!read_file_bytes(file, bytes)) {
        err = "failed to read fixture file";
        return false;
    }

    FixtureHeader header{};
    const uint8_t* payload = nullptr;
    size_t payload_size = 0;
    if (!parse_fixture_header(bytes, header, payload, payload_size)) {
        err = "invalid fixture header or payload bounds";
        return false;
    }

    if (!(header.magic[0] == 'A' && header.magic[1] == 'E' && header.magic[2] == '3' && header.magic[3] == 'D')) {
        err = "invalid magic";
        return false;
    }
    if (header.schema_version != kFixtureSchemaVersion) {
        err = "schema_version mismatch";
        return false;
    }

    const auto expected_constants_hash = constants_hash8_from_repo(repo_root);
    if (std::memcmp(header.constants_hash, expected_constants_hash.data(), expected_constants_hash.size()) != 0) {
        err = "constants_hash mismatch";
        return false;
    }

    const auto expected_payload_hash = hash8_payload(payload, payload_size);
    if (std::memcmp(header.payload_hash, expected_payload_hash.data(), expected_payload_hash.size()) != 0) {
        err = "payload_hash mismatch";
        return false;
    }

    ReplayEnvelope env{};
    const uint8_t* input = nullptr;
    const uint8_t* expected = nullptr;
    if (!parse_replay_envelope(payload, payload_size, env, input, expected)) {
        err = "invalid replay envelope";
        return false;
    }
    if (env.version != kReplayPayloadVersion) {
        err = "replay payload version mismatch";
        return false;
    }

    bool ok = false;
    switch (env.kind) {
    case kReplayKindTsdfIntegrate:
        ok = replay_kind_tsdf(input, env.input_size, expected, env.expected_size, err);
        break;
    case kReplayKindSha256Input:
        ok = replay_kind_sha256(input, env.input_size, expected, env.expected_size, err);
        break;
    case kReplayKindCanonicalizeBlock:
        ok = replay_kind_canonicalize(input, env.input_size, expected, env.expected_size, err);
        break;
    default:
        err = "unsupported replay kind";
        return false;
    }
    if (!ok) return false;

    const fs::path out_file = output_dir / file.filename();
    if (!output_dir.empty() && !write_file_bytes(out_file, bytes)) {
        err = "failed to write golden_output fixture copy";
        return false;
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    fs::path fixtures_dir = fs::path(AETHER_REPO_ROOT) / "fixtures";
    fs::path repo_root = fs::path(AETHER_REPO_ROOT);
    fs::path output_dir = fs::path(AETHER_REPO_ROOT) / "aether_cpp" / "build" / "golden_output";

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--fixtures-dir" && i + 1 < argc) {
            fixtures_dir = fs::path(argv[++i]);
        } else if (arg == "--repo-root" && i + 1 < argc) {
            repo_root = fs::path(argv[++i]);
        } else if (arg == "--output-dir" && i + 1 < argc) {
            output_dir = fs::path(argv[++i]);
        }
    }

    std::error_code ec;
    std::vector<fs::path> files;
    fs::recursive_directory_iterator it(fixtures_dir, ec);
    fs::recursive_directory_iterator end;
    if (ec) {
        std::fprintf(stderr, "fixture replay: unable to iterate %s: %s\n",
                     fixtures_dir.string().c_str(), ec.message().c_str());
        return 1;
    }
    for (; it != end; it.increment(ec)) {
        if (ec) {
            std::fprintf(stderr, "fixture replay iterator error: %s\n", ec.message().c_str());
            return 1;
        }
        if (!it->is_regular_file()) continue;
        if (it->path().extension() == ".bin") files.push_back(it->path());
    }
    std::sort(files.begin(), files.end());
    if (files.empty()) {
        std::fprintf(stderr, "fixture replay: no .bin fixture files found in %s\n", fixtures_dir.string().c_str());
        return 1;
    }

    int failed = 0;
    for (const auto& file : files) {
        std::string err;
        if (!run_replay_for_file(file, repo_root, output_dir, err)) {
            std::fprintf(stderr, "fixture replay FAILED: %s (%s)\n", file.string().c_str(), err.c_str());
            ++failed;
        }
    }

    if (failed == 0) {
        std::printf("fixture replay PASS: %zu fixtures\n", files.size());
        return 0;
    }
    std::fprintf(stderr, "fixture replay FAIL: %d/%zu failed\n", failed, files.size());
    return 1;
}

