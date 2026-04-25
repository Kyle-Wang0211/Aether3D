// SPDX-License-Identifier: LicenseRef-Aether3D-Proprietary
// Copyright (c) 2024-2026 Aether3D. All rights reserved.
//
// MetalGPUDevice — Concrete GPUDevice implementation wrapping Apple Metal.
// Objective-C++ (.mm) because Metal is an Objective-C API.

#if defined(__APPLE__)

#import <Metal/Metal.h>
#import <Foundation/Foundation.h>

#include "aether/render/metal_gpu_device.h"
#include <unordered_map>
#include <mutex>
#include <atomic>
#include <cstring>

namespace aether {
namespace render {

// ═══════════════════════════════════════════════════════════════════════
// Metal format/enum mapping helpers
// ═══════════════════════════════════════════════════════════════════════

static MTLStorageMode map_storage(GPUStorageMode mode) {
    switch (mode) {
        case GPUStorageMode::kShared:  return MTLStorageModeShared;
        case GPUStorageMode::kPrivate: return MTLStorageModePrivate;
#if TARGET_OS_OSX
        case GPUStorageMode::kManaged: return MTLStorageModeManaged;
#else
        case GPUStorageMode::kManaged: return MTLStorageModeShared;
#endif
    }
    return MTLStorageModeShared;
}

static MTLPixelFormat map_texture_format(GPUTextureFormat fmt) {
    switch (fmt) {
        case GPUTextureFormat::kR8Unorm:              return MTLPixelFormatR8Unorm;
        case GPUTextureFormat::kRG8Unorm:             return MTLPixelFormatRG8Unorm;
        case GPUTextureFormat::kRGBA8Unorm:           return MTLPixelFormatRGBA8Unorm;
        case GPUTextureFormat::kBGRA8Unorm:           return MTLPixelFormatBGRA8Unorm;
        case GPUTextureFormat::kRGBA8Srgb:            return MTLPixelFormatRGBA8Unorm_sRGB;
        case GPUTextureFormat::kR16Float:             return MTLPixelFormatR16Float;
        case GPUTextureFormat::kRG16Float:            return MTLPixelFormatRG16Float;
        case GPUTextureFormat::kRGBA16Float:          return MTLPixelFormatRGBA16Float;
        case GPUTextureFormat::kR32Float:             return MTLPixelFormatR32Float;
        case GPUTextureFormat::kRG32Float:            return MTLPixelFormatRG32Float;
        case GPUTextureFormat::kRGBA32Float:          return MTLPixelFormatRGBA32Float;
        case GPUTextureFormat::kDepth32Float:         return MTLPixelFormatDepth32Float;
        case GPUTextureFormat::kDepth32Float_Stencil8:return MTLPixelFormatDepth32Float_Stencil8;
        case GPUTextureFormat::kR32Uint:              return MTLPixelFormatR32Uint;
        case GPUTextureFormat::kRG32Uint:             return MTLPixelFormatRG32Uint;
        case GPUTextureFormat::kInvalid:              return MTLPixelFormatInvalid;
    }
    return MTLPixelFormatRGBA8Unorm;
}

static MTLPrimitiveType map_primitive(GPUPrimitiveType type) {
    switch (type) {
        case GPUPrimitiveType::kTriangle:      return MTLPrimitiveTypeTriangle;
        case GPUPrimitiveType::kTriangleStrip: return MTLPrimitiveTypeTriangleStrip;
        case GPUPrimitiveType::kLine:          return MTLPrimitiveTypeLine;
        case GPUPrimitiveType::kLineStrip:     return MTLPrimitiveTypeLineStrip;
        case GPUPrimitiveType::kPoint:         return MTLPrimitiveTypePoint;
    }
    return MTLPrimitiveTypeTriangle;
}

static MTLCullMode map_cull(GPUCullMode mode) {
    switch (mode) {
        case GPUCullMode::kNone:  return MTLCullModeNone;
        case GPUCullMode::kFront: return MTLCullModeFront;
        case GPUCullMode::kBack:  return MTLCullModeBack;
    }
    return MTLCullModeNone;
}

static MTLWinding map_winding(GPUWindingOrder order) {
    switch (order) {
        case GPUWindingOrder::kClockwise:        return MTLWindingClockwise;
        case GPUWindingOrder::kCounterClockwise: return MTLWindingCounterClockwise;
    }
    return MTLWindingClockwise;
}

static MTLLoadAction map_load(GPULoadAction action) {
    switch (action) {
        case GPULoadAction::kDontCare: return MTLLoadActionDontCare;
        case GPULoadAction::kLoad:     return MTLLoadActionLoad;
        case GPULoadAction::kClear:    return MTLLoadActionClear;
    }
    return MTLLoadActionClear;
}

static MTLStoreAction map_store(GPUStoreAction action) {
    switch (action) {
        case GPUStoreAction::kDontCare: return MTLStoreActionDontCare;
        case GPUStoreAction::kStore:    return MTLStoreActionStore;
    }
    return MTLStoreActionStore;
}

static MTLCompareFunction map_compare(GPUCompareFunction func) {
    switch (func) {
        case GPUCompareFunction::kAlways:       return MTLCompareFunctionAlways;
        case GPUCompareFunction::kLess:         return MTLCompareFunctionLess;
        case GPUCompareFunction::kLessEqual:    return MTLCompareFunctionLessEqual;
        case GPUCompareFunction::kGreater:      return MTLCompareFunctionGreater;
        case GPUCompareFunction::kGreaterEqual: return MTLCompareFunctionGreaterEqual;
    }
    return MTLCompareFunctionAlways;
}

static MTLBlendOperation map_blend_op(GPUBlendOperation op) {
    switch (op) {
        case GPUBlendOperation::kAdd:             return MTLBlendOperationAdd;
        case GPUBlendOperation::kSubtract:        return MTLBlendOperationSubtract;
        case GPUBlendOperation::kReverseSubtract: return MTLBlendOperationReverseSubtract;
    }
    return MTLBlendOperationAdd;
}

static MTLBlendFactor map_blend_factor(GPUBlendFactor factor) {
    switch (factor) {
        case GPUBlendFactor::kZero:                    return MTLBlendFactorZero;
        case GPUBlendFactor::kOne:                     return MTLBlendFactorOne;
        case GPUBlendFactor::kSourceColor:             return MTLBlendFactorSourceColor;
        case GPUBlendFactor::kOneMinusSourceColor:     return MTLBlendFactorOneMinusSourceColor;
        case GPUBlendFactor::kDestinationColor:        return MTLBlendFactorDestinationColor;
        case GPUBlendFactor::kOneMinusDestinationColor:return MTLBlendFactorOneMinusDestinationColor;
        case GPUBlendFactor::kSourceAlpha:             return MTLBlendFactorSourceAlpha;
        case GPUBlendFactor::kOneMinusSourceAlpha:     return MTLBlendFactorOneMinusSourceAlpha;
        case GPUBlendFactor::kDestinationAlpha:        return MTLBlendFactorDestinationAlpha;
        case GPUBlendFactor::kOneMinusDestinationAlpha:return MTLBlendFactorOneMinusDestinationAlpha;
    }
    return MTLBlendFactorOne;
}

// ═══════════════════════════════════════════════════════════════════════
// MetalGPUDevice
// ═══════════════════════════════════════════════════════════════════════

class MetalCommandBuffer;  // Forward declare for create_command_buffer()

class MetalGPUDevice final : public GPUDevice {
public:
    explicit MetalGPUDevice(id<MTLDevice> device)
        : device_(device), command_queue_([device newCommandQueue]) {}

