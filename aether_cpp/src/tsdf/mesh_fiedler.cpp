// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/tsdf/mesh_fiedler.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace aether {
namespace tsdf {
namespace {

/// CSR (Compressed Sparse Row) adjacency representation for the mesh graph.
struct CSRAdjacency {
    std::vector<uint32_t> row_offsets;  // size = vertex_count + 1
    std::vector<uint32_t> col_indices;  // size = 2 * edge_count
    std::vector<uint32_t> degrees;      // degree[v] = number of neighbors
};

/// Build CSR adjacency from triangle index array.
/// Each triangle (i0, i1, i2) contributes 3 undirected edges.
CSRAdjacency build_adjacency(
    const uint32_t* indices,
    std::size_t index_count,
    std::size_t vertex_count) {

    CSRAdjacency adj;
    adj.degrees.resize(vertex_count, 0);
    adj.row_offsets.resize(vertex_count + 1, 0);

    const std::size_t tri_count = index_count / 3;

    // First pass: count degrees (with possible duplicates).
    // We'll use a temporary edge list and then sort/unique per vertex.
    std::vector<std::vector<uint32_t>> neighbors(vertex_count);

    for (std::size_t t = 0; t < tri_count; ++t) {
        const uint32_t v0 = indices[t * 3 + 0];
        const uint32_t v1 = indices[t * 3 + 1];
        const uint32_t v2 = indices[t * 3 + 2];
        if (v0 >= vertex_count || v1 >= vertex_count || v2 >= vertex_count) {
            continue;
        }
        neighbors[v0].push_back(v1);
        neighbors[v0].push_back(v2);
        neighbors[v1].push_back(v0);
        neighbors[v1].push_back(v2);
        neighbors[v2].push_back(v0);
        neighbors[v2].push_back(v1);
    }

    // Deduplicate neighbors per vertex.
    std::size_t total_nnz = 0;
    for (std::size_t v = 0; v < vertex_count; ++v) {
        auto& nb = neighbors[v];
        std::sort(nb.begin(), nb.end());
        nb.erase(std::unique(nb.begin(), nb.end()), nb.end());
        adj.degrees[v] = static_cast<uint32_t>(nb.size());
        total_nnz += nb.size();
    }

    // Build CSR.
    adj.row_offsets[0] = 0;
    for (std::size_t v = 0; v < vertex_count; ++v) {
        adj.row_offsets[v + 1] = adj.row_offsets[v] + adj.degrees[v];
    }
    adj.col_indices.resize(total_nnz);
    for (std::size_t v = 0; v < vertex_count; ++v) {
        const uint32_t offset = adj.row_offsets[v];
        for (std::size_t j = 0; j < neighbors[v].size(); ++j) {
            adj.col_indices[offset + j] = neighbors[v][j];
        }
    }

    return adj;
}

/// Multiply L * x where L is the graph Laplacian (L = D - A).
/// Result: y[v] = degree[v] * x[v] - sum(x[neighbor]) for each v.
void laplacian_multiply(
    const CSRAdjacency& adj,
    const double* x,
    double* y,
    std::size_t n) {
    for (std::size_t v = 0; v < n; ++v) {
        double sum = 0.0;
        const uint32_t start = adj.row_offsets[v];
        const uint32_t end = adj.row_offsets[v + 1];
        for (uint32_t j = start; j < end; ++j) {
            sum += x[adj.col_indices[j]];
        }
        y[v] = static_cast<double>(adj.degrees[v]) * x[v] - sum;
    }
}

/// Compute dot product of two vectors.
double dot(const double* a, const double* b, std::size_t n) {
    double s = 0.0;
    for (std::size_t i = 0; i < n; ++i) {
        s += a[i] * b[i];
    }
    return s;
}

/// Compute L2 norm.
double norm2(const double* v, std::size_t n) {
    return std::sqrt(dot(v, v, n));
}

/// Normalize vector in-place. Returns the norm before normalization.
double normalize(double* v, std::size_t n) {
    const double len = norm2(v, n);
    if (len > 1e-15) {
        const double inv = 1.0 / len;
        for (std::size_t i = 0; i < n; ++i) {
            v[i] *= inv;
        }
    }
    return len;
}

/// Remove component along a direction: v -= (v·d)*d.
/// Assumes d is already normalized.
void deflate(double* v, const double* d, std::size_t n) {
    const double proj = dot(v, d, n);
    for (std::size_t i = 0; i < n; ++i) {
        v[i] -= proj * d[i];
    }
}

}  // namespace

FiedlerResult compute_fiedler_value(
    const uint32_t* indices,
    std::size_t index_count,
    std::size_t vertex_count,
    int max_iterations) {

    FiedlerResult result{};

    if (indices == nullptr || index_count < 3 || vertex_count < 2) {
        return result;
    }

    const std::size_t n = vertex_count;

    // Build adjacency.
    CSRAdjacency adj = build_adjacency(indices, index_count, n);

    // Constant eigenvector v1 = (1/√n, 1/√n, ..., 1/√n).
    // This is always the eigenvector for λ₁ = 0 of any graph Laplacian.
    const double inv_sqrt_n = 1.0 / std::sqrt(static_cast<double>(n));

    std::vector<double> v1(n, inv_sqrt_n);
    std::vector<double> x(n);
    std::vector<double> y(n);

    // Step 1: Power iteration on L to find λ_max (largest eigenvalue).
    // Initialize x with random-ish values orthogonal to v1.
    for (std::size_t i = 0; i < n; ++i) {
        x[i] = static_cast<double>(i % 7) - 3.0;
    }
    deflate(x.data(), v1.data(), n);
    normalize(x.data(), n);

    double lambda_max = 0.0;
    for (int iter = 0; iter < max_iterations; ++iter) {
        laplacian_multiply(adj, x.data(), y.data(), n);
        deflate(y.data(), v1.data(), n);
        lambda_max = normalize(y.data(), n);
        std::memcpy(x.data(), y.data(), n * sizeof(double));
    }

    if (lambda_max < 1e-12) {
        // Disconnected or trivial graph.
        result.fiedler_value = 0.0;
        result.computed = true;
        result.iterations_used = max_iterations;
        return result;
    }

    // Step 2: Power iteration on (λ_max * I - L) to find its largest eigenvalue.
    // The eigenvectors of (λ_max * I - L) are the same as L, but eigenvalues
    // are reversed: λ_max - λ_i.  The LARGEST eigenvalue of (λ_max*I - L)
    // corresponds to the SMALLEST non-trivial eigenvalue of L (= λ₂).
    //
    // So: largest_of_shifted = λ_max - λ₂  →  λ₂ = λ_max - largest_of_shifted.

    // Re-initialize x orthogonal to v1.
    for (std::size_t i = 0; i < n; ++i) {
        x[i] = static_cast<double>((i * 17 + 5) % 11) - 5.0;
    }
    deflate(x.data(), v1.data(), n);
    normalize(x.data(), n);

    double largest_shifted = 0.0;
    for (int iter = 0; iter < max_iterations; ++iter) {
        // y = (λ_max * I - L) * x = λ_max * x - L * x
        laplacian_multiply(adj, x.data(), y.data(), n);
        for (std::size_t i = 0; i < n; ++i) {
            y[i] = lambda_max * x[i] - y[i];
        }
        // Deflate v1 component (corresponding to eigenvalue λ_max - 0 = λ_max
        // in the shifted operator, which we do NOT want).
        deflate(y.data(), v1.data(), n);
        largest_shifted = normalize(y.data(), n);
        std::memcpy(x.data(), y.data(), n * sizeof(double));
    }

    result.fiedler_value = lambda_max - largest_shifted;
    // Clamp to non-negative (numerical noise can make it slightly negative).
    if (result.fiedler_value < 0.0) result.fiedler_value = 0.0;
    result.computed = true;
    result.iterations_used = max_iterations * 2;  // two phases

    return result;
}

}  // namespace tsdf
}  // namespace aether
