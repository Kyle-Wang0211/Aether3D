import Accelerate
import CoreML
import Darwin
import Flutter
import Foundation
import UIKit
#if canImport(os)
import os
#endif

@objc final class Da3DepthPlugin: NSObject {
  private struct RuntimeSpec {
    let resourceName: String
    let windowSize: Int
    let inputHeight: Int
    let inputWidth: Int
    let inputContract: String

    var label: String {
      "K\(windowSize)@\(inputHeight)x\(inputWidth)"
    }

    var isPoseConditioned: Bool {
      inputContract.lowercased().contains("pose_conditioned") ||
        resourceName.lowercased().hasSuffix("_pose")
    }
  }

  private static let supportedResourceNames: Set<String> = [
    "DA3BASE_280x504_N35_image_only",
    "DA3BASE_280x504_N40_image_only",
    "DA3BASE_280x504_N50_image_only",
    "DA3BASE_280x504_N60_image_only",
    "DA3BASE_280x504_N90_image_only",
    "DA3BASE_280x504_N120_image_only",
    // Pose-conditioned external-ARKit-pose mode (2026-06-11 icosa42
    // capture redesign). N3/N5 are the capture-time cell probes
    // (portrait 280w×504h); N18 is the production face-window model.
    "DA3BASE_280x504_N3_pose",
    "DA3BASE_280x504_N5_pose",
    "DA3BASE_504x896_N18_pose",
  ]

  private let queue = DispatchQueue(
    label: "pocketworld.da3_depth.coreml",
    qos: .userInitiated
  )
  private var loadedResourceName: String?
  private var loadedModel: MLModel?

  private final class CpuSampler {
    private let queue = DispatchQueue(label: "pocketworld.da3_depth.cpu_sampler")
    private var timer: DispatchSourceTimer?
    private var samples: [Double] = []

    func start() {
      queue.sync {
        samples.removeAll(keepingCapacity: true)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
          guard let self else { return }
          self.samples.append(Da3DepthPlugin.processCpuOneCorePercent())
        }
        self.timer = timer
        timer.resume()
      }
    }