    ~MetalGPUDevice() override {
        // ARC releases device_ and command_queue_ automatically
    }

    GraphicsBackend backend() const noexcept override {
        return GraphicsBackend::kMetal;
    }

    GPUCaps capabilities() const noexcept override {
        GPUCaps caps{};
        caps.backend = GraphicsBackend::kMetal;
        caps.max_buffer_size = static_cast<std::uint32_t>(
            std::min<NSUInteger>(device_.maxBufferLength, UINT32_MAX));
        caps.max_texture_size = 16384;
        caps.max_compute_workgroup_size = 1024;
        caps.max_threadgroup_memory = 32768;
        caps.supports_compute = true;
        caps.supports_indirect_draw = true;
        caps.supports_shared_memory = true;
        caps.supports_half_precision = true;
        caps.supports_simd_group = true;
        caps.simd_width = 32;  // Apple GPU SIMD width
        return caps;
    }

    GPUMemoryStats memory_stats() const noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        GPUMemoryStats stats{};
        stats.allocated_bytes = allocated_bytes_;
        stats.peak_bytes = peak_bytes_;
        stats.buffer_count = static_cast<std::uint32_t>(buffers_.size());
        stats.texture_count = static_cast<std::uint32_t>(textures_.size());
        return stats;
    }

    // ─── Buffer Management ───

    GPUBufferHandle create_buffer(const GPUBufferDesc& desc) noexcept override {
        MTLResourceOptions options = MTLResourceCPUCacheModeDefaultCache;
        switch (desc.storage) {
            case GPUStorageMode::kShared:
                options |= MTLResourceStorageModeShared;
                break;
            case GPUStorageMode::kPrivate:
                options |= MTLResourceStorageModePrivate;
                break;
            case GPUStorageMode::kManaged:
#if TARGET_OS_OSX
                options |= MTLResourceStorageModeManaged;
#else
                options |= MTLResourceStorageModeShared;
#endif
                break;
        }

        id<MTLBuffer> buffer = [device_ newBufferWithLength:desc.size_bytes
                                                    options:options];
        if (!buffer) return GPUBufferHandle{0};

        if (desc.label) {
            buffer.label = [NSString stringWithUTF8String:desc.label];
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        buffers_[handle_id] = buffer;
        allocated_bytes_ += desc.size_bytes;
        peak_bytes_ = std::max(peak_bytes_, allocated_bytes_);
        return GPUBufferHandle{handle_id};
    }

    void destroy_buffer(GPUBufferHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it != buffers_.end()) {
            allocated_bytes_ -= it->second.length;
            buffers_.erase(it);
        }
    }

