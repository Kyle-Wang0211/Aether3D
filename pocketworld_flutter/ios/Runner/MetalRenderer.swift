import Flutter
import IOSurface
import Metal
import QuartzCore

// ─── Phase 5.3 architectural prep — Metal renderer extracted from plugin ─
//
// Locked decision G in PHASE5_PLAN.md said: "Dawn iOS deferred; 5.3 do
// architectural prep (MetalRenderer.swift centralized)". This file is
// that prep — all Metal-specific code (shader source + texture creation
// + per-frame render command building) was moved out of
// AetherTexturePlugin.swift so the plugin's iOS-API surface
// (FlutterPlugin / FlutterMethodChannel / NotificationCenter wiring)
// stays orthogonal to the GPU backend.
//
// Future Dawn-iOS swap = replace this file's `SharedNativeTexture`
// implementation with a Dawn/WebGPU equivalent. The plugin code in
// AetherTexturePlugin.swift doesn't need to change — it sees the
// same `init(device:width:height:)` + `render(commandQueue:angle:)`
// signatures. The Metal-specific types (MTLDevice, MTLCommandQueue)
// will need to be replaced with Dawn equivalents at the plugin's
// command-queue creation site too — but the rest of the plugin is
// renderer-agnostic.
//
// Why not introduce a `protocol NativeRenderer` now? Because we only
// have one impl. YAGNI says: ship the file split; introduce the
// protocol when the second impl actually shows up.

private let kTriangleShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float3 color;
};

vertex VertexOut vs_main(uint vid [[vertex_id]],
                          constant float& angle [[buffer(0)]]) {
    float2 positions[3] = {
        float2( 0.0,  0.7),
        float2(-0.7, -0.7),
        float2( 0.7, -0.7),
    };
    float3 colors[3] = {
        float3(1.0, 0.0, 0.0),
        float3(0.0, 1.0, 0.0),
        float3(0.0, 0.0, 1.0),
    };
    float c = cos(angle);
    float s = sin(angle);
    float2 p = positions[vid];
    p = float2(c * p.x - s * p.y, s * p.x + c * p.y);

    VertexOut out;
    out.position = float4(p, 0.0, 1.0);
    out.color    = colors[vid];
    return out;
}

