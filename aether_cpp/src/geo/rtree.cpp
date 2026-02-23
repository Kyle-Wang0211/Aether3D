// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/geo/rtree.h"
#include "aether/geo/geo_constants.h"
#include "aether/geo/haversine.h"
#include "aether/geo/asc_cell.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace aether {
namespace geo {

// ---------------------------------------------------------------------------
// Internal node structure
// ---------------------------------------------------------------------------
static constexpr std::uint32_t kMaxEntries = RTREE_MAX_ENTRIES;
static constexpr std::uint32_t kMinEntries = RTREE_MIN_ENTRIES;

struct RTreeNode {
    MBR mbr{};
    bool is_leaf{true};
    std::uint32_t count{0};

    // For internal nodes: child indices; for leaf nodes: entry data
    std::uint32_t children[kMaxEntries]{};   // index into node pool
    RTreeEntry entries[kMaxEntries]{};
    MBR child_mbrs[kMaxEntries]{};

    MBR compute_mbr() const {
        if (count == 0) return {};
        MBR r{};
        if (is_leaf) {
            r.lat_min = r.lat_max = entries[0].lat;
            r.lon_min = r.lon_max = entries[0].lon;
            for (std::uint32_t i = 1; i < count; ++i) {
                if (entries[i].lat < r.lat_min) r.lat_min = entries[i].lat;
                if (entries[i].lat > r.lat_max) r.lat_max = entries[i].lat;
                if (entries[i].lon < r.lon_min) r.lon_min = entries[i].lon;
                if (entries[i].lon > r.lon_max) r.lon_max = entries[i].lon;
            }
        } else {
            r = child_mbrs[0];
            for (std::uint32_t i = 1; i < count; ++i) {
                r = mbr_union(r, child_mbrs[i]);
            }
        }
        return r;
    }
};

struct RTree {
    std::vector<RTreeNode> nodes;
    std::uint32_t root{0};
    std::size_t entry_count{0};
    std::uint32_t depth{0};

