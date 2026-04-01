// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// CoreML implementation of DepthInferenceEngine.
// Objective-C++ (.mm) because CoreML is an Objective-C API.
// Runs Depth Anything V2 on Neural Engine (A14+), ~10-31ms per frame.
//
// Ported from DepthAnythingV2Bridge.swift — same CoreML logic,
// now lives in the C++ core layer (no algorithm code in Swift).

#if defined(__APPLE__)

#import <CoreML/CoreML.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <Accelerate/Accelerate.h>

#include "aether/pipeline/depth_inference_engine.h"

#include <atomic>
#include <cstring>
#include <dispatch/dispatch.h>
#include <mutex>
#include <new>
#include <string>

namespace aether {
namespace pipeline {

// ═══════════════════════════════════════════════════════════════════════
// CoreMLDepthInferenceEngine
// ═══════════════════════════════════════════════════════════════════════
// Wraps CoreML model for Neural Engine depth inference.
// Async path uses GCD serial queue — at most one inference in-flight.
// Results published via atomic pointer swap (lock-free poll).

class CoreMLDepthInferenceEngine final : public DepthInferenceEngine {
public:
    CoreMLDepthInferenceEngine(const char* model_path, const char* name) noexcept;
    ~CoreMLDepthInferenceEngine() noexcept override;

    core::Status infer(
        const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
        DepthInferenceResult& out) noexcept override;