    void* map_buffer(GPUBufferHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end()) return nullptr;
        return it->second.contents;
    }

    void unmap_buffer(GPUBufferHandle handle) noexcept override {
#if TARGET_OS_OSX
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it != buffers_.end() &&
            it->second.storageMode == MTLStorageModeManaged) {
            [it->second didModifyRange:NSMakeRange(0, it->second.length)];
        }
#else
        (void)handle;  // No-op on iOS (shared memory)
#endif
    }

    void update_buffer(GPUBufferHandle handle, const void* data,
                       std::size_t offset, std::size_t size) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(handle.id);
        if (it == buffers_.end() || !data) return;
        id<MTLBuffer> buf = it->second;
        if (offset + size > buf.length) return;

        std::memcpy(static_cast<std::uint8_t*>(buf.contents) + offset, data, size);

#if TARGET_OS_OSX
        if (buf.storageMode == MTLStorageModeManaged) {
            [buf didModifyRange:NSMakeRange(offset, size)];
        }
#endif
    }

    // ─── Texture Management ───

    GPUTextureHandle create_texture(const GPUTextureDesc& desc) noexcept override {
        MTLTextureDescriptor* td = [MTLTextureDescriptor new];
        td.textureType = (desc.depth > 1) ? MTLTextureType3D : MTLTextureType2D;
        td.pixelFormat = map_texture_format(desc.format);
        td.width = desc.width;
        td.height = desc.height;
        td.depth = desc.depth;
        td.mipmapLevelCount = desc.mip_levels;
        td.storageMode = map_storage(desc.storage);

        MTLTextureUsage usage = 0;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kShaderRead))
            usage |= MTLTextureUsageShaderRead;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kShaderWrite))
            usage |= MTLTextureUsageShaderWrite;
        if (desc.usage_mask & static_cast<std::uint8_t>(GPUTextureUsage::kRenderTarget))
            usage |= MTLTextureUsageRenderTarget;
        td.usage = usage;

        id<MTLTexture> texture = [device_ newTextureWithDescriptor:td];
        if (!texture) return GPUTextureHandle{0};

        if (desc.label) {
            texture.label = [NSString stringWithUTF8String:desc.label];
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        textures_[handle_id] = texture;
        return GPUTextureHandle{handle_id};
    }

    void destroy_texture(GPUTextureHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        textures_.erase(handle.id);
    }

    void update_texture(GPUTextureHandle handle, const void* data,
                        std::uint32_t width, std::uint32_t height,
                        std::uint32_t bytes_per_row) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(handle.id);
        if (it == textures_.end() || !data) return;
        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        [it->second replaceRegion:region
                      mipmapLevel:0
                        withBytes:data
                      bytesPerRow:bytes_per_row];
    }

    // ─── Shader Management ───

    GPUShaderHandle load_shader(const char* name,
                                GPUShaderStage stage) noexcept override {
        (void)stage;
        // Cache the MTLLibrary on first use (avoids 12x newDefaultLibrary during init).
        if (!cached_library_) {
            // Strategy 1: Default library (Xcode-embedded metallib)
            cached_library_ = [device_ newDefaultLibrary];

            // Strategy 2: Main bundle metallib (App.app/default.metallib)
            if (!cached_library_) {
                NSLog(@"[Aether3D][Metal] newDefaultLibrary returned nil, trying main bundle metallib...");
                NSURL* libURL = [[NSBundle mainBundle] URLForResource:@"default" withExtension:@"metallib"];
                if (libURL) {
                    NSError* loadErr = nil;
                    cached_library_ = [device_ newLibraryWithURL:libURL error:&loadErr];
                    if (!cached_library_) {
                        NSLog(@"[Aether3D][Metal] Failed to load metallib from main bundle: %@", loadErr);
                    }
                } else {
                    NSLog(@"[Aether3D][Metal] No default.metallib found in main bundle!");
                }
            }

            // Strategy 3: Search next to the executable (headless CMake tests).
            // CMake custom commands place default.metallib in the build dir alongside the test binary.
            if (!cached_library_) {
                NSLog(@"[Aether3D][Metal] Trying executable-relative metallib (headless test path)...");
                // _NSGetExecutablePath or /proc/self/exe — use NSProcessInfo for portability
                NSString* execPath = [[NSProcessInfo processInfo] arguments].firstObject;
                if (execPath) {
                    NSString* execDir = [execPath stringByDeletingLastPathComponent];
                    // Search order: same dir, then ../lib, then ../Resources
                    NSArray<NSString*>* searchPaths = @[
                        [execDir stringByAppendingPathComponent:@"default.metallib"],
                        [[execDir stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"lib/default.metallib"],
                        [[execDir stringByDeletingLastPathComponent]
                            stringByAppendingPathComponent:@"Resources/default.metallib"],
                    ];
                    for (NSString* path in searchPaths) {
                        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                            NSLog(@"[Aether3D][Metal] Found metallib at: %@", path);
                            NSURL* url = [NSURL fileURLWithPath:path];
                            NSError* loadErr = nil;
                            cached_library_ = [device_ newLibraryWithURL:url error:&loadErr];
                            if (cached_library_) {
                                NSLog(@"[Aether3D][Metal] Loaded metallib from: %@", path);
                                break;
                            } else {
                                NSLog(@"[Aether3D][Metal] Failed to load %@: %@", path, loadErr);
                            }
                        }
                    }
                }
            }
        }
        if (!cached_library_) {
            NSLog(@"[Aether3D][Metal] All library loading methods failed — no shaders available.");
            return GPUShaderHandle{0};
        }

        NSString* funcName = [NSString stringWithUTF8String:name];
        id<MTLFunction> function = [cached_library_ newFunctionWithName:funcName];
        if (!function) {
            NSLog(@"[Aether3D][Metal] Shader function '%s' not found in default library", name);
            return GPUShaderHandle{0};
        }

        std::lock_guard<std::mutex> lock(mutex_);
        std::uint32_t handle_id = ++next_id_;
        functions_[handle_id] = function;
        return GPUShaderHandle{handle_id};
    }

    void destroy_shader(GPUShaderHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        functions_.erase(handle.id);
    }

    // ─── Pipeline Management ───

    GPURenderPipelineHandle create_render_pipeline(
        GPUShaderHandle vertex_shader,
        GPUShaderHandle fragment_shader,
        const GPURenderTargetDesc& target_desc) noexcept override {

        std::lock_guard<std::mutex> lock(mutex_);
        auto vs_it = functions_.find(vertex_shader.id);
        auto fs_it = functions_.find(fragment_shader.id);
        if (vs_it == functions_.end() || fs_it == functions_.end())
            return GPURenderPipelineHandle{0};

        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = vs_it->second;
        desc.fragmentFunction = fs_it->second;
        const std::uint32_t attachment_count =
            std::min<std::uint32_t>(std::max<std::uint32_t>(target_desc.color_attachment_count, 1),
                                    kMaxColorAttachments);
        for (std::uint32_t i = 0; i < attachment_count; ++i) {
            GPUColorAttachmentTargetDesc attachment = target_desc.color_attachments[i];
            if (i == 0 && attachment.format == GPUTextureFormat::kRGBA8Unorm) {
                attachment.format = target_desc.color_format;
                attachment.blend.blending_enabled = target_desc.blending_enabled;
                if (target_desc.blending_enabled) {
                    attachment.blend.rgb_blend_op = GPUBlendOperation::kAdd;
                    attachment.blend.alpha_blend_op = GPUBlendOperation::kAdd;
                    attachment.blend.source_rgb_blend = GPUBlendFactor::kOne;
                    attachment.blend.destination_rgb_blend = GPUBlendFactor::kOneMinusSourceAlpha;
                    attachment.blend.source_alpha_blend = GPUBlendFactor::kOne;
                    attachment.blend.destination_alpha_blend = GPUBlendFactor::kOneMinusSourceAlpha;
                }
            }

            auto* color_attachment = desc.colorAttachments[i];
            color_attachment.pixelFormat = map_texture_format(attachment.format);
            color_attachment.blendingEnabled = attachment.blend.blending_enabled ? YES : NO;
            if (attachment.blend.blending_enabled) {
                color_attachment.rgbBlendOperation = map_blend_op(attachment.blend.rgb_blend_op);
                color_attachment.alphaBlendOperation = map_blend_op(attachment.blend.alpha_blend_op);
                color_attachment.sourceRGBBlendFactor =
                    map_blend_factor(attachment.blend.source_rgb_blend);
                color_attachment.destinationRGBBlendFactor =
                    map_blend_factor(attachment.blend.destination_rgb_blend);
                color_attachment.sourceAlphaBlendFactor =
                    map_blend_factor(attachment.blend.source_alpha_blend);
                color_attachment.destinationAlphaBlendFactor =
                    map_blend_factor(attachment.blend.destination_alpha_blend);
            }
        }
        desc.depthAttachmentPixelFormat = map_texture_format(target_desc.depth_format);
        desc.rasterSampleCount = target_desc.sample_count;

        NSError* error = nil;
        id<MTLRenderPipelineState> state =
            [device_ newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!state) {
            NSLog(@"[Aether3D][Metal] Render pipeline creation FAILED: %@", error);
            return GPURenderPipelineHandle{0};
        }

        id<MTLDepthStencilState> depth_state = nil;
        if ((target_desc.depth_test_enabled || target_desc.depth_write_enabled) &&
            target_desc.depth_format != GPUTextureFormat::kInvalid) {
            MTLDepthStencilDescriptor* depth_desc = [MTLDepthStencilDescriptor new];
            depth_desc.depthCompareFunction = map_compare(target_desc.depth_compare);
            depth_desc.depthWriteEnabled = target_desc.depth_write_enabled ? YES : NO;
            depth_state = [device_ newDepthStencilStateWithDescriptor:depth_desc];
        }

        std::uint32_t handle_id = ++next_id_;
        render_pipelines_[handle_id] = state;
        depth_states_[handle_id] = depth_state;
        return GPURenderPipelineHandle{handle_id};
    }

    void destroy_render_pipeline(GPURenderPipelineHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        render_pipelines_.erase(handle.id);
        depth_states_.erase(handle.id);
    }

    GPUComputePipelineHandle create_compute_pipeline(
        GPUShaderHandle compute_shader) noexcept override {

        std::lock_guard<std::mutex> lock(mutex_);
        auto it = functions_.find(compute_shader.id);
        if (it == functions_.end()) return GPUComputePipelineHandle{0};

        NSError* error = nil;
        id<MTLComputePipelineState> state =
            [device_ newComputePipelineStateWithFunction:it->second error:&error];
        if (!state) {
            NSLog(@"[Aether3D][Metal] Compute pipeline creation FAILED: %@", error);
            return GPUComputePipelineHandle{0};
        }

        std::uint32_t handle_id = ++next_id_;
        compute_pipelines_[handle_id] = state;
        return GPUComputePipelineHandle{handle_id};
    }

    void destroy_compute_pipeline(GPUComputePipelineHandle handle) noexcept override {
        std::lock_guard<std::mutex> lock(mutex_);
        compute_pipelines_.erase(handle.id);
    }

    // ─── Command Buffer ───

    std::unique_ptr<GPUCommandBuffer> create_command_buffer() noexcept override;

    // ─── Synchronization ───

    void wait_idle() noexcept override {
        // Create a temporary command buffer, commit, and wait
        id<MTLCommandBuffer> buf = [command_queue_ commandBuffer];
        [buf commit];
        [buf waitUntilCompleted];
    }

    // ─── Metal-specific accessors (used by MetalCommandBuffer) ───

    id<MTLDevice> mtl_device() const { return device_; }
    id<MTLCommandQueue> mtl_command_queue() const { return command_queue_; }

    id<MTLBuffer> get_buffer(std::uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = buffers_.find(id);
        return (it != buffers_.end()) ? it->second : nil;
    }

    id<MTLTexture> get_texture(std::uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = textures_.find(id);
        return (it != textures_.end()) ? it->second : nil;
    }

    id<MTLRenderPipelineState> get_render_pipeline(std::uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = render_pipelines_.find(id);
        return (it != render_pipelines_.end()) ? it->second : nil;
    }

    id<MTLDepthStencilState> get_depth_state(std::uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = depth_states_.find(id);
        return (it != depth_states_.end()) ? it->second : nil;
    }

    id<MTLComputePipelineState> get_compute_pipeline(std::uint32_t id) {
        std::lock_guard<std::mutex> lock(mutex_);
        auto it = compute_pipelines_.find(id);
        return (it != compute_pipelines_.end()) ? it->second : nil;
    }

