// Phase 1.4 hello adapter — print GPU name + backend.
// Adapted from third_party/dawn/docs/quickstart-cmake.md.
//
// Verifies: Dawn submodule + CMake integration produces a working WebGPU
// instance, requests an adapter, and reports its info. On macOS this should
// print "Apple ..." with backendType reflecting Metal.

#include <webgpu/webgpu_cpp.h>

#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <ostream>

namespace {

// In current Dawn, AdapterInfo string fields are wgpu::StringView (data + length),
// not const char*. Provide an ostream printer that handles both null-terminated
// (length == WGPU_STRLEN) and explicit-length variants.
std::ostream& operator<<(std::ostream& os, const wgpu::StringView& s) {
    if (s.data == nullptr) {
        return os;
    }
    if (s.length == WGPU_STRLEN) {
        return os << s.data;
    }
    return os.write(s.data, static_cast<std::streamsize>(s.length));
}

const char* backend_type_to_string(wgpu::BackendType backend) {
    switch (backend) {
        case wgpu::BackendType::Undefined: return "Undefined";
        case wgpu::BackendType::Null: return "Null";
        case wgpu::BackendType::WebGPU: return "WebGPU";
        case wgpu::BackendType::D3D11: return "D3D11";
        case wgpu::BackendType::D3D12: return "D3D12";
        case wgpu::BackendType::Metal: return "Metal";
        case wgpu::BackendType::Vulkan: return "Vulkan";
        case wgpu::BackendType::OpenGL: return "OpenGL";
        case wgpu::BackendType::OpenGLES: return "OpenGLES";
        default: return "(unknown)";
    }
}

const char* adapter_type_to_string(wgpu::AdapterType type) {
    switch (type) {
        case wgpu::AdapterType::DiscreteGPU: return "DiscreteGPU";
        case wgpu::AdapterType::IntegratedGPU: return "IntegratedGPU";
        case wgpu::AdapterType::CPU: return "CPU";
        case wgpu::AdapterType::Unknown: return "Unknown";
        default: return "(unknown)";
    }
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

    wgpu::RequestAdapterOptions options{};
    wgpu::Adapter adapter;

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
        std::cerr << "Adapter is null after RequestAdapter\n";
        return EXIT_FAILURE;
    }

    wgpu::AdapterInfo info{};
    adapter.GetInfo(&info);

    std::cout << "=== aether_dawn_hello (P1.4) ===\n";
    std::cout << "Vendor:      " << info.vendor << '\n';
    std::cout << "Architecture:" << info.architecture << '\n';
    std::cout << "Device:      " << info.device << '\n';
    std::cout << "Description: " << info.description << '\n';
    std::cout << "VendorID:    0x" << std::hex << info.vendorID << std::dec << '\n';
    std::cout << "DeviceID:    0x" << std::hex << info.deviceID << std::dec << '\n';
    std::cout << "BackendType: " << backend_type_to_string(info.backendType) << '\n';
    std::cout << "AdapterType: " << adapter_type_to_string(info.adapterType) << '\n';
    return EXIT_SUCCESS;
}