    std::uint32_t alloc_node() {
        std::uint32_t idx = static_cast<std::uint32_t>(nodes.size());
        nodes.emplace_back();
        return idx;
    }
};

// ---------------------------------------------------------------------------
// MBR operations
// ---------------------------------------------------------------------------
MBR mbr_union(const MBR& a, const MBR& b) {
    MBR r{};
    r.lat_min = (a.lat_min < b.lat_min) ? a.lat_min : b.lat_min;
    r.lat_max = (a.lat_max > b.lat_max) ? a.lat_max : b.lat_max;
    r.lon_min = (a.lon_min < b.lon_min) ? a.lon_min : b.lon_min;
    r.lon_max = (a.lon_max > b.lon_max) ? a.lon_max : b.lon_max;
    return r;
}

static MBR entry_to_mbr(const RTreeEntry& e) {
    return {e.lat, e.lat, e.lon, e.lon};
}

// mbr_enlargement removed (unused; use mbr_enlargement_entry instead)

static double mbr_enlargement_entry(const MBR& base, const RTreeEntry& e) {
    MBR merged = mbr_union(base, entry_to_mbr(e));
    return merged.area() - base.area();
}

// ---------------------------------------------------------------------------
// Split node (simplified R*-tree axis split)
// ---------------------------------------------------------------------------
static std::uint32_t split_leaf(RTree* tree, std::uint32_t node_idx) {
    RTreeNode& node = tree->nodes[node_idx];
    // Sort entries by latitude, split at midpoint
    RTreeEntry all[kMaxEntries + 1];
    std::memcpy(all, node.entries, node.count * sizeof(RTreeEntry));
    std::uint32_t total = node.count;

    std::sort(all, all + total, [](const RTreeEntry& a, const RTreeEntry& b) {
        return a.lat < b.lat;
    });

    std::uint32_t split_pos = total / 2;
    if (split_pos < kMinEntries) split_pos = kMinEntries;
    if (total - split_pos < kMinEntries) split_pos = total - kMinEntries;

    std::uint32_t new_idx = tree->alloc_node();
    // Re-fetch reference after alloc (vector may realloc)
    RTreeNode& orig = tree->nodes[node_idx];
    RTreeNode& sibling = tree->nodes[new_idx];

    orig.count = split_pos;
    std::memcpy(orig.entries, all, split_pos * sizeof(RTreeEntry));
    orig.mbr = orig.compute_mbr();

    sibling.is_leaf = true;
    sibling.count = total - split_pos;
    std::memcpy(sibling.entries, all + split_pos, sibling.count * sizeof(RTreeEntry));
    sibling.mbr = sibling.compute_mbr();

    return new_idx;
}

static std::uint32_t split_internal(RTree* tree, std::uint32_t node_idx) {
    RTreeNode& node = tree->nodes[node_idx];
    std::uint32_t total = node.count;

    // Sort children by MBR lat_min
    struct ChildPair { std::uint32_t child; MBR mbr; };
    std::vector<ChildPair> pairs(total);
    for (std::uint32_t i = 0; i < total; ++i) {
        pairs[i] = {node.children[i], node.child_mbrs[i]};
    }
    std::sort(pairs.begin(), pairs.end(), [](const ChildPair& a, const ChildPair& b) {
        return a.mbr.lat_min < b.mbr.lat_min;
    });

    std::uint32_t split_pos = total / 2;
    if (split_pos < kMinEntries) split_pos = kMinEntries;
    if (total - split_pos < kMinEntries) split_pos = total - kMinEntries;

    std::uint32_t new_idx = tree->alloc_node();
    RTreeNode& orig = tree->nodes[node_idx];
    RTreeNode& sibling = tree->nodes[new_idx];

    orig.is_leaf = false;
    orig.count = split_pos;
    for (std::uint32_t i = 0; i < split_pos; ++i) {
        orig.children[i] = pairs[i].child;
        orig.child_mbrs[i] = pairs[i].mbr;
    }
    orig.mbr = orig.compute_mbr();

    sibling.is_leaf = false;
    sibling.count = total - split_pos;
    for (std::uint32_t i = 0; i < sibling.count; ++i) {
        sibling.children[i] = pairs[split_pos + i].child;
        sibling.child_mbrs[i] = pairs[split_pos + i].mbr;
    }
    sibling.mbr = sibling.compute_mbr();

    return new_idx;
}

// ---------------------------------------------------------------------------
// Insert (with recursive overflow handling)
// ---------------------------------------------------------------------------

// Returns the new sibling node index if a split occurred, or UINT32_MAX if not.
static std::uint32_t insert_recursive(RTree* tree, std::uint32_t node_idx,
                                       const RTreeEntry& entry) {
    RTreeNode& node = tree->nodes[node_idx];

    if (node.is_leaf) {
        if (node.count < kMaxEntries) {
            node.entries[node.count] = entry;
            node.count++;
            node.mbr = node.compute_mbr();
            return UINT32_MAX;
        }
        // Overflow → need to split. Temporarily store the extra entry.
        node.entries[node.count] = entry; // write beyond count (within array)
        node.count++;
        std::uint32_t sib = split_leaf(tree, node_idx);
        return sib;
    }

    // Internal node: choose subtree
    std::uint32_t best = 0;
    double best_enlarge = mbr_enlargement_entry(node.child_mbrs[0], entry);
    for (std::uint32_t i = 1; i < node.count; ++i) {
        double enlarge = mbr_enlargement_entry(node.child_mbrs[i], entry);
        if (enlarge < best_enlarge) {
            best = i;
            best_enlarge = enlarge;
        }
    }

    std::uint32_t sib = insert_recursive(tree, node.children[best], entry);
    // Update MBR of the child we descended into
    tree->nodes[node_idx].child_mbrs[best] = tree->nodes[tree->nodes[node_idx].children[best]].mbr;

    if (sib == UINT32_MAX) {
        tree->nodes[node_idx].mbr = tree->nodes[node_idx].compute_mbr();
        return UINT32_MAX;
    }

    // Need to add sibling as new child
    RTreeNode& n = tree->nodes[node_idx];
    if (n.count < kMaxEntries) {
        n.children[n.count] = sib;
        n.child_mbrs[n.count] = tree->nodes[sib].mbr;
        n.count++;
        n.mbr = n.compute_mbr();
        return UINT32_MAX;
    }

    // Internal overflow → split
    n.children[n.count] = sib;
    n.child_mbrs[n.count] = tree->nodes[sib].mbr;
    n.count++;
    std::uint32_t new_sib = split_internal(tree, node_idx);
    return new_sib;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
RTree* rtree_create() {
    auto* tree = new RTree();
    tree->root = tree->alloc_node();
    tree->nodes[tree->root].is_leaf = true;
    tree->depth = 1;
    return tree;
}

void rtree_destroy(RTree* tree) {
    delete tree;
}

core::Status rtree_insert(RTree* tree, const RTreeEntry& entry) {
    if (!tree) return core::Status::kInvalidArgument;

    std::uint32_t sib = insert_recursive(tree, tree->root, entry);
    if (sib != UINT32_MAX) {
        // Root split → create new root
        std::uint32_t new_root = tree->alloc_node();
        RTreeNode& nr = tree->nodes[new_root];
        nr.is_leaf = false;
        nr.count = 2;
        nr.children[0] = tree->root;
        nr.child_mbrs[0] = tree->nodes[tree->root].mbr;
        nr.children[1] = sib;
        nr.child_mbrs[1] = tree->nodes[sib].mbr;
        nr.mbr = nr.compute_mbr();
        tree->root = new_root;
        tree->depth++;
    }
    tree->entry_count++;
    return core::Status::kOk;
}

core::Status rtree_remove(RTree* tree, std::uint64_t id) {
    if (!tree) return core::Status::kInvalidArgument;

    // Simple linear scan for removal (sufficient for typical sizes)
    // In a production R*-tree we'd use condenseTree, but this is correct.
    std::vector<std::uint32_t> stack;
    stack.push_back(tree->root);

    while (!stack.empty()) {
        std::uint32_t idx = stack.back();
        stack.pop_back();
        RTreeNode& node = tree->nodes[idx];

        if (node.is_leaf) {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                if (node.entries[i].id == id) {
                    // Remove by swapping with last
                    node.entries[i] = node.entries[node.count - 1];
                    node.count--;
                    node.mbr = node.compute_mbr();
                    tree->entry_count--;
                    return core::Status::kOk;
                }
            }
        } else {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                stack.push_back(node.children[i]);
            }
        }
    }
    return core::Status::kOutOfRange;
}