private:
    id<MTLDevice> device_;
    id<MTLCommandQueue> command_queue_;
    id<MTLLibrary> cached_library_;  // Cached MTLLibrary (avoids 12x newDefaultLibrary)
    mutable std::mutex mutex_;
    std::uint32_t next_id_{0};

    // Resource maps (handle.id → Metal object)
    std::unordered_map<std::uint32_t, id<MTLBuffer>> buffers_;
    std::unordered_map<std::uint32_t, id<MTLTexture>> textures_;
    std::unordered_map<std::uint32_t, id<MTLFunction>> functions_;
    std::unordered_map<std::uint32_t, id<MTLRenderPipelineState>> render_pipelines_;
    std::unordered_map<std::uint32_t, id<MTLDepthStencilState>> depth_states_;
    std::unordered_map<std::uint32_t, id<MTLComputePipelineState>> compute_pipelines_;

    // Memory tracking
    std::size_t allocated_bytes_{0};
    std::size_t peak_bytes_{0};
};

// ═══════════════════════════════════════════════════════════════════════
// MetalComputeEncoder
// ═══════════════════════════════════════════════════════════════════════

class MetalComputeEncoder final : public GPUComputeEncoder {
public:
    MetalComputeEncoder(id<MTLComputeCommandEncoder> encoder, MetalGPUDevice& dev)
        : encoder_(encoder), device_(dev) {}

