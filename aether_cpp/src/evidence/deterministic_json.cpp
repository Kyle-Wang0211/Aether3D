// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.

#include "aether/evidence/deterministic_json.h"
#include "aether/crypto/sha256.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <iomanip>
#include <sstream>

namespace aether {
namespace evidence {
namespace {

bool is_negative_zero(double value) {
    return value == 0.0 && std::signbit(value);
}

std::string trim_trailing_zeros(std::string text) {
    while (!text.empty() && text.back() == '0') {
        text.pop_back();
    }
    if (!text.empty() && text.back() == '.') {
        text.pop_back();
    }
    if (text.empty() || text == "-0") {
        return "0";
    }
    return text;
}

std::string escape_json_string(const std::string& in) {
    std::string out;
    out.reserve(in.size() + 8);
    out.push_back('"');
    for (unsigned char c : in) {
        switch (c) {
        case '\"': out += "\\\""; break;
        case '\\': out += "\\\\"; break;
        case '\b': out += "\\b"; break;
        case '\f': out += "\\f"; break;
        case '\n': out += "\\n"; break;
        case '\r': out += "\\r"; break;
        case '\t': out += "\\t"; break;
        default:
            if (c < 0x20u) {
                char buf[7];
                std::snprintf(buf, sizeof(buf), "\\u%04x", static_cast<unsigned>(c));
                out += buf;
            } else {
                out.push_back(static_cast<char>(c));
            }
            break;
        }
    }
    out.push_back('"');
    return out;
}

void append_canonical_json(const CanonicalJsonValue& value, std::string& out) {
    switch (value.type) {
    case CanonicalJsonType::kNull:
        out += "null";
        return;
    case CanonicalJsonType::kBool:
        out += value.bool_value ? "true" : "false";
        return;
    case CanonicalJsonType::kInt:
        out += std::to_string(value.int_value);
        return;
    case CanonicalJsonType::kString:
        out += escape_json_string(value.string_value);
        return;
    case CanonicalJsonType::kNumber:
        out += value.number_value;
        return;
    case CanonicalJsonType::kArray:
        out.push_back('[');
        for (size_t i = 0; i < value.array_value.size(); ++i) {
            if (i != 0) out.push_back(',');
            append_canonical_json(value.array_value[i], out);
        }
        out.push_back(']');
        return;
    case CanonicalJsonType::kObject:
        out.push_back('{');
        for (size_t i = 0; i < value.object_value.size(); ++i) {
            if (i != 0) out.push_back(',');
            out += escape_json_string(value.object_value[i].first);
            out.push_back(':');
            append_canonical_json(value.object_value[i].second, out);
        }
        out.push_back('}');
        return;
    }
}

}  // namespace

CanonicalJsonValue CanonicalJsonValue::make_null() {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kNull;
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_bool(bool v) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kBool;
    out.bool_value = v;
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_int(int64_t v) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kInt;
    out.int_value = v;
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_string(std::string v) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kString;
    out.string_value = std::move(v);
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_number(std::string v) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kNumber;
    out.number_value = std::move(v);
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_number_quantized(double v, int precision) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kNumber;
    out.number_value = format_quantized(v, precision);
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_array(std::vector<CanonicalJsonValue> values) {
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kArray;
    out.array_value = std::move(values);
    return out;
}

CanonicalJsonValue CanonicalJsonValue::make_object(
    std::vector<std::pair<std::string, CanonicalJsonValue>> entries,
    bool sort_keys) {
    if (sort_keys) {
        std::stable_sort(entries.begin(), entries.end(),
                         [](const std::pair<std::string, CanonicalJsonValue>& lhs,
                            const std::pair<std::string, CanonicalJsonValue>& rhs) {
            return lhs.first < rhs.first;
        });
    }
    CanonicalJsonValue out;
    out.type = CanonicalJsonType::kObject;
    out.object_value = std::move(entries);
    return out;
}

double quantize_half_away_from_zero(double value, int precision) {
    if (!std::isfinite(value)) return value;
    if (is_negative_zero(value)) return 0.0;
    const double mul = std::pow(10.0, static_cast<double>(precision));
    const double scaled = value * mul;
    const double rounded = scaled >= 0.0 ? std::floor(scaled + 0.5) : std::ceil(scaled - 0.5);
    const double quantized = rounded / mul;
    return is_negative_zero(quantized) ? 0.0 : quantized;
}

std::string format_quantized(double value, int precision) {
    if (std::isnan(value)) return "null";
    if (std::isinf(value)) return value > 0.0 ? "1e308" : "-1e308";
    const double quantized = quantize_half_away_from_zero(value, precision);
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(precision) << quantized;
    return trim_trailing_zeros(oss.str());
}

std::string format_double_no_scientific(double value, int max_precision) {
    if (std::isnan(value)) return "null";
    if (std::isinf(value)) return value > 0.0 ? "1e308" : "-1e308";
    double normalized = value;
    if (is_negative_zero(normalized)) normalized = 0.0;
    std::ostringstream oss;
    oss << std::fixed << std::setprecision(max_precision) << normalized;
    return trim_trailing_zeros(oss.str());
}

core::Status encode_canonical_json(const CanonicalJsonValue& value, std::string& out_json) {
    out_json.clear();
    append_canonical_json(value, out_json);
    return core::Status::kOk;
}

core::Status canonical_json_sha256_hex(const CanonicalJsonValue& value, std::string& out_hex) {
    std::string json;
    const core::Status status = encode_canonical_json(value, json);
    if (status != core::Status::kOk) return status;

    crypto::Sha256Digest digest{};
    const uint8_t* ptr = reinterpret_cast<const uint8_t*>(json.data());
    crypto::sha256(ptr, json.size(), digest);

    static constexpr char kHex[] = "0123456789abcdef";
    out_hex.assign(64, '0');
    for (size_t i = 0; i < 32; ++i) {
        out_hex[2 * i] = kHex[(digest.bytes[i] >> 4) & 0x0f];
        out_hex[2 * i + 1] = kHex[digest.bytes[i] & 0x0f];
    }
    return core::Status::kOk;
}

}  // namespace evidence
}  // namespace aether