    void submit_async(
        const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept override;

    bool poll_result(DepthInferenceResult& out) noexcept override;

    bool is_available() const noexcept override;

    std::uint32_t model_input_width() const noexcept override { return input_width_; }
    std::uint32_t model_input_height() const noexcept override { return input_height_; }
    const char* model_name() const noexcept override { return name_.c_str(); }

private:
    struct PendingAsyncFrame {
        std::uint8_t* rgba{nullptr};
        std::uint32_t width{0};
        std::uint32_t height{0};
        std::uint32_t submit_id{0};

        void reset() noexcept {
            delete[] rgba;
            rgba = nullptr;
            width = 0;
            height = 0;
            submit_id = 0;
        }
    };

    // Auto-detected from model spec at load time (defaults if detection fails)
    std::uint32_t input_width_{518};
    std::uint32_t input_height_{518};
    std::string name_{"DAv2"};

    // Detected input/output key names (from model description)
    NSString* input_key_{nil};
    NSString* output_key_{nil};
    NSURL* model_url_{nil};

    // CoreML model (retained by ARC in .mm file)
    MLModel* model_{nil};
    CIContext* ci_context_{nil};
    bool cpu_only_mode_{false};

    // Async inference state
    dispatch_queue_t queue_{nullptr};
    std::atomic<bool> is_processing_{false};
    std::atomic<DepthInferenceResult*> latest_result_{nullptr};
    std::mutex async_mutex_;
    PendingAsyncFrame pending_frame_;

    // ─── Internal Methods ───

    /// Create BGRA CVPixelBuffer from RGBA input, resized to kModelSize × kModelSize.
    CVPixelBufferRef create_resized_pixel_buffer(
        const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept;

    /// Run CoreML prediction and extract depth map.
    bool run_prediction(CVPixelBufferRef pixel_buffer,
                        DepthInferenceResult& out) noexcept;

    /// Extract depth from MLFeatureProvider output.
    bool extract_depth(id<MLFeatureProvider> output,
                       DepthInferenceResult& out) noexcept;

    bool load_model(MLComputeUnits units, const char* reason) noexcept;
    static bool should_retry_on_cpu(NSError* error) noexcept;

    /// Convert CVPixelBuffer (image-type depth output) to DepthInferenceResult.
    bool pixel_buffer_to_result(CVPixelBufferRef pb,
                                DepthInferenceResult& out) noexcept;

    /// Convert MLMultiArray to DepthInferenceResult.
    bool multi_array_to_result(MLMultiArray* array,
                               DepthInferenceResult& out) noexcept;

    void dispatch_async_inference(
        std::uint8_t* rgba_copy,
        std::uint32_t w,
        std::uint32_t h,
        std::uint32_t submit_id) noexcept;
};

// ═══════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ═══════════════════════════════════════════════════════════════════════

bool CoreMLDepthInferenceEngine::load_model(
    MLComputeUnits units, const char* reason) noexcept
{
    @autoreleasepool {
        if (!model_url_) return false;

        MLModelConfiguration* config = [[MLModelConfiguration alloc] init];
        config.computeUnits = units;
        NSError* error = nil;
        MLModel* loaded = [MLModel modelWithContentsOfURL:model_url_
                                            configuration:config
                                                    error:&error];
        if (error || !loaded) {
            std::fprintf(stderr,
                "[Aether3D] %s: %s load FAILED (%s)\n",
                name_.c_str(),
                reason ? reason : (units == MLComputeUnitsCPUOnly ? "CPU-only" : "GPU"),
                error ? [[error localizedDescription] UTF8String] : "unknown");
            return false;
        }

        model_ = loaded;
        cpu_only_mode_ = (units == MLComputeUnitsCPUOnly);
        input_key_ = nil;
        output_key_ = nil;

        MLModelDescription* desc = model_.modelDescription;
        NSDictionary<NSString*, MLFeatureDescription*>* inputs = desc.inputDescriptionsByName;
        for (NSString* key in inputs) {
            MLFeatureDescription* feat = inputs[key];
            if (feat.type == MLFeatureTypeImage) {
                input_key_ = key;
                MLImageConstraint* constraint = feat.imageConstraint;
                if (constraint) {
                    input_width_ = static_cast<std::uint32_t>(constraint.pixelsWide);
                    input_height_ = static_cast<std::uint32_t>(constraint.pixelsHigh);
                }
                break;
            }
        }

        NSDictionary<NSString*, MLFeatureDescription*>* outputs = desc.outputDescriptionsByName;
        for (NSString* key in outputs) {
            output_key_ = key;
            break;
        }

        if (!ci_context_) {
            ci_context_ = [CIContext contextWithOptions:@{
                kCIContextUseSoftwareRenderer: @NO
            }];
        }

        std::fprintf(stderr,
            "[Aether3D] %s CoreML: loaded (%s, input=%s %ux%u, output=%s)\n",
            name_.c_str(),
            cpu_only_mode_ ? "CPU-only" : "GPU/CPU",
            input_key_ ? [input_key_ UTF8String] : "auto",
            input_width_, input_height_,
            output_key_ ? [output_key_ UTF8String] : "auto");
        return true;
    }
}

bool CoreMLDepthInferenceEngine::should_retry_on_cpu(NSError* error) noexcept
{
    if (!error) return false;
    NSString* desc = [error localizedDescription];
    if (!desc) return false;
    return [desc rangeOfString:@"Insufficient Permission"
                       options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [desc rangeOfString:@"background"
                       options:NSCaseInsensitiveSearch].location != NSNotFound ||
           [desc rangeOfString:@"Unable to compute the prediction using ML Program"
                       options:NSCaseInsensitiveSearch].location != NSNotFound;
}

CoreMLDepthInferenceEngine::CoreMLDepthInferenceEngine(
    const char* model_path, const char* name) noexcept
{
    if (name) name_ = std::string("DAv2-") + name;
    if (!model_path) return;

    @autoreleasepool {
        NSString* path_str = [NSString stringWithUTF8String:model_path];
        if (!path_str) return;

        model_url_ = [NSURL fileURLWithPath:path_str];
        if (!model_url_) return;

        std::fprintf(stderr,
            "[Aether3D] %s: loading with GPU (skip ANE — ANE blocks 10-30s+)\n",
            name_.c_str());
        if (!load_model(MLComputeUnitsCPUAndGPU, "GPU")) {
            std::fprintf(stderr,
                "[Aether3D] %s: GPU load FAILED — retrying CPU-only\n",
                name_.c_str());
            if (!load_model(MLComputeUnitsCPUOnly, "CPU-only")) {
                std::fprintf(stderr,
                    "[Aether3D] %s: CPU-only load ALSO FAILED at %s\n",
                    name_.c_str(), model_path);
                model_ = nil;
                return;
            }
        }

        std::string queue_name = "com.aether3d.depth-inference." + name_;
        queue_ = dispatch_queue_create(queue_name.c_str(), DISPATCH_QUEUE_SERIAL);
    }
}

CoreMLDepthInferenceEngine::~CoreMLDepthInferenceEngine() noexcept {
    // Clean up any pending async result
    DepthInferenceResult* pending = latest_result_.exchange(nullptr);
    delete pending;
    {
        std::lock_guard<std::mutex> lock(async_mutex_);
        pending_frame_.reset();
    }

    // ARC handles model_ and ci_context_ release
    // dispatch_queue_t is also ARC-managed on modern Apple platforms
}

// ═══════════════════════════════════════════════════════════════════════
// Synchronous Inference
// ═══════════════════════════════════════════════════════════════════════

core::Status CoreMLDepthInferenceEngine::infer(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h,
    DepthInferenceResult& out) noexcept
{
    if (!model_ || !rgba || w == 0 || h == 0) {
        return core::Status::kResourceExhausted;
    }

    @autoreleasepool {
        CVPixelBufferRef resized = create_resized_pixel_buffer(rgba, w, h);
        if (!resized) return core::Status::kResourceExhausted;

        bool ok = run_prediction(resized, out);
        CVPixelBufferRelease(resized);

        return ok ? core::Status::kOk : core::Status::kResourceExhausted;
    }
}

// ═══════════════════════════════════════════════════════════════════════
// Asynchronous Inference
// ═══════════════════════════════════════════════════════════════════════

void CoreMLDepthInferenceEngine::submit_async(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept
{
    if (!model_ || !rgba || w == 0 || h == 0 || !queue_) return;

    // Copy RGBA data for async processing (the caller's buffer may be reused)
    std::size_t byte_count = static_cast<std::size_t>(w) * h * 4;
    auto* rgba_copy = new (std::nothrow) std::uint8_t[byte_count];
    if (!rgba_copy) return;
    std::memcpy(rgba_copy, rgba, byte_count);

    std::uint32_t cw = w;
    std::uint32_t ch = h;

    // Throttled counter for inference diagnostics
    static std::atomic<std::uint32_t> submit_counter{0};
    std::uint32_t submit_id = submit_counter.fetch_add(1);
    bool should_dispatch = false;
    {
        std::lock_guard<std::mutex> lock(async_mutex_);
        if (!is_processing_.load(std::memory_order_relaxed)) {
            is_processing_.store(true, std::memory_order_relaxed);
            should_dispatch = true;
        } else {
            pending_frame_.reset();
            pending_frame_.rgba = rgba_copy;
            pending_frame_.width = cw;
            pending_frame_.height = ch;
            pending_frame_.submit_id = submit_id;
        }
    }
    if (!should_dispatch) {
        if (submit_id < 5 || submit_id % 120 == 0) {
            std::fprintf(stderr,
                "[Aether3D] %s submit#%u: queued as latest pending frame (%ux%u)\n",
                name_.c_str(), submit_id, cw, ch);
        }
        return;
    }

    dispatch_async_inference(rgba_copy, cw, ch, submit_id);
}

void CoreMLDepthInferenceEngine::dispatch_async_inference(
    std::uint8_t* rgba_copy,
    std::uint32_t cw,
    std::uint32_t ch,
    std::uint32_t submit_id) noexcept
{
    dispatch_async(queue_, ^{
        @autoreleasepool {
            bool success = false;
            DepthInferenceResult* result = new (std::nothrow) DepthInferenceResult();
            if (result) {
                CVPixelBufferRef resized = create_resized_pixel_buffer(rgba_copy, cw, ch);
                if (resized) {
                    if (run_prediction(resized, *result)) {
                        // Publish result (atomic swap)
                        DepthInferenceResult* old = latest_result_.exchange(result);
                        delete old;  // Discard previous unconsumed result
                        result = nullptr;  // Ownership transferred
                        success = true;
                    } else if (submit_id < 5) {
                        std::fprintf(stderr,
                            "[Aether3D] %s submit#%u: run_prediction FAILED\n",
                            name_.c_str(), submit_id);
                    }
                    CVPixelBufferRelease(resized);
                } else if (submit_id < 5) {
                    std::fprintf(stderr,
                        "[Aether3D] %s submit#%u: create_resized_pixel_buffer FAILED (%ux%u)\n",
                        name_.c_str(), submit_id, cw, ch);
                }
            }
            if (submit_id < 5 || submit_id % 120 == 0) {
                std::fprintf(stderr,
                    "[Aether3D] %s submit#%u: inference %s (%ux%u → %ux%u)\n",
                    name_.c_str(), submit_id,
                    success ? "OK" : "FAIL",
                    cw, ch, input_width_, input_height_);
            }
            delete result;  // nullptr-safe; deletes only if prediction failed
            delete[] rgba_copy;

            PendingAsyncFrame next_frame;
            bool has_pending = false;
            {
                std::lock_guard<std::mutex> lock(async_mutex_);
                if (pending_frame_.rgba) {
                    next_frame = pending_frame_;
                    pending_frame_.rgba = nullptr;
                    pending_frame_.width = 0;
                    pending_frame_.height = 0;
                    pending_frame_.submit_id = 0;
                    has_pending = true;
                } else {
                    is_processing_.store(false, std::memory_order_relaxed);
                }
            }
            if (has_pending) {
                dispatch_async_inference(
                    next_frame.rgba,
                    next_frame.width,
                    next_frame.height,
                    next_frame.submit_id
                );
            }
        }
    });
}

bool CoreMLDepthInferenceEngine::poll_result(
    DepthInferenceResult& out) noexcept
{
    DepthInferenceResult* result = latest_result_.exchange(nullptr);
    if (!result) return false;

    out = std::move(*result);
    delete result;
    return true;
}

bool CoreMLDepthInferenceEngine::is_available() const noexcept {
    return model_ != nil;
}

// ═══════════════════════════════════════════════════════════════════════
// Internal: Pixel Buffer Creation + Resize
// ═══════════════════════════════════════════════════════════════════════

CVPixelBufferRef CoreMLDepthInferenceEngine::create_resized_pixel_buffer(
    const std::uint8_t* rgba, std::uint32_t w, std::uint32_t h) noexcept
{
    if (!ci_context_ || !rgba) return nullptr;

    // Step 1: Create CVPixelBuffer from RGBA data.
    // CoreML/CIImage expects BGRA, so we create as BGRA and swizzle.
    CVPixelBufferRef src_buffer = nullptr;
    NSDictionary* attrs = @{
        (__bridge NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (__bridge NSString*)kCVPixelBufferCGImageCompatibilityKey: @YES
    };

    CVReturn status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        w, h,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &src_buffer);

    if (status != kCVReturnSuccess || !src_buffer) return nullptr;

    // Lock and copy RGBA → BGRA using Accelerate vImage (~10x faster than scalar)
    CVPixelBufferLockBaseAddress(src_buffer, 0);
    std::uint8_t* dst = static_cast<std::uint8_t*>(
        CVPixelBufferGetBaseAddress(src_buffer));
    std::size_t dst_stride = CVPixelBufferGetBytesPerRow(src_buffer);
    std::size_t src_stride = static_cast<std::size_t>(w) * 4;

    vImage_Buffer src_vimg = {
        const_cast<std::uint8_t*>(rgba), h, w, src_stride
    };
    vImage_Buffer dst_vimg = {
        dst, h, w, dst_stride
    };
    // Swift's convertToBGRA already produces BGRA (kCVPixelFormatType_32BGRA).
    // No channel swap needed — copy BGRA→BGRA unchanged.
    // (Old code did RGBA→BGRA which was wrong: input is BGRA not RGBA)
    const uint8_t permuteMap[4] = {0, 1, 2, 3};  // Identity: BGRA→BGRA unchanged
    vImagePermuteChannels_ARGB8888(&src_vimg, &dst_vimg, permuteMap, kvImageNoFlags);

    CVPixelBufferUnlockBaseAddress(src_buffer, 0);

    // Step 2: Resize to model input size using CIImage (GPU-accelerated)
    // Uses auto-detected input dimensions (e.g., Small=518×392, Large=518×518)
    CIImage* ci_image = [CIImage imageWithCVPixelBuffer:src_buffer];
    CVPixelBufferRelease(src_buffer);  // CIImage retains the data

    if (!ci_image) return nullptr;

    CGFloat scale_x = static_cast<CGFloat>(input_width_) / w;
    CGFloat scale_y = static_cast<CGFloat>(input_height_) / h;
    CIImage* scaled = [ci_image imageByApplyingTransform:
        CGAffineTransformMakeScale(scale_x, scale_y)];

    if (!scaled) return nullptr;

    // Step 3: Render resized image to output CVPixelBuffer
    CVPixelBufferRef out_buffer = nullptr;
    status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        input_width_, input_height_,
        kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attrs,
        &out_buffer);

    if (status != kCVReturnSuccess || !out_buffer) return nullptr;

    [ci_context_ render:scaled toCVPixelBuffer:out_buffer];

    return out_buffer;  // Caller owns (must CVPixelBufferRelease)
}

// ═══════════════════════════════════════════════════════════════════════
// Internal: CoreML Prediction
// ═══════════════════════════════════════════════════════════════════════

bool CoreMLDepthInferenceEngine::run_prediction(
    CVPixelBufferRef pixel_buffer,
    DepthInferenceResult& out) noexcept
{
    if (!model_ || !pixel_buffer) return false;

    // Wrap pixel buffer as CoreML input
    MLFeatureValue* image_value = [MLFeatureValue featureValueWithPixelBuffer:pixel_buffer];
    if (!image_value) return false;

    // Use auto-detected input key if available, otherwise try common names.
    // Small model (Apple): input="image", output="depth"
    // Large model (LloydAI): input="colorImage", output="depthOutput"
    NSArray<NSString*>* input_keys;
    if (input_key_) {
        input_keys = @[input_key_];
    } else {
        input_keys = @[
            @"image", @"colorImage", @"input", @"input_image", @"pixel_values"
        ];
    }

    for (NSString* key in input_keys) {
        for (int attempt = 0; attempt < 2; ++attempt) {
            NSError* error = nil;
            MLDictionaryFeatureProvider* input =
                [[MLDictionaryFeatureProvider alloc]
                    initWithDictionary:@{key: image_value}
                    error:&error];
            if (error || !input) {
                std::fprintf(stderr,
                    "[Aether3D] %s CoreML: feature provider failed for key '%s': %s\n",
                    name_.c_str(), [key UTF8String],
                    error ? [[error localizedDescription] UTF8String] : "nil");
                break;
            }

            id<MLFeatureProvider> output = nil;
            @try {
                output = [model_ predictionFromFeatures:input error:&error];
            } @catch (NSException* exception) {
                std::fprintf(stderr,
                    "[Aether3D] %s CoreML: EXCEPTION during prediction: %s — %s\n",
                    name_.c_str(),
                    [[exception name] UTF8String],
                    [[exception reason] UTF8String]);
                model_ = nil;
                return false;
            }
            if (error || !output) {
                if (attempt == 0 &&
                    !cpu_only_mode_ &&
                    should_retry_on_cpu(error) &&
                    load_model(MLComputeUnitsCPUOnly, "runtime CPU-only fallback")) {
                    std::fprintf(stderr,
                        "[Aether3D] %s CoreML: runtime GPU prediction failed, retrying CPU-only\n",
                        name_.c_str());
                    continue;
                }
                std::fprintf(stderr,
                    "[Aether3D] %s CoreML: prediction failed for key '%s': %s\n",
                    name_.c_str(), [key UTF8String],
                    error ? [[error localizedDescription] UTF8String] : "nil output");
                break;
            }

            if (extract_depth(output, out)) {
                if (!input_key_) {
                    input_key_ = key;
                    std::fprintf(stderr,
                        "[Aether3D] %s CoreML: auto-detected input key '%s'\n",
                        name_.c_str(), [key UTF8String]);
                }
                return true;
            }
            break;
        }
    }

    // All key combinations failed
    std::fprintf(stderr,
        "[Aether3D] %s CoreML: prediction failed — no valid input key found\n",
        name_.c_str());
    return false;
}

bool CoreMLDepthInferenceEngine::extract_depth(
    id<MLFeatureProvider> output,
    DepthInferenceResult& out) noexcept
{
    // Use auto-detected output key if available, otherwise try common names.
    NSArray<NSString*>* output_keys;
    if (output_key_) {
        output_keys = @[output_key_];
    } else {
        output_keys = @[
            @"depth", @"depthOutput", @"output", @"predicted_depth", @"result"
        ];
    }

    for (NSString* key in output_keys) {
        MLFeatureValue* value = [output featureValueForName:key];
        if (!value) continue;

        // Handle both image-type and multiArray-type outputs
        if (value.type == MLFeatureTypeImage) {
            // Image-type output (e.g., Large model returns grayscale image)
            CVPixelBufferRef depth_pb = value.imageBufferValue;
            if (depth_pb) {
                if (pixel_buffer_to_result(depth_pb, out)) {
                    if (!output_key_) output_key_ = key;
                    return true;
                }
            }
        }

        MLMultiArray* array = [value multiArrayValue];
        if (!array) continue;

        if (multi_array_to_result(array, out)) {
            if (!output_key_) output_key_ = key;
            return true;
        }
    }

    return false;
}

bool CoreMLDepthInferenceEngine::pixel_buffer_to_result(
    CVPixelBufferRef pb,
    DepthInferenceResult& out) noexcept
{
    if (!pb) return false;

    CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    std::uint32_t pw = static_cast<std::uint32_t>(CVPixelBufferGetWidth(pb));
    std::uint32_t ph = static_cast<std::uint32_t>(CVPixelBufferGetHeight(pb));
    if (pw == 0 || ph == 0) {
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        return false;
    }

    std::size_t count = static_cast<std::size_t>(pw) * ph;
    out.depth_map.resize(count);
    out.width = pw;
    out.height = ph;

    OSType fmt = CVPixelBufferGetPixelFormatType(pb);
    std::size_t stride = CVPixelBufferGetBytesPerRow(pb);
    const std::uint8_t* base = static_cast<const std::uint8_t*>(
        CVPixelBufferGetBaseAddress(pb));

    if (fmt == kCVPixelFormatType_OneComponent16Half) {
        // Float16 grayscale
        for (std::uint32_t y = 0; y < ph; ++y) {
            const __fp16* row = reinterpret_cast<const __fp16*>(base + y * stride);
            for (std::uint32_t x = 0; x < pw; ++x) {
                out.depth_map[y * pw + x] = static_cast<float>(row[x]);
            }
        }
    } else if (fmt == kCVPixelFormatType_OneComponent32Float) {
        // Float32 grayscale
        for (std::uint32_t y = 0; y < ph; ++y) {
            const float* row = reinterpret_cast<const float*>(base + y * stride);
            for (std::uint32_t x = 0; x < pw; ++x) {
                out.depth_map[y * pw + x] = row[x];
            }
        }
    } else if (fmt == kCVPixelFormatType_32BGRA || fmt == kCVPixelFormatType_32RGBA) {
        // Grayscale encoded as BGRA/RGBA — take first channel as depth proxy
        for (std::uint32_t y = 0; y < ph; ++y) {
            const std::uint8_t* row = base + y * stride;
            for (std::uint32_t x = 0; x < pw; ++x) {
                out.depth_map[y * pw + x] = row[x * 4] / 255.0f;
            }
        }
    } else if (fmt == kCVPixelFormatType_OneComponent8) {
        // 8-bit grayscale
        for (std::uint32_t y = 0; y < ph; ++y) {
            const std::uint8_t* row = base + y * stride;
            for (std::uint32_t x = 0; x < pw; ++x) {
                out.depth_map[y * pw + x] = row[x] / 255.0f;
            }
        }
    } else {
        // Unsupported pixel format
        CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
        std::fprintf(stderr,
            "[Aether3D] %s: unsupported depth pixel format: 0x%08X\n",
            name_.c_str(), static_cast<unsigned>(fmt));
        return false;
    }

    CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);

    // Auto-detect metric vs relative depth model.
    // ─────────────────────────────────────────────────────────────────
    // Relative DAv2:  outputs disparity in [0,1] (or 8-bit [0,255] already normalized)
    // Metric DAv2:    outputs absolute depth in METERS — indoor max ~20m, outdoor ~80m
    // Metric3D V2:    outputs in canonical focal space, converted by fx/1000 → meters
    //
    // Detection: if max_val > 1.5f → definitely metric (no disparity map reaches 1.5)
    // Borrowed from WildGS-SLAM pattern: metric model output always >> 1.0
    float min_val = out.depth_map[0];
    float max_val = out.depth_map[0];
    for (std::size_t i = 1; i < count; ++i) {
        float v = out.depth_map[i];
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }

    if (max_val > 1.5f) {
        // Metric model detected: clamp to valid indoor range [0.1m, 20m] and mark as metric
        // DAv2-metric-hypersim max_depth=20m; DAv2-metric-vkitti max_depth=80m
        for (std::size_t i = 0; i < count; ++i) {
            float v = out.depth_map[i];
            out.depth_map[i] = (v < 0.1f) ? 0.0f : (v > 80.0f ? 80.0f : v);
        }
        out.is_metric = true;
    } else {
        // Relative model: normalize to [0,1]
        float range = max_val - min_val;
        if (range > 1e-6f) {
            float inv_range = 1.0f / range;
            for (std::size_t i = 0; i < count; ++i) {
                out.depth_map[i] = (out.depth_map[i] - min_val) * inv_range;
            }
        }
        out.is_metric = false;
    }

    return true;
}

bool CoreMLDepthInferenceEngine::multi_array_to_result(
    MLMultiArray* array,
    DepthInferenceResult& out) noexcept
{
    if (!array) return false;

    NSArray<NSNumber*>* shape = array.shape;
    if (shape.count < 2) return false;

    // Shape is typically [1, H, W] or [H, W]
    std::uint32_t height = static_cast<std::uint32_t>(
        shape[shape.count - 2].intValue);
    std::uint32_t width = static_cast<std::uint32_t>(
        shape[shape.count - 1].intValue);

    if (width == 0 || height == 0) return false;

    std::size_t count = static_cast<std::size_t>(width) * height;

    // Allocate output
    out.depth_map.resize(count);
    out.width = width;
    out.height = height;

    // Copy data from MLMultiArray.
    // MLMultiArray.dataPointer gives direct float access for Float32 arrays.
    // For Float16 models, dataType will be MLMultiArrayDataTypeFloat16 —
    // we handle both cases.
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        const float* src = static_cast<const float*>(array.dataPointer);
        std::memcpy(out.depth_map.data(), src, count * sizeof(float));
    } else if (array.dataType == MLMultiArrayDataTypeFloat16) {
        // Float16 → Float32 conversion
        const __fp16* src = static_cast<const __fp16*>(array.dataPointer);
        for (std::size_t i = 0; i < count; ++i) {
            out.depth_map[i] = static_cast<float>(src[i]);
        }
    } else if (array.dataType == MLMultiArrayDataTypeDouble) {
        const double* src = static_cast<const double*>(array.dataPointer);
        for (std::size_t i = 0; i < count; ++i) {
            out.depth_map[i] = static_cast<float>(src[i]);
        }
    } else {
        // Fallback: use MLMultiArray subscript (slower but handles all types)
        for (std::size_t i = 0; i < count; ++i) {
            out.depth_map[i] = [array objectAtIndexedSubscript:i].floatValue;
        }
    }

    // Auto-detect metric vs relative depth model (same logic as pixel_buffer_to_result)
    // Metric model: max_val > 1.5m (absolute meters from DAv2-metric / Metric3D / UniDepth)
    // Relative model: max_val ≤ 1.0 (disparity, normalize to [0,1])
    float min_val = out.depth_map[0];
    float max_val = out.depth_map[0];
    for (std::size_t i = 1; i < count; ++i) {
        float v = out.depth_map[i];
        if (v < min_val) min_val = v;
        if (v > max_val) max_val = v;
    }

    if (max_val > 1.5f) {
        // Metric model: clamp to valid range, mark is_metric=true
        for (std::size_t i = 0; i < count; ++i) {
            float v = out.depth_map[i];
            out.depth_map[i] = (v < 0.1f) ? 0.0f : (v > 80.0f ? 80.0f : v);
        }
        out.is_metric = true;
    } else {
        // Relative model: normalize to [0,1]
        float range = max_val - min_val;
        if (range > 1e-6f) {
            float inv_range = 1.0f / range;
            for (std::size_t i = 0; i < count; ++i) {
                out.depth_map[i] = (out.depth_map[i] - min_val) * inv_range;
            }
        }
        out.is_metric = false;
    }

    return true;
}

// ═══════════════════════════════════════════════════════════════════════
// Factory
// ═══════════════════════════════════════════════════════════════════════

std::unique_ptr<DepthInferenceEngine> create_depth_inference_engine(
    const char* model_path, const char* name) noexcept
{
    if (!model_path) return nullptr;

    auto* engine = new (std::nothrow) CoreMLDepthInferenceEngine(model_path, name);
    if (!engine) return nullptr;

    return std::unique_ptr<DepthInferenceEngine>(engine);
}

}  // namespace pipeline
}  // namespace aether

#else  // !__APPLE__

// ═══════════════════════════════════════════════════════════════════════
// Non-Apple stub (Android/Linux) — returns unavailable engine
// ═══════════════════════════════════════════════════════════════════════

#include "aether/pipeline/depth_inference_engine.h"
#include <new>

namespace aether {
namespace pipeline {

class StubDepthInferenceEngine final : public DepthInferenceEngine {
public:
    core::Status infer(
        const std::uint8_t*, std::uint32_t, std::uint32_t,
        DepthInferenceResult&) noexcept override {
        return core::Status::kResourceExhausted;
    }

    void submit_async(
        const std::uint8_t*, std::uint32_t, std::uint32_t) noexcept override {}

    bool poll_result(DepthInferenceResult&) noexcept override {
        return false;
    }

    bool is_available() const noexcept override { return false; }
};

std::unique_ptr<DepthInferenceEngine> create_depth_inference_engine(
    const char*, const char*) noexcept
{
    auto* engine = new (std::nothrow) StubDepthInferenceEngine();
    if (!engine) return nullptr;
    return std::unique_ptr<DepthInferenceEngine>(engine);
}

}  // namespace pipeline
}  // namespace aether

#endif  // __APPLE__