    void set_pipeline(GPUComputePipelineHandle pipeline) noexcept override {
        id<MTLComputePipelineState> state = device_.get_compute_pipeline(pipeline.id);
        if (state) {
            [encoder_ setComputePipelineState:state];
            threadgroup_size_ = state.maxTotalThreadsPerThreadgroup;
        }
    }

    void set_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                   std::uint32_t index) noexcept override {
        id<MTLBuffer> buf = device_.get_buffer(buffer.id);
        if (buf) [encoder_ setBuffer:buf offset:offset atIndex:index];
    }

    void set_texture(GPUTextureHandle texture, std::uint32_t index) noexcept override {
        id<MTLTexture> tex = device_.get_texture(texture.id);
        if (tex) [encoder_ setTexture:tex atIndex:index];
    }

    void set_bytes(const void* data, std::uint32_t size,
                  std::uint32_t index) noexcept override {
        if (data) [encoder_ setBytes:data length:size atIndex:index];
    }

    void dispatch(std::uint32_t groups_x, std::uint32_t groups_y,
                 std::uint32_t groups_z,
                 std::uint32_t threads_x, std::uint32_t threads_y,
                 std::uint32_t threads_z) noexcept override {
        MTLSize threadgroups = MTLSizeMake(groups_x, groups_y, groups_z);
        MTLSize threads_per = MTLSizeMake(threads_x, threads_y, threads_z);
        [encoder_ dispatchThreadgroups:threadgroups
                 threadsPerThreadgroup:threads_per];
    }

    void end_encoding() noexcept override {
        [encoder_ endEncoding];
    }

