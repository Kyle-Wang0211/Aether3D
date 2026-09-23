// Port of PotreeConverter 2.0 @ 8bfad98d2a6b2111cdcb3840cb508b59408d0721 (BSD-2-Clause).
// Basic types shared by the chunker, indexer, sampler and writers.
//
//   Vector3                  Converter/include/Vector3.h
//   AttributeType/Attribute  Converter/include/Attributes.h
//   BoundingBox, morton,
//   childBoundingBoxOf,
//   Source/State/Options     Converter/include/converter_utils.h
//   Node, Sampler            Converter/include/structures.h
//   Buffer                   Converter/modules/unsuck/unsuck.hpp:107-203
//   VBuffer, VBufferPool     Converter/include/VBuffer.h, VBufferPool.h  (see DEVIATIONS.md D5)
//
// Only portability changes; every one is listed in DEVIATIONS.md.
#pragma once

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

namespace aether::pointcloud_lod_build::pc {

using std::function;
using std::make_shared;
using std::shared_ptr;
using std::string;
using std::vector;

using i64 = int64_t;
using u64 = uint64_t;
using i32 = int32_t;
using u32 = uint32_t;
using u16 = uint16_t;
using u8 = uint8_t;

// unsuck.hpp:41
inline constexpr double Infinity = std::numeric_limits<double>::infinity();

// ---------------------------------------------------------------------------
// Vector3.h
struct Vector3 {
  double x = double(0.0);
  double y = double(0.0);
  double z = double(0.0);

  Vector3() {}
  Vector3(double x_, double y_, double z_) : x(x_), y(y_), z(z_) {}

  double max() const {
    double value = std::max(std::max(x, y), z);
    return value;
  }
  Vector3 operator-(const Vector3& right) const { return Vector3(x - right.x, y - right.y, z - right.z); }
  Vector3 operator+(const Vector3& right) const { return Vector3(x + right.x, y + right.y, z + right.z); }
  Vector3 operator+(const double& scalar) const { return Vector3(x + scalar, y + scalar, z + scalar); }
  Vector3 operator/(const double& scalar) const { return Vector3(x / scalar, y / scalar, z / scalar); }
  Vector3 operator*(const Vector3& right) const { return Vector3(x * right.x, y * right.y, z * right.z); }
  Vector3 operator*(const double& scalar) const { return Vector3(x * scalar, y * scalar, z * scalar); }
};

// ---------------------------------------------------------------------------
// Attributes.h
enum class AttributeType {
  INT8 = 0, INT16 = 1, INT32 = 2, INT64 = 3,
  UINT8 = 10, UINT16 = 11, UINT32 = 12, UINT64 = 13,
  FLOAT = 20, DOUBLE = 21,
  UNDEFINED = 123456,
};

inline string getAttributeTypename(AttributeType type) {
  if (type == AttributeType::INT8) return "int8";
  else if (type == AttributeType::INT16) return "int16";
  else if (type == AttributeType::INT32) return "int32";
  else if (type == AttributeType::INT64) return "int64";
  else if (type == AttributeType::UINT8) return "uint8";
  else if (type == AttributeType::UINT16) return "uint16";
  else if (type == AttributeType::UINT32) return "uint32";
  else if (type == AttributeType::UINT64) return "uint64";
  else if (type == AttributeType::FLOAT) return "float";
  else if (type == AttributeType::DOUBLE) return "double";
  else if (type == AttributeType::UNDEFINED) return "undefined";
  else return "error";
}

struct Attribute {
  string name = "";
  string description = "";
  int size = 0;
  int numElements = 0;
  int elementSize = 0;
  AttributeType type = AttributeType::UNDEFINED;

  Vector3 min = {Infinity, Infinity, Infinity};
  Vector3 max = {-Infinity, -Infinity, -Infinity};

  Vector3 scale = {1.0, 1.0, 1.0};
  Vector3 offset = {0.0, 0.0, 0.0};

  vector<int64_t> histogram = vector<int64_t>(256, 0);

  Attribute() {}
  Attribute(string name_, int size_, int numElements_, int elementSize_, AttributeType type_)
      : name(name_), size(size_), numElements(numElements_), elementSize(elementSize_), type(type_) {}
};

struct Attributes {
  vector<Attribute> list;
  int bytes = 0;

