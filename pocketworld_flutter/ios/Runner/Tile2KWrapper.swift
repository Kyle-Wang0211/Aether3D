// Tile2KWrapper.swift
//
// Splits a 2K image into 518×518 tiles for DA3-LARGE-1.1 CoreML inference,
// then blends the per-tile depth outputs back into a full 2K depth map.
//
// Why this exists
// ----------------
// DA3-LARGE-1.1 (DinoV2-Large backbone) has a hard input constraint:
// 14-pixel patch size → input dim must be multiple of 14. ByteDance trained
// at 518 (= 14 × 37 patches). Cannot infer at full 2K (1920×1080) directly:
//   - Attention complexity O(N²) where N = #patches → ~44k patches @ 4K is
//     ~7.5 GB just for attention matrix in fp16. A100 GPU 80GB hits it; any
//     iPhone OOMs immediately.
//   - DinoV2 also has positional embedding interpolation limits.
//
// Solution: tile-based inference.
//   - Split 2K frame into N tiles of 518×518 with overlap
//   - Run DA3-LARGE-1.1 on each tile (W1 D2 measured 759 ± 17 ms / tile on
//     iPhone 14 Pro CPU)
//   - Blend tile depth outputs back to full 2K resolution, using sky head
//     output as inverse confidence in overlap regions
//
// Plan G memory budget
// --------------------
// Per-tile peak: ~1.0 GB during inference (model 902 MB + activations 80 MB,
// measured W1 D2). Sequential tile execution keeps peak constant — only one
// MLPrediction active at a time.
//
// Tile layout math
// ----------------
// For 1920×1080 input + 518 tile + 32 px overlap:
//   stride = 518 - 32 = 486
//   nx = ceil((1920 - 518) / 486) + 1 = ceil(1402/486) + 1 = 4
//   ny = ceil((1080 - 518) / 486) + 1 = ceil(562/486) + 1 = 3
//   Total: 4 × 3 = 12 tiles per frame
//
// (Earlier docs estimated "8 tiles" — that was off; actual is 12 with
// healthy 32-px overlap. Updated W1 timing: 60 × 12 × 759ms ≈ 9 min depth
// stage, not 6 min. Still within Plan G envelope.)
//
// W1 D3 D1 (this file): tile layout computation + image splitting only.
// W1 D3 D2: CoreML per-tile inference integration.
// W1 D3 D3: depth blending with sky-weighted overlap.

import Accelerate
import CoreML
import CoreImage
import Foundation
import UIKit
import VideoToolbox

@objc public final class Tile2KWrapper: NSObject {

    // MARK: - Tile layout types

    /// A single tile's position + dimensions in the source image's coordinates.
    public struct TileRect: Equatable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        public let row: Int
        public let col: Int

