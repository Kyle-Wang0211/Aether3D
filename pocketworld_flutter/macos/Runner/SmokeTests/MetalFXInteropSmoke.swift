// Phase 6.4d.2 smoke: prove Metal + MetalFX + IOSurface interop before
// wiring MetalFX into the Flutter/Dawn render path.

import CoreVideo
import Foundation
import IOSurface
import Metal
import MetalFX

private struct Half4 {
    let r: Float
    let g: Float
    let b: Float
    let a: Float
}

private enum SmokeError: Error, CustomStringConvertible {
    case unsupportedOS
    case noMetalDevice
    case commandQueue
    case iosurfaceCreate(String)
    case textureCreate(String)
    case commandBuffer
    case renderEncoder
    case spatialScaler
    case commandFailed(String)
    case invalidPixel(Half4)

    var description: String {
        switch self {
        case .unsupportedOS:
            return "MetalFX spatial scaler requires macOS 13.0+"
        case .noMetalDevice:
            return "MTLCreateSystemDefaultDevice returned nil"
        case .commandQueue:
            return "makeCommandQueue returned nil"
        case .iosurfaceCreate(let label):
            return "IOSurfaceCreate failed for \(label)"
        case .textureCreate(let label):
            return "makeTexture(iosurface:) failed for \(label)"
        case .commandBuffer:
            return "makeCommandBuffer returned nil"
        case .renderEncoder:
            return "makeRenderCommandEncoder returned nil"
        case .spatialScaler:
            return "MTLFXSpatialScalerDescriptor.makeSpatialScaler returned nil"
        case .commandFailed(let status):
            return "Metal command buffer completed with \(status)"
        case .invalidPixel(let px):
            return String(format: "unexpected output pixel rgba=(%.3f, %.3f, %.3f, %.3f)",
                          px.r, px.g, px.b, px.a)
        }
    }
}

private func makeRGBA16FIOSurface(width: Int, height: Int, label: String) throws -> IOSurface {
    let props: [IOSurfacePropertyKey: Any] = [
        .width: width,
        .height: height,
        .pixelFormat: Int(kCVPixelFormatType_64RGBAHalf),
        .bytesPerElement: 8,
        .bytesPerRow: width * 8,
    ]
    guard let surface = IOSurface(properties: props) else {
        throw SmokeError.iosurfaceCreate(label)
    }
    return surface
}

private func makeTexture(
    device: MTLDevice,
    surface: IOSurface,
    width: Int,
    height: Int,
    usage: MTLTextureUsage,
    label: String
) throws -> MTLTexture {
    let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float,
        width: width,
        height: height,
        mipmapped: false
    )
    desc.usage = usage
    desc.storageMode = .shared
    guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else {
        throw SmokeError.textureCreate(label)
    }
    texture.label = label
    return texture
}

private func halfToFloat(_ bits: UInt16) -> Float {
    let sign = UInt32(bits & 0x8000) << 16
    let exp = UInt32((bits >> 10) & 0x1f)
    let mantissa = UInt32(bits & 0x03ff)

    let out: UInt32
    if exp == 0 {
        if mantissa == 0 {
            out = sign
        } else {
            var mant = mantissa
            var shiftedExp: UInt32 = 113
            while (mant & 0x0400) == 0 {
                mant <<= 1
                shiftedExp -= 1
            }
            mant &= 0x03ff
            out = sign | (shiftedExp << 23) | (mant << 13)
        }
    } else if exp == 0x1f {
        out = sign | 0x7f800000 | (mantissa << 13)
    } else {
        out = sign | ((exp + 112) << 23) | (mantissa << 13)
    }
    return Float(bitPattern: out)
}

private func readPixel(surface: IOSurface, x: Int, y: Int) -> Half4 {
    IOSurfaceLock(surface, [], nil)
    defer { IOSurfaceUnlock(surface, [], nil) }

    let base = IOSurfaceGetBaseAddress(surface)
    let bytesPerRow = IOSurfaceGetBytesPerRow(surface)
    let offset = y * bytesPerRow + x * 8
    let px = base.advanced(by: offset).assumingMemoryBound(to: UInt16.self)
    return Half4(
        r: halfToFloat(px[0]),
        g: halfToFloat(px[1]),
        b: halfToFloat(px[2]),
        a: halfToFloat(px[3])
    )
}

@available(macOS 13.0, *)
private func runSmoke() throws {
    let inputWidth = 640
    let inputHeight = 360
    let outputWidth = 1280
    let outputHeight = 720

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw SmokeError.noMetalDevice
    }
    guard let queue = device.makeCommandQueue() else {
        throw SmokeError.commandQueue
    }

    let inputSurface = try makeRGBA16FIOSurface(
        width: inputWidth,
        height: inputHeight,
        label: "input"
    )
    let outputSurface = try makeRGBA16FIOSurface(
        width: outputWidth,
        height: outputHeight,
        label: "output"
    )
    let input = try makeTexture(
        device: device,
        surface: inputSurface,
        width: inputWidth,
        height: inputHeight,
        usage: [.renderTarget, .shaderRead],
        label: "MetalFX smoke input"
    )
    let output = try makeTexture(
        device: device,
        surface: outputSurface,
        width: outputWidth,
        height: outputHeight,
        usage: [.shaderRead, .shaderWrite, .renderTarget],
        label: "MetalFX smoke output"
    )

    guard let commandBuffer = queue.makeCommandBuffer() else {
        throw SmokeError.commandBuffer
    }
    commandBuffer.label = "MetalFX interop smoke"

    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = input
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
        throw SmokeError.renderEncoder
    }
    encoder.label = "clear input red"
    encoder.endEncoding()

    let desc = MTLFXSpatialScalerDescriptor()
    desc.inputWidth = inputWidth
    desc.inputHeight = inputHeight
    desc.outputWidth = outputWidth
    desc.outputHeight = outputHeight
    desc.colorTextureFormat = .rgba16Float
    desc.outputTextureFormat = .rgba16Float
    desc.colorProcessingMode = .perceptual
    guard let scaler = desc.makeSpatialScaler(device: device) else {
        throw SmokeError.spatialScaler
    }
    scaler.colorTexture = input
    scaler.outputTexture = output
    scaler.encode(commandBuffer: commandBuffer)

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    if commandBuffer.status != .completed {
        throw SmokeError.commandFailed(String(describing: commandBuffer.status))
    }

    let center = readPixel(surface: outputSurface, x: outputWidth / 2, y: outputHeight / 2)
    print(String(format: "output center rgba=(%.4f, %.4f, %.4f, %.4f)",
                 center.r, center.g, center.b, center.a))
    guard center.r > 0.80, center.g < 0.10, center.b < 0.10, center.a > 0.80 else {
        throw SmokeError.invalidPixel(center)
    }
}

do {
    if #available(macOS 13.0, *) {
        try runSmoke()
        print("PASS MetalFXInteropSmoke")
    } else {
        throw SmokeError.unsupportedOS
    }
} catch {
    fputs("FAIL MetalFXInteropSmoke: \(error)\n", stderr)
    exit(1)
}