private:
    id<MTLComputeCommandEncoder> encoder_;
    MetalGPUDevice& device_;
    NSUInteger threadgroup_size_{256};
};

// ═══════════════════════════════════════════════════════════════════════
// MetalRenderEncoder
// ═══════════════════════════════════════════════════════════════════════

class MetalRenderEncoder final : public GPURenderEncoder {
public:
    MetalRenderEncoder(id<MTLRenderCommandEncoder> encoder, MetalGPUDevice& dev)
        : encoder_(encoder), device_(dev) {}

    void set_pipeline(GPURenderPipelineHandle pipeline) noexcept override {
        id<MTLRenderPipelineState> state = device_.get_render_pipeline(pipeline.id);
        if (state) [encoder_ setRenderPipelineState:state];
        id<MTLDepthStencilState> depth_state = device_.get_depth_state(pipeline.id);
        if (depth_state) {
            [encoder_ setDepthStencilState:depth_state];
        }
    }

    void set_vertex_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                           std::uint32_t index) noexcept override {
        id<MTLBuffer> buf = device_.get_buffer(buffer.id);
        if (buf) [encoder_ setVertexBuffer:buf offset:offset atIndex:index];
    }

    void set_fragment_buffer(GPUBufferHandle buffer, std::uint32_t offset,
                             std::uint32_t index) noexcept override {
        id<MTLBuffer> buf = device_.get_buffer(buffer.id);
        if (buf) [encoder_ setFragmentBuffer:buf offset:offset atIndex:index];
    }

    void set_vertex_bytes(const void* data, std::uint32_t size,
                          std::uint32_t index) noexcept override {
        if (data) [encoder_ setVertexBytes:data length:size atIndex:index];
    }

    void set_fragment_bytes(const void* data, std::uint32_t size,
                            std::uint32_t index) noexcept override {
        if (data) [encoder_ setFragmentBytes:data length:size atIndex:index];
    }

    void set_vertex_texture(GPUTextureHandle texture,
                            std::uint32_t index) noexcept override {
        id<MTLTexture> tex = device_.get_texture(texture.id);
        if (tex) [encoder_ setVertexTexture:tex atIndex:index];
    }

    void set_fragment_texture(GPUTextureHandle texture,
                              std::uint32_t index) noexcept override {
        id<MTLTexture> tex = device_.get_texture(texture.id);
        if (tex) [encoder_ setFragmentTexture:tex atIndex:index];
    }

    void set_viewport(const GPUViewport& viewport) noexcept override {
        MTLViewport vp{};
        vp.originX = viewport.origin_x;
        vp.originY = viewport.origin_y;
        vp.width = viewport.width;
        vp.height = viewport.height;
        vp.znear = viewport.near_depth;
        vp.zfar = viewport.far_depth;
        [encoder_ setViewport:vp];
    }

    void set_scissor(const GPUScissorRect& rect) noexcept override {
        MTLScissorRect sr{rect.x, rect.y, rect.width, rect.height};
        [encoder_ setScissorRect:sr];
    }

    void set_cull_mode(GPUCullMode mode) noexcept override {
        [encoder_ setCullMode:map_cull(mode)];
    }

    void set_winding(GPUWindingOrder order) noexcept override {
        [encoder_ setFrontFacingWinding:map_winding(order)];
    }

    void draw(GPUPrimitiveType type, std::uint32_t vertex_start,
             std::uint32_t vertex_count) noexcept override {
        [encoder_ drawPrimitives:map_primitive(type)
                     vertexStart:vertex_start
                     vertexCount:vertex_count];
    }

    void draw_indexed(GPUPrimitiveType type, std::uint32_t index_count,
                     GPUBufferHandle index_buffer,
                     std::uint32_t index_offset) noexcept override {
        id<MTLBuffer> idx_buf = device_.get_buffer(index_buffer.id);
        if (!idx_buf) return;
        [encoder_ drawIndexedPrimitives:map_primitive(type)
                             indexCount:index_count
                              indexType:MTLIndexTypeUInt32
                            indexBuffer:idx_buf
                      indexBufferOffset:index_offset];
    }

    void draw_instanced(GPUPrimitiveType type,
                       std::uint32_t vertex_count,
                       std::uint32_t instance_count) noexcept override {
        [encoder_ drawPrimitives:map_primitive(type)
                     vertexStart:0
                     vertexCount:vertex_count
                   instanceCount:instance_count];
    }

    void end_encoding() noexcept override {
        [encoder_ endEncoding];
    }

