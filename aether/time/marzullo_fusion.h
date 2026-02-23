// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_TIME_MARZULLO_FUSION_H
#define AETHER_TIME_MARZULLO_FUSION_H

#include <algorithm>
#include <cstdint>
#include <vector>

namespace aether {
namespace time {

struct TimeInterval {
    int64_t low_ms{0};
    int64_t high_ms{0};
    uint32_t source_weight{1};
};

struct FusedInterval {
    int64_t low_ms{0};
    int64_t high_ms{0};
    uint32_t support_weight{0};
    bool valid{false};
};

inline bool normalize_interval(const TimeInterval& in, TimeInterval& out) {
    if (in.source_weight == 0) {
        return false;
    }
    if (in.low_ms <= in.high_ms) {
        out = in;
        return true;
    }
    out.low_ms = in.high_ms;
    out.high_ms = in.low_ms;
    out.source_weight = in.source_weight;
    return true;
}

// Deterministic weighted Marzullo fusion:
// pick the interval with maximal overlap weight, then choose the tightest
// overlap segment for that maximum.
inline FusedInterval fuse_marzullo(const std::vector<TimeInterval>& intervals) {
    struct Event {
        int64_t point_ms{0};
        int32_t delta{0};
        uint8_t edge_kind{0};  // 0 = open, 1 = close
    };

    std::vector<Event> events;
    events.reserve(intervals.size() * 2);

    for (const TimeInterval& interval : intervals) {
        TimeInterval normalized{};
        if (!normalize_interval(interval, normalized)) {
            continue;
        }
        events.push_back(Event{
            normalized.low_ms,
            static_cast<int32_t>(normalized.source_weight),
            0});
        events.push_back(Event{
            normalized.high_ms,
            -static_cast<int32_t>(normalized.source_weight),
            1});
    }

    if (events.empty()) {
        return FusedInterval{};
    }

    std::sort(events.begin(), events.end(), [](const Event& a, const Event& b) {
        if (a.point_ms != b.point_ms) {
            return a.point_ms < b.point_ms;
        }
        return a.edge_kind < b.edge_kind;
    });

    int32_t active_weight = 0;
    int32_t best_weight = 0;
    int64_t best_low = 0;
    int64_t best_high = 0;
    bool has_best = false;

    for (size_t i = 0; i + 1 < events.size(); ++i) {
        active_weight += events[i].delta;
        const int64_t seg_low = events[i].point_ms;
        const int64_t seg_high = events[i + 1].point_ms;
        if (seg_low > seg_high) {
            continue;
        }
        if (active_weight > best_weight) {
            best_weight = active_weight;
            best_low = seg_low;
            best_high = seg_high;
            has_best = true;
            continue;
        }
        if (active_weight == best_weight && has_best) {
            const int64_t current_width = seg_high - seg_low;
            const int64_t best_width = best_high - best_low;
            if (current_width < best_width) {
                best_low = seg_low;
                best_high = seg_high;
            }
        }
    }

    FusedInterval out{};
    out.low_ms = best_low;
    out.high_ms = best_high;
    out.support_weight = best_weight > 0 ? static_cast<uint32_t>(best_weight) : 0;
    out.valid = has_best && out.support_weight > 0;
    return out;
}

}  // namespace time
}  // namespace aether

#endif  // AETHER_TIME_MARZULLO_FUSION_H
