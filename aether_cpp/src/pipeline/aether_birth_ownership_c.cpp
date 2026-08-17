// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether_birth_ownership_c.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <new>
#include <numeric>
#include <vector>

namespace {

struct Point3 {
    double x;
    double y;
    double z;
};

bool finite_point(const Point3& point) {
    return std::isfinite(point.x) && std::isfinite(point.y) &&
        std::isfinite(point.z);
}

Point3 load_point(const float* xyz, int32_t index) {
    return Point3{
        static_cast<double>(xyz[static_cast<std::size_t>(index) * 3]),
        static_cast<double>(xyz[static_cast<std::size_t>(index) * 3 + 1]),
        static_cast<double>(xyz[static_cast<std::size_t>(index) * 3 + 2]),
    };
}

struct Neighbor {
    double distance_squared;
    int32_t index;
};

bool nearer_neighbor(const Neighbor& left, const Neighbor& right) {
    if (left.distance_squared != right.distance_squared) {
        return left.distance_squared < right.distance_squared;
    }
    return left.index < right.index;
}

struct PartitionIndex {
    struct KdNode {
        int32_t point_index = -1;
        int32_t left = -1;
        int32_t right = -1;
        int32_t axis = 0;
    };

    std::vector<Point3> points;
    std::vector<KdNode> kd_nodes;
    int32_t kd_root = -1;

    static double coordinate(const Point3& point, int32_t axis) {
        if (axis == 0) return point.x;
        if (axis == 1) return point.y;
        return point.z;
    }

    int32_t build_kd(std::vector<int32_t>& order,
                     std::size_t begin,
                     std::size_t end,
                     int32_t depth) {
        if (begin >= end) return -1;
        const int32_t axis = depth % 3;
        const std::size_t middle = begin + (end - begin) / 2;
        const auto less = [&](int32_t left, int32_t right) {
            const Point3& a = points[static_cast<std::size_t>(left)];
            const Point3& b = points[static_cast<std::size_t>(right)];
            const double primary_a = coordinate(a, axis);
            const double primary_b = coordinate(b, axis);
            if (primary_a != primary_b) return primary_a < primary_b;
            if (a.x != b.x) return a.x < b.x;
            if (a.y != b.y) return a.y < b.y;
            if (a.z != b.z) return a.z < b.z;
            return left < right;
        };
        std::nth_element(
            order.begin() + static_cast<std::ptrdiff_t>(begin),
            order.begin() + static_cast<std::ptrdiff_t>(middle),
            order.begin() + static_cast<std::ptrdiff_t>(end), less);
        const int32_t node_index = static_cast<int32_t>(kd_nodes.size());
        kd_nodes.push_back(KdNode{order[middle], -1, -1, axis});
        const int32_t left = build_kd(order, begin, middle, depth + 1);
        const int32_t right = build_kd(order, middle + 1, end, depth + 1);
        kd_nodes[static_cast<std::size_t>(node_index)].left = left;
        kd_nodes[static_cast<std::size_t>(node_index)].right = right;
        return node_index;
    }

    void build() {
        std::vector<int32_t> order(points.size());
        std::iota(order.begin(), order.end(), 0);
        kd_nodes.reserve(points.size());
        kd_root = build_kd(order, 0, order.size(), 0);
    }

    void nearest_squared_recursive(const Point3& query,
                                   int32_t node_index,
                                   double* best) const {
        if (node_index < 0) return;
        const KdNode& node = kd_nodes[static_cast<std::size_t>(node_index)];
        const Point3& point = points[static_cast<std::size_t>(node.point_index)];
        const double dx = query.x - point.x;
        const double dy = query.y - point.y;
        const double dz = query.z - point.z;
        const double distance_squared = dx * dx + dy * dy + dz * dz;
        if (distance_squared < *best) *best = distance_squared;
        const double delta = coordinate(query, node.axis) -
            coordinate(point, node.axis);
        const int32_t nearer = delta <= 0.0 ? node.left : node.right;
        const int32_t farther = delta <= 0.0 ? node.right : node.left;
        nearest_squared_recursive(query, nearer, best);
        if (delta * delta <= *best) {
            nearest_squared_recursive(query, farther, best);
        }
    }

    double nearest_distance(const Point3& query) const {
        double best = std::numeric_limits<double>::infinity();
        nearest_squared_recursive(query, kd_root, &best);
        return std::sqrt(best);
    }

    void nearest_neighbors_recursive(const Point3& query,
                                     int32_t node_index,
                                     std::size_t keep,
                                     Neighbor* neighbors,
                                     std::size_t* neighbor_count) const {
        if (node_index < 0) return;
        const KdNode& node = kd_nodes[static_cast<std::size_t>(node_index)];
        const Point3& point = points[static_cast<std::size_t>(node.point_index)];
        const double dx = query.x - point.x;
        const double dy = query.y - point.y;
        const double dz = query.z - point.z;
        const Neighbor incoming{dx * dx + dy * dy + dz * dz,
                                node.point_index};
        if (*neighbor_count < keep) {
            neighbors[(*neighbor_count)++] = incoming;
            std::push_heap(
                neighbors, neighbors + *neighbor_count, nearer_neighbor);
        } else if (nearer_neighbor(incoming, neighbors[0])) {
            std::pop_heap(neighbors, neighbors + keep, nearer_neighbor);
            neighbors[keep - 1] = incoming;
            std::push_heap(neighbors, neighbors + keep, nearer_neighbor);
        }
        const double delta = coordinate(query, node.axis) -
            coordinate(point, node.axis);
        const int32_t nearer_node = delta <= 0.0 ? node.left : node.right;
        const int32_t farther_node = delta <= 0.0 ? node.right : node.left;
        nearest_neighbors_recursive(
            query, nearer_node, keep, neighbors, neighbor_count);
        const double worst = *neighbor_count < keep
            ? std::numeric_limits<double>::infinity()
            : neighbors[0].distance_squared;
        if (delta * delta <= worst) {
            nearest_neighbors_recursive(
                query, farther_node, keep, neighbors, neighbor_count);
        }
    }