private:
    id<MTLRenderCommandEncoder> encoder_;
    MetalGPUDevice& device_;
};

// ═══════════════════════════════════════════════════════════════════════
// MetalCommandBuffer
// ═══════════════════════════════════════════════════════════════════════

class MetalCommandBuffer final : public GPUCommandBuffer {
public:
    MetalCommandBuffer(id<MTLCommandBuffer> buffer, MetalGPUDevice& dev)
        : buffer_(buffer), device_(dev) {}

    GPUComputeEncoder* make_compute_encoder() noexcept override {
        id<MTLComputeCommandEncoder> encoder = [buffer_ computeCommandEncoder];
        if (!encoder) return nullptr;
        compute_encoder_ = std::make_unique<MetalComputeEncoder>(encoder, device_);
        return compute_encoder_.get();
    }

    GPURenderEncoder* make_render_encoder(
        const GPURenderTargetDesc& target) noexcept override {

        // Create offscreen render pass descriptor from target description
        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];

        const std::uint32_t attachment_count =
            std::min<std::uint32_t>(std::max<std::uint32_t>(target.color_attachment_count, 1),
                                    kMaxColorAttachments);
        for (std::uint32_t i = 0; i < attachment_count; ++i) {
            GPUTextureFormat format = target.color_attachments[i].format;
            if (i == 0 && format == GPUTextureFormat::kRGBA8Unorm) {
                format = target.color_format;
            }
            MTLTextureDescriptor* color_td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:map_texture_format(format)
                                            width:target.width
                                           height:target.height
                                        mipmapped:NO];
            color_td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
            color_td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> color_tex = [device_.mtl_device() newTextureWithDescriptor:color_td];

            rpd.colorAttachments[i].texture = color_tex;
            rpd.colorAttachments[i].loadAction = map_load(target.color_load);
            rpd.colorAttachments[i].storeAction = map_store(target.color_store);
            rpd.colorAttachments[i].clearColor =
                MTLClearColorMake(target.clear_color[0], target.clear_color[1],
                                  target.clear_color[2], target.clear_color[3]);
        }

        // Depth attachment
        if (target.depth_format != GPUTextureFormat::kInvalid) {
            MTLTextureDescriptor* depth_td = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:map_texture_format(target.depth_format)
                                            width:target.width
                                           height:target.height
                                        mipmapped:NO];
            depth_td.usage = MTLTextureUsageRenderTarget;
            depth_td.storageMode = MTLStorageModePrivate;
            id<MTLTexture> depth_tex = [device_.mtl_device() newTextureWithDescriptor:depth_td];

            rpd.depthAttachment.texture = depth_tex;
            rpd.depthAttachment.loadAction = map_load(target.depth_load);
            rpd.depthAttachment.storeAction = map_store(target.depth_store);
            rpd.depthAttachment.clearDepth = target.clear_depth;
        }

        id<MTLRenderCommandEncoder> encoder =
            [buffer_ renderCommandEncoderWithDescriptor:rpd];
        if (!encoder) return nullptr;

        render_encoder_ = std::make_unique<MetalRenderEncoder>(encoder, device_);
        return render_encoder_.get();
    }

    GPURenderEncoder* make_render_encoder(
        const GPURenderPassDesc& pass) noexcept override {
        MTLRenderPassDescriptor* rpd = [MTLRenderPassDescriptor new];

        const std::uint32_t attachment_count =
            std::min<std::uint32_t>(std::max<std::uint32_t>(pass.color_attachment_count, 1),
                                    kMaxColorAttachments);
        for (std::uint32_t i = 0; i < attachment_count; ++i) {
            id<MTLTexture> color_tex = device_.get_texture(pass.color_attachments[i].texture.id);
            if (!color_tex) return nullptr;
            rpd.colorAttachments[i].texture = color_tex;
            rpd.colorAttachments[i].loadAction = map_load(pass.color_attachments[i].load);
            rpd.colorAttachments[i].storeAction = map_store(pass.color_attachments[i].store);
            rpd.colorAttachments[i].clearColor =
                MTLClearColorMake(pass.color_attachments[i].clear_color[0],
                                  pass.color_attachments[i].clear_color[1],
                                  pass.color_attachments[i].clear_color[2],
                                  pass.color_attachments[i].clear_color[3]);
        }

        if (pass.depth_attachment.texture.valid()) {
            id<MTLTexture> depth_tex = device_.get_texture(pass.depth_attachment.texture.id);
            if (!depth_tex) return nullptr;
            rpd.depthAttachment.texture = depth_tex;
            rpd.depthAttachment.loadAction = map_load(pass.depth_attachment.load);
            rpd.depthAttachment.storeAction = map_store(pass.depth_attachment.store);
            rpd.depthAttachment.clearDepth = pass.depth_attachment.clear_depth;
        }

        id<MTLRenderCommandEncoder> encoder =
            [buffer_ renderCommandEncoderWithDescriptor:rpd];
        if (!encoder) return nullptr;

        render_encoder_ = std::make_unique<MetalRenderEncoder>(encoder, device_);
        return render_encoder_.get();
    }

    GPURenderEncoder* make_render_encoder_native(
        void* native_rpd) noexcept override {
        if (!native_rpd) return nullptr;

        // native_rpd is an MTLRenderPassDescriptor* from Swift
        // (via Unmanaged.passUnretained().toOpaque()).
        // This renders directly into the MTKView's drawable — no offscreen textures.
        MTLRenderPassDescriptor* rpd =
            (__bridge MTLRenderPassDescriptor*)native_rpd;

        id<MTLRenderCommandEncoder> encoder =
            [buffer_ renderCommandEncoderWithDescriptor:rpd];
        if (!encoder) return nullptr;

        render_encoder_ = std::make_unique<MetalRenderEncoder>(encoder, device_);
        return render_encoder_.get();
    }

    void commit() noexcept override {
        [buffer_ commit];
        committed_ = true;
    }

    void wait_until_completed() noexcept override {
        if (committed_) {
            [buffer_ waitUntilCompleted];
        }
    }

    GPUTimestamp timestamp() const noexcept override {
        GPUTimestamp ts{};
        if (committed_) {
            ts.gpu_time_ms = (buffer_.GPUEndTime - buffer_.GPUStartTime) * 1000.0;
        }
        return ts;
    }

    bool had_error() const noexcept override {
        if (!committed_) return false;
        return buffer_.error != nil;
    }

