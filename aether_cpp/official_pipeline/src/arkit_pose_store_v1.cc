#include "arkit_pose_store_v1.h"

#include <cerrno>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace aether::sfm {
namespace {

constexpr char kMagic[8] = {'A', 'R', 'K', 'P', 'O', 'S', '1', '\0'};
constexpr uint32_t kVersion = 1;
constexpr size_t kHeaderBytes = 32;
constexpr size_t kRecordBytes = 104;
constexpr uint32_t kMaxRecords = 1000000;

uint64_t Fnv1a64(const uint8_t* data, const size_t size) {
  uint64_t hash = 1469598103934665603ULL;
  for (size_t i = 0; i < size; ++i) {
    hash ^= data[i];
    hash *= 1099511628211ULL;
  }
  return hash;
}

void AppendU32(std::vector<uint8_t>* out, const uint32_t value) {
  for (int shift = 0; shift < 32; shift += 8) {
    out->push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void AppendU64(std::vector<uint8_t>* out, const uint64_t value) {
  for (int shift = 0; shift < 64; shift += 8) {
    out->push_back(static_cast<uint8_t>((value >> shift) & 0xff));
  }
}

void AppendDouble(std::vector<uint8_t>* out, const double value) {
  uint64_t bits = 0;
  static_assert(sizeof(bits) == sizeof(value));
  std::memcpy(&bits, &value, sizeof(bits));
  AppendU64(out, bits);
}

bool ReadU32(const std::vector<uint8_t>& bytes,
             size_t* offset,
             uint32_t* value) {
  if (*offset > bytes.size() || bytes.size() - *offset < 4) return false;
  uint32_t result = 0;
  for (int shift = 0; shift < 32; shift += 8) {
    result |= static_cast<uint32_t>(bytes[(*offset)++]) << shift;
  }
  *value = result;
  return true;
}

bool ReadU64(const std::vector<uint8_t>& bytes,
             size_t* offset,
             uint64_t* value) {
  if (*offset > bytes.size() || bytes.size() - *offset < 8) return false;
  uint64_t result = 0;
  for (int shift = 0; shift < 64; shift += 8) {
    result |= static_cast<uint64_t>(bytes[(*offset)++]) << shift;
  }
  *value = result;
  return true;
}

bool ReadDouble(const std::vector<uint8_t>& bytes,
                size_t* offset,
                double* value) {
  uint64_t bits = 0;
  if (!ReadU64(bytes, offset, &bits)) return false;
  std::memcpy(value, &bits, sizeof(bits));
  return true;
}

bool WriteAll(const int fd, const uint8_t* data, const size_t size) {
  size_t written = 0;
  while (written < size) {
    const ssize_t count = write(fd, data + written, size - written);
    if (count < 0) {
      if (errno == EINTR) continue;
      return false;
    }
    if (count == 0) return false;
    written += static_cast<size_t>(count);
  }
  return true;
}

bool ValidateOrderedRecords(const std::vector<ArkitPoseRecordV1>& records) {
  if (records.size() > kMaxRecords) return false;
  for (size_t i = 0; i < records.size(); ++i) {
    if (records[i].frame_id != static_cast<int32_t>(i) ||
        !IsValidArkitPoseRecordV1(records[i])) {
      return false;
    }
  }
  return true;
}

}  // namespace

bool IsValidArkitPoseRecordV1(const ArkitPoseRecordV1& record) {
  if (record.frame_id < 0 || record.image_id == 0 ||
      record.frame_identity_digest == 0) {
    return false;
  }
  double q_norm_sq = 0.0;
  for (const double value : record.cam_from_world_q_xyzw) {
    if (!std::isfinite(value)) return false;
    q_norm_sq += value * value;
  }
  double g_norm_sq = 0.0;
  for (const double value : record.gravity_cam_xyz) {
    if (!std::isfinite(value)) return false;
    g_norm_sq += value * value;
  }
  for (const double value : record.cam_from_world_t_xyz) {
    if (!std::isfinite(value)) return false;
  }
  return std::abs(q_norm_sq - 1.0) <= 1e-8 &&
         std::abs(g_norm_sq - 1.0) <= 1e-8;
}

ArkitPoseStoreStatusV1 WriteArkitPoseStoreV1(
    const std::string& path,
    const std::vector<ArkitPoseRecordV1>& records) {
  if (path.empty() || !ValidateOrderedRecords(records)) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }

  std::vector<uint8_t> payload;
  payload.reserve(records.size() * kRecordBytes);
  for (const ArkitPoseRecordV1& record : records) {
    AppendU32(&payload, static_cast<uint32_t>(record.frame_id));
    AppendU32(&payload, record.image_id);
    AppendU32(&payload, record.active ? 1U : 0U);
    AppendU32(&payload, 0U);  // reserved for forward-compatible flags
    AppendU64(&payload, record.frame_identity_digest);
    for (const double value : record.cam_from_world_q_xyzw) {
      AppendDouble(&payload, value);
    }
    for (const double value : record.cam_from_world_t_xyz) {
      AppendDouble(&payload, value);
    }
    for (const double value : record.gravity_cam_xyz) {
      AppendDouble(&payload, value);
    }
  }

  std::vector<uint8_t> file;
  file.reserve(kHeaderBytes + payload.size());
  file.insert(file.end(), kMagic, kMagic + sizeof(kMagic));
  AppendU32(&file, kVersion);
  AppendU32(&file, static_cast<uint32_t>(records.size()));
  AppendU64(&file, static_cast<uint64_t>(payload.size()));
  AppendU64(&file, Fnv1a64(payload.data(), payload.size()));
  file.insert(file.end(), payload.begin(), payload.end());

  const std::string tmp = path + ".tmp";
  const int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd < 0) return ArkitPoseStoreStatusV1::kIoError;
  const bool wrote = WriteAll(fd, file.data(), file.size());
  const bool synced = wrote && fsync(fd) == 0;
  const bool closed = close(fd) == 0;
  if (!wrote || !synced || !closed) {
    unlink(tmp.c_str());
    return ArkitPoseStoreStatusV1::kIoError;
  }
  if (rename(tmp.c_str(), path.c_str()) != 0) {
    unlink(tmp.c_str());
    return ArkitPoseStoreStatusV1::kIoError;
  }