    std::size_t nearest_neighbors(const Point3& query,
                                  std::size_t keep,
                                  Neighbor* neighbors) const {
        std::size_t count = 0;
        nearest_neighbors_recursive(query, kd_root, keep, neighbors, &count);
        std::sort_heap(neighbors, neighbors + count, nearer_neighbor);
        return count;
    }
};

// The certificate needs the exact 8-nearest neighbors from all three
// deterministic partitions. Searching three independent trees repeats most
// bounding-box decisions. This index stores the same points and local
// partition indices in one KD tree, then maintains one exact heap per
// partition during a single traversal. A subtree is pruned only when it cannot
// improve any partition, preserving the independent-search result.
struct CombinedPartitionIndex {
    struct Entry {
        Point3 point;
        int32_t partition = -1;
        int32_t local_index = -1;
    };
    struct KdNode {
        int32_t entry_index = -1;
        int32_t left = -1;
        int32_t right = -1;
        int32_t axis = 0;
        double minimum[3]{};
        double maximum[3]{};
    };

    std::vector<Entry> entries;
    std::vector<KdNode> kd_nodes;
    int32_t kd_root = -1;

    static double coordinate(const Point3& point, int32_t axis) {
        if (axis == 0) return point.x;
        if (axis == 1) return point.y;
        return point.z;
    }

    int32_t build_kd(std::vector<int32_t>& order,
                     std::size_t begin,
                     std::size_t end,
                     int32_t depth) {
        if (begin >= end) return -1;
        const int32_t axis = depth % 3;
        const std::size_t middle = begin + (end - begin) / 2;
        const auto less = [&](int32_t left, int32_t right) {
            const Entry& a = entries[static_cast<std::size_t>(left)];
            const Entry& b = entries[static_cast<std::size_t>(right)];
            const double primary_a = coordinate(a.point, axis);
            const double primary_b = coordinate(b.point, axis);
            if (primary_a != primary_b) return primary_a < primary_b;
            if (a.point.x != b.point.x) return a.point.x < b.point.x;
            if (a.point.y != b.point.y) return a.point.y < b.point.y;
            if (a.point.z != b.point.z) return a.point.z < b.point.z;
            if (a.partition != b.partition) return a.partition < b.partition;
            return a.local_index < b.local_index;
        };
        std::nth_element(
            order.begin() + static_cast<std::ptrdiff_t>(begin),
            order.begin() + static_cast<std::ptrdiff_t>(middle),
            order.begin() + static_cast<std::ptrdiff_t>(end), less);
        const int32_t node_index = static_cast<int32_t>(kd_nodes.size());
        kd_nodes.push_back(KdNode{order[middle], -1, -1, axis});
        const int32_t left = build_kd(order, begin, middle, depth + 1);
        const int32_t right = build_kd(order, middle + 1, end, depth + 1);
        KdNode& node = kd_nodes[static_cast<std::size_t>(node_index)];
        node.left = left;
        node.right = right;
        const Point3& point = entries[
            static_cast<std::size_t>(node.entry_index)].point;
        node.minimum[0] = node.maximum[0] = point.x;
        node.minimum[1] = node.maximum[1] = point.y;
        node.minimum[2] = node.maximum[2] = point.z;
        for (int32_t child_index : {left, right}) {
            if (child_index < 0) continue;
            const KdNode& child = kd_nodes[
                static_cast<std::size_t>(child_index)];
            for (int32_t dimension = 0; dimension < 3; ++dimension) {
                node.minimum[dimension] = std::min(
                    node.minimum[dimension], child.minimum[dimension]);
                node.maximum[dimension] = std::max(
                    node.maximum[dimension], child.maximum[dimension]);
            }
        }
        return node_index;
    }

    double box_distance_squared(const Point3& query,
                                int32_t node_index) const {
        if (node_index < 0) return std::numeric_limits<double>::infinity();
        const KdNode& node = kd_nodes[static_cast<std::size_t>(node_index)];
        const double values[3] = {query.x, query.y, query.z};
        double distance = 0.0;
        for (int32_t dimension = 0; dimension < 3; ++dimension) {
            double delta = 0.0;
            if (values[dimension] < node.minimum[dimension]) {
                delta = node.minimum[dimension] - values[dimension];
            } else if (values[dimension] > node.maximum[dimension]) {
                delta = values[dimension] - node.maximum[dimension];
            }
            distance += delta * delta;
        }
        return distance;
    }

    void build() {
        std::vector<int32_t> order(entries.size());
        std::iota(order.begin(), order.end(), 0);
        kd_nodes.reserve(entries.size());
        kd_root = build_kd(order, 0, order.size(), 0);
    }