fragment float4 fs_main(VertexOut in [[stage_in]]) {
    return float4(in.color, 1.0);
}
"""

/// Specific failure points during SharedNativeTexture allocation. Each one
/// maps to a distinct FlutterError code so a Dart-side log identifies
/// the exact failure without binary-search bisection through the init.
enum TextureCreateError: Error {
    case iosurfaceCreate
    case cvpixelbufferCreate(CVReturn)
    case mtlTextureCreate
    case shaderCompile(Error)
    case shaderFunctionMissing(String)
    case renderPipelineCreate(Error)
}

/// Native-GPU-written texture, exposed to Flutter through FlutterTexture
/// protocol via a shared IOSurface. Renders a colored triangle (R/G/B at
/// the three vertices, barycentric blend). Default 256×256 BGRA8 with
/// per-instance overrides.
class SharedNativeTexture: NSObject, FlutterTexture {
    private let pixelBuffer: CVPixelBuffer
    private let mtlTexture: MTLTexture
    private let renderPipeline: MTLRenderPipelineState
    private var hasRenderedOnce = false

    // Phase 4 polish #3: passRetained contract assertion.
    //
    // copyPixelBuffer() returns Unmanaged.passRetained(pixelBuffer) — a +1
    // refcount handed to Flutter. The contract (Flutter 3.41.7) is the
    // compositor releases it after the frame composes. Steady-state
    // retain count = 1 (our private let) + a few transient refs from
    // in-flight composition. If Flutter regresses to NOT release, the
    // refcount grows ~60/sec at 60fps — silent CVPixelBuffer leak that
    // shows up as Activity Monitor RAM creep with no exception, no log.
    //
    // This assertion samples CFGetRetainCount once per second (every
    // 60th call at steady-state 60fps) and warns if it exceeds the
    // threshold. Cost per non-sampled call: a single u64 increment +
    // modulo (sub-nanosecond). Cost on sampled call: one CF refcount
    // load + compare + (rare) NSLog. Total per-frame budget impact
    // << 0.01 ms (well under the 16.67 ms frame budget).
    //
    // The threshold (5) covers normal pipelining slack: our ref +
    // current passRetained + 2-3 in-flight composition stages. A real
    // leak would push this past 5 within 1 second of 60fps callbacks,
    // and keep climbing.
    private var copyCount: UInt64 = 0
    private let leakCheckIntervalCalls: UInt64 = 60
    private let leakCheckThresholdRefs: CFIndex = 5

    init(device: MTLDevice, width: Int = 256, height: Int = 256) throws {
        // 1. IOSurface
        let ioProps: [IOSurfacePropertyKey: Any] = [
            .width:           width,
            .height:          height,
            .pixelFormat:     Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement: 4,
            .bytesPerRow:     width * 4,
        ]
        guard let ioSurface = IOSurface(properties: ioProps) else {
            throw TextureCreateError.iosurfaceCreate
        }

        // 2. CVPixelBuffer wrapping the IOSurface (Flutter reads).
        // CVPixelBufferCreateWithIOSurface returns via Unmanaged
        // (unlike the plain-Optional CVPixelBufferCreate); takeRetainedValue
        // balances the +1 refcount the API hands us.
        var pbUnmanaged: Unmanaged<CVPixelBuffer>?
        let cvStatus = CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault, ioSurface, nil, &pbUnmanaged
        )
        guard cvStatus == kCVReturnSuccess,
              let buffer = pbUnmanaged?.takeRetainedValue() else {
            throw TextureCreateError.cvpixelbufferCreate(cvStatus)
        }

        // 3. MTLTexture wrapping the SAME IOSurface (Metal writes).
        let texDesc = MTLTextureDescriptor()
        texDesc.pixelFormat = .bgra8Unorm
        texDesc.width  = width
        texDesc.height = height
        texDesc.usage  = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(
            descriptor: texDesc, iosurface: ioSurface, plane: 0
        ) else {
            throw TextureCreateError.mtlTextureCreate
        }

        // 4. Compile shaders.
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: kTriangleShaderSource, options: nil)
        } catch {
            throw TextureCreateError.shaderCompile(error)
        }
        guard let vertexFn = library.makeFunction(name: "vs_main") else {
            throw TextureCreateError.shaderFunctionMissing("vs_main")
        }
        guard let fragmentFn = library.makeFunction(name: "fs_main") else {
            throw TextureCreateError.shaderFunctionMissing("fs_main")
        }

        // 5. Render pipeline state.
        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertexFn
        pipelineDesc.fragmentFunction = fragmentFn
        pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline: MTLRenderPipelineState
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: pipelineDesc)
        } catch {
            throw TextureCreateError.renderPipelineCreate(error)
        }

        self.pixelBuffer    = buffer
        self.mtlTexture     = texture
        self.renderPipeline = pipeline
        super.init()
    }

    /// Draw a triangle into the shared texture. `angle` rotates vertex
    /// positions in-shader (radians). Synchronous on the FIRST frame so
    /// the widget mounts on populated content; async thereafter so the
    /// 60 Hz display-link tick doesn't block on GPU completion.
    func render(commandQueue: MTLCommandQueue, angle: Float) {
        guard let cb = commandQueue.makeCommandBuffer() else { return }
        cb.label = "SharedNativeTexture.render"

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture     = mtlTexture
        pass.colorAttachments[0].loadAction  = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: 0.05, green: 0.05, blue: 0.08, alpha: 1.0
        )

        guard let encoder = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "triangle pass"
        encoder.setRenderPipelineState(renderPipeline)
        var a = angle
        encoder.setVertexBytes(&a, length: MemoryLayout<Float>.size, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // GPU command-buffer completion handler. Catches device loss /
        // out-of-memory / shader runtime errors that would otherwise be
        // silent (the widget would just freeze on the last good frame).
        // For Phase 5.3 / production this should escalate back to Dart
        // via an event channel; for now logging is enough because this
        // surface is dev-only and a sustained 60 fps confirms no errors
        // are firing in the steady state.
        cb.addCompletedHandler { cmdBuf in
            if let error = cmdBuf.error {
                NSLog("[SharedNativeTexture] GPU error: status=%d error=%@",
                      cmdBuf.status.rawValue, "\(error)")
            }
        }

        cb.commit()
        // Only wait on the first frame (so widget mounts on a populated
        // buffer). Steady state lets Metal pipeline overlap with the
        // next display-link tick — required to keep 60 fps once GPU work
        // grows past trivial.
        if !hasRenderedOnce {
            cb.waitUntilCompleted()
            hasRenderedOnce = true
        }
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        // CONTRACT: Flutter docs (Flutter 3.41.7) require passRetained;
        // Flutter's texture compositor releases the CVPixelBuffer after
        // the frame composes. The polish #3 assertion above watches
        // refcount drift; if it climbs past leakCheckThresholdRefs over
        // many frames, Flutter has stopped releasing.
        copyCount &+= 1
        if copyCount % leakCheckIntervalCalls == 0 {
            // CFGetRetainCount is documented as "for debugging only" —
            // value can be momentarily inaccurate under multithreaded
            // CF traffic. A periodic warning under steady drift remains
            // a strong leak signal even allowing for noise.
            let rc = CFGetRetainCount(pixelBuffer)
            if rc > leakCheckThresholdRefs {
                NSLog("[SharedNativeTexture] passRetained contract WARNING: pixelBuffer retainCount=%ld after %llu copyPixelBuffer calls. Flutter compositor may not be releasing. (Phase 4 polish #3 assertion)",
                      rc, copyCount)
            }
        }
        return Unmanaged.passRetained(pixelBuffer)
    }
}