core::Status rtree_query_range(const RTree* tree, const MBR& range,
                               RTreeEntry* out_entries, std::size_t max_results,
                               std::size_t* out_count) {
    if (!tree || !out_count) return core::Status::kInvalidArgument;
    *out_count = 0;

    std::vector<std::uint32_t> stack;
    stack.push_back(tree->root);

    while (!stack.empty()) {
        std::uint32_t idx = stack.back();
        stack.pop_back();
        const RTreeNode& node = tree->nodes[idx];

        if (node.is_leaf) {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                if (range.contains(node.entries[i].lat, node.entries[i].lon)) {
                    if (out_entries && *out_count < max_results) {
                        out_entries[*out_count] = node.entries[i];
                    }
                    (*out_count)++;
                }
            }
        } else {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                if (range.intersects(node.child_mbrs[i])) {
                    stack.push_back(node.children[i]);
                }
            }
        }
    }
    return core::Status::kOk;
}

core::Status rtree_query_knn(const RTree* tree,
                             double query_lat, double query_lon,
                             std::size_t k,
                             KNNResult* out_results, std::size_t* out_count) {
    if (!tree || !out_results || !out_count || k == 0) {
        return core::Status::kInvalidArgument;
    }
    *out_count = 0;

    // Simple approach: collect all entries, compute distances, partial sort
    std::vector<KNNResult> all;
    std::vector<std::uint32_t> stack;
    stack.push_back(tree->root);

    while (!stack.empty()) {
        std::uint32_t idx = stack.back();
        stack.pop_back();
        const RTreeNode& node = tree->nodes[idx];

        if (node.is_leaf) {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                double d = distance_haversine(query_lat, query_lon,
                                              node.entries[i].lat, node.entries[i].lon);
                all.push_back({node.entries[i].id, d});
            }
        } else {
            for (std::uint32_t i = 0; i < node.count; ++i) {
                stack.push_back(node.children[i]);
            }
        }
    }

    if (all.size() > k) {
        std::partial_sort(all.begin(), all.begin() + static_cast<std::ptrdiff_t>(k), all.end(),
            [](const KNNResult& a, const KNNResult& b) { return a.distance_m < b.distance_m; });
        all.resize(k);
    } else {
        std::sort(all.begin(), all.end(),
            [](const KNNResult& a, const KNNResult& b) { return a.distance_m < b.distance_m; });
    }

    *out_count = all.size();
    for (std::size_t i = 0; i < all.size(); ++i) {
        out_results[i] = all[i];
    }
    return core::Status::kOk;
}