        public init(x: Int, y: Int, width: Int, height: Int, row: Int, col: Int) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.row = row
            self.col = col
        }
    }

    /// Full layout description for splitting + later blending.
    public struct TileLayout {
        public let tileSize: Int
        public let overlap: Int
        public let stride: Int
        public let tiles: [TileRect]
        public let imageWidth: Int
        public let imageHeight: Int
        public let nx: Int  // tiles per row
        public let ny: Int  // rows
    }

    // MARK: - Layout computation

    /// Compute tile placement for an image of `imageWidth × imageHeight`,
    /// using `tileSize × tileSize` tiles with at least `overlap` pixels between
    /// adjacent tiles. The last tile in each row/column is pinned to the
    /// image edge (no underhang), which may give it slightly more overlap
    /// with its neighbor — preferred over leaving an uncovered strip.
    ///
    /// Layout is row-major: tile index = row * nx + col.
    @objc public static func computeLayout(
        imageWidth: Int,
        imageHeight: Int,
        tileSize: Int = 518,
        overlap: Int = 32
    ) -> [String: Any] {
        // Returned as dictionary for Obj-C bridging (Swift struct version below).
        let layout = makeLayout(
            imageWidth: imageWidth,
            imageHeight: imageHeight,
            tileSize: tileSize,
            overlap: overlap
        )
        var tilesDict: [[String: Int]] = []
        for tile in layout.tiles {
            tilesDict.append([
                "x": tile.x,
                "y": tile.y,
                "width": tile.width,
                "height": tile.height,
                "row": tile.row,
                "col": tile.col,
            ])
        }
        return [
            "tileSize": layout.tileSize,
            "overlap": layout.overlap,
            "stride": layout.stride,
            "imageWidth": layout.imageWidth,
            "imageHeight": layout.imageHeight,
            "nx": layout.nx,
            "ny": layout.ny,
            "tiles": tilesDict,
            "totalTiles": layout.tiles.count,
        ]
    }

    /// Tile layout for an image of `imageWidth × imageHeight`.
    ///
    /// Delegates to C++ `aether_compute_tile_layout` (aether_cpp/src/pipeline/
    /// tile_layout.cpp) — the deterministic tile-placement math is shared
    /// cross-platform (iOS / Android / 鸿蒙 / Web) and bit-equal verified vs the
    /// prior Swift implementation in W1 + W2 D1 parity bench (max |Δ|=0).
    ///
    /// 1D index of (row, col) in `tiles` is `row * nx + col`.
    public static func makeLayout(
        imageWidth: Int,
        imageHeight: Int,
        tileSize: Int = 518,
        overlap: Int = 32
    ) -> TileLayout {
        precondition(tileSize > overlap, "tileSize \(tileSize) must exceed overlap \(overlap)")
        precondition(imageWidth >= tileSize, "imageWidth \(imageWidth) must be >= tileSize \(tileSize)")
        precondition(imageHeight >= tileSize, "imageHeight \(imageHeight) must be >= tileSize \(tileSize)")

        // First call (capacity=0) just to query nx, ny, tile_count.
        var info = aether_tile_layout_info_t()
        _ = aether_compute_tile_layout(
            Int32(imageWidth), Int32(imageHeight),
            Int32(tileSize), Int32(overlap),
            &info, nil, 0
        )

        // Second call fills tile rects into pre-allocated buffer.
        var cTiles = [aether_tile_rect_t](
            repeating: aether_tile_rect_t(x: 0, y: 0, width: 0, height: 0, row: 0, col: 0),
            count: Int(info.tile_count)
        )
        _ = cTiles.withUnsafeMutableBufferPointer { bp in
            aether_compute_tile_layout(
                Int32(imageWidth), Int32(imageHeight),
                Int32(tileSize), Int32(overlap),
                &info, bp.baseAddress, info.tile_count
            )
        }

        let swiftTiles: [TileRect] = cTiles.map { ct in
            TileRect(
                x: Int(ct.x), y: Int(ct.y),
                width: Int(ct.width), height: Int(ct.height),
                row: Int(ct.row), col: Int(ct.col)
            )
        }

        return TileLayout(
            tileSize: Int(info.tile_size),
            overlap: Int(info.overlap),
            stride: Int(info.stride),
            tiles: swiftTiles,
            imageWidth: Int(info.image_width),
            imageHeight: Int(info.image_height),
            nx: Int(info.nx),
            ny: Int(info.ny)
        )
    }

    // MARK: - Image splitting

    /// Split a CGImage into N CGImage tiles per the given layout.
    /// Each returned tile is a `tileSize × tileSize` crop of the source.
    public static func splitImage(_ image: CGImage, layout: TileLayout) -> [CGImage] {
        var result: [CGImage] = []
        result.reserveCapacity(layout.tiles.count)
        for tile in layout.tiles {
            let rect = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
            if let cropped = image.cropping(to: rect) {
                result.append(cropped)
            } else {
                NSLog("[Tile2K] WARN: cropping failed at tile r=\(tile.row) c=\(tile.col) rect=\(rect)")
            }
        }
        return result
    }

    /// Convenience: split a CVPixelBuffer into tile CGImages.
    /// Used by the capture-side path where ARKit / camera frame comes through
    /// as `ARFrame.capturedImage` (CVPixelBuffer YUV).
    public static func splitPixelBuffer(_ buffer: CVPixelBuffer, layout: TileLayout) -> [CGImage] {
        guard let cgImage = cgImageFromPixelBuffer(buffer) else {
            NSLog("[Tile2K] ERROR: CVPixelBuffer → CGImage conversion failed")
            return []
        }
        return splitImage(cgImage, layout: layout)
    }

    private static func cgImageFromPixelBuffer(_ buffer: CVPixelBuffer) -> CGImage? {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &cgImage)
        return cgImage
    }

    // MARK: - CoreML per-tile inference (W1 D3 D2)

    /// Per-tile inference output.
    /// `depth`: Float buffer of `tileSize × tileSize` (raw relative depth from DA3 model)
    /// `conf`: Float buffer same size (DA3-LARGE-1.1 confidence head; higher = more
    ///         reliable. W1 D1 dummy-seed test observed range ~[1.0, 1.48].
    ///         Blender uses this as overlap weight: weight[i] = conf[i] - 1.0
    ///         clamped to [0.01, 1.0] so even low-conf tiles contribute non-zero.)
    public struct TileInference {
        public let tile: TileRect
        public let depth: [Float]
        public let conf: [Float]
        public let inferenceTimeMs: Double
    }

    /// Loaded CoreML model holder. Created once, reused for all tiles in a session.
    /// W1 D2 decision: `MLComputeUnits.cpuOnly` (759±17 ms/tile vs GPU 1086ms vs ANE crash).
    public final class Session {
        public let model: MLModel
        public let inputImageName: String   // "image"
        public let outputDepthName: String  // "depth"
        public let outputConfName: String   // "depth_conf"
        public let tileSize: Int

        /// Build a session from a bundled .mlmodelc URL (Xcode-compiled .mlpackage).
        public init(modelURL: URL, tileSize: Int = 518) throws {
            let config = MLModelConfiguration()
            config.computeUnits = .cpuOnly  // W1 D2 lock; do NOT change without bench
            self.model = try MLModel(contentsOf: modelURL, configuration: config)
            self.inputImageName = "image"
            // DA3-LARGE-1.1 (ONNX-path conversion) output names — set by
            // scripts/da3_export/da3_large_to_coreml_via_onnx.py:
            //   outputs=[ct.TensorType(name="depth"), ct.TensorType(name="depth_conf")]
            self.outputDepthName = "depth"
            self.outputConfName = "depth_conf"
            self.tileSize = tileSize
        }

        /// Run inference on a single tile. CGImage must be `tileSize × tileSize`.
        /// Returns raw float buffers + timing. Caller owns blending.
        public func inferTile(_ tileImage: CGImage, tile: TileRect) throws -> TileInference {
            precondition(
                tileImage.width == tileSize && tileImage.height == tileSize,
                "Tile must be \(tileSize)×\(tileSize), got \(tileImage.width)×\(tileImage.height)"
            )
            let inputArray = try cgImageToMLMultiArray(tileImage, tileSize: tileSize)
            let inputProvider = try MLDictionaryFeatureProvider(
                dictionary: [inputImageName: inputArray]
            )
            let start = CFAbsoluteTimeGetCurrent()
            let output = try model.prediction(from: inputProvider)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

            guard let depthArr = output.featureValue(for: outputDepthName)?.multiArrayValue,
                  let confArr = output.featureValue(for: outputConfName)?.multiArrayValue else {
                throw NSError(
                    domain: "Tile2K",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Model output missing depth/depth_conf"]
                )
            }
            let depth = mlMultiArrayToFloatBuffer(depthArr)
            let conf = mlMultiArrayToFloatBuffer(confArr)
            return TileInference(tile: tile, depth: depth, conf: conf, inferenceTimeMs: elapsed)
        }
    }

    /// Convert CGImage to MLMultiArray of shape (1, 3, tileSize, tileSize), float32, NCHW.
    /// Pixel values normalized to [0, 1] then ImageNet-mean-subtracted to match DA3 training:
    ///   mean = [0.485, 0.456, 0.406], std = [0.229, 0.224, 0.225]
    /// (Same as Depth-Anything 3 official preprocessing in src/depth_anything_3/api.py)
    private static func cgImageToMLMultiArray(_ image: CGImage, tileSize: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: tileSize), NSNumber(value: tileSize)],
            dataType: .float32
        )
        // Draw CGImage into a fresh RGBA buffer (ARGB on iOS, big-endian native).
        let bytesPerPixel = 4
        let bytesPerRow = tileSize * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * tileSize)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw NSError(domain: "Tile2K", code: 2, userInfo: [NSLocalizedDescriptionKey: "no sRGB"])
        }
        let bitmapInfo: UInt32 =
            CGImageAlphaInfo.premultipliedLast.rawValue |
            CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(
            data: &bytes,
            width: tileSize,
            height: tileSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw NSError(domain: "Tile2K", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGContext fail"])
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: tileSize, height: tileSize))

        // Convert RGBA → CHW float32 + ImageNet normalize.
        // DA3 expects values like (rgb/255 - mean) / std.
        let meanR: Float = 0.485
        let meanG: Float = 0.456
        let meanB: Float = 0.406
        let stdR: Float = 0.229
        let stdG: Float = 0.224
        let stdB: Float = 0.225

        // MLMultiArray dataPointer is contiguous Float32, layout (1, 3, H, W).
        let dataPtr = array.dataPointer.bindMemory(to: Float32.self, capacity: 3 * tileSize * tileSize)
        let planeSize = tileSize * tileSize

        for y in 0..<tileSize {
            for x in 0..<tileSize {
                let srcOffset = y * bytesPerRow + x * bytesPerPixel
                let r = Float(bytes[srcOffset + 0]) / 255.0
                let g = Float(bytes[srcOffset + 1]) / 255.0
                let b = Float(bytes[srcOffset + 2]) / 255.0
                let dstOffset = y * tileSize + x
                dataPtr[0 * planeSize + dstOffset] = (r - meanR) / stdR
                dataPtr[1 * planeSize + dstOffset] = (g - meanG) / stdG
                dataPtr[2 * planeSize + dstOffset] = (b - meanB) / stdB
            }
        }
        return array
    }

    /// Convert MLMultiArray to flat Float buffer.
    /// W1 D3 D4 (2026-05-15) discovery: DA3-LARGE-1.1 .mlmodelc actually returns
    /// Float16 outputs (raw=0x10010), not Float32 as I assumed from the ONNX
    /// conversion script. fp16 conversion needed.
    private static func mlMultiArrayToFloatBuffer(_ arr: MLMultiArray) -> [Float] {
        let count = arr.count
        var buffer = [Float](repeating: 0, count: count)
        // Use rawValue compare instead of `.float32 / .float16` so we don't
        // need iOS 16+ enum case availability (deployment target 13.0).
        let raw = arr.dataType.rawValue
        if raw == 0x10020 {  // MLMultiArrayDataType.float32
            let ptr = arr.dataPointer.bindMemory(to: Float32.self, capacity: count)
            for i in 0..<count {
                buffer[i] = ptr[i]
            }
        } else if raw == 0x10010 {  // MLMultiArrayDataType.float16 (iOS 16+ enum case)
            // Use Apple's vDSP fp16→fp32 conversion (Accelerate framework,
            // iOS 14+). Way faster than per-element bit unpacking.
            let src = arr.dataPointer
            if #available(iOS 14, *) {
                var srcDesc = vImage_Buffer(data: src, height: 1, width: UInt(count), rowBytes: count * 2)
                buffer.withUnsafeMutableBufferPointer { dst in
                    var dstDesc = vImage_Buffer(
                        data: UnsafeMutableRawPointer(dst.baseAddress!),
                        height: 1, width: UInt(count), rowBytes: count * 4
                    )
                    _ = vImageConvert_Planar16FtoPlanarF(&srcDesc, &dstDesc, 0)
                }
            } else {
                NSLog("[Tile2K] fp16 conversion needs iOS 14+, depth buffer will be 0")
            }
        } else if raw == 0x10040 {  // .double
            let ptr = arr.dataPointer.bindMemory(to: Double.self, capacity: count)
            for i in 0..<count {
                buffer[i] = Float(ptr[i])
            }
        } else {
            NSLog("[Tile2K] WARN: unhandled MLMultiArray dataType raw=0x%x (%d)",
                  raw, raw)
        }
        return buffer
    }

    // MARK: - Depth blending (W1 D3 D3)

    /// Output of a multi-tile blend.
    public struct BlendResult {
        /// Full-size depth map, row-major, `width × height` floats. Pixel (x, y)
        /// is at `depth[y * width + x]`. Values are DA3-LARGE-1.1 scale-invariant
        /// relative depth (typical range ~[0.5, 1.1] for the dummy seed input;
        /// real-image range varies). Convert to metric in scale-align stage.
        public let depth: [Float]
        /// Per-pixel accumulated weight before normalization. Useful for
        /// diagnosing uncovered pixels (weight == 0) or low-coverage regions.
        public let weight: [Float]
        public let width: Int
        public let height: Int
        /// Fraction of pixels with non-zero weight. Should be 1.0 for a
        /// properly-tiled image. Anything < 1.0 means a tile layout gap.
        public let coverage: Float
        public let blendTimeMs: Double
        public let minDepth: Float
        public let maxDepth: Float
        public let meanDepth: Float
    }

    /// Blend `tiles` (per-tile inference outputs from `Session.inferTile`) into a
    /// single full-size depth map using confidence + trapezoid edge fade weighting.
    ///
    /// Delegates to C++ `aether_blend_tiles` (aether_cpp/src/pipeline/tile_blend.cpp).
    /// The conf-weighted blend with Method A 0.05 floor + Method B sin² trapezoid
    /// is cross-platform shared math, bit-equal verified vs the prior Swift impl
    /// in W1 parity bench (max |Δdepth|=1.19e-7 fp32 noise, weight=3.58e-7).
    ///
    /// Plan G W1 D3 locked weight formula:
    ///   w = conf_w × edge_w
    ///   conf_w = clamp(conf - 1.0, 0.01, 1.0)
    ///   edge_w = max(0.05, sin²(π/2·tx) · sin²(π/2·ty))
    ///
    /// Non-owning view path: each tile's `depth` / `conf` Swift `[Float]` is
    /// passed to the C ABI directly via nested `withUnsafeBufferPointer`
    /// closures (recursive helper). No packing copy on the Swift side; no
    /// std::vector<TileInference> copy in the C ABI either. Earlier path
    /// memcpy'd ~25 MB per blend call (12 tiles × 2 × 268k floats), inflating
    /// blendTimeMs from 18 ms (Swift inline) to 193 ms (C++ via FFI).
    public static func blendTiles(
        _ tiles: [TileInference],
        layout: TileLayout
    ) -> BlendResult {
        let W = layout.imageWidth
        let H = layout.imageHeight
        let tileSize = layout.tileSize
        let n = tiles.count

        var outDepth = [Float](repeating: 0, count: W * H)
        var outWeight = [Float](repeating: 0, count: W * H)
        var stats = aether_blend_stats_t()

        let start = CFAbsoluteTimeGetCurrent()

        // Recursive nested `withUnsafeBufferPointer` builds aether_tile_inference_t
        // for each tile with the tile's own [Float] base address as `depth` / `conf`.
        // All pointers stay alive at the deepest closure depth, where we call the
        // C ABI on the assembled array.
        outDepth.withUnsafeMutableBufferPointer { odBuf in
            outWeight.withUnsafeMutableBufferPointer { owBuf in
                Self.withTilePointers(tiles: tiles, index: 0, accumulator: []) { cInfs in
                    cInfs.withUnsafeBufferPointer { iBuf in
                        _ = aether_blend_tiles(
                            iBuf.baseAddress, Int32(n),
                            Int32(W), Int32(H),
                            Int32(tileSize), Int32(layout.overlap),
                            0.05, 0.01, 1.0,
                            odBuf.baseAddress, owBuf.baseAddress,
                            &stats
                        )
                    }
                }
            }
        }

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        return BlendResult(
            depth: outDepth,
            weight: outWeight,
            width: W,
            height: H,
            coverage: stats.coverage,
            blendTimeMs: elapsed,
            minDepth: stats.min_depth,
            maxDepth: stats.max_depth,
            meanDepth: stats.mean_depth
        )
    }

    /// Recursively walk `tiles[index..]`, capturing each tile's depth + conf
    /// `[Float]` baseAddress via nested `withUnsafeBufferPointer`. At the deepest
    /// recursion level (index == tiles.count), all N tiles' pointers are live;
    /// invoke `action` with the assembled `[aether_tile_inference_t]`.
    ///
    /// Recursion depth = N tiles (12 for 1920×1080 capture). Stack is fine.
    private static func withTilePointers(
        tiles: [TileInference],
        index: Int,
        accumulator: [aether_tile_inference_t],
        action: ([aether_tile_inference_t]) -> Void
    ) {
        if index >= tiles.count {
            action(accumulator)
            return
        }
        let t = tiles[index]
        t.depth.withUnsafeBufferPointer { dBuf in
            t.conf.withUnsafeBufferPointer { cBuf in
                var inf = aether_tile_inference_t()
                inf.tile = aether_tile_rect_t(
                    x: Int32(t.tile.x),
                    y: Int32(t.tile.y),
                    width: Int32(t.tile.width),
                    height: Int32(t.tile.height),
                    row: Int32(t.tile.row),
                    col: Int32(t.tile.col)
                )
                inf.depth = dBuf.baseAddress
                inf.conf = cBuf.baseAddress
                withTilePointers(
                    tiles: tiles,
                    index: index + 1,
                    accumulator: accumulator + [inf],
                    action: action
                )
            }
        }
    }

    /// Convert blended depth map to a grayscale UIImage for visual debugging.
    /// Normalizes depth to [0, 255] using the blend result's min/max range.
    /// Useful for W1 D3 D4 — eyeballing blend quality, seam visibility, coverage gaps.
    public static func blendResultToUIImage(_ result: BlendResult) -> UIImage? {
        let W = result.width
        let H = result.height
        let range = max(result.maxDepth - result.minDepth, 0.0001)
        var pixels = [UInt8](repeating: 0, count: W * H)
        for i in 0..<(W * H) {
            if result.weight[i] > 0 {
                let normalized = (result.depth[i] - result.minDepth) / range
                pixels[i] = UInt8(max(0, min(255, normalized * 255.0)))
            } else {
                pixels[i] = 0  // uncovered → black
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)
        guard let provider = provider else { return nil }
        guard let cgImage = CGImage(
            width: W,
            height: H,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: W,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    // MARK: - Diagnostics

    /// Pretty-print layout for debugging. Logged at the start of every
    /// pipeline run so we can verify tile count + coverage in console.
    public static func describe(_ layout: TileLayout) -> String {
        var lines: [String] = []
        lines.append(
            "Tile2K layout: \(layout.imageWidth)×\(layout.imageHeight) → "
            + "\(layout.nx)×\(layout.ny) = \(layout.tiles.count) tiles of "
            + "\(layout.tileSize) (stride \(layout.stride), overlap \(layout.overlap))"
        )
        for tile in layout.tiles {
            lines.append(
                "  [r=\(tile.row) c=\(tile.col)] x=\(tile.x) y=\(tile.y) "
                + "w=\(tile.width) h=\(tile.height) "
                + "→ covers x[\(tile.x), \(tile.x + tile.width)) y[\(tile.y), \(tile.y + tile.height))"
            )
        }
        return lines.joined(separator: "\n")
    }
}