  const std::filesystem::path parent =
      std::filesystem::path(path).parent_path();
  if (!parent.empty()) {
    const int dir_fd = open(parent.c_str(), O_RDONLY);
    if (dir_fd >= 0) {
      const int ignored = fsync(dir_fd);
      (void)ignored;
      close(dir_fd);
    }
  }
  return ArkitPoseStoreStatusV1::kOk;
}

ArkitPoseStoreStatusV1 ReadArkitPoseStoreV1(
    const std::string& path,
    std::vector<ArkitPoseRecordV1>* records) {
  if (records == nullptr || path.empty()) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }
  records->clear();
  if (!std::filesystem::exists(path)) {
    return ArkitPoseStoreStatusV1::kMissing;
  }
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream.good()) return ArkitPoseStoreStatusV1::kIoError;
  const std::streamoff length = stream.tellg();
  if (length < static_cast<std::streamoff>(kHeaderBytes)) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }
  stream.seekg(0);
  std::vector<uint8_t> bytes(static_cast<size_t>(length));
  stream.read(reinterpret_cast<char*>(bytes.data()), length);
  if (!stream.good()) return ArkitPoseStoreStatusV1::kIoError;
  if (std::memcmp(bytes.data(), kMagic, sizeof(kMagic)) != 0) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }

  size_t offset = sizeof(kMagic);
  uint32_t version = 0;
  uint32_t count = 0;
  uint64_t payload_size = 0;
  uint64_t expected_hash = 0;
  if (!ReadU32(bytes, &offset, &version) ||
      !ReadU32(bytes, &offset, &count) ||
      !ReadU64(bytes, &offset, &payload_size) ||
      !ReadU64(bytes, &offset, &expected_hash) || version != kVersion ||
      count > kMaxRecords || payload_size != uint64_t(count) * kRecordBytes ||
      offset != kHeaderBytes || bytes.size() - offset != payload_size ||
      Fnv1a64(bytes.data() + offset, static_cast<size_t>(payload_size)) !=
          expected_hash) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }

  std::vector<ArkitPoseRecordV1> parsed;
  parsed.reserve(count);
  for (uint32_t i = 0; i < count; ++i) {
    uint32_t frame_id = 0;
    uint32_t active = 0;
    uint32_t reserved = 0;
    ArkitPoseRecordV1 record;
    if (!ReadU32(bytes, &offset, &frame_id) ||
        !ReadU32(bytes, &offset, &record.image_id) ||
        !ReadU32(bytes, &offset, &active) ||
        !ReadU32(bytes, &offset, &reserved) ||
        !ReadU64(bytes, &offset, &record.frame_identity_digest) || active > 1 ||
        reserved != 0) {
      return ArkitPoseStoreStatusV1::kInvalid;
    }
    record.frame_id = static_cast<int32_t>(frame_id);
    record.active = active == 1;
    for (double& value : record.cam_from_world_q_xyzw) {
      if (!ReadDouble(bytes, &offset, &value))
        return ArkitPoseStoreStatusV1::kInvalid;
    }
    for (double& value : record.cam_from_world_t_xyz) {
      if (!ReadDouble(bytes, &offset, &value))
        return ArkitPoseStoreStatusV1::kInvalid;
    }
    for (double& value : record.gravity_cam_xyz) {
      if (!ReadDouble(bytes, &offset, &value))
        return ArkitPoseStoreStatusV1::kInvalid;
    }
    parsed.push_back(record);
  }
  if (offset != bytes.size() || !ValidateOrderedRecords(parsed)) {
    return ArkitPoseStoreStatusV1::kInvalid;
  }
  *records = std::move(parsed);
  return ArkitPoseStoreStatusV1::kOk;
}

}  // namespace aether::sfm
