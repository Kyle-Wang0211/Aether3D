// colmap_ios_stubs.cc — colmap::Bitmap backed by a plain pixel buffer, NO image
// IO library (no FreeImage, no OpenImageIO) for the iOS/host build.
//
// [MIGRATION 4.0.4] COLMAP 4.0 rewrote sensor/bitmap.{h,cc}: the FreeImage backing
// (FIBITMAP / FreeImageHandle / SetPtr / Allocate / ConvertToRowMajorArray) was
// replaced by an OpenImageIO backend over a plain `std::vector<uint8_t> data_`
// member (Width/Height/Channels/RowMajorData/GetPixel/SetPixel are now INLINE in
// bitmap.h and need no out-of-line definition). The OIIO-backed bitmap.cc is
// excluded from our build (no OIIO dependency); this stub supplies the remaining
// out-of-line Bitmap members so the colmap subset links. The full image-IO /
// colour path is never executed on our path (colmap_bench runs with
// extract_colors=false; on device, decoding happens platform-side and the caller
// fills RowMajorData() directly), so these are minimal no-op / buffer-only impls.

#include "colmap/sensor/bitmap.h"
#include "colmap/feature/index.h"
#include "colmap/feature/aliked.h"        // [MIGRATION 4.0.4] ALIKED factory stubs
#include "colmap/feature/onnx_matchers.h" // [MIGRATION 4.0.4] LightGlue factory stub

#include <cstring>
#include <memory>
#include <ostream>

