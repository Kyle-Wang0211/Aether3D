// colmap_ios_stubs.cc — colmap::Bitmap backed by a plain pixel buffer (no
// FreeImage) for the iOS build. Image DECODING happens platform-side (CGImage);
// this only needs to (a) hold a grayscale/RGB buffer the caller fills, and
// (b) hand it back via ConvertToRowMajorArray for feature/sift.cc + VLFeat.
// feature/sift.cc, VLFeat, and bitmap.h stay UNMODIFIED — only the IO backing.
//
// Pixels: ROW-MAJOR, TOP-DOWN (matches CGImage), channel-interleaved. The real
// FreeImage stores bottom-up; we store + read top-down consistently, so the
// extracted keypoint coordinates are standard top-left-origin image coords.

#include "colmap/sensor/bitmap.h"
#include "colmap/feature/matcher.h"
#include "colmap/feature/index.h"
#include "aether_bitmap_shim.h"

#include <memory>
#include <stdexcept>

namespace colmap {

// ---- FreeImageHandle: owns the FIBITMAP buffer ----
Bitmap::FreeImageHandle::FreeImageHandle() : ptr(nullptr) {}
Bitmap::FreeImageHandle::FreeImageHandle(FIBITMAP* p) : ptr(p) {}
Bitmap::FreeImageHandle::~FreeImageHandle() { delete ptr; }
Bitmap::FreeImageHandle::FreeImageHandle(FreeImageHandle&& other) noexcept
    : ptr(other.ptr) {
  other.ptr = nullptr;
}
Bitmap::FreeImageHandle& Bitmap::FreeImageHandle::operator=(
    FreeImageHandle&& other) noexcept {
  if (this != &other) {
    delete ptr;
    ptr = other.ptr;
    other.ptr = nullptr;
  }
  return *this;
}

Bitmap::Bitmap() = default;

void Bitmap::SetPtr(FIBITMAP* ptr) {
  delete handle_.ptr;
  handle_.ptr = ptr;
  if (ptr) {
    width_ = ptr->width;
    height_ = ptr->height;
    channels_ = ptr->channels;
  }
}

// Allocate a blank buffer the C ABI fills via Data()->data.
bool Bitmap::Allocate(int width, int height, bool as_rgb) {
  width_ = width;
  height_ = height;
  channels_ = as_rgb ? 3 : 1;
  delete handle_.ptr;
  handle_.ptr = new FIBITMAP{
      width, height, channels_,
      std::vector<uint8_t>(static_cast<size_t>(width) * height * channels_, 0)};
  return true;
}

std::vector<uint8_t> Bitmap::ConvertToRowMajorArray() const {
  if (handle_.ptr) return handle_.ptr->data;   // already row-major, top-down
  return {};
}

// ---- unused on-device (no image IO / colouring on the feature path) ----
bool Bitmap::Read(const std::string& /*path*/, bool /*as_rgb*/) { return false; }

// (FeatureMatchingOptions::Check() now comes from the real matcher.cc, which is
// compiled into the build for on-device matching — stub removed to avoid a
// duplicate symbol.)

bool Bitmap::InterpolateBilinear(double /*x*/,
                                 double /*y*/,
                                 BitmapColor<float>* /*color*/) const {
  return false;
}

// FAISS descriptor index (feature/index.cc) is NOT built on-device — it pulls
// faiss (heavy). The CPU brute-force matcher (cpu_brute_force_matcher=true) never
// uses the index at runtime (sift.cc: only the non-brute path calls it), but
// matcher.cc's FeatureMatcherCache references this symbol at link time. Stub it.
std::unique_ptr<FeatureDescriptorIndex> FeatureDescriptorIndex::Create(
    FeatureDescriptorIndex::Type /*type*/, int /*num_threads*/) {
  return nullptr;
}

}  // namespace colmap