    void nearest_neighbors_recursive(
        const Point3& query,
        int32_t node_index,
        std::size_t keep,
        std::array<std::array<Neighbor, 64>, 3>* neighbors,
        std::array<std::size_t, 3>* counts) const {
        if (node_index < 0) return;
        const KdNode& node = kd_nodes[static_cast<std::size_t>(node_index)];
        const Entry& entry = entries[static_cast<std::size_t>(node.entry_index)];
        const double dx = query.x - entry.point.x;
        const double dy = query.y - entry.point.y;
        const double dz = query.z - entry.point.z;
        const Neighbor incoming{dx * dx + dy * dy + dz * dz,
                                entry.local_index};
        const std::size_t partition = static_cast<std::size_t>(entry.partition);
        Neighbor* heap = (*neighbors)[partition].data();
        std::size_t& count = (*counts)[partition];
        if (count < keep) {
            heap[count++] = incoming;
            std::push_heap(heap, heap + count, nearer_neighbor);
        } else if (nearer_neighbor(incoming, heap[0])) {
            std::pop_heap(heap, heap + keep, nearer_neighbor);
            heap[keep - 1] = incoming;
            std::push_heap(heap, heap + keep, nearer_neighbor);
        }
        double worst_needed = 0.0;
        for (std::size_t p = 0; p < 3; ++p) {
            if ((*counts)[p] < keep) {
                worst_needed = std::numeric_limits<double>::infinity();
                break;
            }
            worst_needed = std::max(
                worst_needed, (*neighbors)[p][0].distance_squared);
        }
        const double left_distance = box_distance_squared(query, node.left);
        const double right_distance = box_distance_squared(query, node.right);
        const int32_t nearer_node = left_distance <= right_distance
            ? node.left : node.right;
        const int32_t farther_node = left_distance <= right_distance
            ? node.right : node.left;
        const double nearer_distance = std::min(left_distance, right_distance);
        const double farther_distance = std::max(left_distance, right_distance);
        if (nearer_distance <= worst_needed) {
            nearest_neighbors_recursive(
                query, nearer_node, keep, neighbors, counts);
        }
        worst_needed = 0.0;
        for (std::size_t p = 0; p < 3; ++p) {
            if ((*counts)[p] < keep) {
                worst_needed = std::numeric_limits<double>::infinity();
                break;
            }
            worst_needed = std::max(
                worst_needed, (*neighbors)[p][0].distance_squared);
        }
        if (farther_distance <= worst_needed) {
            nearest_neighbors_recursive(
                query, farther_node, keep, neighbors, counts);
        }
    }

