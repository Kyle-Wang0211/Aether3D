// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/upload/erasure_coding.h"

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

namespace aether {
namespace upload {
namespace {

inline std::uint64_t splitmix64(std::uint64_t x) {
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ull;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebull;
    return x ^ (x >> 31);
}

double to_unit_interval(std::uint64_t x) {
    constexpr double kScale = 1.0 / static_cast<double>(std::numeric_limits<std::uint64_t>::max());
    return static_cast<double>(x) * kScale;
}

int sample_robust_soliton_degree(int symbol_count, std::uint64_t seed) {
    if (symbol_count <= 1) {
        return 1;
    }

    const int k = symbol_count;
    const double delta = 0.05;
    const double c = 0.1;
    const double safe_k = static_cast<double>(k);
    const double R = std::max(1.0, c * std::log(std::max(2.0, safe_k / delta)) * std::sqrt(safe_k));
    const int r = std::max(1, std::min(k, static_cast<int>(std::floor(safe_k / R))));

    std::vector<double> distribution(static_cast<std::size_t>(k + 1), 0.0);

    distribution[1] = 1.0 / safe_k;
    for (int d = 2; d <= k; ++d) {
        distribution[static_cast<std::size_t>(d)] = 1.0 / (static_cast<double>(d) * static_cast<double>(d - 1));
    }

    for (int d = 1; d < r; ++d) {
        distribution[static_cast<std::size_t>(d)] += R / (static_cast<double>(d) * safe_k);
    }
    if (r >= 1 && r <= k) {
        distribution[static_cast<std::size_t>(r)] += (R * std::log(R / delta)) / safe_k;
    }

    double norm = 0.0;
    for (int d = 1; d <= k; ++d) {
        norm += distribution[static_cast<std::size_t>(d)];
    }
    if (!(norm > 0.0) || !std::isfinite(norm)) {
        return std::min(4, k);
    }

    const double u = to_unit_interval(splitmix64(seed));
    double cdf = 0.0;
    for (int d = 1; d <= k; ++d) {
        cdf += distribution[static_cast<std::size_t>(d)] / norm;
        if (u <= cdf) {
            return d;
        }
    }
    return k;
}

inline bool bit_get(const std::vector<std::uint64_t>& row, int bit) {
    const std::size_t word = static_cast<std::size_t>(bit / 64);
    const int offset = bit % 64;
    if (word >= row.size()) {
        return false;
    }
    return ((row[word] >> offset) & 1ull) != 0ull;
}

inline void bit_set(std::vector<std::uint64_t>* row, int bit) {
    const std::size_t word = static_cast<std::size_t>(bit / 64);
    const int offset = bit % 64;
    if (word < row->size()) {
        (*row)[word] |= (1ull << offset);
    }
}

void xor_row(std::vector<std::uint64_t>* lhs, const std::vector<std::uint64_t>& rhs) {
    const std::size_t n = std::min(lhs->size(), rhs.size());
    for (std::size_t i = 0; i < n; ++i) {
        (*lhs)[i] ^= rhs[i];
    }
}

void xor_payload(std::vector<std::uint8_t>* lhs, const std::vector<std::uint8_t>& rhs) {
    const std::size_t n = std::min(lhs->size(), rhs.size());
    for (std::size_t i = 0; i < n; ++i) {
        (*lhs)[i] ^= rhs[i];
    }
}

std::vector<int> parity_sources(
    int original_count,
    int parity_index,
    ErasureMode mode,
    ErasureField field) {
    std::vector<int> sources;
    if (original_count <= 0) {
        return sources;
    }

    if (mode == ErasureMode::kReedSolomon) {
        const int target_degree = (field == ErasureField::kGF65536) ? 6 : 4;
        const int degree = std::min(original_count, std::max(1, target_degree));
        const int start = ((parity_index % original_count) + original_count) % original_count;
        int stride = 1 + ((parity_index * 2 + 1) % std::max(1, original_count - 1));
        if (stride <= 0) {
            stride = 1;
        }
        sources.reserve(static_cast<std::size_t>(degree));
        for (int i = 0; i < degree; ++i) {
            const int idx = (start + i * stride) % original_count;
            bool exists = false;
            for (int v : sources) {
                if (v == idx) {
                    exists = true;
                    break;
                }
            }
            if (!exists) {
                sources.push_back(idx);
            }
        }
        if (sources.empty()) {
            sources.push_back(start);
        }
        return sources;
    }

    const int max_degree = std::min(original_count, field == ErasureField::kGF65536 ? 24 : 16);
    std::uint64_t state = splitmix64(
        static_cast<std::uint64_t>(original_count) * 0x9e3779b97f4a7c15ull ^
        static_cast<std::uint64_t>(parity_index + 1) ^
        0xd1b54a32d192ed03ull);
    int degree = sample_robust_soliton_degree(original_count, state);
    degree = std::max(2, std::min(max_degree, degree));

    sources.reserve(static_cast<std::size_t>(degree));
    while (static_cast<int>(sources.size()) < degree) {
        state = splitmix64(state + 0x9e3779b97f4a7c15ull);
        const int idx = static_cast<int>(state % static_cast<std::uint64_t>(original_count));
        bool exists = false;
        for (int v : sources) {
            if (v == idx) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            sources.push_back(idx);
        }
    }
    const int anchor = ((parity_index % original_count) + original_count) % original_count;
    bool has_anchor = false;
    for (int idx : sources) {
        if (idx == anchor) {
            has_anchor = true;
            break;
        }
    }
    if (!has_anchor) {
        if (static_cast<int>(sources.size()) < degree) {
            sources.push_back(anchor);
        } else if (!sources.empty()) {
            sources[0] = anchor;
        } else {
            sources.push_back(anchor);
        }
    }
    return sources;
}

}  // namespace

core::Status erasure_select_mode(
    int chunk_count,
    double loss_rate,
    ErasureSelection* out_selection) {
    if (out_selection == nullptr || chunk_count < 0 || !std::isfinite(loss_rate)) {
        return core::Status::kInvalidArgument;
    }

    const double clamped_loss = std::max(0.0, std::min(1.0, loss_rate));
    if (chunk_count <= 255 && clamped_loss < 0.08) {
        out_selection->mode = ErasureMode::kReedSolomon;
        out_selection->field = ErasureField::kGF256;
    } else if (chunk_count <= 255 && clamped_loss >= 0.08) {
        out_selection->mode = ErasureMode::kRaptorQ;
        out_selection->field = ErasureField::kGF256;
    } else if (chunk_count > 255 && clamped_loss < 0.03) {
        out_selection->mode = ErasureMode::kReedSolomon;
        out_selection->field = ErasureField::kGF65536;
    } else {
        out_selection->mode = ErasureMode::kRaptorQ;
        out_selection->field = ErasureField::kGF65536;
    }
    return core::Status::kOk;
}

core::Status erasure_encode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size) {
    return erasure_encode_with_mode(
        input_data,
        input_offsets,
        block_count,
        redundancy,
        ErasureMode::kReedSolomon,
        ErasureField::kGF256,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size);
}

core::Status erasure_encode_with_mode(
    const std::uint8_t* input_data,
    const std::uint32_t* input_offsets,
    int block_count,
    double redundancy,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size) {
    if (block_count < 0 || input_offsets == nullptr || out_offsets == nullptr ||
        out_block_count == nullptr || out_data_size == nullptr ||
        !std::isfinite(redundancy)) {
        return core::Status::kInvalidArgument;
    }
    if (block_count > 0 && input_data == nullptr) {
        return core::Status::kInvalidArgument;
    }

    const int parity_count = std::max(0, static_cast<int>(static_cast<double>(block_count) * std::max(0.0, redundancy)));
    const int total_blocks = block_count + parity_count;
    if (out_block_capacity < total_blocks) {
        *out_block_count = total_blocks;
        return core::Status::kResourceExhausted;
    }

    std::vector<std::uint32_t> block_sizes(static_cast<std::size_t>(std::max(block_count, 0)), 0u);
    std::uint32_t max_block_size = 0u;
    for (int i = 0; i < block_count; ++i) {
        const std::uint32_t begin = input_offsets[i];
        const std::uint32_t end = input_offsets[i + 1];
        if (end < begin) {
            return core::Status::kInvalidArgument;
        }
        block_sizes[static_cast<std::size_t>(i)] = end - begin;
        max_block_size = std::max(max_block_size, block_sizes[static_cast<std::size_t>(i)]);
    }

    std::uint32_t cursor = 0u;
    out_offsets[0] = 0u;
    for (int i = 0; i < block_count; ++i) {
        const std::uint32_t begin = input_offsets[i];
        const std::uint32_t end = input_offsets[i + 1];
        const std::uint32_t size = end - begin;
        if (cursor + size > out_data_capacity) {
            *out_data_size = cursor + size;
            *out_block_count = total_blocks;
            return core::Status::kResourceExhausted;
        }
        if (size > 0u) {
            std::memcpy(out_data + cursor, input_data + begin, size);
        }
        cursor += size;
        out_offsets[i + 1] = cursor;
    }

    for (int p = 0; p < parity_count; ++p) {
        if (cursor + max_block_size > out_data_capacity) {
            *out_data_size = cursor + max_block_size;
            *out_block_count = total_blocks;
            return core::Status::kResourceExhausted;
        }
        std::memset(out_data + cursor, 0, max_block_size);
        std::vector<int> src = parity_sources(block_count, p, mode, field);
        for (int src_idx : src) {
            const std::uint32_t begin = input_offsets[src_idx];
            const std::uint32_t size = block_sizes[static_cast<std::size_t>(src_idx)];
            for (std::uint32_t b = 0u; b < size; ++b) {
                out_data[cursor + b] ^= input_data[begin + b];
            }
        }
        cursor += max_block_size;
        out_offsets[block_count + p + 1] = cursor;
    }

    *out_data_size = cursor;
    *out_block_count = total_blocks;
    return core::Status::kOk;
}

core::Status erasure_decode_systematic(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size) {
    return erasure_decode_systematic_with_mode(
        blocks_data,
        block_offsets,
        block_present,
        block_count,
        original_count,
        ErasureMode::kReedSolomon,
        ErasureField::kGF256,
        out_data,
        out_data_capacity,
        out_offsets,
        out_block_capacity,
        out_block_count,
        out_data_size);
}

core::Status erasure_decode_systematic_with_mode(
    const std::uint8_t* blocks_data,
    const std::uint32_t* block_offsets,
    const std::uint8_t* block_present,
    int block_count,
    int original_count,
    ErasureMode mode,
    ErasureField field,
    std::uint8_t* out_data,
    std::uint32_t out_data_capacity,
    std::uint32_t* out_offsets,
    int out_block_capacity,
    int* out_block_count,
    std::uint32_t* out_data_size) {
    if (block_count < 0 || original_count < 0 || block_offsets == nullptr || block_present == nullptr ||
        out_data == nullptr || out_offsets == nullptr || out_block_count == nullptr || out_data_size == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (block_count > 0 && blocks_data == nullptr) {
        return core::Status::kInvalidArgument;
    }
    if (original_count > block_count || out_block_capacity < original_count) {
        return core::Status::kOutOfRange;
    }

    std::vector<std::uint32_t> block_sizes(static_cast<std::size_t>(original_count), 0u);
    std::uint32_t max_block_size = 0u;
    for (int i = 0; i < original_count; ++i) {
        const std::uint32_t begin = block_offsets[i];
        const std::uint32_t end = block_offsets[i + 1];
        if (end < begin) {
            return core::Status::kInvalidArgument;
        }
        block_sizes[static_cast<std::size_t>(i)] = end - begin;
        max_block_size = std::max(max_block_size, block_sizes[static_cast<std::size_t>(i)]);
    }

    std::vector<std::vector<std::uint8_t>> recovered(static_cast<std::size_t>(original_count));
    std::vector<std::uint8_t> have_block(static_cast<std::size_t>(original_count), 0u);
    int missing = 0;
    for (int i = 0; i < original_count; ++i) {
        have_block[static_cast<std::size_t>(i)] = block_present[i] ? 1u : 0u;
        if (!have_block[static_cast<std::size_t>(i)]) {
            ++missing;
        }
    }

    if (missing > 0 && max_block_size > 0u) {
        struct Equation {
            std::vector<int> unknown_indices;
            std::vector<std::uint8_t> payload;
        };
        std::vector<Equation> equations;
        equations.reserve(static_cast<std::size_t>(block_count - original_count));

        for (int parity_global = original_count; parity_global < block_count; ++parity_global) {
            if (block_present[parity_global] == 0u) {
                continue;
            }
            const std::uint32_t begin = block_offsets[parity_global];
            const std::uint32_t end = block_offsets[parity_global + 1];
            if (end < begin) {
                return core::Status::kInvalidArgument;
            }
            const std::uint32_t size = end - begin;

            Equation eq{};
            eq.payload.assign(max_block_size, 0u);
            const std::uint32_t copy_size = std::min(max_block_size, size);
            if (copy_size > 0u) {
                std::memcpy(eq.payload.data(), blocks_data + begin, copy_size);
            }
            const std::vector<int> src = parity_sources(
                original_count,
                parity_global - original_count,
                mode,
                field);
            for (int src_idx : src) {
                if (have_block[static_cast<std::size_t>(src_idx)] != 0u) {
                    const std::uint32_t src_begin = block_offsets[src_idx];
                    const std::uint32_t src_size = block_sizes[static_cast<std::size_t>(src_idx)];
                    for (std::uint32_t b = 0u; b < src_size; ++b) {
                        eq.payload[b] ^= blocks_data[src_begin + b];
                    }
                } else {
                    eq.unknown_indices.push_back(src_idx);
                }
            }
            if (!eq.unknown_indices.empty()) {
                equations.push_back(std::move(eq));
            }
        }

        bool progress = true;
        while (progress) {
            progress = false;
            for (Equation& eq : equations) {
                if (eq.unknown_indices.size() != 1u) {
                    continue;
                }
                const int idx = eq.unknown_indices[0];
                if (have_block[static_cast<std::size_t>(idx)] != 0u) {
                    continue;
                }
                recovered[static_cast<std::size_t>(idx)] = eq.payload;
                have_block[static_cast<std::size_t>(idx)] = 1u;
                missing -= 1;
                progress = true;
                for (Equation& other : equations) {
                    if (&other == &eq) {
                        continue;
                    }
                    auto it = std::find(other.unknown_indices.begin(), other.unknown_indices.end(), idx);
                    if (it == other.unknown_indices.end()) {
                        continue;
                    }
                    for (std::uint32_t b = 0u; b < max_block_size; ++b) {
                        other.payload[b] ^= recovered[static_cast<std::size_t>(idx)][b];
                    }
                    other.unknown_indices.erase(it);
                }
            }
        }

        if (missing > 0) {
            std::vector<int> unknown_blocks;
            unknown_blocks.reserve(static_cast<std::size_t>(missing));
            std::vector<int> unknown_to_col(static_cast<std::size_t>(original_count), -1);
            for (int i = 0; i < original_count; ++i) {
                if (have_block[static_cast<std::size_t>(i)] == 0u) {
                    unknown_to_col[static_cast<std::size_t>(i)] = static_cast<int>(unknown_blocks.size());
                    unknown_blocks.push_back(i);
                }
            }

            const int unknown_count = static_cast<int>(unknown_blocks.size());
            const int coeff_words = (unknown_count + 63) / 64;
            struct DenseEquation {
                std::vector<std::uint64_t> coeff;
                std::vector<std::uint8_t> payload;
            };

            std::vector<DenseEquation> dense_rows;
            dense_rows.reserve(equations.size());
            for (const Equation& eq : equations) {
                DenseEquation row{};
                row.coeff.assign(static_cast<std::size_t>(std::max(1, coeff_words)), 0ull);
                row.payload = eq.payload;
                int set_count = 0;
                for (int idx : eq.unknown_indices) {
                    if (idx < 0 || idx >= original_count) {
                        continue;
                    }
                    const int col = unknown_to_col[static_cast<std::size_t>(idx)];
                    if (col < 0) {
                        continue;
                    }
                    bit_set(&row.coeff, col);
                    ++set_count;
                }
                if (set_count > 0) {
                    dense_rows.push_back(std::move(row));
                }
            }

            std::vector<int> pivot_row_for_col(static_cast<std::size_t>(unknown_count), -1);
            int lead_row = 0;
            const int row_count = static_cast<int>(dense_rows.size());
            for (int col = 0; col < unknown_count && lead_row < row_count; ++col) {
                int selected = -1;
                for (int r = lead_row; r < row_count; ++r) {
                    if (bit_get(dense_rows[static_cast<std::size_t>(r)].coeff, col)) {
                        selected = r;
                        break;
                    }
                }
                if (selected < 0) {
                    continue;
                }
                if (selected != lead_row) {
                    std::swap(
                        dense_rows[static_cast<std::size_t>(selected)],
                        dense_rows[static_cast<std::size_t>(lead_row)]);
                }
                pivot_row_for_col[static_cast<std::size_t>(col)] = lead_row;

                for (int r = 0; r < row_count; ++r) {
                    if (r == lead_row) {
                        continue;
                    }
                    DenseEquation& rr = dense_rows[static_cast<std::size_t>(r)];
                    if (!bit_get(rr.coeff, col)) {
                        continue;
                    }
                    const DenseEquation& pivot = dense_rows[static_cast<std::size_t>(lead_row)];
                    xor_row(&rr.coeff, pivot.coeff);
                    xor_payload(&rr.payload, pivot.payload);
                }
                ++lead_row;
            }

            bool solved_all = true;
            for (int col = 0; col < unknown_count; ++col) {
                const int pivot_row = pivot_row_for_col[static_cast<std::size_t>(col)];
                if (pivot_row < 0) {
                    solved_all = false;
                    continue;
                }
                const int block_idx = unknown_blocks[static_cast<std::size_t>(col)];
                recovered[static_cast<std::size_t>(block_idx)] =
                    dense_rows[static_cast<std::size_t>(pivot_row)].payload;
                have_block[static_cast<std::size_t>(block_idx)] = 1u;
            }

            if (solved_all) {
                missing = 0;
            } else {
                missing = 0;
                for (int i = 0; i < original_count; ++i) {
                    if (have_block[static_cast<std::size_t>(i)] == 0u) {
                        ++missing;
                    }
                }
            }
        }
    }

    if (missing > 0) {
        return core::Status::kResourceExhausted;
    }

    std::uint32_t cursor = 0u;
    out_offsets[0] = 0u;
    for (int i = 0; i < original_count; ++i) {
        const std::uint32_t size = block_sizes[static_cast<std::size_t>(i)];
        if (cursor + size > out_data_capacity) {
            *out_data_size = cursor + size;
            return core::Status::kResourceExhausted;
        }
        if (block_present[i] != 0u) {
            const std::uint32_t begin = block_offsets[i];
            if (size > 0u) {
                std::memcpy(out_data + cursor, blocks_data + begin, size);
            }
        } else if (size > 0u) {
            const std::vector<std::uint8_t>& rec = recovered[static_cast<std::size_t>(i)];
            if (rec.size() < size) {
                return core::Status::kResourceExhausted;
            }
            std::memcpy(out_data + cursor, rec.data(), size);
        }
        cursor += size;
        out_offsets[i + 1] = cursor;
    }

    *out_block_count = original_count;
    *out_data_size = cursor;
    return core::Status::kOk;
}

}  // namespace upload
}  // namespace aether
