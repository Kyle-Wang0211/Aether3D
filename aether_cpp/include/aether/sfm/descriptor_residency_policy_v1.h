#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <list>
#include <unordered_map>
#include <vector>

namespace aether::sfm {

enum class DescriptorFormatV1 : uint32_t {
    kRawU8 = 1,
    kHalf = 2,
};

struct DescriptorResidencyKeyV1 {
    uint64_t runtime_session_nonce = 0;
    uint32_t frame_ordinal = 0;
    uint32_t generation = 0;

    friend bool operator==(const DescriptorResidencyKeyV1& lhs,
                           const DescriptorResidencyKeyV1& rhs) {
        return lhs.runtime_session_nonce == rhs.runtime_session_nonce &&
               lhs.frame_ordinal == rhs.frame_ordinal &&
               lhs.generation == rhs.generation;
    }

    friend bool operator!=(const DescriptorResidencyKeyV1& lhs,
                           const DescriptorResidencyKeyV1& rhs) {
        return !(lhs == rhs);
    }
};

struct DescriptorResidencyKeyHashV1 {
    size_t operator()(const DescriptorResidencyKeyV1& key) const noexcept {
        size_t hash = std::hash<uint64_t>{}(key.runtime_session_nonce);
        hash ^= std::hash<uint32_t>{}(key.frame_ordinal) +
                UINT64_C(0x9e3779b97f4a7c15) + (hash << 6) + (hash >> 2);
        hash ^= std::hash<uint32_t>{}(key.generation) +
                UINT64_C(0x9e3779b97f4a7c15) + (hash << 6) + (hash >> 2);
        return hash;
    }
};

struct DescriptorResidencyMetadataV1 {
    uint32_t descriptor_count = 0;
    DescriptorFormatV1 format = DescriptorFormatV1::kRawU8;
    uint64_t byte_size = 0;

    friend bool operator==(const DescriptorResidencyMetadataV1& lhs,
                           const DescriptorResidencyMetadataV1& rhs) {
        return lhs.descriptor_count == rhs.descriptor_count &&
               lhs.format == rhs.format && lhs.byte_size == rhs.byte_size;
    }
};

struct DescriptorResidencyAccessV1 {
    bool hit = false;
    bool admitted = false;
    bool replaced_stale = false;
    std::vector<DescriptorResidencyKeyV1> evicted;
};

struct DescriptorResidencyStatsV1 {
    uint64_t hits = 0;
    uint64_t misses = 0;
    uint64_t evictions = 0;
    uint64_t stale_replacements = 0;
    uint64_t oversize_bypasses = 0;
};

/// Backend-neutral ownership and eviction policy for immutable descriptor
/// tables. Backend resource handles deliberately do not appear here.
class DescriptorResidencyPolicyV1 {
  public:
    explicit DescriptorResidencyPolicyV1(uint64_t byte_budget)
        : byte_budget_(byte_budget) {}

    DescriptorResidencyAccessV1 Access(
        const DescriptorResidencyKeyV1& key,
        const DescriptorResidencyMetadataV1& metadata) {
        DescriptorResidencyAccessV1 result;
        auto exact = entries_.find(key);
        if (exact != entries_.end() && exact->second.metadata == metadata) {
            lru_.splice(lru_.begin(), lru_, exact->second.lru_position);
            exact->second.lru_position = lru_.begin();
            ++stats_.hits;
            result.hit = true;
            result.admitted = true;
            return result;
        }

        ++stats_.misses;
        std::vector<DescriptorResidencyKeyV1> stale;
        stale.reserve(1);
        for (const auto& [resident_key, entry] : entries_) {
            (void)entry;
            if (resident_key.runtime_session_nonce == key.runtime_session_nonce &&
                resident_key.frame_ordinal == key.frame_ordinal) {
                stale.push_back(resident_key);
            }
        }
        SortKeys(&stale);
        for (const auto& stale_key : stale) {
            Erase(stale_key);
            result.evicted.push_back(stale_key);
        }
        if (!stale.empty()) {
            result.replaced_stale = true;
            stats_.stale_replacements += stale.size();
        }

        if (metadata.byte_size == 0 || metadata.byte_size > byte_budget_) {
            ++stats_.oversize_bypasses;
            return result;
        }
        while (resident_bytes_ > byte_budget_ - metadata.byte_size) {
            const DescriptorResidencyKeyV1 victim = lru_.back();
            lru_.pop_back();
            const auto victim_it = entries_.find(victim);
            if (victim_it != entries_.end()) {
                resident_bytes_ -= victim_it->second.metadata.byte_size;
                entries_.erase(victim_it);
            }
            result.evicted.push_back(victim);
            ++stats_.evictions;
        }

        lru_.push_front(key);
        Entry entry;
        entry.metadata = metadata;
        entry.lru_position = lru_.begin();
        entries_.emplace(key, entry);
        resident_bytes_ += metadata.byte_size;
        result.admitted = true;
        return result;
    }