    void nearest_neighbors_all(
        const Point3& query,
        std::size_t keep,
        std::array<std::array<Neighbor, 64>, 3>* neighbors,
        std::array<std::size_t, 3>* counts) const {
        counts->fill(0);
        nearest_neighbors_recursive(query, kd_root, keep, neighbors, counts);
        for (std::size_t partition = 0; partition < 3; ++partition) {
            std::sort_heap((*neighbors)[partition].data(),
                           (*neighbors)[partition].data() + (*counts)[partition],
                           nearer_neighbor);
        }
    }
};

bool smallest_eigenpair(const double covariance[3][3],
                        double* out_value,
                        Point3* out_vector) {
    if (!out_value || !out_vector) return false;
    double matrix[3][3]{};
    double vectors[3][3] = {
        {1.0, 0.0, 0.0},
        {0.0, 1.0, 0.0},
        {0.0, 0.0, 1.0},
    };
    std::memcpy(matrix, covariance, sizeof(matrix));
    for (int iteration = 0; iteration < 32; ++iteration) {
        int p = 0;
        int q = 1;
        double largest = std::abs(matrix[0][1]);
        if (std::abs(matrix[0][2]) > largest) {
            p = 0;
            q = 2;
            largest = std::abs(matrix[0][2]);
        }
        if (std::abs(matrix[1][2]) > largest) {
            p = 1;
            q = 2;
            largest = std::abs(matrix[1][2]);
        }
        if (largest <= 1e-15) break;
        const double app = matrix[p][p];
        const double aqq = matrix[q][q];
        const double apq = matrix[p][q];
        const double angle = 0.5 * std::atan2(2.0 * apq, aqq - app);
        const double cosine = std::cos(angle);
        const double sine = std::sin(angle);
        for (int axis = 0; axis < 3; ++axis) {
            if (axis == p || axis == q) continue;
            const double aip = matrix[axis][p];
            const double aiq = matrix[axis][q];
            matrix[axis][p] = cosine * aip - sine * aiq;
            matrix[p][axis] = matrix[axis][p];
            matrix[axis][q] = sine * aip + cosine * aiq;
            matrix[q][axis] = matrix[axis][q];
        }
        matrix[p][p] = cosine * cosine * app -
            2.0 * sine * cosine * apq + sine * sine * aqq;
        matrix[q][q] = sine * sine * app +
            2.0 * sine * cosine * apq + cosine * cosine * aqq;
        matrix[p][q] = 0.0;
        matrix[q][p] = 0.0;
        for (int axis = 0; axis < 3; ++axis) {
            const double vip = vectors[axis][p];
            const double viq = vectors[axis][q];
            vectors[axis][p] = cosine * vip - sine * viq;
            vectors[axis][q] = sine * vip + cosine * viq;
        }
    }
    int minimum = 0;
    if (matrix[1][1] < matrix[minimum][minimum]) minimum = 1;
    if (matrix[2][2] < matrix[minimum][minimum]) minimum = 2;
    Point3 vector{
        vectors[0][minimum], vectors[1][minimum], vectors[2][minimum]};
    const double norm = std::sqrt(
        vector.x * vector.x + vector.y * vector.y + vector.z * vector.z);
    if (!(norm > 0.0) || !std::isfinite(norm) ||
        !std::isfinite(matrix[minimum][minimum])) {
        return false;
    }
    *out_value = matrix[minimum][minimum];
    *out_vector = Point3{vector.x / norm, vector.y / norm, vector.z / norm};
    return true;
}

bool supported_by_partition_with_neighbors(
    const Point3& candidate,
    const PartitionIndex& partition,
    const aether_local_manifold_options_t& options,
    const Neighbor* neighbors,
    std::size_t neighbor_count,
    double* out_nearest_distance = nullptr) {
    const std::size_t keep = static_cast<std::size_t>(options.neighbors);
    if (out_nearest_distance) {
        *out_nearest_distance = neighbor_count == 0
            ? partition.nearest_distance(candidate)
            : std::sqrt(neighbors[0].distance_squared);
    }
    if (neighbor_count < keep) return false;
    if (std::sqrt(neighbors[0].distance_squared) >
        options.maximum_nearest_m) {
        return false;
    }
    if (std::sqrt(neighbors[keep - 1].distance_squared) >
        options.maximum_neighbor_radius_m) {
        return false;
    }

    Point3 center{0.0, 0.0, 0.0};
    for (int32_t neighbor = 0; neighbor < options.neighbors; ++neighbor) {
        const Point3& point = partition.points[static_cast<std::size_t>(
            neighbors[static_cast<std::size_t>(neighbor)].index)];
        center.x += point.x;
        center.y += point.y;
        center.z += point.z;
    }
    const double inverse_count = 1.0 / static_cast<double>(options.neighbors);
    center.x *= inverse_count;
    center.y *= inverse_count;
    center.z *= inverse_count;
    double covariance[3][3]{};
    for (int32_t neighbor = 0; neighbor < options.neighbors; ++neighbor) {
        const Point3& point = partition.points[static_cast<std::size_t>(
            neighbors[static_cast<std::size_t>(neighbor)].index)];
        const double delta[3] = {
            point.x - center.x, point.y - center.y, point.z - center.z};
        for (int row = 0; row < 3; ++row) {
            for (int column = 0; column < 3; ++column) {
                covariance[row][column] += delta[row] * delta[column];
            }
        }
    }
    for (auto& row : covariance) {
        for (double& value : row) value *= inverse_count;
    }
    double smallest = 0.0;
    Point3 normal{};
    if (!smallest_eigenpair(covariance, &smallest, &normal)) return false;
    const double rms = std::sqrt(std::max(smallest, 0.0));
    if (rms > options.maximum_neighbor_rms_m) return false;
    const double perpendicular = std::abs(
        (candidate.x - center.x) * normal.x +
        (candidate.y - center.y) * normal.y +
        (candidate.z - center.z) * normal.z);
    return perpendicular <= options.maximum_perpendicular_m;
}

bool supported_by_partition(const Point3& candidate,
                            const PartitionIndex& partition,
                            const aether_local_manifold_options_t& options,
                            double* out_nearest_distance = nullptr) {
    const std::size_t keep = static_cast<std::size_t>(options.neighbors);
    std::array<Neighbor, 64> neighbors{};
    const std::size_t neighbor_count =
        partition.nearest_neighbors(candidate, keep, neighbors.data());
    return supported_by_partition_with_neighbors(
        candidate, partition, options, neighbors.data(), neighbor_count,
        out_nearest_distance);
}

bool valid_options(const aether_local_manifold_options_t& options) {
    return options.neighbors >= 3 && options.neighbors <= 64 &&
        options.partition_count >= 3 &&
        options.first_partition >= 0 &&
        options.first_partition < options.partition_count &&
        options.second_partition >= 0 &&
        options.second_partition < options.partition_count &&
        options.first_partition != options.second_partition &&
        std::isfinite(options.maximum_nearest_m) &&
        options.maximum_nearest_m > 0.0 &&
        std::isfinite(options.maximum_neighbor_radius_m) &&
        options.maximum_neighbor_radius_m >= options.maximum_nearest_m &&
        std::isfinite(options.maximum_neighbor_rms_m) &&
        options.maximum_neighbor_rms_m >= 0.0 &&
        std::isfinite(options.maximum_perpendicular_m) &&
        options.maximum_perpendicular_m >= 0.0;
}

struct ErrorSummary {
    int32_t count = 0;
    double median_m = 0.0;
    double p90_m = 0.0;
    double p95_m = 0.0;
    double maximum_m = 0.0;
    double within_5cm = 0.0;
    double within_10cm = 0.0;
    double within_20cm = 0.0;
};

double linear_quantile(const double* sorted,
                       int32_t count,
                       double quantile) {
    const double position =
        static_cast<double>(count - 1) * quantile;
    const int32_t lower = static_cast<int32_t>(std::floor(position));
    const int32_t upper = static_cast<int32_t>(std::ceil(position));
    const double weight = position - static_cast<double>(lower);
    return sorted[lower] + (sorted[upper] - sorted[lower]) * weight;
}

ErrorSummary summarize_errors(double* distances, int32_t count) {
    ErrorSummary summary{};
    summary.count = count;
    if (count == 0) return summary;
    std::sort(distances, distances + count);
    summary.median_m = linear_quantile(distances, count, 0.50);
    summary.p90_m = linear_quantile(distances, count, 0.90);
    summary.p95_m = linear_quantile(distances, count, 0.95);
    summary.maximum_m = distances[count - 1];
    int32_t within_5cm = 0;
    int32_t within_10cm = 0;
    int32_t within_20cm = 0;
    for (int32_t index = 0; index < count; ++index) {
        const double distance = distances[index];
        if (distance <= 0.05) ++within_5cm;
        if (distance <= 0.10) ++within_10cm;
        if (distance <= 0.20) ++within_20cm;
    }
    const double inverse_count = 1.0 / static_cast<double>(count);
    summary.within_5cm = static_cast<double>(within_5cm) * inverse_count;
    summary.within_10cm = static_cast<double>(within_10cm) * inverse_count;
    summary.within_20cm = static_cast<double>(within_20cm) * inverse_count;
    return summary;
}

bool quality_non_regressing(const ErrorSummary& before,
                            const ErrorSummary& after) {
    if (after.count == 0) return true;
    constexpr double kComparisonEpsilon = 1e-9;
    return after.median_m <= before.median_m + kComparisonEpsilon &&
        after.p90_m <= before.p90_m + kComparisonEpsilon &&
        after.p95_m <= before.p95_m + kComparisonEpsilon &&
        after.maximum_m <= before.maximum_m + kComparisonEpsilon &&
        after.within_5cm + kComparisonEpsilon >= before.within_5cm &&
        after.within_10cm + kComparisonEpsilon >= before.within_10cm &&
        after.within_20cm + kComparisonEpsilon >= before.within_20cm;
}

}  // namespace