  Vector3 posScale = Vector3{1.0, 1.0, 1.0};
  Vector3 posOffset = Vector3{0.0, 0.0, 0.0};

  Attributes() {}
  explicit Attributes(vector<Attribute> attributes) {
    this->list = attributes;
    for (auto& attribute : attributes) bytes += attribute.size;
  }

  int getOffset(const string& name) const {
    int offset = 0;
    for (auto& attribute : list) {
      if (attribute.name == name) return offset;
      offset += attribute.size;
    }
    return -1;
  }

  Attribute* get(const string& name) {
    for (auto& attribute : list) {
      if (attribute.name == name) return &attribute;
    }
    return nullptr;
  }
};

// ---------------------------------------------------------------------------
// converter_utils.h
struct BoundingBox {
  Vector3 min;
  Vector3 max;
  BoundingBox() {
    this->min = {Infinity, Infinity, Infinity};
    this->max = {-Infinity, -Infinity, -Infinity};
  }
  BoundingBox(Vector3 min_, Vector3 max_) : min(min_), max(max_) {}
};

// converter_utils.h:88-96
inline uint64_t splitBy3(unsigned int a) {
  uint64_t x = a & 0x1fffff;
  x = (x | x << 32) & 0x1f00000000ffff;
  x = (x | x << 16) & 0x1f0000ff0000ff;
  x = (x | x << 8) & 0x100f00f00f00f00f;
  x = (x | x << 4) & 0x10c30c30c30c30c3;
  x = (x | x << 2) & 0x1249249249249249;
  return x;
}

// converter_utils.h:99-103
inline uint64_t mortonEncode_magicbits(unsigned int x, unsigned int y, unsigned int z) {
  uint64_t answer = 0;
  answer |= splitBy3(x) | splitBy3(y) << 1 | splitBy3(z) << 2;
  return answer;
}

// converter_utils.h:105-135
inline BoundingBox childBoundingBoxOf(Vector3 min, Vector3 max, int index) {
  BoundingBox box;
  auto size = max - min;
  Vector3 center = min + (size * 0.5);

  if ((index & 0b100) == 0) { box.min.x = min.x; box.max.x = center.x; }
  else { box.min.x = center.x; box.max.x = max.x; }

  if ((index & 0b010) == 0) { box.min.y = min.y; box.max.y = center.y; }
  else { box.min.y = center.y; box.max.y = max.y; }

  if ((index & 0b001) == 0) { box.min.z = min.z; box.max.z = center.z; }
  else { box.min.z = center.z; box.max.z = max.z; }

  return box;
}

// converter_utils.h:52-68, reduced to the fields the algorithm reads (D9).
struct State {
  std::atomic<int64_t> pointsTotal{0};
};

// ---------------------------------------------------------------------------
// unsuck.hpp:107-203. malloc-backed; a failed allocation leaves data == nullptr
// and ok() == false instead of exit(4312) (D2).
struct Buffer {
  void* data = nullptr;
  uint8_t* data_u8 = nullptr;
  char* data_char = nullptr;
  int64_t size = 0;
  int64_t pos = 0;

  Buffer() {}
  explicit Buffer(int64_t size_) {
    if (size_ > 0) data = std::malloc(static_cast<size_t>(size_));
    if (size_ > 0 && data == nullptr) return;
    data_u8 = reinterpret_cast<uint8_t*>(data);
    data_char = reinterpret_cast<char*>(data);
    this->size = size_;
  }
  Buffer(const Buffer&) = delete;
  Buffer& operator=(const Buffer&) = delete;
  ~Buffer() { std::free(data); }

  bool ok(int64_t requested) const { return requested <= 0 || data != nullptr; }

  template <class T> void set(T value, int64_t position) { std::memcpy(data_u8 + position, &value, sizeof(T)); }
  template <class T> T get(int64_t position) const {
    T value;
    std::memcpy(&value, data_u8 + position, sizeof(T));
    return value;
  }
  inline void write(const void* source, int64_t n) {
    std::memcpy(data_u8 + pos, source, static_cast<size_t>(n));
    pos += n;
  }
};

// ---------------------------------------------------------------------------
// VBuffer.h replacement (D5). Upstream reserves 1-2 GB of address space per
// buffer with VirtualAlloc/mmap(PROT_NONE) and only has Windows and Linux
// branches (on every other OS create() fails and exits). Here: a heap block that
// grows on commit(). Same contract as upstream: commit(n) sets size = n and makes
// at least n bytes addressable, preserving existing content. No caller relies on
// the pointer staying put across a growing commit() (verified per call site).
struct VBuffer {
  uint8_t* ptr = nullptr;
  int64_t comittedCapacity = 0;
  int64_t size = 0;

