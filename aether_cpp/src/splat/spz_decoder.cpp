// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/splat/spz_decoder.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

#if __has_include(<zlib.h>)
#include <zlib.h>
#define AETHER_HAS_ZLIB 1
#else
#define AETHER_HAS_ZLIB 0
#endif

namespace aether {
namespace splat {

namespace {

#if AETHER_HAS_ZLIB
std::vector<std::uint8_t> decompress_gzip(const std::uint8_t* data,
                                           std::size_t size) noexcept {
    // Estimate decompressed size (SPZ is typically ~10x compressed)
    std::size_t output_capacity = size * 16;
    std::vector<std::uint8_t> output(output_capacity);

    z_stream stream{};
    stream.next_in = const_cast<Bytef*>(data);
    stream.avail_in = static_cast<uInt>(size);
    stream.next_out = output.data();
    stream.avail_out = static_cast<uInt>(output_capacity);

    // windowBits = 15 + 32 to auto-detect gzip/zlib header
    int ret = inflateInit2(&stream, 15 + 32);
    if (ret != Z_OK) return {};

    while (true) {
        ret = inflate(&stream, Z_NO_FLUSH);
        if (ret == Z_STREAM_END) break;
        if (ret != Z_OK) {
            inflateEnd(&stream);
            return {};
        }

        if (stream.avail_out == 0) {
            // Need more output space
            std::size_t written = output.size() - stream.avail_out;
            output_capacity *= 2;
            output.resize(output_capacity);
            stream.next_out = output.data() + written;
            stream.avail_out = static_cast<uInt>(output_capacity - written);
        }
    }

    std::size_t total = stream.total_out;
    inflateEnd(&stream);

    output.resize(total);
    return output;
}
#endif

}  // namespace

core::Status decode_spz(const std::uint8_t* compressed_data,
                         std::size_t compressed_size,
                         SpzDecodeResult& result) noexcept {
#if AETHER_HAS_ZLIB
    auto decompressed = decompress_gzip(compressed_data, compressed_size);
    if (decompressed.empty()) {
        return core::Status::kInvalidArgument;
    }
    return decode_spz_raw(decompressed.data(), decompressed.size(), result);
#else
    (void)compressed_data;
    (void)compressed_size;
    (void)result;
    return core::Status::kResourceExhausted;  // zlib not available
#endif
}

core::Status load_spz(const char* path, SpzDecodeResult& result) noexcept {
    std::FILE* file = std::fopen(path, "rb");
    if (!file) return core::Status::kInvalidArgument;

    std::fseek(file, 0, SEEK_END);
    long file_size = std::ftell(file);
    std::fseek(file, 0, SEEK_SET);

    if (file_size <= 0) {
        std::fclose(file);
        return core::Status::kInvalidArgument;
    }

    std::vector<std::uint8_t> buffer(static_cast<std::size_t>(file_size));
    std::size_t read = std::fread(buffer.data(), 1, buffer.size(), file);
    std::fclose(file);

    if (read != buffer.size()) {
        return core::Status::kInvalidArgument;
    }

    return decode_spz(buffer.data(), buffer.size(), result);
}

}  // namespace splat
}  // namespace aether