struct aether_local_manifold_session {
    aether_local_manifold_options_t options{};
    std::vector<PartitionIndex> partitions;
    CombinedPartitionIndex combined_partitions;
};

void aether_local_manifold_options_default(
    aether_local_manifold_options_t* out_options) {
    if (!out_options) return;
    *out_options = aether_local_manifold_options_t{};
    out_options->neighbors = 8;
    out_options->partition_count = 3;
    out_options->first_partition = 0;
    out_options->second_partition = 1;
    out_options->maximum_nearest_m = 0.12;
    out_options->maximum_neighbor_radius_m = 0.25;
    out_options->maximum_neighbor_rms_m = 0.03;
    out_options->maximum_perpendicular_m = 0.02;
}

int32_t aether_local_manifold_session_create(
    const float* sparse_xyz,
    int32_t sparse_point_count,
    const aether_local_manifold_options_t* options,
    aether_local_manifold_session_t** out_session) {
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
    try {
#endif
    if (out_session) *out_session = nullptr;
    if (!sparse_xyz || sparse_point_count <= 0 || !options || !out_session ||
        !valid_options(*options) ||
        sparse_point_count < options->neighbors * options->partition_count) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    std::vector<Point3> points(static_cast<std::size_t>(sparse_point_count));
    for (int32_t index = 0; index < sparse_point_count; ++index) {
        points[static_cast<std::size_t>(index)] = load_point(sparse_xyz, index);
        if (!finite_point(points[static_cast<std::size_t>(index)])) {
            return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        }
    }
    std::vector<int32_t> order(static_cast<std::size_t>(sparse_point_count));
    std::iota(order.begin(), order.end(), 0);
    std::sort(order.begin(), order.end(), [&](int32_t left, int32_t right) {
        const Point3& a = points[static_cast<std::size_t>(left)];
        const Point3& b = points[static_cast<std::size_t>(right)];
        if (a.x != b.x) return a.x < b.x;
        if (a.y != b.y) return a.y < b.y;
        if (a.z != b.z) return a.z < b.z;
        return left < right;
    });

    std::unique_ptr<aether_local_manifold_session> session(
        new (std::nothrow) aether_local_manifold_session());
    if (!session) return AETHER_BIRTH_OWNERSHIP_ERR_INTERNAL;
    session->options = *options;
    session->partitions.resize(
        static_cast<std::size_t>(options->partition_count));
    const std::size_t partition_capacity = static_cast<std::size_t>(
        sparse_point_count / options->partition_count + 1);
    for (auto& partition : session->partitions) {
        partition.points.reserve(partition_capacity);
    }
    if (options->partition_count == 3) {
        session->combined_partitions.entries.reserve(
            static_cast<std::size_t>(sparse_point_count));
    }
    for (int32_t rank = 0; rank < sparse_point_count; ++rank) {
        const int32_t partition = rank % options->partition_count;
        const Point3& point = points[static_cast<std::size_t>(
            order[static_cast<std::size_t>(rank)])];
        const int32_t local_index = static_cast<int32_t>(
            session->partitions[
                static_cast<std::size_t>(partition)].points.size());
        session->partitions[static_cast<std::size_t>(partition)].points.push_back(
            point);
        if (options->partition_count == 3) {
            session->combined_partitions.entries.push_back(
                CombinedPartitionIndex::Entry{
                    point, partition, local_index});
        }
    }
    for (auto& partition : session->partitions) {
        if (partition.points.size() <
            static_cast<std::size_t>(options->neighbors)) {
            return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        }
        if (options->partition_count != 3) partition.build();
    }
    if (options->partition_count == 3) {
        session->combined_partitions.build();
    }
    *out_session = session.release();
    return AETHER_BIRTH_OWNERSHIP_OK;
#if defined(__cpp_exceptions) || defined(__EXCEPTIONS)
    } catch (...) {
        if (out_session) *out_session = nullptr;
        return AETHER_BIRTH_OWNERSHIP_ERR_INTERNAL;
    }
#endif
}