  VBuffer() {}
  VBuffer(const VBuffer&) = delete;
  VBuffer& operator=(const VBuffer&) = delete;
  ~VBuffer() { std::free(ptr); }

  static shared_ptr<VBuffer> create(int64_t /*reservation hint, unused*/) { return make_shared<VBuffer>(); }

  // Returns false (and leaves the buffer unchanged) if memory is exhausted.
  [[nodiscard]] bool commit(int64_t n) {
    if (n <= comittedCapacity) { this->size = n; return true; }
    void* p = std::realloc(ptr, static_cast<size_t>(n));
    if (p == nullptr) return false;
    ptr = static_cast<uint8_t*>(p);
    comittedCapacity = n;
    this->size = n;
    return true;
  }
};

// VBufferPool.h. Upstream keeps every released buffer (and its committed pages)
// alive for reuse, so resident memory never falls below its high-water mark.
// Here release() drops the reference and the block is freed (D5).
struct VBufferPool {
  static shared_ptr<VBuffer> acquire() { return VBuffer::create(0); }
  static void release(shared_ptr<VBuffer>& /*buffer*/) {}
};

// ---------------------------------------------------------------------------
// structures.h:29-142
struct Node {
  vector<shared_ptr<Node>> children;

  string name;
  shared_ptr<VBuffer> points;
  Vector3 min;
  Vector3 max;

  int64_t indexStart = 0;

  int64_t byteOffset = 0;
  int64_t byteSize = 0;
  int64_t numPoints = 0;

  bool sampled = false;

  Node() {}
  Node(string name_, Vector3 min_, Vector3 max_) : name(name_), min(min_), max(max_) { children.resize(8, nullptr); }

  int64_t level() const { return static_cast<int64_t>(name.size()) - 1; }

  // structures.h:63-90
  void addDescendant(shared_ptr<Node> descendant) {
    static std::mutex mtx;
    std::lock_guard<std::mutex> lock(mtx);

    int descendantLevel = static_cast<int>(descendant->name.size()) - 1;
    Node* current = this;

    for (int level = 1; level < descendantLevel; level++) {
      int index = descendant->name[static_cast<size_t>(level)] - '0';

      if (current->children[static_cast<size_t>(index)] != nullptr) {
        current = current->children[static_cast<size_t>(index)].get();
      } else {
        string childName = current->name + std::to_string(index);
        auto box = childBoundingBoxOf(current->min, current->max, index);
        auto child = make_shared<Node>(childName, box.min, box.max);
        current->children[static_cast<size_t>(index)] = child;
        current = child.get();
      }
    }

    auto index = descendant->name[static_cast<size_t>(descendantLevel)] - '0';
    current->children[static_cast<size_t>(index)] = descendant;
  }

  void traverse(const function<void(Node*)>& callback) {
    callback(this);
    for (auto child : children) {
      if (child != nullptr) child->traverse(callback);
    }
  }

  bool isLeaf() const {
    for (auto& child : children) {
      if (child != nullptr) return false;
    }
    return true;
  }
};

// structures.h:154-168
struct Sampler {
  bool enableTrace = false;
  Sampler() {}
  virtual ~Sampler() {}
  virtual void sample(Node* node, Attributes attributes, double baseSpacing,
                      function<void(Node*)> callbackNodeCompleted,
                      function<void(Node*)> callbackNodeDiscarded) = 0;
};

// ---------------------------------------------------------------------------
// Error channel replacing upstream's exit()/__debugbreak() (D2). The first
// failure wins; workers poll failed() and return early.
struct ErrorState {
  std::atomic<bool> flag{false};
  std::mutex mtx;
  string message;

  void fail(const string& msg) {
    std::lock_guard<std::mutex> lock(mtx);
    if (!flag.load()) {
      message = msg;
      flag.store(true);
    }
  }
  bool failed() const { return flag.load(); }
};

}  // namespace aether::pointcloud_lod_build::pc
