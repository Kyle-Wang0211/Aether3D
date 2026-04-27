import Metal
import MetalFX

final class MetalFXUpsampler {
    enum Method: String {
        case metalFX = "MetalFX"
        case bilinear = "bilinear"
    }

    private let device: MTLDevice
    private let sampler: MTLSamplerState
    private var fallbackPipelineByFormat: [UInt: MTLRenderPipelineState] = [:]
    private var cachedScaler: AnyObject?
    private var cachedInputSize: (Int, Int) = (0, 0)
    private var cachedOutputSize: (Int, Int) = (0, 0)
    private var cachedInputFormat: MTLPixelFormat = .invalid
    private var cachedOutputFormat: MTLPixelFormat = .invalid

    init(device: MTLDevice) throws {
        self.device = device

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.mipFilter = .notMipmapped
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDesc) else {
            throw NSError(domain: "MetalFXUpsampler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "makeSamplerState returned nil"
            ])
        }
        self.sampler = sampler
    }

    func encode(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture,
        preferMetalFX: Bool
    ) -> Method {
        if preferMetalFX,
           input.width != output.width || input.height != output.height,
           encodeMetalFX(commandBuffer: commandBuffer, input: input, output: output) {
            return .metalFX
        }

        encodeBilinear(commandBuffer: commandBuffer, input: input, output: output)
        return .bilinear
    }

    private func encodeMetalFX(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture
    ) -> Bool {
        guard #available(macOS 13.0, *) else { return false }

        let inputSize = (input.width, input.height)
        let outputSize = (output.width, output.height)
        let needsNewScaler =
            cachedScaler == nil ||
            cachedInputSize != inputSize ||
            cachedOutputSize != outputSize ||
            cachedInputFormat != input.pixelFormat ||
            cachedOutputFormat != output.pixelFormat

        if needsNewScaler {
            let desc = MTLFXSpatialScalerDescriptor()
            desc.inputWidth = input.width
            desc.inputHeight = input.height
            desc.outputWidth = output.width
            desc.outputHeight = output.height
            desc.colorTextureFormat = input.pixelFormat
            desc.outputTextureFormat = output.pixelFormat
            desc.colorProcessingMode = .perceptual
            guard let scaler = desc.makeSpatialScaler(device: device) else {
                cachedScaler = nil
                return false
            }
            cachedScaler = scaler
            cachedInputSize = inputSize
            cachedOutputSize = outputSize
            cachedInputFormat = input.pixelFormat
            cachedOutputFormat = output.pixelFormat
        }

        guard let scaler = cachedScaler as? MTLFXSpatialScaler else { return false }
        scaler.colorTexture = input
        scaler.outputTexture = output
        scaler.encode(commandBuffer: commandBuffer)
        return true
    }

    private func encodeBilinear(
        commandBuffer: MTLCommandBuffer,
        input: MTLTexture,
        output: MTLTexture
    ) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encoder.label = "Aether bilinear upsample"
        do {
            encoder.setRenderPipelineState(try fallbackPipeline(outputFormat: output.pixelFormat))
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } catch {
            NSLog("[MetalFXUpsampler] bilinear fallback pipeline failed: %@", "\(error)")
        }
        encoder.endEncoding()
    }

    private func fallbackPipeline(outputFormat: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = UInt(outputFormat.rawValue)
        if let pipeline = fallbackPipelineByFormat[key] {
            return pipeline
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut aether_upsample_vertex(uint vid [[vertex_id]]) {
            const float2 positions[6] = {
                float2(-1.0, -1.0), float2( 1.0, -1.0), float2(-1.0,  1.0),
                float2( 1.0, -1.0), float2( 1.0,  1.0), float2(-1.0,  1.0),
            };
            VertexOut out;
            float2 p = positions[vid];
            out.position = float4(p, 0.0, 1.0);
            out.uv = float2(p.x * 0.5 + 0.5, p.y * 0.5 + 0.5);
            return out;
        }

        fragment float4 aether_upsample_fragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::sample> colorTex [[texture(0)]],
            sampler linearSampler [[sampler(0)]]
        ) {
            return colorTex.sample(linearSampler, in.uv);
        }
        """

        let library = try device.makeLibrary(source: source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "Aether bilinear upsample"
        desc.vertexFunction = library.makeFunction(name: "aether_upsample_vertex")
        desc.fragmentFunction = library.makeFunction(name: "aether_upsample_fragment")
        desc.colorAttachments[0].pixelFormat = outputFormat
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)
        fallbackPipelineByFormat[key] = pipeline
        return pipeline
    }
}