core::Status rtree_bulk_load(RTree* tree,
                             const RTreeEntry* entries, std::size_t count) {
    if (!tree || (count > 0 && !entries)) return core::Status::kInvalidArgument;
    if (tree->entry_count > 0) return core::Status::kInvalidArgument;

    // Sort by Hilbert key for spatial locality, then build bottom-up
    struct HilbertEntry {
        RTreeEntry entry;
        std::uint64_t hilbert_key;
    };
    std::vector<HilbertEntry> sorted(count);
    for (std::size_t i = 0; i < count; ++i) {
        sorted[i].entry = entries[i];
        std::uint64_t cell = 0;
        latlon_to_cell(entries[i].lat, entries[i].lon, ASC_CELL_ORDER, &cell);
        sorted[i].hilbert_key = cell;
    }
    std::sort(sorted.begin(), sorted.end(),
        [](const HilbertEntry& a, const HilbertEntry& b) {
            return a.hilbert_key < b.hilbert_key;
        });

    // Build leaf nodes
    std::vector<std::uint32_t> current_level;
    for (std::size_t i = 0; i < count; ) {
        std::uint32_t node_idx = tree->alloc_node();
        RTreeNode& node = tree->nodes[node_idx];
        node.is_leaf = true;
        std::uint32_t fill = 0;
        while (fill < kMaxEntries && i < count) {
            node.entries[fill] = sorted[i].entry;
            fill++;
            i++;
        }
        node.count = fill;
        node.mbr = node.compute_mbr();
        current_level.push_back(node_idx);
    }

    // Build internal levels bottom-up
    std::uint32_t depth = 1;
    while (current_level.size() > 1) {
        std::vector<std::uint32_t> next_level;
        for (std::size_t i = 0; i < current_level.size(); ) {
            std::uint32_t node_idx = tree->alloc_node();
            RTreeNode& node = tree->nodes[node_idx];
            node.is_leaf = false;
            std::uint32_t fill = 0;
            while (fill < kMaxEntries && i < current_level.size()) {
                node.children[fill] = current_level[i];
                node.child_mbrs[fill] = tree->nodes[current_level[i]].mbr;
                fill++;
                i++;
            }
            node.count = fill;
            node.mbr = node.compute_mbr();
            next_level.push_back(node_idx);
        }
        current_level = next_level;
        depth++;
    }

    if (!current_level.empty()) {
        tree->root = current_level[0];
    }
    tree->entry_count = count;
    tree->depth = depth;
    return core::Status::kOk;
}

std::size_t rtree_size(const RTree* tree) {
    return tree ? tree->entry_count : 0;
}

std::uint32_t rtree_depth(const RTree* tree) {
    return tree ? tree->depth : 0;
}

}  // namespace geo
}  // namespace aether
