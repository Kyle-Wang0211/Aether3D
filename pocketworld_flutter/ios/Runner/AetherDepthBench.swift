//
// AetherDepthBench.swift
// PocketWorld
//
// W1 D2 benchmark: load DA3-LARGE-1.1 CoreML (714 MB fp16) on iPhone 14 Pro
// and measure single-tile (518×518) inference time across CPU / GPU / ANE /
// ALL compute units. Picks the fastest unit, logs compile time, peak memory,
// and standard deviation across 20 iterations.
//
// Triggered from AppDelegate on debug builds when the model is bundled.
// Logs go to NSLog (visible in Xcode console and Console.app).
//

import Foundation
import CoreML
#if canImport(UIKit)
import UIKit
#endif

@objc final class AetherDepthBench: NSObject {

    /// Run the depth model benchmark on the bundled DA3-LARGE-1.1 CoreML.
    /// Safe to call multiple times; logs only — no UI side effects.
    /// `completion` fires once when bench finishes (success, abort, or model
    /// missing). Use it to schedule app exit in bench-only mode.
    @objc static func runIfModelBundled(completion: (() -> Void)? = nil) {
        var didFire = false
        func fire() {
            if !didFire {
                didFire = true
                completion?()
            }
        }
        defer { fire() }

        NSLog("[DepthBench] runIfModelBundled() entered")

        // Refuse to run when device is already hot — data would be useless.
        let initialThermal = ProcessInfo.processInfo.thermalState
        NSLog("[DepthBench] initial thermalState=\(thermalStateName(initialThermal))")
        if initialThermal == .critical {
            NSLog("[DepthBench] ABORT: thermalState=critical. Cool down 20-30 min unplugged, then rerun.")
            return
        }
        if initialThermal == .serious {
            NSLog("[DepthBench] WARN: thermalState=serious, timing data biased ~30-50% high vs cold-device. Mechanics still valid.")
        }

        NSLog("[DepthBench] Bundle.main.bundlePath = \(Bundle.main.bundlePath)")
        let mlpkg = Bundle.main.url(forResource: "DA3LARGE_v11_518", withExtension: "mlpackage")
        let mlmodelc = Bundle.main.url(forResource: "DA3LARGE_v11_518", withExtension: "mlmodelc")
        NSLog("[DepthBench] mlpackage URL: \(String(describing: mlpkg))")
        NSLog("[DepthBench] mlmodelc URL: \(String(describing: mlmodelc))")
        if mlpkg == nil && mlmodelc == nil {
            // Brute scan bundle Resources for anything starting with DA3LARGE
            if let resPath = Bundle.main.resourcePath {
                NSLog("[DepthBench] resourcePath = \(resPath)")
                let files = (try? FileManager.default.contentsOfDirectory(atPath: resPath)) ?? []
                let matches = files.filter { $0.localizedCaseInsensitiveContains("DA3LARGE") || $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") }
                NSLog("[DepthBench] candidate files in Resources: \(matches)")
            }
        }
        guard let bundledURL = mlpkg ?? mlmodelc else {
            NSLog("[DepthBench] DA3LARGE_v11_518 not in bundle, skipping benchmark")
            return
        }
        NSLog("[DepthBench] ======== W1 D2 benchmark start ========")
        NSLog("[DepthBench] Source: \(bundledURL.lastPathComponent)")
        NSLog("[DepthBench] Bundle path: \(bundledURL.path)")
        logDeviceInfo()
        logFileSize(bundledURL)

        // If we bundled the raw .mlpackage (Xcode didn't compile it at build time
        // because we used lastKnownFileType=folder), compile to .mlmodelc here.
        // Takes a few seconds — one-shot per app launch.
        let modelURL: URL
        if bundledURL.pathExtension == "mlpackage" {
            NSLog("[DepthBench] mlpackage detected → compiling to mlmodelc at runtime…")
            let compileStart = CFAbsoluteTimeGetCurrent()
            do {
                modelURL = try MLModel.compileModel(at: bundledURL)
            } catch {
                NSLog("[DepthBench] MLModel.compileModel(at:) FAILED: \(error)")
                return
            }
            NSLog("[DepthBench] compiled in %.2fs → %@", CFAbsoluteTimeGetCurrent() - compileStart, modelURL.path)
            logFileSize(modelURL)
        } else {
            modelURL = bundledURL
        }

        var units: [(String, MLComputeUnits)] = [
            ("CPU_ONLY", .cpuOnly),
            ("CPU_AND_GPU", .cpuAndGPU),
            ("ALL", .all),
        ]
        // .cpuAndNeuralEngine requires iOS 16+; project deployment target is
        // iOS 13/14. iPhone 14 Pro ships iOS 16+ so this branch will run at
        // runtime on the test device.
        if #available(iOS 16.0, *) {
            units.insert(("CPU_AND_NE", .cpuAndNeuralEngine), at: 2)
        } else {
            NSLog("[DepthBench] iOS < 16: skipping CPU_AND_NE direct test (ALL still routes via ANE)")
        }

        // W1 D2 compute-unit benchmark is opt-in via AETHER_FULL_BENCH=1.
        // (We already locked CPU_ONLY for production based on W1 D2 data —
        // re-running heats the device ~5 min, biasing later tests. Skip by
        // default; opt in only when re-bench needed.)
        let doFullBench = ProcessInfo.processInfo.environment["AETHER_FULL_BENCH"] == "1"
        if doFullBench {
            for (name, cu) in units {
                benchmark(modelURL: modelURL, name: name, computeUnits: cu)
            }
            NSLog("[DepthBench] ======== W1 D2 benchmark complete ========")
        } else {
            NSLog("[DepthBench] AETHER_FULL_BENCH not set, skipping compute-unit benchmark (CPU_ONLY 759ms already locked)")
        }

        // W1 D3 D4: Tile2K end-to-end smoke test using bundled test_scene.jpg.
        // Runs first / standalone when AETHER_FULL_BENCH not set, so iPhone is
        // still cool → clean per-tile timing.
        runTile2KE2EIfFixtureBundled(modelURL: modelURL)

        // W2 D1: EdgeTAM mask smoke test on the same fixture.
        if #available(iOS 16.0, *) {
            runEdgeTAME2EIfBundled()
        } else {
            NSLog("[EdgeTAM-E2E] iOS < 16, skipping (EdgeTAMWrapper requires .float16 MLMultiArrayDataType, iOS 16+)")
        }
    }

    /// W2 D1: EdgeTAM 3-stage SAM 2 mobile inference smoke test.
    /// Loads bundled image_encoder + prompt_encoder + mask_decoder + image_pe.bin →
    /// runs mask prediction on test_scene.jpg with auto-prompt (center) → logs
    /// per-stage timing + IoU + saves mask PNG to Documents.
    @available(iOS 16.0, *)
    private static func runEdgeTAME2EIfBundled() {
        guard let imgEncURL = Bundle.main.url(forResource: "edgetam_image_encoder", withExtension: "mlpackage")
                          ?? Bundle.main.url(forResource: "edgetam_image_encoder", withExtension: "mlmodelc"),
              let promptEncURL = Bundle.main.url(forResource: "edgetam_prompt_encoder", withExtension: "mlpackage")
                              ?? Bundle.main.url(forResource: "edgetam_prompt_encoder", withExtension: "mlmodelc"),
              let maskDecURL = Bundle.main.url(forResource: "edgetam_mask_decoder", withExtension: "mlpackage")
                            ?? Bundle.main.url(forResource: "edgetam_mask_decoder", withExtension: "mlmodelc"),
              let imagePeURL = Bundle.main.url(forResource: "edgetam_image_pe.float32", withExtension: "bin") else {
            NSLog("[EdgeTAM-E2E] one or more EdgeTAM resources missing in bundle, skipping")
            return
        }
        guard let fixtureURL = Bundle.main.url(forResource: "test_scene", withExtension: "jpg") else {
            NSLog("[EdgeTAM-E2E] test_scene.jpg missing, skipping")
            return
        }
        NSLog("[EdgeTAM-E2E] ======== W2 D1 EdgeTAM mask test start ========")

        let memBefore = currentResidentMemoryMB()
        let availBefore = availableMemoryMB()
        NSLog("[EdgeTAM-E2E] mem before load: resident=%.0f MB, jetsam-avail=%.0f MB",
              memBefore, availBefore)

        let session: EdgeTAMWrapper.Session
        let loadStart = CFAbsoluteTimeGetCurrent()
        do {
            session = try EdgeTAMWrapper.Session(
                imageEncoderURL: imgEncURL,
                promptEncoderURL: promptEncURL,
                maskDecoderURL: maskDecURL,
                imagePeURL: imagePeURL
            )
        } catch {
            NSLog("[EdgeTAM-E2E] session init FAILED: \(error)")
            return
        }
        let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
        let memAfterLoad = currentResidentMemoryMB()
        NSLog("[EdgeTAM-E2E] session loaded in %.0f ms, resident=%.0f MB (Δ%.0f)",
              loadMs, memAfterLoad, memAfterLoad - memBefore)

        // Load fixture as CGImage.
        guard let data = try? Data(contentsOf: fixtureURL),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            NSLog("[EdgeTAM-E2E] failed to decode fixture")
            return
        }
        NSLog("[EdgeTAM-E2E] Fixture: \(cgImage.width)×\(cgImage.height)")

        // Predict — center prompt (default).
        let result: EdgeTAMWrapper.MaskResult
        do {
            result = try session.predictMask(image: cgImage)
        } catch {
            NSLog("[EdgeTAM-E2E] predictMask FAILED: \(error)")
            return
        }

        let memAfterPred = currentResidentMemoryMB()
        NSLog("[EdgeTAM-E2E] mask predicted in %.0f ms, mem peak %.0f MB",
              result.inferenceTimeMs, max(memAfterLoad, memAfterPred))
        NSLog("[EdgeTAM-E2E] prompt point: (%.0f, %.0f) in %d×%d image",
              result.promptPoint.x, result.promptPoint.y, result.imageWidth, result.imageHeight)
        NSLog("[EdgeTAM-E2E] IoU hypotheses: [%.3f, %.3f, %.3f], picked %d (IoU=%.3f)",
              result.allIoUs[0], result.allIoUs[1], result.allIoUs[2],
              result.bestHypothesis, result.iou)

        // Mask stats
        let fgPixels = result.mask.reduce(0) { $0 + ($1 > 0.5 ? 1 : 0) }
        let fgPct = Float(fgPixels) / Float(result.mask.count) * 100.0
        let maxProb = result.mask.max() ?? 0
        let meanProb = result.mask.reduce(0, +) / Float(result.mask.count)
        NSLog("[EdgeTAM-E2E] mask: %d×%d, foreground %.1f%%, mean prob %.3f, max prob %.3f",
              EdgeTAMWrapper.maskOutSize, EdgeTAMWrapper.maskOutSize, fgPct, meanProb, maxProb)

        // Save mask PNG to Documents for visual inspection.
        let maskSize = EdgeTAMWrapper.maskOutSize
        var maskBytes = [UInt8](repeating: 0, count: maskSize * maskSize)
        for i in 0..<(maskSize * maskSize) {
            maskBytes[i] = UInt8(min(255, max(0, result.mask[i] * 255.0)))
        }
        if let cs = CGColorSpace(name: CGColorSpace.linearGray),
           let provider = CGDataProvider(data: Data(maskBytes) as CFData),
           let maskImg = CGImage(
               width: maskSize, height: maskSize,
               bitsPerComponent: 8, bitsPerPixel: 8,
               bytesPerRow: maskSize,
               space: cs,
               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
               provider: provider,
               decode: nil,
               shouldInterpolate: false,
               intent: .defaultIntent
           ) {
            let ui = UIImage(cgImage: maskImg)
            if let png = ui.pngData() {
                let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let outURL = docs.appendingPathComponent("edgetam_mask_test.png")
                try? png.write(to: outURL)
                NSLog("[EdgeTAM-E2E] wrote %.1f KB mask → %@", Double(png.count) / 1024.0, outURL.path as NSString)
            }
        }

        NSLog("[EdgeTAM-E2E] ======== W2 D1 complete ========")
    }

    /// W1 D3 D4: end-to-end Tile2K pipeline smoke test.
    /// Loads `test_scene.jpg` (1920×1080 fixture from Unsplash, CC0) →
    /// split 12 tiles → CoreML inference (.cpuOnly per Plan G) → blend →
    /// write `depth_blended_test.png` to Documents/ for visual eyeballing.
    ///
    /// Measures: per-tile inference time, total 12-tile time, blend time,
    /// memory peak, depth value range, coverage. Confirms Tile2KWrapper
    /// pipeline mechanics on real hardware.
    private static func runTile2KE2EIfFixtureBundled(modelURL: URL) {
        guard let fixtureURL = Bundle.main.url(forResource: "test_scene", withExtension: "jpg") else {
            NSLog("[Tile2K-E2E] test_scene.jpg not in bundle, skipping E2E test")
            return
        }
        NSLog("[Tile2K-E2E] ======== W1 D3 D4 end-to-end test start ========")

        // Load the fixture into CGImage.
        guard let data = try? Data(contentsOf: fixtureURL),
              let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage else {
            NSLog("[Tile2K-E2E] FAILED to decode \(fixtureURL.path)")
            return
        }
        let W = cgImage.width
        let H = cgImage.height
        NSLog("[Tile2K-E2E] Fixture: \(W)×\(H), bundle path: \(fixtureURL.lastPathComponent)")

        // Compute tile layout.
        let layout = Tile2KWrapper.makeLayout(imageWidth: W, imageHeight: H)
        NSLog("[Tile2K-E2E] Layout: \(layout.nx)×\(layout.ny) = \(layout.tiles.count) tiles of \(layout.tileSize), overlap \(layout.overlap), stride \(layout.stride)")

        // Split image.
        let splitStart = CFAbsoluteTimeGetCurrent()
        let tileImages = Tile2KWrapper.splitImage(cgImage, layout: layout)
        let splitTimeMs = (CFAbsoluteTimeGetCurrent() - splitStart) * 1000.0
        NSLog("[Tile2K-E2E] Split: %.0f ms, got %d tile CGImages", splitTimeMs, tileImages.count)
        guard tileImages.count == layout.tiles.count else {
            NSLog("[Tile2K-E2E] FAILED: split returned %d tiles, expected %d", tileImages.count, layout.tiles.count)
            return
        }

        // Load CoreML session.
        let session: Tile2KWrapper.Session
        do {
            session = try Tile2KWrapper.Session(modelURL: modelURL, tileSize: layout.tileSize)
        } catch {
            NSLog("[Tile2K-E2E] Session init FAILED: \(error)")
            return
        }
        let memAfterModelLoad = currentResidentMemoryMB()
        NSLog("[Tile2K-E2E] Model loaded (.cpuOnly), resident=%.0f MB, jetsam-avail=%.0f MB",
              memAfterModelLoad, availableMemoryMB())

        // Per-tile inference (serial, .cpuOnly per Plan G W1 D2 decision).
        var results: [Tile2KWrapper.TileInference] = []
        let inferStart = CFAbsoluteTimeGetCurrent()
        var memPeak = memAfterModelLoad
        for (i, tileImg) in tileImages.enumerated() {
            do {
                let r = try session.inferTile(tileImg, tile: layout.tiles[i])
                results.append(r)
                let mem = currentResidentMemoryMB()
                if mem > memPeak { memPeak = mem }
                NSLog("[Tile2K-E2E] tile %2d/%d r=%d c=%d → %.0f ms, depth=[%.3f, %.3f], conf=[%.3f, %.3f], mem=%.0f MB",
                      i + 1, tileImages.count, r.tile.row, r.tile.col,
                      r.inferenceTimeMs,
                      r.depth.min() ?? 0, r.depth.max() ?? 0,
                      r.conf.min() ?? 0, r.conf.max() ?? 0,
                      mem)
            } catch {
                NSLog("[Tile2K-E2E] tile %d FAILED: \(error)", i)
                return
            }
        }
        let inferTotalMs = (CFAbsoluteTimeGetCurrent() - inferStart) * 1000.0
        let avgTileMs = inferTotalMs / Double(results.count)
        NSLog("[Tile2K-E2E] All %d tiles inferred in %.0f ms (avg %.0f ms/tile, peak mem %.0f MB, jetsam-avail %.0f MB)",
              results.count, inferTotalMs, avgTileMs, memPeak, availableMemoryMB())

        // Blend.
        let blendResult = Tile2KWrapper.blendTiles(results, layout: layout)
        NSLog("[Tile2K-E2E] Blend: %.0f ms, coverage=%.2f%%, depth range [%.3f, %.3f], mean %.3f",
              blendResult.blendTimeMs,
              blendResult.coverage * 100,
              blendResult.minDepth, blendResult.maxDepth, blendResult.meanDepth)

        // Save debug PNG for visual eyeballing.
        if let depthUI = Tile2KWrapper.blendResultToUIImage(blendResult),
           let png = depthUI.pngData() {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let outURL = docs.appendingPathComponent("depth_blended_test.png")
            do {
                try png.write(to: outURL)
                NSLog("[Tile2K-E2E] Wrote %.1f KB depth visualization → %@", Double(png.count) / 1024.0, outURL.path as NSString)
            } catch {
                NSLog("[Tile2K-E2E] PNG write FAILED: \(error)")
            }
        } else {
            NSLog("[Tile2K-E2E] blendResultToUIImage returned nil")
        }

        NSLog("[Tile2K-E2E] ======== W1 D3 D4 complete ========")
    }

    private static func benchmark(modelURL: URL, name: String, computeUnits: MLComputeUnits) {
        let thermal = ProcessInfo.processInfo.thermalState
        NSLog("[DepthBench][\(name)] thermalState at start: \(thermalStateName(thermal))")
        if thermal == .critical {
            NSLog("[DepthBench][\(name)] SKIP — thermal critical, would corrupt data")
            return
        }

        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        // Compile + load timing
        let loadStart = CFAbsoluteTimeGetCurrent()
        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            NSLog("[DepthBench][\(name)] LOAD FAILED: \(error)")
            return
        }
        let loadTime = CFAbsoluteTimeGetCurrent() - loadStart

        // Build dummy 1x3x518x518 input filled with normal-ish random noise
        guard let input = makeDummyInput() else {
            NSLog("[DepthBench][\(name)] failed to build dummy input")
            return
        }
        let provider: MLFeatureProvider
        do {
            provider = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        } catch {
            NSLog("[DepthBench][\(name)] feature provider failed: \(error)")
            return
        }

        // Warmup x 2
        for i in 0..<2 {
            do {
                _ = try model.prediction(from: provider)
            } catch {
                NSLog("[DepthBench][\(name)] WARMUP \(i) FAILED: \(error)")
                return
            }
        }

        // Timed x 8
        var times: [Double] = []
        times.reserveCapacity(8)
        let memBefore = currentResidentMemoryMB()
        var memPeak = memBefore
        for _ in 0..<8 {
            let t0 = CFAbsoluteTimeGetCurrent()
            do {
                _ = try model.prediction(from: provider)
            } catch {
                NSLog("[DepthBench][\(name)] PREDICT FAILED: \(error)")
                return
            }
            times.append(CFAbsoluteTimeGetCurrent() - t0)
            memPeak = max(memPeak, currentResidentMemoryMB())
        }

        let mean = times.reduce(0, +) / Double(times.count)
        let variance = times.map { pow($0 - mean, 2) }.reduce(0, +) / Double(times.count)
        let stddev = sqrt(variance)
        let minT = times.min() ?? 0
        let maxT = times.max() ?? 0

        let availAfter = availableMemoryMB()
        NSLog(
            "[DepthBench][\(name)] load=%.2fs inference=%.0f±%.0f ms (min=%.0f, max=%.0f) | mem=%.0f→%.0f MB (Δ%.0f) | jetsam-avail=%.0f MB",
            loadTime,
            mean * 1000, stddev * 1000, minT * 1000, maxT * 1000,
            memBefore, memPeak, memPeak - memBefore,
            availAfter
        )
    }

    // MARK: - Helpers

    private static func makeDummyInput() -> MLMultiArray? {
        let shape: [NSNumber] = [1, 3, 518, 518]
        guard let arr = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
        // Fill with low-amplitude normalized RGB-like values.
        for i in 0..<arr.count {
            arr[i] = NSNumber(value: Float.random(in: -1.0...1.0))
        }
        return arr
    }

    private static func currentResidentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.resident_size) / 1024.0 / 1024.0
    }

    /// iOS jetsam-relevant available memory (what we have headroom for).
    /// Returns MB remaining before EXC_RESOURCE high watermark.
    private static func availableMemoryMB() -> Double {
        // os_proc_available_memory returns bytes until jetsam.
        let bytes = os_proc_available_memory()
        return Double(bytes) / 1024.0 / 1024.0
    }

    private static func logDeviceInfo() {
        #if canImport(UIKit)
        let device = UIDevice.current
        let info = ProcessInfo.processInfo
        let physMemMB = Double(info.physicalMemory) / 1024 / 1024
        NSLog("[DepthBench] Device: \(device.model) iOS \(device.systemVersion) | physMem=%.0f MB | nCores=\(info.activeProcessorCount)", physMemMB)
        #else
        NSLog("[DepthBench] (no UIKit, skipping device info)")
        #endif
    }

    private static func thermalStateName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func logFileSize(_ url: URL) {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        var total: Int64 = 0
        for case let f as URL in enumerator {
            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(sz)
            }
        }
        NSLog("[DepthBench] On-disk size: %.1f MB", Double(total) / 1024 / 1024)
    }
}