namespace colmap {

namespace {
inline int ChannelsForRGB(bool as_rgb) { return as_rgb ? 3 : 1; }
}  // namespace

// ---- construction ----------------------------------------------------------
Bitmap::Bitmap()
    : width_(0), height_(0), channels_(0), linear_colorspace_(false) {}

Bitmap::Bitmap(int width, int height, bool as_rgb, bool linear_colorspace)
    : width_(width),
      height_(height),
      channels_(ChannelsForRGB(as_rgb)),
      linear_colorspace_(linear_colorspace),
      data_(static_cast<size_t>(width) * height * ChannelsForRGB(as_rgb), 0) {}

Bitmap::Bitmap(const Bitmap& other)
    : width_(other.width_),
      height_(other.height_),
      channels_(other.channels_),
      linear_colorspace_(other.linear_colorspace_),
      data_(other.data_) {}

Bitmap::Bitmap(Bitmap&& other) noexcept
    : width_(other.width_),
      height_(other.height_),
      channels_(other.channels_),
      linear_colorspace_(other.linear_colorspace_),
      data_(std::move(other.data_)) {
  other.width_ = 0;
  other.height_ = 0;
  other.channels_ = 0;
}

Bitmap& Bitmap::operator=(const Bitmap& other) {
  if (this != &other) {
    width_ = other.width_;
    height_ = other.height_;
    channels_ = other.channels_;
    linear_colorspace_ = other.linear_colorspace_;
    data_ = other.data_;
  }
  return *this;
}

Bitmap& Bitmap::operator=(Bitmap&& other) noexcept {
  if (this != &other) {
    width_ = other.width_;
    height_ = other.height_;
    channels_ = other.channels_;
    linear_colorspace_ = other.linear_colorspace_;
    data_ = std::move(other.data_);
    other.width_ = 0;
    other.height_ = 0;
    other.channels_ = 0;
  }
  return *this;
}

// ---- fills / interpolation (buffer-only) -----------------------------------
void Bitmap::Fill(const BitmapColor<uint8_t>& color) {
  for (int y = 0; y < height_; ++y) {
    for (int x = 0; x < width_; ++x) {
      SetPixel(x, y, color);
    }
  }
}

// [MIGRATION 4.1.0] GetPixel/Interpolate* now return std::optional (upstream
// API change); GetPixel itself is inline in bitmap.h and needs no stub.
std::optional<BitmapColor<uint8_t>> Bitmap::InterpolateNearestNeighbor(
    double x, double y) const {
  return GetPixel(static_cast<int>(std::lround(x)),
                  static_cast<int>(std::lround(y)));
}

std::optional<BitmapColor<float>> Bitmap::InterpolateBilinear(
    double /*x*/, double /*y*/) const {
  return std::nullopt;
}

// ---- EXIF (no embedded metadata on our path) -------------------------------
std::optional<int> Bitmap::ExifOrientation() const { return std::nullopt; }
std::optional<std::string> Bitmap::ExifCameraModel() const {
  return std::nullopt;
}
std::optional<double> Bitmap::ExifFocalLength() const { return std::nullopt; }
std::optional<double> Bitmap::ExifLatitude() const { return std::nullopt; }
std::optional<double> Bitmap::ExifLongitude() const { return std::nullopt; }
std::optional<double> Bitmap::ExifAltitude() const { return std::nullopt; }

// ---- image IO (decoding handled platform-side; never on this path) ---------
bool Bitmap::Read(const std::filesystem::path& /*path*/,
                  bool /*as_rgb*/,
                  bool /*linearize_colorspace*/) {
  return false;
}

bool Bitmap::Write(const std::filesystem::path& /*path*/,
                   bool /*delinearize_colorspace*/) const {
  return false;
}

// ---- geometric ops (buffer-only / no-op) -----------------------------------
void Bitmap::Rescale(int /*new_width*/,
                     int /*new_height*/,
                     RescaleFilter /*filter*/) {}

// [MIGRATION 4.1.0] new upstream in-place downscale helper (bitmap.cc, excluded).
// Rescale above is a no-op on this path, so report scale factor 1 (unchanged).
double Bitmap::Thumbnail(int /*max_image_size*/, RescaleFilter /*filter*/) {
  return 1.0;
}

void Bitmap::Rot90(int /*k*/) {}

Bitmap Bitmap::Clone() const { return *this; }

Bitmap Bitmap::CloneAsGrey() const {
  Bitmap grey;
  grey.width_ = width_;
  grey.height_ = height_;
  grey.channels_ = 1;
  grey.linear_colorspace_ = linear_colorspace_;
  grey.data_.assign(static_cast<size_t>(width_) * height_, 0);
  return grey;
}

Bitmap Bitmap::CloneAsRGB() const {
  Bitmap rgb;
  rgb.width_ = width_;
  rgb.height_ = height_;
  rgb.channels_ = 3;
  rgb.linear_colorspace_ = linear_colorspace_;
  rgb.data_.assign(static_cast<size_t>(width_) * height_ * 3, 0);
  return rgb;
}

void Bitmap::SetJpegQuality(int /*quality*/) {}

// ---- metadata (no-op) ------------------------------------------------------
void Bitmap::SetMetaData(const std::string_view& /*name*/,
                         const std::string_view& /*type*/,
                         const void* /*value*/) {}

void Bitmap::SetMetaData(const std::string_view& /*name*/,
                         const std::string_view& /*value*/) {}

bool Bitmap::GetMetaData(const std::string_view& /*name*/,
                         const std::string_view& /*type*/,
                         void* /*value*/) const {
  return false;
}

std::optional<std::string> Bitmap::GetMetaData(
    const std::string_view& /*name*/) const {
  return std::nullopt;
}

void Bitmap::CloneMetadata(Bitmap* /*target*/) const {}

std::ostream& operator<<(std::ostream& stream, const Bitmap& bitmap) {
  stream << "Bitmap(width=" << bitmap.Width() << ", height=" << bitmap.Height()
         << ", channels=" << bitmap.Channels() << ")";
  return stream;
}

// FAISS descriptor index (feature/index.cc pulls heavy faiss) is NOT built on
// our path. The CPU brute-force matcher never uses the index at runtime, but the
// matcher cache references this symbol at link time — stub it.
std::unique_ptr<FeatureDescriptorIndex> FeatureDescriptorIndex::Create(
    FeatureDescriptorIndex::Type /*type*/, int /*num_threads*/) {
  return nullptr;
}

// [MIGRATION 4.0.4] COLMAP 4.0 added ALIKED (learned features) + LightGlue/ONNX
// matching backends. Their impls (feature/aliked.cc, feature/onnx_matchers.cc)
// pull libtorch + ONNX Runtime and are NOT built for our device subset. The
// SIFT factory dispatchers (CreateSiftFeatureExtractor / CreateSiftFeatureMatcher
// in extractor.cc / matcher.cc / sift.cc) reference these symbols at link time
// for the non-SIFT branches, but our path is SIFT-only (FeatureExtractorType::SIFT
// / FeatureMatcherType::SIFT_BRUTEFORCE), so these are never reached at runtime.
// Stub them to satisfy the linker — same pattern as the faiss index stub above.
std::unique_ptr<FeatureExtractor> CreateAlikedFeatureExtractor(
    const FeatureExtractionOptions& /*options*/) {
  return nullptr;
}

std::unique_ptr<FeatureMatcher> CreateAlikedFeatureMatcher(
    const FeatureMatchingOptions& /*options*/) {
  return nullptr;
}

std::unique_ptr<FeatureMatcher> CreateLightGlueONNXFeatureMatcher(
    const FeatureMatchingOptions& /*options*/,
    const LightGlueONNXMatchingOptions& /*lightglue_options*/) {
  return nullptr;
}

bool AlikedExtractionOptions::Check() const { return true; }
bool AlikedMatchingOptions::Check() const { return true; }
bool LightGlueONNXMatchingOptions::Check() const { return true; }

}  // namespace colmap
