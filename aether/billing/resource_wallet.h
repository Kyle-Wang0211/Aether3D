// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_BILLING_RESOURCE_WALLET_H
#define AETHER_BILLING_RESOURCE_WALLET_H

#include <cstdint>
#include <map>

namespace aether {
namespace billing {

enum class WalletError : uint8_t {
    kNone = 0,
    kInvalidAmount = 1,
    kInsufficientQuota = 2,
    kOverflow = 3,
};

struct WalletDecision {
    bool allowed{false};
    WalletError error{WalletError::kNone};
    int64_t available_after{0};
    uint64_t ledger_sequence{0};
};

struct WalletSnapshot {
    int64_t capacity_units{0};
    int64_t available_units{0};
    int64_t consumed_lifetime_units{0};
    uint64_t ledger_sequence{0};
};

// Deterministic resource wallet with idempotent charging by request id.
class ResourceWallet {
public:
    explicit ResourceWallet(int64_t capacity_units)
        : capacity_units_(capacity_units), available_units_(capacity_units) {}

    WalletDecision charge(uint64_t request_id, int64_t units) {
        auto it = cached_decisions_.find(request_id);
        if (it != cached_decisions_.end()) {
            return it->second;
        }

        WalletDecision decision{};
        decision.ledger_sequence = next_ledger_sequence_++;

        if (units <= 0) {
            decision.allowed = false;
            decision.error = WalletError::kInvalidAmount;
            decision.available_after = available_units_;
            cached_decisions_[request_id] = decision;
            return decision;
        }
        if (units > available_units_) {
            decision.allowed = false;
            decision.error = WalletError::kInsufficientQuota;
            decision.available_after = available_units_;
            cached_decisions_[request_id] = decision;
            return decision;
        }
        if (consumed_lifetime_units_ > (INT64_MAX - units)) {
            decision.allowed = false;
            decision.error = WalletError::kOverflow;
            decision.available_after = available_units_;
            cached_decisions_[request_id] = decision;
            return decision;
        }

        available_units_ -= units;
        consumed_lifetime_units_ += units;
        decision.allowed = true;
        decision.error = WalletError::kNone;
        decision.available_after = available_units_;
        cached_decisions_[request_id] = decision;
        return decision;
    }

    WalletDecision credit(int64_t units) {
        WalletDecision decision{};
        decision.ledger_sequence = next_ledger_sequence_++;
        if (units <= 0) {
            decision.allowed = false;
            decision.error = WalletError::kInvalidAmount;
            decision.available_after = available_units_;
            return decision;
        }
        const int64_t headroom = capacity_units_ - available_units_;
        const int64_t delta = units > headroom ? headroom : units;
        available_units_ += delta;
        decision.allowed = true;
        decision.error = WalletError::kNone;
        decision.available_after = available_units_;
        return decision;
    }

    WalletSnapshot snapshot() const {
        return WalletSnapshot{
            capacity_units_,
            available_units_,
            consumed_lifetime_units_,
            next_ledger_sequence_};
    }

private:
    int64_t capacity_units_{0};
    int64_t available_units_{0};
    int64_t consumed_lifetime_units_{0};
    uint64_t next_ledger_sequence_{1};
    std::map<uint64_t, WalletDecision> cached_decisions_{};
};

}  // namespace billing
}  // namespace aether

#endif  // AETHER_BILLING_RESOURCE_WALLET_H