int32_t aether_local_manifold_session_filter(
    const aether_local_manifold_session_t* session,
    const float* candidate_xyz,
    int32_t candidate_count,
    const uint8_t* candidate_eligible,
    uint8_t* out_first_support,
    uint8_t* out_second_support,
    uint8_t* out_birth,
    int32_t output_capacity) {
    if (!session || !candidate_xyz || candidate_count < 0 || !out_first_support ||
        !out_second_support || !out_birth || output_capacity < candidate_count) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    std::memset(out_first_support, 0, static_cast<std::size_t>(output_capacity));
    std::memset(out_second_support, 0, static_cast<std::size_t>(output_capacity));
    std::memset(out_birth, 0, static_cast<std::size_t>(output_capacity));
    for (int32_t index = 0; index < candidate_count; ++index) {
        if (candidate_eligible && candidate_eligible[index] == 0) continue;
        const Point3 candidate = load_point(candidate_xyz, index);
        if (!finite_point(candidate)) return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        const std::size_t first_partition = static_cast<std::size_t>(
            session->options.first_partition);
        const std::size_t second_partition = static_cast<std::size_t>(
            session->options.second_partition);
        bool first = false;
        bool second = false;
        if (session->options.partition_count == 3) {
            std::array<std::array<Neighbor, 64>, 3> all_neighbors{};
            std::array<std::size_t, 3> neighbor_counts{};
            session->combined_partitions.nearest_neighbors_all(
                candidate,
                static_cast<std::size_t>(session->options.neighbors),
                &all_neighbors, &neighbor_counts);
            first = supported_by_partition_with_neighbors(
                candidate, session->partitions[first_partition],
                session->options, all_neighbors[first_partition].data(),
                neighbor_counts[first_partition]);
            second = supported_by_partition_with_neighbors(
                candidate, session->partitions[second_partition],
                session->options, all_neighbors[second_partition].data(),
                neighbor_counts[second_partition]);
        } else {
            first = supported_by_partition(
                candidate, session->partitions[first_partition],
                session->options);
            second = supported_by_partition(
                candidate, session->partitions[second_partition],
                session->options);
        }
        out_first_support[index] = first ? 1 : 0;
        out_second_support[index] = second ? 1 : 0;
        out_birth[index] = first && second ? 1 : 0;
    }
    return AETHER_BIRTH_OWNERSHIP_OK;
}

