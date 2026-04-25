// Phase 1.7 hello triangle — render a colored triangle to an offscreen
// 256x256 RGBA8 texture, copy back to a buffer, write to PPM file.
//
// Verifies the full Dawn graphics pipeline path:
//   - Render-attachment texture creation
//   - Single shader module with vertex + fragment entry points
//   - Render pipeline (vertex no-buffer, fragment to single color target)
//   - Render pass (clear + draw)
//   - CopyTextureToBuffer with 256-aligned bytesPerRow
//   - MapAsync readback + PPM write
//
// Why P1.7 alongside P1.5 (compute):
// Phase 4 (Flutter Texture interop) does "Dawn renders to MTLTexture →
// IOSurface → CVPixelBuffer → Flutter Texture". If P1.7 passes here in
// Phase 1, any Phase 4 failure is necessarily in the iOS interop layer,
// not in Dawn's graphics pipeline itself. Bisect time drops from ~1 day
// to ~1 hour. See feedback memory: layered risk validation.

#include <webgpu/webgpu_cpp.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <ostream>

namespace {

std::ostream& operator<<(std::ostream& os, const wgpu::StringView& s) {
    if (s.data == nullptr) {
        return os;
    }
    if (s.length == WGPU_STRLEN) {
        return os << s.data;
    }
    return os.write(s.data, static_cast<std::streamsize>(s.length));
}

constexpr uint32_t kWidth = 256;
constexpr uint32_t kHeight = 256;
constexpr uint32_t kBytesPerPixel = 4;            // RGBA8Unorm
constexpr uint32_t kBytesPerRow = kWidth * kBytesPerPixel;          // 1024 ÷ 256 = 4 ✓ aligned
constexpr uint64_t kBufferBytes =
    static_cast<uint64_t>(kBytesPerRow) * static_cast<uint64_t>(kHeight);

// Single module, two entry points. Hardcoded triangle in NDC, barycentric
// RGB so each corner is one primary color.
constexpr const char* kShaderWgsl = R"(
struct VOut {
    @builtin(position) pos: vec4f,
    @location(0) color: vec3f,
};

@vertex
fn vs_main(@builtin(vertex_index) vid: u32) -> VOut {
    let positions = array(
        vec2f( 0.0,  0.7),
        vec2f(-0.7, -0.7),
        vec2f( 0.7, -0.7),
    );
    let colors = array(
        vec3f(1.0, 0.0, 0.0),
        vec3f(0.0, 1.0, 0.0),
        vec3f(0.0, 0.0, 1.0),
    );
    var out: VOut;
    out.pos = vec4f(positions[vid], 0.0, 1.0);
    out.color = colors[vid];
    return out;
}

@fragment
fn fs_main(@location(0) color: vec3f) -> @location(0) vec4f {
    return vec4f(color, 1.0);
}
)";

constexpr const char* kOutputPath = "aether_dawn_hello_triangle.ppm";

bool write_ppm_rgba8(const char* path, const uint8_t* rgba, uint32_t w, uint32_t h) {
    FILE* fp = std::fopen(path, "wb");
    if (fp == nullptr) {
        return false;
    }
    std::fprintf(fp, "P6\n%u %u\n255\n", w, h);
    for (uint32_t y = 0; y < h; ++y) {
        const uint8_t* row = rgba + static_cast<size_t>(y) * kBytesPerRow;
        for (uint32_t x = 0; x < w; ++x) {
            const uint8_t pixel[3] = {row[x * 4 + 0], row[x * 4 + 1], row[x * 4 + 2]};
            std::fwrite(pixel, 1, 3, fp);
        }
    }
    std::fclose(fp);
    return true;
}

}  // namespace