    bool Contains(const DescriptorResidencyKeyV1& key) const {
        return entries_.find(key) != entries_.end();
    }

    std::vector<DescriptorResidencyKeyV1> InvalidateFrame(
        uint64_t runtime_session_nonce,
        uint32_t frame_ordinal) {
        std::vector<DescriptorResidencyKeyV1> removed;
        for (const auto& [key, entry] : entries_) {
            (void)entry;
            if (key.runtime_session_nonce == runtime_session_nonce &&
                key.frame_ordinal == frame_ordinal) {
                removed.push_back(key);
            }
        }
        SortKeys(&removed);
        for (const auto& key : removed) Erase(key);
        return removed;
    }

    std::vector<DescriptorResidencyKeyV1> ClearSession(
        uint64_t runtime_session_nonce) {
        std::vector<DescriptorResidencyKeyV1> removed;
        for (const auto& [key, entry] : entries_) {
            (void)entry;
            if (key.runtime_session_nonce == runtime_session_nonce) {
                removed.push_back(key);
            }
        }
        SortKeys(&removed);
        for (const auto& key : removed) Erase(key);
        return removed;
    }

    std::vector<DescriptorResidencyKeyV1> ClearAll() {
        std::vector<DescriptorResidencyKeyV1> removed;
        removed.reserve(entries_.size());
        for (const auto& [key, entry] : entries_) {
            (void)entry;
            removed.push_back(key);
        }
        SortKeys(&removed);
        entries_.clear();
        lru_.clear();
        resident_bytes_ = 0;
        return removed;
    }

    bool empty() const { return entries_.empty(); }
    size_t size() const { return entries_.size(); }
    uint64_t resident_bytes() const { return resident_bytes_; }
    uint64_t byte_budget() const { return byte_budget_; }
    DescriptorResidencyStatsV1 stats() const { return stats_; }

  private:
    struct Entry {
        DescriptorResidencyMetadataV1 metadata;
        std::list<DescriptorResidencyKeyV1>::iterator lru_position;
    };

    static void SortKeys(std::vector<DescriptorResidencyKeyV1>* keys) {
        std::sort(keys->begin(), keys->end(),
                  [](const DescriptorResidencyKeyV1& lhs,
                     const DescriptorResidencyKeyV1& rhs) {
                      if (lhs.runtime_session_nonce != rhs.runtime_session_nonce) {
                          return lhs.runtime_session_nonce <
                                 rhs.runtime_session_nonce;
                      }
                      if (lhs.frame_ordinal != rhs.frame_ordinal) {
                          return lhs.frame_ordinal < rhs.frame_ordinal;
                      }
                      return lhs.generation < rhs.generation;
                  });
    }

    void Erase(const DescriptorResidencyKeyV1& key) {
        const auto it = entries_.find(key);
        if (it == entries_.end()) return;
        resident_bytes_ -= it->second.metadata.byte_size;
        lru_.erase(it->second.lru_position);
        entries_.erase(it);
    }

    uint64_t byte_budget_ = 0;
    uint64_t resident_bytes_ = 0;
    std::list<DescriptorResidencyKeyV1> lru_;
    std::unordered_map<DescriptorResidencyKeyV1, Entry,
                       DescriptorResidencyKeyHashV1>
        entries_;
    DescriptorResidencyStatsV1 stats_;
};

}  // namespace aether::sfm