int32_t aether_local_manifold_session_filter_reference_certified(
    const aether_local_manifold_session_t* session,
    const float* candidate_xyz,
    int32_t candidate_count,
    const uint8_t* candidate_eligible,
    int32_t production_fold,
    uint8_t* out_birth,
    int32_t output_capacity,
    aether_reference_birth_certificate_result_t* out_result) {
    if (out_result) {
        *out_result = aether_reference_birth_certificate_result_t{};
    }
    if (out_birth && output_capacity > 0) {
        std::memset(out_birth, 0, static_cast<std::size_t>(output_capacity));
    }
    if (!session || !candidate_xyz || candidate_count < 0 ||
        production_fold < 0 || production_fold >= 3 || !out_birth ||
        output_capacity < candidate_count || !out_result) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    if (session->options.partition_count != 3 ||
        session->partitions.size() != 3) {
        return AETHER_BIRTH_OWNERSHIP_ERR_UNSUPPORTED;
    }
    if (candidate_count == 0) return AETHER_BIRTH_OWNERSHIP_OK;
    const std::size_t count = static_cast<std::size_t>(candidate_count);
    if (count > std::numeric_limits<std::size_t>::max() / 3) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    std::unique_ptr<uint8_t[]> supports(
        new (std::nothrow) uint8_t[count * 3]);
    std::unique_ptr<double[]> nearest_distances(
        new (std::nothrow) double[count * 3]);
    std::unique_ptr<double[]> before_distances(
        new (std::nothrow) double[count]);
    std::unique_ptr<double[]> after_distances(
        new (std::nothrow) double[count]);
    if (!supports || !nearest_distances || !before_distances ||
        !after_distances) {
        return AETHER_BIRTH_OWNERSHIP_ERR_INTERNAL;
    }
    std::memset(supports.get(), 0, count * 3);

    for (int32_t candidate_index = 0; candidate_index < candidate_count;
         ++candidate_index) {
        if (candidate_eligible && candidate_eligible[candidate_index] == 0) {
            continue;
        }
        const Point3 candidate = load_point(candidate_xyz, candidate_index);
        if (!finite_point(candidate)) {
            return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        }
        std::array<std::array<Neighbor, 64>, 3> all_neighbors{};
        std::array<std::size_t, 3> neighbor_counts{};
        session->combined_partitions.nearest_neighbors_all(
            candidate, static_cast<std::size_t>(session->options.neighbors),
            &all_neighbors, &neighbor_counts);
        for (int32_t partition_index = 0; partition_index < 3;
             ++partition_index) {
            const std::size_t partition =
                static_cast<std::size_t>(partition_index);
            supports[static_cast<std::size_t>(partition_index) * count +
                     static_cast<std::size_t>(candidate_index)] =
                supported_by_partition_with_neighbors(
                    candidate,
                    session->partitions[partition],
                    session->options,
                    all_neighbors[partition].data(),
                    neighbor_counts[partition],
                    &nearest_distances[
                        static_cast<std::size_t>(partition_index) * count +
                        static_cast<std::size_t>(candidate_index)])
                ? 1
                : 0;
        }
    }

    uint32_t failed_fold_mask = 0;
    for (int32_t fold = 0; fold < 3; ++fold) {
        const int32_t first_prior = (fold + 1) % 3;
        const int32_t second_prior = (fold + 2) % 3;
        int32_t before_count = 0;
        int32_t after_count = 0;
        for (int32_t candidate_index = 0; candidate_index < candidate_count;
             ++candidate_index) {
            if (candidate_eligible && candidate_eligible[candidate_index] == 0) {
                continue;
            }
            const double distance = nearest_distances[
                static_cast<std::size_t>(fold) * count +
                static_cast<std::size_t>(candidate_index)];
            before_distances[static_cast<std::size_t>(before_count++)] = distance;
            const std::size_t candidate_offset =
                static_cast<std::size_t>(candidate_index);
            if (supports[static_cast<std::size_t>(first_prior) * count +
                         candidate_offset] != 0 &&
                supports[static_cast<std::size_t>(second_prior) * count +
                         candidate_offset] != 0) {
                after_distances[static_cast<std::size_t>(after_count++)] = distance;
            }
        }
        const ErrorSummary before =
            summarize_errors(before_distances.get(), before_count);
        const ErrorSummary after =
            summarize_errors(after_distances.get(), after_count);
        if (!quality_non_regressing(before, after)) {
            failed_fold_mask |= UINT32_C(1) << static_cast<uint32_t>(fold);
        }
    }

    const int32_t production_first = (production_fold + 1) % 3;
    const int32_t production_second = (production_fold + 2) % 3;
    int32_t pre_certificate_birth_count = 0;
    for (int32_t candidate_index = 0; candidate_index < candidate_count;
         ++candidate_index) {
        if (candidate_eligible && candidate_eligible[candidate_index] == 0) {
            continue;
        }
        const std::size_t candidate_offset =
            static_cast<std::size_t>(candidate_index);
        const bool born =
            supports[static_cast<std::size_t>(production_first) * count +
                     candidate_offset] != 0 &&
            supports[static_cast<std::size_t>(production_second) * count +
                     candidate_offset] != 0;
        if (!born) continue;
        ++pre_certificate_birth_count;
        if (failed_fold_mask == 0) out_birth[candidate_index] = 1;
    }
    out_result->failed_fold_mask = failed_fold_mask;
    out_result->pre_certificate_birth_count = pre_certificate_birth_count;
    out_result->blocked_birth_count =
        failed_fold_mask == 0 ? 0 : pre_certificate_birth_count;
    out_result->final_birth_count =
        failed_fold_mask == 0 ? pre_certificate_birth_count : 0;
    return AETHER_BIRTH_OWNERSHIP_OK;
}

void aether_local_manifold_session_free(
    aether_local_manifold_session_t* session) {
    delete session;
}