int main(int /*argc*/, char* /*argv*/[]) {
    static constexpr auto kTimedWaitAny = wgpu::InstanceFeatureName::TimedWaitAny;
    wgpu::InstanceDescriptor instance_desc{
        .requiredFeatureCount = 1,
        .requiredFeatures = &kTimedWaitAny,
    };
    wgpu::Instance instance = wgpu::CreateInstance(&instance_desc);
    if (instance == nullptr) {
        std::cerr << "wgpu::CreateInstance failed\n";
        return EXIT_FAILURE;
    }

    // ---------------------------------------------------------------- adapter
    wgpu::Adapter adapter;
    {
        wgpu::RequestAdapterOptions options{};
        instance.WaitAny(
            instance.RequestAdapter(
                &options, wgpu::CallbackMode::WaitAnyOnly,
                [&adapter](wgpu::RequestAdapterStatus status,
                           wgpu::Adapter received,
                           wgpu::StringView message) {
                    if (status != wgpu::RequestAdapterStatus::Success) {
                        std::cerr << "RequestAdapter failed: " << message << '\n';
                        return;
                    }
                    adapter = std::move(received);
                }),
            UINT64_MAX);
        if (adapter == nullptr) {
            std::cerr << "Adapter is null\n";
            return EXIT_FAILURE;
        }
    }

    // ----------------------------------------------------------------- device
    wgpu::Device device;
    {
        wgpu::DeviceDescriptor device_desc{};
        instance.WaitAny(
            adapter.RequestDevice(
                &device_desc, wgpu::CallbackMode::WaitAnyOnly,
                [&device](wgpu::RequestDeviceStatus status,
                          wgpu::Device received,
                          wgpu::StringView message) {
                    if (status != wgpu::RequestDeviceStatus::Success) {
                        std::cerr << "RequestDevice failed: " << message << '\n';
                        return;
                    }
                    device = std::move(received);
                }),
            UINT64_MAX);
        if (device == nullptr) {
            std::cerr << "Device is null\n";
            return EXIT_FAILURE;
        }
    }

    wgpu::Queue queue = device.GetQueue();

    // -------------------------------------------------------- target texture
    wgpu::TextureDescriptor texture_desc{};
    texture_desc.size = {kWidth, kHeight, 1};
    texture_desc.format = wgpu::TextureFormat::RGBA8Unorm;
    texture_desc.usage = wgpu::TextureUsage::RenderAttachment | wgpu::TextureUsage::CopySrc;
    wgpu::Texture texture = device.CreateTexture(&texture_desc);
    wgpu::TextureView texture_view = texture.CreateView();

    // ------------------------------------------------------- readback buffer
    wgpu::BufferDescriptor readback_desc{
        .usage = wgpu::BufferUsage::MapRead | wgpu::BufferUsage::CopyDst,
        .size = kBufferBytes,
    };
    wgpu::Buffer readback_buffer = device.CreateBuffer(&readback_desc);

    // ---------------------------------------------------------- shader module
    wgpu::ShaderSourceWGSL wgsl_source{};
    wgsl_source.code = kShaderWgsl;
    wgpu::ShaderModuleDescriptor shader_desc{};
    shader_desc.nextInChain = &wgsl_source;
    wgpu::ShaderModule shader = device.CreateShaderModule(&shader_desc);

    // --------------------------------------------------------- render pipeline
    wgpu::ColorTargetState color_target{};
    color_target.format = wgpu::TextureFormat::RGBA8Unorm;
    color_target.writeMask = wgpu::ColorWriteMask::All;

    wgpu::FragmentState fragment_state{};
    fragment_state.module = shader;
    fragment_state.entryPoint = "fs_main";
    fragment_state.targetCount = 1;
    fragment_state.targets = &color_target;

    wgpu::RenderPipelineDescriptor pipeline_desc{};
    pipeline_desc.vertex.module = shader;
    pipeline_desc.vertex.entryPoint = "vs_main";
    pipeline_desc.vertex.bufferCount = 0;            // vertices come from @vertex_index
    pipeline_desc.primitive.topology = wgpu::PrimitiveTopology::TriangleList;
    pipeline_desc.fragment = &fragment_state;
    // multisample / depthStencil left at defaults
    wgpu::RenderPipeline pipeline = device.CreateRenderPipeline(&pipeline_desc);

    // ------------------------------------------------- encode + render + copy
    wgpu::CommandEncoder encoder = device.CreateCommandEncoder();
    {
        wgpu::RenderPassColorAttachment color_attach{};
        color_attach.view = texture_view;
        color_attach.loadOp = wgpu::LoadOp::Clear;
        color_attach.storeOp = wgpu::StoreOp::Store;
        color_attach.clearValue = {0.05, 0.05, 0.08, 1.0};   // dark, so triangle pops

        wgpu::RenderPassDescriptor pass_desc{};
        pass_desc.colorAttachmentCount = 1;
        pass_desc.colorAttachments = &color_attach;

        wgpu::RenderPassEncoder pass = encoder.BeginRenderPass(&pass_desc);
        pass.SetPipeline(pipeline);
        pass.Draw(3);
        pass.End();
    }
    {
        wgpu::TexelCopyTextureInfo src{};
        src.texture = texture;
        src.mipLevel = 0;
        src.origin = {0, 0, 0};
        src.aspect = wgpu::TextureAspect::All;

        wgpu::TexelCopyBufferLayout layout{};
        layout.offset = 0;
        layout.bytesPerRow = kBytesPerRow;
        layout.rowsPerImage = kHeight;

        wgpu::TexelCopyBufferInfo dst{};
        dst.layout = layout;
        dst.buffer = readback_buffer;

        wgpu::Extent3D extent{kWidth, kHeight, 1};
        encoder.CopyTextureToBuffer(&src, &dst, &extent);
    }
    wgpu::CommandBuffer commands = encoder.Finish();
    queue.Submit(1, &commands);

    // -------------------------------------------------------- map readback
    bool mapped = false;
    instance.WaitAny(
        readback_buffer.MapAsync(
            wgpu::MapMode::Read, 0, kBufferBytes,
            wgpu::CallbackMode::WaitAnyOnly,
            [&mapped](wgpu::MapAsyncStatus status, wgpu::StringView message) {
                if (status != wgpu::MapAsyncStatus::Success) {
                    std::cerr << "MapAsync failed: " << message << '\n';
                    return;
                }
                mapped = true;
            }),
        UINT64_MAX);
    if (!mapped) {
        std::cerr << "Buffer never mapped\n";
        return EXIT_FAILURE;
    }

    const auto* rgba = static_cast<const uint8_t*>(
        readback_buffer.GetConstMappedRange(0, kBufferBytes));
    if (rgba == nullptr) {
        std::cerr << "GetConstMappedRange returned null\n";
        return EXIT_FAILURE;
    }

    // ----------------------------------------------------------- write PPM
    std::cout << "=== aether_dawn_hello_triangle (P1.7) ===\n";
    if (!write_ppm_rgba8(kOutputPath, rgba, kWidth, kHeight)) {
        std::cerr << "Failed to write " << kOutputPath << '\n';
        readback_buffer.Unmap();
        return EXIT_FAILURE;
    }
    readback_buffer.Unmap();

    std::cout << "Wrote " << kWidth << "x" << kHeight << " RGB to "
              << kOutputPath << '\n';
    std::cout << "Open with: open " << kOutputPath << '\n';
    std::cout << "PASS\n";
    return EXIT_SUCCESS;
}