private:
    id<MTLCommandBuffer> buffer_;
    MetalGPUDevice& device_;
    bool committed_{false};
    std::unique_ptr<MetalComputeEncoder> compute_encoder_;
    std::unique_ptr<MetalRenderEncoder> render_encoder_;
};

// ─── MetalGPUDevice::create_command_buffer (defined after MetalCommandBuffer) ───

std::unique_ptr<GPUCommandBuffer> MetalGPUDevice::create_command_buffer() noexcept {
    id<MTLCommandBuffer> buffer = [command_queue_ commandBuffer];
    if (!buffer) return nullptr;
    return std::make_unique<MetalCommandBuffer>(buffer, *this);
}

// ═══════════════════════════════════════════════════════════════════════
// Factory Functions
// ═══════════════════════════════════════════════════════════════════════

std::unique_ptr<GPUDevice> create_metal_gpu_device(void* mtl_device) noexcept {
    if (!mtl_device) return nullptr;
    id<MTLDevice> device = (__bridge id<MTLDevice>)mtl_device;
    return std::make_unique<MetalGPUDevice>(device);
}

std::unique_ptr<GPUCommandBuffer> create_metal_command_buffer(GPUDevice& device) noexcept {
    // Type-tag dispatch (project compiles with -fno-rtti, so dynamic_cast is unavailable).
    // GPUDevice exposes a virtual backend() method whose return value is the type tag.
    if (device.backend() != GraphicsBackend::kMetal) return nullptr;
    auto* metal_device = static_cast<MetalGPUDevice*>(&device);

    id<MTLCommandBuffer> buffer = [metal_device->mtl_command_queue() commandBuffer];
    if (!buffer) return nullptr;

    return std::make_unique<MetalCommandBuffer>(buffer, *metal_device);
}

std::unique_ptr<GPUCommandBuffer> wrap_metal_command_buffer(void* mtl_cmd_buffer,
                                                             GPUDevice& device) noexcept {
    if (!mtl_cmd_buffer) return nullptr;
    // Type-tag dispatch (see create_metal_command_buffer comment above).
    if (device.backend() != GraphicsBackend::kMetal) return nullptr;
    auto* metal_device = static_cast<MetalGPUDevice*>(&device);

    // Swift passes MTLCommandBuffer via Unmanaged.passUnretained().toOpaque()
    // → __bridge cast recovers the ObjC object without ownership transfer.
    id<MTLCommandBuffer> buffer = (__bridge id<MTLCommandBuffer>)mtl_cmd_buffer;
    if (!buffer) return nullptr;

    return std::make_unique<MetalCommandBuffer>(buffer, *metal_device);
}

}  // namespace render
}  // namespace aether

#endif  // __APPLE__