int32_t aether_filter_finite_floor_ownership(
    const float* candidate_xyz,
    int32_t candidate_count,
    const aether_finite_floor_domain_t* floor,
    double floor_slab_m,
    double domain_margin_m,
    uint8_t* out_owned,
    int32_t output_capacity) {
    if (!candidate_xyz || candidate_count < 0 || !floor ||
        !std::isfinite(floor_slab_m) || floor_slab_m <= 0.0 ||
        !std::isfinite(domain_margin_m) || domain_margin_m < 0.0 ||
        !out_owned || output_capacity < candidate_count) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    std::memset(out_owned, 0, static_cast<std::size_t>(output_capacity));
    if (floor->certified == 0) return AETHER_BIRTH_OWNERSHIP_OK;

    const double normal_norm = std::sqrt(
        floor->normal_xyz[0] * floor->normal_xyz[0] +
        floor->normal_xyz[1] * floor->normal_xyz[1] +
        floor->normal_xyz[2] * floor->normal_xyz[2]);
    const double basis_u_norm = std::sqrt(
        floor->basis_u_xyz[0] * floor->basis_u_xyz[0] +
        floor->basis_u_xyz[1] * floor->basis_u_xyz[1] +
        floor->basis_u_xyz[2] * floor->basis_u_xyz[2]);
    const double basis_v_norm = std::sqrt(
        floor->basis_v_xyz[0] * floor->basis_v_xyz[0] +
        floor->basis_v_xyz[1] * floor->basis_v_xyz[1] +
        floor->basis_v_xyz[2] * floor->basis_v_xyz[2]);
    if (!(normal_norm > 0.0) || !(basis_u_norm > 0.0) ||
        !(basis_v_norm > 0.0) || !std::isfinite(normal_norm) ||
        !std::isfinite(basis_u_norm) || !std::isfinite(basis_v_norm) ||
        !std::isfinite(floor->plane_value_n_dot_x) ||
        !std::isfinite(floor->bounds_u_m[0]) ||
        !std::isfinite(floor->bounds_u_m[1]) ||
        !std::isfinite(floor->bounds_v_m[0]) ||
        !std::isfinite(floor->bounds_v_m[1]) ||
        floor->bounds_u_m[0] > floor->bounds_u_m[1] ||
        floor->bounds_v_m[0] > floor->bounds_v_m[1]) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    for (int32_t index = 0; index < candidate_count; ++index) {
        const Point3 candidate = load_point(candidate_xyz, index);
        if (!finite_point(candidate)) return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        const double signed_distance =
            (candidate.x * floor->normal_xyz[0] +
             candidate.y * floor->normal_xyz[1] +
             candidate.z * floor->normal_xyz[2]) /
                normal_norm -
            floor->plane_value_n_dot_x;
        if (signed_distance > floor_slab_m) continue;
        const double coordinate_u =
            (candidate.x * floor->basis_u_xyz[0] +
             candidate.y * floor->basis_u_xyz[1] +
             candidate.z * floor->basis_u_xyz[2]) /
            basis_u_norm;
        const double coordinate_v =
            (candidate.x * floor->basis_v_xyz[0] +
             candidate.y * floor->basis_v_xyz[1] +
             candidate.z * floor->basis_v_xyz[2]) /
            basis_v_norm;
        if (coordinate_u >= floor->bounds_u_m[0] - domain_margin_m &&
            coordinate_u <= floor->bounds_u_m[1] + domain_margin_m &&
            coordinate_v >= floor->bounds_v_m[0] - domain_margin_m &&
            coordinate_v <= floor->bounds_v_m[1] + domain_margin_m) {
            out_owned[index] = 1;
        }
    }
    return AETHER_BIRTH_OWNERSHIP_OK;
}

int32_t aether_filter_finite_wall_ownership(
    const float* candidate_xyz,
    int32_t candidate_count,
    double floor_value_n_dot_x,
    const aether_structural_wall_t* walls,
    int32_t wall_count,
    double wall_slab_m,
    double domain_margin_m,
    uint8_t* out_owned,
    int32_t output_capacity) {
    if (!candidate_xyz || candidate_count < 0 || wall_count < 0 ||
        (wall_count > 0 && !walls) || !std::isfinite(floor_value_n_dot_x) ||
        !std::isfinite(wall_slab_m) || wall_slab_m <= 0.0 ||
        !std::isfinite(domain_margin_m) || domain_margin_m < 0.0 ||
        !out_owned || output_capacity < candidate_count) {
        return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
    }
    std::memset(out_owned, 0, static_cast<std::size_t>(output_capacity));
    for (int32_t candidate_index = 0; candidate_index < candidate_count;
         ++candidate_index) {
        const Point3 candidate = load_point(candidate_xyz, candidate_index);
        if (!finite_point(candidate)) return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
        for (int32_t wall_index = 0; wall_index < wall_count; ++wall_index) {
            const auto& wall = walls[wall_index];
            if (wall.certified == 0) continue;
            const double normal_norm = std::sqrt(
                wall.normal_xyz[0] * wall.normal_xyz[0] +
                wall.normal_xyz[1] * wall.normal_xyz[1] +
                wall.normal_xyz[2] * wall.normal_xyz[2]);
            if (!(normal_norm > 0.0) || !std::isfinite(normal_norm)) {
                return AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS;
            }
            const double distance = std::abs(
                (candidate.x * wall.normal_xyz[0] +
                 candidate.y * wall.normal_xyz[1] +
                 candidate.z * wall.normal_xyz[2]) /
                    normal_norm -
                wall.plane_value_n_dot_x);
            if (distance > wall_slab_m) continue;
            const double coordinate_u =
                candidate.x * wall.basis_u_xyz[0] +
                candidate.y * wall.basis_u_xyz[1] +
                candidate.z * wall.basis_u_xyz[2];
            const double height =
                candidate.x * wall.basis_v_xyz[0] +
                candidate.y * wall.basis_v_xyz[1] +
                candidate.z * wall.basis_v_xyz[2] - floor_value_n_dot_x;
            if (coordinate_u >= wall.bounds_u_m[0] - domain_margin_m &&
                coordinate_u <= wall.bounds_u_m[1] + domain_margin_m &&
                height >= wall.bounds_height_m[0] - domain_margin_m &&
                height <= wall.bounds_height_m[1] + domain_margin_m) {
                out_owned[candidate_index] = 1;
                break;
            }
        }
    }
    return AETHER_BIRTH_OWNERSHIP_OK;
}

const char* aether_birth_ownership_result_str(int32_t rc) {
    switch (rc) {
        case AETHER_BIRTH_OWNERSHIP_OK: return "ok";
        case AETHER_BIRTH_OWNERSHIP_ERR_BAD_ARGS: return "bad arguments";
        case AETHER_BIRTH_OWNERSHIP_ERR_UNSUPPORTED: return "unsupported";
        case AETHER_BIRTH_OWNERSHIP_ERR_INTERNAL: return "internal failure";
        default: return "unknown";
    }
}
