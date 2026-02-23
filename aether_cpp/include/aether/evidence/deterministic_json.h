// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#ifndef AETHER_EVIDENCE_DETERMINISTIC_JSON_H
#define AETHER_EVIDENCE_DETERMINISTIC_JSON_H

#include "aether/core/status.h"
#include <cstdint>
#include <string>
#include <utility>
#include <vector>

namespace aether {
namespace evidence {

enum class CanonicalJsonType : uint8_t {
    kNull = 0,
    kBool = 1,
    kInt = 2,
    kString = 3,
    kNumber = 4,
    kArray = 5,
    kObject = 6,
};

struct CanonicalJsonValue {
    CanonicalJsonType type{CanonicalJsonType::kNull};
    bool bool_value{false};
    int64_t int_value{0};
    std::string string_value;
    std::string number_value;
    std::vector<CanonicalJsonValue> array_value;
    std::vector<std::pair<std::string, CanonicalJsonValue>> object_value;

    static CanonicalJsonValue make_null();
    static CanonicalJsonValue make_bool(bool v);
    static CanonicalJsonValue make_int(int64_t v);
    static CanonicalJsonValue make_string(std::string v);
    static CanonicalJsonValue make_number(std::string v);
    static CanonicalJsonValue make_number_quantized(double v, int precision = 4);
    static CanonicalJsonValue make_array(std::vector<CanonicalJsonValue> values);
    static CanonicalJsonValue make_object(
        std::vector<std::pair<std::string, CanonicalJsonValue>> entries,
        bool sort_keys = true);
};

double quantize_half_away_from_zero(double value, int precision = 4);
std::string format_quantized(double value, int precision = 4);
std::string format_double_no_scientific(double value, int max_precision = 15);

core::Status encode_canonical_json(const CanonicalJsonValue& value, std::string& out_json);
core::Status canonical_json_sha256_hex(const CanonicalJsonValue& value, std::string& out_hex);

}  // namespace evidence
}  // namespace aether

#endif  // AETHER_EVIDENCE_DETERMINISTIC_JSON_H