    func stop() -> [String: Any] {
      queue.sync {
        timer?.cancel()
        timer = nil
        guard !samples.isEmpty else {
          return [
            "sampleCount": 0,
            "peakOneCorePercent": 0.0,
            "meanOneCorePercent": 0.0,
            "peakDeviceNormalizedPercent": 0.0,
            "meanDeviceNormalizedPercent": 0.0,
          ]
        }
        let peak = samples.max() ?? 0.0
        let mean = samples.reduce(0.0, +) / Double(samples.count)
        let logicalCores = max(1, ProcessInfo.processInfo.processorCount)
        return [
          "sampleCount": samples.count,
          "peakOneCorePercent": peak,
          "meanOneCorePercent": mean,
          "peakDeviceNormalizedPercent": peak / Double(logicalCores),
          "meanDeviceNormalizedPercent": mean / Double(logicalCores),
          "logicalCores": logicalCores,
        ]
      }
    }
  }

  @objc static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "pocketworld/da3_depth",
      binaryMessenger: messenger
    )
    let plugin = Da3DepthPlugin()
    channel.setMethodCallHandler { call, result in
      plugin.handle(call: call, result: result)
    }
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "runDa3DepthWindow":
      handleRunDa3DepthWindow(call: call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleRunDa3DepthWindow(
    call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(
        code: "BAD_ARGS",
        message: "runDa3DepthWindow requires a map payload",
        details: nil
      ))
      return
    }

    queue.async {
      do {
        let payload = try autoreleasepool {
          try self.runWindow(args: args)
        }
        DispatchQueue.main.async { result(payload) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "DA3_DEPTH_COREML_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  private func runWindow(args: [String: Any]) throws -> [String: Any] {
    let outputDir = try Self.requiredString(args["outputDir"], "outputDir")
    let windowID = try Self.requiredString(args["windowID"], "windowID")
    let model = try Self.requiredMap(args["model"], "model")
    let inputSizePolicy = try Self.requiredMap(args["inputSizePolicy"], "inputSizePolicy")
    let frames = try Self.requiredMapArray(args["frames"], "frames")

    let spec = try Self.runtimeSpec(model: model, inputSizePolicy: inputSizePolicy)
    guard frames.count == spec.windowSize else {
      throw Self.validationError(
        "Flutter DA3 runtime contract requires exactly \(spec.windowSize) frame entries per window, got \(frames.count)"
      )
    }

    let outputURL = URL(fileURLWithPath: outputDir, isDirectory: true)
    let relativeDepthDir = outputURL.appendingPathComponent("relative_depth", isDirectory: true)
    let confidenceDir = outputURL.appendingPathComponent("confidence", isDirectory: true)
    let poseDir = outputURL.appendingPathComponent("pred_pose", isDirectory: true)
    try FileManager.default.createDirectory(at: relativeDepthDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: confidenceDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: poseDir, withIntermediateDirectories: true)

    let rssBeforeLoadMB = Self.residentMemoryMB()
    let modelURL = Self.resolveBundledModelURL(resourceName: spec.resourceName)
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "window_start",
      fields: [
        "resourceName": spec.resourceName,
        "frameCount": frames.count,
        "windowSize": spec.windowSize,
        "inputHeight": spec.inputHeight,
        "inputWidth": spec.inputWidth,
        "inputContract": spec.inputContract,
        "officialStreamingBaseline": !spec.isPoseConditioned,
        "computeUnits": "cpuOnly",
        "rssBeforeLoadMB": rssBeforeLoadMB as Any,
        "system": Self.systemSnapshot(),
        "modelPathExtension": modelURL?.pathExtension as Any,
      ]
    )
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "model_load_begin",
      fields: ["resourceName": spec.resourceName]
    )
    let loadStart = CFAbsoluteTimeGetCurrent()
    let coreMLModel = try ensureLoaded(resourceName: spec.resourceName)
    let loadMs = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000.0
    let rssAfterLoadMB = Self.residentMemoryMB()
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "model_load_done",
      fields: [
        "loadMs": loadMs,
        "rssAfterLoadMB": rssAfterLoadMB as Any,
        "system": Self.systemSnapshot(),
      ]
    )
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "image_array_begin",
      fields: ["frameCount": frames.count]
    )
    let imageArray = try Self.makeImageArray(frames: frames, spec: spec)
    let imageArrayStats = Self.floatMultiArrayStats(imageArray)
    NSLog("[Da3DepthPlugin] \(windowID) imageArrayStats: \(imageArrayStats)")
    let rssAfterImageArrayMB = Self.residentMemoryMB()
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "image_array_done",
      fields: [
        "rssAfterImageArrayMB": rssAfterImageArrayMB as Any,
        "imageArrayStats": imageArrayStats,
        "system": Self.systemSnapshot(),
      ]
    )

    var rssAfterInputMB = rssAfterImageArrayMB
    Self.appendNativeLog(outputURL: outputURL, windowID: windowID, phase: "provider_begin")
    let provider: MLDictionaryFeatureProvider
    if spec.isPoseConditioned {
      Self.appendNativeLog(outputURL: outputURL, windowID: windowID, phase: "pose_arrays_begin")
      let extrinsics = try Self.makeExtrinsics(frames: frames, spec: spec)
      let intrinsics = try Self.makeIntrinsics(frames: frames, spec: spec)
      rssAfterInputMB = Self.residentMemoryMB()
      Self.appendNativeLog(
        outputURL: outputURL,
        windowID: windowID,
        phase: "pose_arrays_done",
        fields: [
          "rssAfterInputMB": rssAfterInputMB as Any,
          "system": Self.systemSnapshot(),
        ]
      )
      provider = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: imageArray),
        "extrinsics": MLFeatureValue(multiArray: extrinsics),
        "intrinsics": MLFeatureValue(multiArray: intrinsics),
      ])
    } else {
      provider = try MLDictionaryFeatureProvider(dictionary: [
        "image": MLFeatureValue(multiArray: imageArray),
      ])
    }
    Self.appendNativeLog(outputURL: outputURL, windowID: windowID, phase: "provider_done")

    let cpuSampler = CpuSampler()
    cpuSampler.start()
    let systemAtPredictionBegin = Self.systemSnapshot()
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "prediction_begin",
      fields: ["system": systemAtPredictionBegin]
    )
    let start = CFAbsoluteTimeGetCurrent()
    let prediction = try coreMLModel.prediction(from: provider)
    let inferenceMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
    let cpuStats = cpuSampler.stop()
    let rssAfterInferMB = Self.residentMemoryMB()
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "prediction_done",
      fields: [
        "inferenceMs": inferenceMs,
        "rssAfterInferMB": rssAfterInferMB as Any,
        "cpu": cpuStats,
        "system": Self.systemSnapshot(),
      ]
    )

    guard let depthArray = prediction.featureValue(for: "depth")?.multiArrayValue,
          let confArray = prediction.featureValue(for: "depth_conf")?.multiArrayValue else {
      throw Self.validationError("CoreML output missing depth/depth_conf; have \(prediction.featureNames)")
    }

    Self.appendNativeLog(outputURL: outputURL, windowID: windowID, phase: "output_extract_begin")
    let depth = try Self.multiArrayToFloatBuffer(depthArray)
    let conf = try Self.multiArrayToFloatBuffer(confArray)
    guard let predExtrinsics = prediction.featureValue(for: "pred_extrinsics")?.multiArrayValue,
          let predIntrinsics = prediction.featureValue(for: "pred_intrinsics")?.multiArrayValue else {
      throw Self.validationError(
        "official image-only CoreML output missing pred_extrinsics/pred_intrinsics; refusing external-camera fallback; have \(prediction.featureNames)"
      )
    }
    let predExtrinsicsValues = try Self.multiArrayToFloatBuffer(predExtrinsics)
    let predIntrinsicsValues = try Self.multiArrayToFloatBuffer(predIntrinsics)
    let expectedPredExtrinsics = spec.windowSize * 12
    let expectedPredIntrinsics = spec.windowSize * 9
    guard predExtrinsicsValues.count >= expectedPredExtrinsics,
          predIntrinsicsValues.count >= expectedPredIntrinsics else {
      throw Self.validationError(
        "official image-only CoreML pred pose size mismatch pred_extrinsics=\(predExtrinsicsValues.count) expected>=\(expectedPredExtrinsics), pred_intrinsics=\(predIntrinsicsValues.count) expected>=\(expectedPredIntrinsics)"
      )
    }
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "output_extract_done",
      fields: [
        "depthValueCount": depth.count,
        "confValueCount": conf.count,
        "predExtrinsicsValueCount": predExtrinsicsValues.count,
        "predIntrinsicsValueCount": predIntrinsicsValues.count,
        "depthArray": Self.multiArrayDescriptor(depthArray),
        "confArray": Self.multiArrayDescriptor(confArray),
        "predExtrinsicsArray": Self.multiArrayDescriptor(predExtrinsics),
        "predIntrinsicsArray": Self.multiArrayDescriptor(predIntrinsics),
      ]
    )

    let depthShape = depthArray.shape.map { $0.intValue }
    let height = depthShape.count >= 2 ? depthShape[depthShape.count - 2] : spec.inputHeight
    let width = depthShape.count >= 1 ? depthShape[depthShape.count - 1] : spec.inputWidth
    let perFramePixels = height * width
    guard depth.count >= spec.windowSize * perFramePixels,
          conf.count >= spec.windowSize * perFramePixels else {
      throw Self.validationError(
        "CoreML depth/conf size mismatch depth=\(depth.count) conf=\(conf.count) expected \(spec.windowSize * perFramePixels)"
      )
    }

    var framePayloads: [[String: Any]] = []
    framePayloads.reserveCapacity(frames.count)
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "write_outputs_begin",
      fields: [
        "height": height,
        "width": width,
        "perFramePixels": perFramePixels,
      ]
    )
    for (viewIndex, frame) in frames.enumerated() {
      let frameID = try Self.requiredString(frame["frameID"], "frames[].frameID")
      let frameIndex = Self.intValue(frame["frameIndex"]) ?? viewIndex
      let safeID = Self.sanitize("\(windowID)_\(viewIndex)_\(frameIndex)_\(frameID)")

      let depthRelativePath = "relative_depth/\(safeID).bin"
      let confidenceRelativePath = "confidence/\(safeID).bin"
      let predExtrinsicsRelativePath = "pred_pose/\(safeID)_extrinsics.bin"
      let predIntrinsicsRelativePath = "pred_pose/\(safeID)_intrinsics.bin"

      let lo = viewIndex * perFramePixels
      let hi = lo + perFramePixels
      let depthSlice = Array(depth[lo..<hi])
      // DA3-Streaming applies `predictions.conf -= 1.0` immediately before
      // saving frame_*.npz; keep APP confidencePath on that same contract.
      let confSlice = Array(conf[lo..<hi]).map { $0 - 1.0 }
      try Self.writeFloats(depthSlice, to: relativeDepthDir.appendingPathComponent("\(safeID).bin"))
      try Self.writeFloats(confSlice, to: confidenceDir.appendingPathComponent("\(safeID).bin"))

      let extrinsicsPose: [Float]
      let extrinsicsOffset = viewIndex * 12
      extrinsicsPose = Array(predExtrinsicsValues[extrinsicsOffset..<(extrinsicsOffset + 12)])
      try Self.writeFloats(
        extrinsicsPose,
        to: poseDir.appendingPathComponent("\(safeID)_extrinsics.bin")
      )

      let intrinsicsPose: [Float]
      let intrinsicsOffset = viewIndex * 9
      intrinsicsPose = Array(predIntrinsicsValues[intrinsicsOffset..<(intrinsicsOffset + 9)])
      try Self.writeFloats(
        intrinsicsPose,
        to: poseDir.appendingPathComponent("\(safeID)_intrinsics.bin")
      )

      let stats = Self.stats(confSlice)
      framePayloads.append([
        "frameID": frameID,
        "windowID": windowID,
        "status": "completed",
        "relativeDepthPath": depthRelativePath,
        "confidencePath": confidenceRelativePath,
        "predExtrinsicsPath": predExtrinsicsRelativePath,
        "predIntrinsicsPath": predIntrinsicsRelativePath,
        "depthWidth": width,
        "depthHeight": height,
        "inferenceMs": inferenceMs,
        "confMedian": Double(stats.median),
        "confMean": Double(stats.mean),
        "confMin": Double(stats.min),
        "confMax": Double(stats.max),
      ])
    }
    Self.appendNativeLog(
      outputURL: outputURL,
      windowID: windowID,
      phase: "write_outputs_done",
      fields: ["framePayloadCount": framePayloads.count]
    )

    return [
      "schemaVersion": "aether_da3_depth_window_result_v1",
      "windowID": windowID,
      "status": "completed",
      "message": "CoreML DA3-BASE \(spec.label) completed",
      "modelResourceName": spec.resourceName,
      "inputContract": spec.inputContract,
      "inputHeight": spec.inputHeight,
      "inputWidth": spec.inputWidth,
      "telemetry": [
        "loadMs": loadMs,
        "inferenceMs": inferenceMs,
        "rssBeforeLoadMB": rssBeforeLoadMB as Any,
        "rssAfterLoadMB": rssAfterLoadMB as Any,
        "rssAfterInputMB": rssAfterInputMB as Any,
        "rssAfterInferMB": rssAfterInferMB as Any,
        "rssPeakApproxMB": [
          rssBeforeLoadMB,
          rssAfterLoadMB,
          rssAfterInputMB,
          rssAfterInferMB,
        ].compactMap { $0 }.max() as Any,
        "cpu": cpuStats,
        "systemAtPredictionBegin": systemAtPredictionBegin,
        "systemAfterPrediction": Self.systemSnapshot(),
      ],
      "frames": framePayloads,
    ]
  }

  private func ensureLoaded(resourceName: String) throws -> MLModel {
    if loadedResourceName == resourceName, let loadedModel {
      return loadedModel
    }
    guard let modelURL = Self.resolveBundledModelURL(resourceName: resourceName) else {
      throw Self.validationError("\(resourceName).mlmodelc/.mlpackage not found in Bundle.main")
    }

    let compiledURL: URL
    if modelURL.pathExtension == "mlpackage" {
      compiledURL = try MLModel.compileModel(at: modelURL)
    } else {
      compiledURL = modelURL
    }
    let config = MLModelConfiguration()
    config.computeUnits = .cpuOnly
    let model = try MLModel(contentsOf: compiledURL, configuration: config)
    loadedResourceName = resourceName
    loadedModel = model
    return model
  }

  private static func appendNativeLog(
    outputURL: URL,
    windowID: String,
    phase: String,
    fields: [String: Any] = [:]
  ) {
    do {
      let fileURL = outputURL.appendingPathComponent("da3_native_run_log.jsonl")
      var payload: [String: Any] = [
        "time_utc": ISO8601DateFormatter().string(from: Date()),
        "windowID": windowID,
        "phase": phase,
      ]
      for (key, value) in fields {
        if let ready = jsonReady(value) {
          payload[key] = ready
        }
      }
      guard JSONSerialization.isValidJSONObject(payload) else {
        NSLog("[Da3DepthPlugin] native log payload is not JSON: \(payload)")
        return
      }
      let data = try JSONSerialization.data(withJSONObject: payload)
      let newline = Data([0x0A])
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
      }
      let handle = try FileHandle(forWritingTo: fileURL)
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.write(contentsOf: newline)
    } catch {
      NSLog("[Da3DepthPlugin] failed to append native log: \(error.localizedDescription)")
    }
  }

  private static func jsonReady(_ value: Any) -> Any? {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional {
      guard let child = mirror.children.first else { return nil }
      return jsonReady(child.value)
    }
    if let string = value as? String { return string }
    if let bool = value as? Bool { return bool }
    if let int = value as? Int { return int }
    if let int64 = value as? Int64 { return int64 }
    if let double = value as? Double { return double.isFinite ? double : nil }
    if let float = value as? Float { return float.isFinite ? Double(float) : nil }
    if let number = value as? NSNumber { return number }
    if let array = value as? [Any] {
      return array.compactMap { jsonReady($0) }
    }
    if let dict = value as? [String: Any] {
      var ready: [String: Any] = [:]
      for (key, child) in dict {
        if let childReady = jsonReady(child) {
          ready[key] = childReady
        }
      }
      return ready
    }
    return String(describing: value)
  }

  private static func resolveBundledModelURL(resourceName: String) -> URL? {
    for ext in ["mlmodelc", "mlpackage"] {
      if let url = Bundle.main.url(forResource: resourceName, withExtension: ext) {
        return url
      }
    }

    guard let resourceURL = Bundle.main.resourceURL,
          let enumerator = FileManager.default.enumerator(
            at: resourceURL,
            includingPropertiesForKeys: nil
          ) else {
      return nil
    }
    for case let url as URL in enumerator {
      guard ["mlmodelc", "mlpackage"].contains(url.pathExtension),
            url.deletingPathExtension().lastPathComponent == resourceName else {
        continue
      }
      return url
    }
    return nil
  }

  private static func makeImageArray(
    frames: [[String: Any]],
    spec: RuntimeSpec
  ) throws -> MLMultiArray {
    let array = try MLMultiArray(
      shape: [
        NSNumber(value: 1),
        NSNumber(value: spec.windowSize),
        NSNumber(value: 3),
        NSNumber(value: spec.inputHeight),
        NSNumber(value: spec.inputWidth),
      ],
      dataType: .float32
    )
    let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
    let planeSize = spec.inputHeight * spec.inputWidth
    let perViewFloats = 3 * planeSize
    let expectedTensorBytes = perViewFloats * MemoryLayout<Float32>.stride
    let bytesPerPixel = 4
    let bytesPerRow = spec.inputWidth * bytesPerPixel
    var rgbaBytes = [UInt8](repeating: 0, count: bytesPerRow * spec.inputHeight)
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
      throw validationError("no sRGB color space")
    }
    let bitmapInfo: UInt32 =
      CGImageAlphaInfo.premultipliedLast.rawValue |
      CGBitmapInfo.byteOrder32Big.rawValue
    let meanR: Float = 0.485
    let meanG: Float = 0.456
    let meanB: Float = 0.406
    let stdR: Float = 0.229
    let stdG: Float = 0.224
    let stdB: Float = 0.225

    for (viewIndex, frame) in frames.enumerated() {
      let viewBase = viewIndex * perViewFloats
      if let tensorPath = frame["imageTensorFloat32ChwPath"] as? String,
         !tensorPath.isEmpty {
        let tensorURL = URL(fileURLWithPath: tensorPath)
        let data = try Data(contentsOf: tensorURL)
        guard data.count == expectedTensorBytes else {
          throw validationError(
            "DA3 imageTensorFloat32ChwPath must be \(expectedTensorBytes) bytes for \(spec.inputWidth)x\(spec.inputHeight); got \(data.count): \(tensorPath)"
          )
        }
        try data.withUnsafeBytes { rawBuffer in
          guard let src = rawBuffer.bindMemory(to: Float32.self).baseAddress else {
            throw validationError("empty tensor buffer for \(tensorPath)")
          }
          ptr.advanced(by: viewBase).update(from: src, count: perViewFloats)
        }
        continue
      }

      if !spec.isPoseConditioned {
        throw validationError(
          "official image-only DA3 requires imageTensorFloat32ChwPath from Dart official preprocess; refusing PNG decode fallback"
        )
      }

      let imagePath = try requiredString(frame["imagePath"], "frames[].imagePath")
      guard let image = UIImage(contentsOfFile: imagePath)?.cgImage else {
        throw validationError("could not decode imagePath: \(imagePath)")
      }
      guard image.width == spec.inputWidth,
            image.height == spec.inputHeight else {
        throw validationError(
          "DA3 imagePath must already be \(spec.inputWidth)x\(spec.inputHeight) from photos_depth; got \(image.width)x\(image.height): \(imagePath)"
        )
      }
      rgbaBytes = [UInt8](repeating: 0, count: bytesPerRow * spec.inputHeight)
      try rgbaBytes.withUnsafeMutableBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else {
          throw validationError("empty image buffer for \(imagePath)")
        }
        guard let context = CGContext(
          data: baseAddress,
          width: spec.inputWidth,
          height: spec.inputHeight,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: colorSpace,
          bitmapInfo: bitmapInfo
        ) else {
          throw validationError("CGContext failed for \(imagePath)")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(
          x: 0,
          y: 0,
          width: spec.inputWidth,
          height: spec.inputHeight
        ))
      }

      for y in 0..<spec.inputHeight {
        for x in 0..<spec.inputWidth {
          let src = y * bytesPerRow + x * bytesPerPixel
          let dst = y * spec.inputWidth + x
          let r = Float(rgbaBytes[src + 0]) / 255.0
          let g = Float(rgbaBytes[src + 1]) / 255.0
          let b = Float(rgbaBytes[src + 2]) / 255.0
          ptr[viewBase + 0 * planeSize + dst] = (r - meanR) / stdR
          ptr[viewBase + 1 * planeSize + dst] = (g - meanG) / stdG
          ptr[viewBase + 2 * planeSize + dst] = (b - meanB) / stdB
        }
      }
    }
    return array
  }

  private static func makeExtrinsics(
    frames: [[String: Any]],
    spec: RuntimeSpec
  ) throws -> MLMultiArray {
    let array = try MLMultiArray(
      shape: [
        NSNumber(value: 1),
        NSNumber(value: spec.windowSize),
        NSNumber(value: 4),
        NSNumber(value: 4),
      ],
      dataType: .float32
    )
    let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
    for i in 0..<array.count { ptr[i] = 0 }
    for (viewIndex, frame) in frames.enumerated() {
      let base = viewIndex * 16
      let values = doubleArray(frame["cameraExtrinsicOpenCvW2c4x4"])
      if values.count == 16 {
        for i in 0..<16 { ptr[base + i] = Float(values[i]) }
      } else {
        let fallback = fallbackExtrinsics4x4(frame: frame)
        for i in 0..<16 { ptr[base + i] = fallback[i] }
      }
    }
    return array
  }

  private static func floatMultiArrayStats(_ array: MLMultiArray) -> [String: Any] {
    let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
    var minValue = Float.infinity
    var maxValue = -Float.infinity
    var sum = 0.0
    var nonFinite = 0
    for i in 0..<array.count {
      let value = ptr[i]
      if value.isFinite {
        minValue = min(minValue, value)
        maxValue = max(maxValue, value)
        sum += Double(value)
      } else {
        nonFinite += 1
      }
    }
    let finiteCount = max(0, array.count - nonFinite)
    return [
      "count": array.count,
      "finiteCount": finiteCount,
      "nonFiniteCount": nonFinite,
      "min": finiteCount > 0 ? Double(minValue) : 0.0,
      "max": finiteCount > 0 ? Double(maxValue) : 0.0,
      "mean": finiteCount > 0 ? sum / Double(finiteCount) : 0.0,
    ]
  }

  private static func multiArrayDescriptor(_ array: MLMultiArray) -> [String: Any] {
    [
      "count": array.count,
      "dataTypeRaw": array.dataType.rawValue,
      "shape": array.shape.map { $0.intValue },
      "strides": array.strides.map { $0.intValue },
    ]
  }

  private static func makeIntrinsics(
    frames: [[String: Any]],
    spec: RuntimeSpec
  ) throws -> MLMultiArray {
    let array = try MLMultiArray(
      shape: [
        NSNumber(value: 1),
        NSNumber(value: spec.windowSize),
        NSNumber(value: 3),
        NSNumber(value: 3),
      ],
      dataType: .float32
    )
    let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: array.count)
    for i in 0..<array.count { ptr[i] = 0 }
    for (viewIndex, frame) in frames.enumerated() {
      let base = viewIndex * 9
      let precomputed = doubleArray(frame["cameraIntrinsic3x3"])
      if precomputed.count == 9 {
        for i in 0..<9 { ptr[base + i] = Float(precomputed[i]) }
        continue
      }
      let values = doubleArray(frame["intrinsics"])
      let originalWidth = Double(intValue(frame["imageWidth"]) ?? spec.inputWidth)
      let originalHeight = Double(intValue(frame["imageHeight"]) ?? spec.inputHeight)
      let sx = Double(spec.inputWidth) / max(originalWidth, 1.0)
      let sy = Double(spec.inputHeight) / max(originalHeight, 1.0)
      if values.count == 9 {
        ptr[base + 0] = Float(values[0] * sx)
        ptr[base + 1] = Float(values[1])
        ptr[base + 2] = Float(values[2] * sx)
        ptr[base + 3] = Float(values[3])
        ptr[base + 4] = Float(values[4] * sy)
        ptr[base + 5] = Float(values[5] * sy)
        ptr[base + 6] = Float(values[6])
        ptr[base + 7] = Float(values[7])
        ptr[base + 8] = Float(values[8])
      } else if values.count >= 4 {
        ptr[base + 0] = Float(values[0] * sx)
        ptr[base + 4] = Float(values[1] * sy)
        ptr[base + 2] = Float(values[2] * sx)
        ptr[base + 5] = Float(values[3] * sy)
        ptr[base + 8] = 1
      } else {
        ptr[base + 0] = Float(spec.inputWidth)
        ptr[base + 4] = Float(spec.inputHeight)
        ptr[base + 2] = Float(spec.inputWidth) * 0.5
        ptr[base + 5] = Float(spec.inputHeight) * 0.5
        ptr[base + 8] = 1
      }
    }
    return array
  }

  private static func fallbackExtrinsics4x4(frame: [String: Any]) -> [Float] {
    let values = doubleArray(frame["cameraTransform"])
    if values.count == 16 {
      return [
        Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3]),
        Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7]),
        Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11]),
        Float(values[12]), Float(values[13]), Float(values[14]), Float(values[15]),
      ]
    }
    return [
      1, 0, 0, 0,
      0, 1, 0, 0,
      0, 0, 1, 0,
      0, 0, 0, 1,
    ]
  }

  private static func fallbackExtrinsicsPose(frame: [String: Any]) -> [Float] {
    let values = doubleArray(frame["cameraExtrinsicOpenCvW2c4x4"])
    if values.count == 16 {
      return [
        Float(values[0]), Float(values[1]), Float(values[2]), Float(values[3]),
        Float(values[4]), Float(values[5]), Float(values[6]), Float(values[7]),
        Float(values[8]), Float(values[9]), Float(values[10]), Float(values[11]),
      ]
    }
    let fallback = fallbackExtrinsics4x4(frame: frame)
    return Array(fallback[0..<12])
  }

  private static func fallbackIntrinsicsPose(
    frame: [String: Any],
    spec: RuntimeSpec
  ) -> [Float] {
    let precomputed = doubleArray(frame["cameraIntrinsic3x3"])
    if precomputed.count == 9 {
      return precomputed.map { Float($0) }
    }
    let values = doubleArray(frame["intrinsics"])
    let originalWidth = Double(intValue(frame["imageWidth"]) ?? spec.inputWidth)
    let originalHeight = Double(intValue(frame["imageHeight"]) ?? spec.inputHeight)
    let sx = Double(spec.inputWidth) / max(originalWidth, 1.0)
    let sy = Double(spec.inputHeight) / max(originalHeight, 1.0)
    if values.count == 9 {
      return [
        Float(values[0] * sx), Float(values[1]), Float(values[2] * sx),
        Float(values[3]), Float(values[4] * sy), Float(values[5] * sy),
        Float(values[6]), Float(values[7]), Float(values[8]),
      ]
    }
    if values.count >= 4 {
      return [
        Float(values[0] * sx), 0, Float(values[2] * sx),
        0, Float(values[1] * sy), Float(values[3] * sy),
        0, 0, 1,
      ]
    }
    return [
      Float(spec.inputWidth), 0, Float(spec.inputWidth) * 0.5,
      0, Float(spec.inputHeight), Float(spec.inputHeight) * 0.5,
      0, 0, 1,
    ]
  }

  private struct FloatStats {
    let median: Float
    let mean: Float
    let min: Float
    let max: Float
  }

  private static func stats(_ values: [Float]) -> FloatStats {
    guard !values.isEmpty else {
      return FloatStats(median: 1, mean: 1, min: 1, max: 1)
    }
    var minValue = Float.greatestFiniteMagnitude
    var maxValue = -Float.greatestFiniteMagnitude
    var sum: Double = 0
    for value in values {
      if value < minValue { minValue = value }
      if value > maxValue { maxValue = value }
      sum += Double(value)
    }
    let sorted = values.sorted()
    return FloatStats(
      median: sorted[sorted.count / 2],
      mean: Float(sum / Double(values.count)),
      min: minValue,
      max: maxValue
    )
  }

  private static func multiArrayToFloatBuffer(_ array: MLMultiArray) throws -> [Float] {
    let shape = array.shape.map { $0.intValue }
    let strides = array.strides.map { $0.intValue }
    let count = shape.reduce(1) { $0 * max(0, $1) }
    guard count == array.count else {
      throw validationError(
        "MLMultiArray logical count mismatch shape=\(shape) count=\(array.count)"
      )
    }
    let compactStrides = Self.compactRowMajorStrides(shape)
    if strides != compactStrides {
      return try Self.stridedMultiArrayToFloatBuffer(
        array,
        shape: shape,
        strides: strides,
        compactStrides: compactStrides,
        count: count
      )
    }

    var out = [Float](repeating: 0, count: count)
    switch array.dataType.rawValue {
    case 0x10020:
      let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: count)
      for i in 0..<count { out[i] = ptr[i] }
    case 0x10010:
      guard #available(iOS 14.0, *) else {
        throw validationError("float16 MLMultiArray conversion requires iOS 14+")
      }
      var src = vImage_Buffer(
        data: array.dataPointer,
        height: 1,
        width: UInt(count),
        rowBytes: count * 2
      )
      out.withUnsafeMutableBufferPointer { dst in
        var dest = vImage_Buffer(
          data: UnsafeMutableRawPointer(dst.baseAddress!),
          height: 1,
          width: UInt(count),
          rowBytes: count * 4
        )
        _ = vImageConvert_Planar16FtoPlanarF(&src, &dest, 0)
      }
    case 0x10040:
      let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: count)
      for i in 0..<count { out[i] = Float(ptr[i]) }
    default:
      throw validationError("unsupported MLMultiArray dtype raw=\(array.dataType.rawValue)")
    }
    return out
  }

  private static func compactRowMajorStrides(_ shape: [Int]) -> [Int] {
    guard !shape.isEmpty else { return [] }
    var strides = [Int](repeating: 1, count: shape.count)
    if shape.count >= 2 {
      for i in stride(from: shape.count - 2, through: 0, by: -1) {
        strides[i] = strides[i + 1] * max(1, shape[i + 1])
      }
    }
    return strides
  }

  private static func stridedMultiArrayToFloatBuffer(
    _ array: MLMultiArray,
    shape: [Int],
    strides: [Int],
    compactStrides: [Int],
    count: Int
  ) throws -> [Float] {
    guard shape.count == strides.count,
          shape.count == compactStrides.count else {
      throw validationError(
        "MLMultiArray shape/stride rank mismatch shape=\(shape) strides=\(strides)"
      )
    }
    var out = [Float](repeating: 0, count: count)
    let storageCapacity = Self.storageElementCapacity(shape: shape, strides: strides)

    switch array.dataType.rawValue {
    case 0x10020:
      let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: storageCapacity)
      Self.copyStridedFloatArray(
        shape: shape,
        strides: strides,
        compactStrides: compactStrides,
        out: &out
      ) { storageOffset in
        ptr[storageOffset]
      }
    case 0x10010:
      guard #available(iOS 14.0, *) else {
        throw validationError("float16 MLMultiArray conversion requires iOS 14+")
      }
      let ptr = array.dataPointer.bindMemory(to: Float16.self, capacity: storageCapacity)
      Self.copyStridedFloatArray(
        shape: shape,
        strides: strides,
        compactStrides: compactStrides,
        out: &out
      ) { storageOffset in
        Float(ptr[storageOffset])
      }
    case 0x10040:
      let ptr = array.dataPointer.bindMemory(to: Double.self, capacity: storageCapacity)
      Self.copyStridedFloatArray(
        shape: shape,
        strides: strides,
        compactStrides: compactStrides,
        out: &out
      ) { storageOffset in
        Float(ptr[storageOffset])
      }
    default:
      throw validationError("unsupported MLMultiArray dtype raw=\(array.dataType.rawValue)")
    }
    return out
  }

  private static func storageElementCapacity(shape: [Int], strides: [Int]) -> Int {
    guard shape.count == strides.count else { return 0 }
    var maxOffset = 0
    for i in 0..<shape.count {
      maxOffset += max(0, shape[i] - 1) * strides[i]
    }
    return maxOffset + 1
  }

  private static func copyStridedFloatArray(
    shape: [Int],
    strides: [Int],
    compactStrides: [Int],
    out: inout [Float],
    read: (Int) -> Float
  ) {
    guard !shape.isEmpty else { return }
    func walk(_ dim: Int, _ logicalOffset: Int, _ storageOffset: Int) {
      if dim == shape.count {
        out[logicalOffset] = read(storageOffset)
        return
      }
      let n = shape[dim]
      let logicalStep = compactStrides[dim]
      let storageStep = strides[dim]
      for i in 0..<n {
        walk(
          dim + 1,
          logicalOffset + i * logicalStep,
          storageOffset + i * storageStep
        )
      }
    }
    walk(0, 0, 0)
  }

  private static func writeFloats(_ values: [Float], to url: URL) throws {
    let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
    try data.write(to: url, options: .atomic)
  }

  private static func residentMemoryMB() -> Double? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          rebound,
          &count
        )
      }
    }
    guard result == KERN_SUCCESS else { return nil }
    return Double(info.resident_size) / 1024.0 / 1024.0
  }

  private static func jetsamAvailableMemoryMB() -> Double? {
    #if os(iOS)
    return Double(os_proc_available_memory()) / 1024.0 / 1024.0
    #else
    return nil
    #endif
  }

  private static func systemSnapshot() -> [String: Any] {
    let processInfo = ProcessInfo.processInfo
    return [
      "rssMB": residentMemoryMB() as Any,
      "jetsamAvailableMB": jetsamAvailableMemoryMB() as Any,
      "thermalState": thermalStateString(processInfo.thermalState),
      "thermalStateRaw": processInfo.thermalState.rawValue,
      "lowPowerModeEnabled": processInfo.isLowPowerModeEnabled,
      "processorCount": processInfo.processorCount,
      "activeProcessorCount": processInfo.activeProcessorCount,
      "physicalMemoryMB": Double(processInfo.physicalMemory) / 1024.0 / 1024.0,
      "applicationState": applicationStateString(),
    ]
  }

  private static func thermalStateString(_ state: ProcessInfo.ThermalState) -> String {
    switch state {
    case .nominal:
      return "nominal"
    case .fair:
      return "fair"
    case .serious:
      return "serious"
    case .critical:
      return "critical"
    @unknown default:
      return "unknown_\(state.rawValue)"
    }
  }

  private static func applicationStateString() -> String {
    // UIApplication.applicationState is main-thread-only; this runs on
    // the plugin's CoreML dispatch queue (probe path) — hop to main.
    let read: () -> String = {
      switch UIApplication.shared.applicationState {
      case .active:
        return "active"
      case .inactive:
        return "inactive"
      case .background:
        return "background"
      @unknown default:
        return "unknown_\(UIApplication.shared.applicationState.rawValue)"
      }
    }
    if Thread.isMainThread { return read() }
    return DispatchQueue.main.sync(execute: read)
  }

  private static func processCpuOneCorePercent() -> Double {
    var threadList: thread_act_array_t?
    var threadCount = mach_msg_type_number_t(0)
    let threadsResult = task_threads(
      mach_task_self_,
      &threadList,
      &threadCount
    )
    guard threadsResult == KERN_SUCCESS, let threadList else {
      return 0.0
    }
    defer {
      vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threadList)),
        vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.stride)
      )
    }

    var total = 0.0
    for i in 0..<Int(threadCount) {
      var info = thread_basic_info()
      var count = mach_msg_type_number_t(THREAD_INFO_MAX)
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
          thread_info(
            threadList[i],
            thread_flavor_t(THREAD_BASIC_INFO),
            rebound,
            &count
          )
        }
      }
      guard result == KERN_SUCCESS else { continue }
      if (info.flags & TH_FLAGS_IDLE) == 0 {
        total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
      }
    }
    return total
  }

  private static func runtimeSpec(
    model: [String: Any],
    inputSizePolicy: [String: Any]
  ) throws -> RuntimeSpec {
    let id = try requiredString(model["id"], "model.id")
    let license = try requiredString(model["license"], "model.license")
    let resourceName = try requiredString(model["resourceName"], "model.resourceName")
    let inputContract = stringValue(model["da3InputContract"]) ??
      (resourceName.lowercased().hasSuffix("_pose")
        ? "pose_conditioned_coreml_requires_image_extrinsics_intrinsics"
        : "image_only")
    let commercialSafe = boolValue(model["commercialSafe"]) ?? true
    let windowSize = intValue(model["windowSize"]) ?? 0
    let inputWidth = intValue(model["inputWidth"]) ?? 0
    let inputHeight = intValue(model["inputHeight"]) ?? 0

    guard id == "DA3-BASE",
          license.lowercased() == "apache-2.0",
          commercialSafe else {
      throw validationError("Da3DepthPlugin accepts only commercial-safe DA3-BASE")
    }
    let upperResource = resourceName.uppercased()
    guard supportedResourceNames.contains(resourceName),
          !upperResource.contains("DA3LARGE"),
          !upperResource.contains("GIANT"),
          !upperResource.contains("NESTED") else {
      throw validationError("unsupported DA3 model resource: \(resourceName)")
    }
    // Bidirectional resource↔contract validation (ported from the
    // bench plugin where the pose path was first productionized).
    let isPoseResource = resourceName.lowercased().hasSuffix("_pose")
    if isPoseResource {
      guard inputContract.lowercased().contains("pose_conditioned") else {
        throw validationError(
          "pose-conditioned DA3 resource requires da3InputContract=pose_conditioned"
        )
      }
    } else {
      guard inputContract.lowercased() == "image_only" else {
        throw validationError(
          "official image-only DA3 resource requires da3InputContract=image_only"
        )
      }
    }
    guard windowSize > 0, inputWidth > 0, inputHeight > 0 else {
      throw validationError("model must include windowSize/inputWidth/inputHeight from Flutter policy")
    }
    guard boolValue(inputSizePolicy["locked"]) == true,
          intValue(inputSizePolicy["width"]) == inputWidth,
          intValue(inputSizePolicy["height"]) == inputHeight else {
      throw validationError("inputSizePolicy must match Flutter model spec \(inputWidth)x\(inputHeight)")
    }
    return RuntimeSpec(
      resourceName: resourceName,
      windowSize: windowSize,
      inputHeight: inputHeight,
      inputWidth: inputWidth,
      inputContract: inputContract
    )
  }

  private static func sanitize(_ value: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return value.unicodeScalars
      .map { allowed.contains($0) ? String($0) : "_" }
      .joined()
  }

  private static func requiredString(_ value: Any?, _ field: String) throws -> String {
    if let value = value as? String, !value.isEmpty { return value }
    throw validationError("missing string field \(field)")
  }

  private static func requiredMap(_ value: Any?, _ field: String) throws -> [String: Any] {
    if let value = value as? [String: Any] { return value }
    if let value = value as? [AnyHashable: Any] {
      var out: [String: Any] = [:]
      for (key, val) in value { out["\(key)"] = val }
      return out
    }
    throw validationError("missing map field \(field)")
  }

  private static func requiredMapArray(_ value: Any?, _ field: String) throws -> [[String: Any]] {
    if let value = value as? [[String: Any]] { return value }
    if let value = value as? [Any] {
      var out: [[String: Any]] = []
      for item in value {
        guard let map = item as? [String: Any] else {
          throw validationError("list field \(field) must contain map items")
        }
        out.append(map)
      }
      return out
    }
    throw validationError("missing list field \(field)")
  }

  private static func doubleArray(_ value: Any?) -> [Double] {
    guard let list = value as? [Any] else { return [] }
    return list.compactMap { item in
      if let number = item as? NSNumber { return number.doubleValue }
      if let value = item as? Double { return value }
      if let value = item as? Float { return Double(value) }
      return nil
    }
  }

  private static func boolValue(_ value: Any?) -> Bool? {
    if let value = value as? Bool { return value }
    if let value = value as? NSNumber { return value.boolValue }
    return nil
  }

  private static func stringValue(_ value: Any?) -> String? {
    guard let value else { return nil }
    let text = "\(value)"
    return text.isEmpty ? nil : text
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }

  private static func validationError(_ message: String) -> NSError {
    NSError(
      domain: "Da3DepthPlugin",
      code: 1,
      userInfo: [NSLocalizedDescriptionKey: message]
    )
  }
}
