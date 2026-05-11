import ARKit
@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Flutter
import Foundation
import UIKit

// AetherARKit — in-Runner-binary ARKit bridge.
//
// What it exposes:
//   MethodChannel `aether_arkit`
//     • `isAvailable`  → Bool. Whether the device supports
//                        ARWorldTrackingConfiguration. False on iPad
//                        Air 1, iPhone 6 and earlier; true on every
//                        device PocketWorld targets in practice.
//     • `startSession` → Void. Spins up a new ARSession (or restarts
//                        an existing one). Idempotent.
//     • `stopSession`  → Void. Pauses the session and tears down the
//                        delegate.
//     • `lockOrigin`   → {azimuth: Float}. Captures the camera's
//                        current pose as the world reference. The
//                        session keeps running afterwards; subsequent
//                        pose events carry world-relative
//                        position/orientation. Verbatim of
//                        ObjectModeV2ARDomeCoordinator.lockAtCameraForward
//                        with distance=0.5 m.
//
//   EventChannel `aether_arkit/pose_stream` → JSON dictionary per
//     ARFrame:
//       {
//         "tx", "ty", "tz"           — camera position in world space
//         "qx", "qy", "qz", "qw"     — camera orientation (unit quat)
//         "extrinsic"                — column-major 16-float 4×4
//         "intrinsicFxFyCxCy"        — 4 floats
//         "isTracking"               — true iff trackingState == .normal
//         "trackingStateName"        — "normal" | "not_available" |
//                                      "limited_initializing" |
//                                      "limited_relocalizing" |
//                                      "limited_excessive_motion" |
//                                      "limited_insufficient_features" |
//                                      "limited_unknown". Mirrors
//                                      ARCamera.TrackingState exactly so
//                                      Tier 1 pose-drift aggregation on
//                                      the Dart side can attribute the
//                                      degraded windows to a root cause.
//         "t"                        — ARFrame timestamp (CACurrentMediaTime)
//       }
//
// Why this lives in the Runner target rather than as a pub plugin:
//   Same reason as AetherPrefsPlugin — keeping AR-specific Swift
//   code inside the app binary avoids the iOS 26 plugin-registrar
//   metadata race that bit shared_preferences. ARKit is a small
//   surface anyway; a plugin would be overkill.
//
// Cross-platform note: this is the iOS-only path. Android (ARCore)
// will register an identically-named MethodChannel from MainActivity
// when the android/ scaffold lands. PlatformARPoseProvider on Dart
// side falls back to MockARPoseProvider when neither is registered
// (e.g. simulator, web, HarmonyOS today).

@available(iOS 11.0, *)
class AetherARKitPlugin: NSObject {
  // MARK: Singleton wiring

  private static var sharedInstance: AetherARKitPlugin?

  /// Used by AetherARKitPreviewFactory so the platform view's ARSCNView
  /// can attach to the SAME ARSession the plugin owns — match iOS's
  /// "single ARSession backs both preview and recorder" architecture
  /// from ObjectModeV2ARCaptureCoordinator.
  static func currentSession() -> ARSession? {
    return sharedInstance?.arSession
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = AetherARKitPlugin(messenger: registrar.messenger())
    sharedInstance = plugin
    let factory = AetherARKitPreviewFactory(getSession: {
      AetherARKitPlugin.currentSession()
    })
    registrar.register(factory, withId: "aether_arkit_preview")
  }

  // MARK: Channels

  private let methodChannel: FlutterMethodChannel
  private let poseEventChannel: FlutterEventChannel
  private let poseStreamHandler = PoseStreamHandler()

  // MARK: ARKit state

  private var arSession: ARSession?
  private let sessionDelegate = ARSessionForwarder()

  /// `worldOrigin` is the user-locked center of the captured object,
  /// recomputed every broadcast frame from `worldSubjectAnchor.transform`.
  /// `worldYaw` is the camera's bearing at lock time. Subsequent frames'
  /// azimuth = atan2(rel.z, rel.x) − worldYaw, so the dome's az = 0
  /// always corresponds to "where the user was standing at lock".
  private var worldOrigin: simd_float3?
  private var worldYaw: Float = 0

  /// The named `ARAnchor` we install at the locked origin point.
  /// ARKit's contract: this is a fixed real-world point; ARKit tracks
  /// it across world-frame re-alignments (limited→normal recovery,
  /// loop closure) and updates its `transform` accordingly. Reading
  /// the anchor's transform every broadcast frame keeps `worldOrigin`
  /// glued to the real-world point the user locked, regardless of
  /// internal SLAM corrections. WWDC 2018 §610 + Polycam polyform
  /// pattern. We trust ARKit's updates unconditionally; an earlier
  /// 0.5 m drift-rejection threshold got stuck rejecting forever once
  /// ARKit issued a real >0.5 m correction.
  private var worldSubjectAnchor: ARAnchor?

  /// Snapshot of `worldOrigin` at lockOrigin time, kept for the 1 Hz
  /// drift diagnostic in `broadcast`. `simd_distance(currentOrigin,
  /// lockTimeOrigin)` tells us how far ARKit has internally moved the
  /// anchor since we placed it — small drift is normal SLAM refinement,
  /// metres-scale drift means the anchor sits in a feature-poor region
  /// (mid-air with no nearby texture).
  private var lockTimeOrigin: simd_float3?
  private var lastDriftLogTime: TimeInterval = 0

  /// Last time we computed image-quality metrics from an ARFrame. iOS
  /// `ObjectModeV2ARDomeCoordinator.sampleInterval = 1.0 / 6.0` — we
  /// only run Laplacian + brightness + signature at 6 Hz to keep CPU
  /// cost bounded.
  private var lastQualityComputeTime: TimeInterval = 0
  private static let qualityInterval: TimeInterval = 1.0 / 6.0

  /// Serial background queue for the Laplacian / signature compute.
  /// Why: ARSession delivers delegate callbacks on the main thread.
  /// Quality compute on a 1920×1440 pixel buffer was running 5-15 ms
  /// per call at 6 Hz, which combined with Flutter UI work pushed the
  /// per-frame budget over 16 ms. ARKit then queued up 13+ ARFrames
  /// waiting for the delegate, hit its pool limit, and started
  /// dropping/warning. Moving compute to a background queue gets the
  /// per-frame main-thread work down to ~2 ms.
  private let qualityQueue = DispatchQueue(
    label: "com.pocketworld.arkit.quality",
    qos: .userInitiated
  )
  /// Latest 128×128 grayscale Y-plane thumbnail from the background
  /// extract. Read & cleared only on the main thread (ARKit delegate
  /// queue) inside `broadcast`, so no lock needed. Stale by 1-3
  /// ARFrames (~17-50 ms) which is well under the 167 ms qualityInterval.
  ///
  /// All the actual metrics (Laplacian variance, brightness, signature)
  /// derive from this thumbnail in pure Dart — see
  /// lib/quality/quality_compute.dart. Native's job is now ONLY plane
  /// extract + downsample; everything past that is shared code across
  /// the 4 target platforms.
  private var pendingGray128: Data?
  /// True iff a quality compute is already in flight; used to skip
  /// firing another one before the previous finishes (defensive — the
  /// timer-based throttle should already prevent overlap, but guards
  /// against pathological CPU stalls where compute > interval).
  private var qualityComputeInFlight: Bool = false

  // ── Diagnostic counters for the off-main-thread quality compute.
  // Aggregated and printed once per 5-second window so we can confirm:
  //   • compute is firing at the expected ~6 Hz (30 per 5s)
  //   • avg elapsed_ms is well under 16 ms (otherwise our budget is
  //     gone again the moment we hop back to main)
  //   • skips=0 (defensive guard never triggers under normal load)
  //   • attached:fires ratio close to 1.0 (quality result actually
  //     reaches the pose payload, isn't getting stranded)
  private var qDiagWindowStart: TimeInterval = 0
  private var qDiagFires: Int = 0
  private var qDiagSkips: Int = 0
  private var qDiagElapsedMsSum: Double = 0
  private var qDiagAttached: Int = 0
  private var qDiagPoseEvents: Int = 0

  // MARK: Recording (verbatim port of ObjectModeV2ARCaptureCoordinator)

  /// Serial off-main queue for ALL AVAssetWriter operations — both
  /// the per-frame `adaptor.append(...)` (Phase 6.4f.8) and the
  /// `finishWriting` epilogue. Keeping append off main fixes the
  /// 2-3 s UI freeze + ARFrame retention spike that fired right after
  /// `startRecording` returned (encoder warm-up cost was eating main
  /// thread cycles + starving ARSessionDelegate).
  private let writerQueue = DispatchQueue(
    label: "com.pocketworld.arkit.writer",
    qos: .userInitiated
  )
  private var writer: AVAssetWriter?
  private var writerInput: AVAssetWriterInput?
  private var writerAdaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var startPTS: CMTime?
  private var recordedFrameCount: Int = 0
  private var recordingOutputURL: URL?
  private var isRecording: Bool = false

  // MARK: Init

  private init(messenger: FlutterBinaryMessenger) {
    self.methodChannel = FlutterMethodChannel(
      name: "aether_arkit",
      binaryMessenger: messenger
    )
    self.poseEventChannel = FlutterEventChannel(
      name: "aether_arkit/pose_stream",
      binaryMessenger: messenger
    )
    super.init()
    methodChannel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    poseEventChannel.setStreamHandler(poseStreamHandler)
    sessionDelegate.onFrame = { [weak self] frame in
      self?.broadcast(frame: frame)
    }
  }

  // MARK: MethodChannel handler

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "isAvailable":
      result(ARWorldTrackingConfiguration.isSupported)
    case "startSession":
      do {
        try startSession()
        result(nil)
      } catch {
        result(FlutterError(
          code: "ar_start_failed",
          message: error.localizedDescription,
          details: nil
        ))
      }
    case "stopSession":
      stopSession()
      result(nil)
    case "lockOrigin":
      let distance: Float
      if let args = call.arguments as? [String: Any],
         let d = (args["distanceMeters"] as? NSNumber)?.floatValue {
        distance = d
      } else {
        distance = 0.5
      }
      let lockResult = lockOrigin(distanceMeters: distance)
      if let payload = lockResult {
        result(payload)
      } else {
        result(FlutterError(
          code: "ar_no_frame",
          message: "ARSession has no current frame to lock against",
          details: nil
        ))
      }
    case "startRecording":
      startRecording { error in
        if let error = error {
          result(FlutterError(
            code: "ar_record_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(nil)
        }
      }
    case "stopRecording":
      stopRecording { payload, error in
        if let error = error {
          result(FlutterError(
            code: "ar_record_finish_failed",
            message: error.localizedDescription,
            details: nil
          ))
        } else {
          result(payload)
        }
      }
    case "requestSamFrame":
      // On-demand snapshot of the latest ARFrame.capturedImage,
      // YUV→RGBA downsampled to a square. Used by the Dart-side
      // MobileSAM 5 Hz loop in CaptureSession. We do NOT push
      // frames over the EventChannel because:
      //   • A 1024×1024×4 = 4 MB blob at 5 Hz = 20 MB/s of
      //     channel chatter even when SAM isn't running.
      //   • The Dart caller already polls on a Timer; pull-based
      //     means it can throttle without us shipping unwanted
      //     bytes.
      // Default 1024 = MobileSAM's training input resolution
      // (ResizeLongestSide(1024)); see kRecommendedMaskSize in
      // lib/capture/sam/subject_mask_data.dart for the full
      // tradeoff math. Caller may override via args["size"];
      // valid range [64, 1024] (clamp on both ends — values
      // beyond 1024 get downsampled by SAM internally and
      // provide zero extra signal).
      let target: Int
      if let args = call.arguments as? [String: Any],
         let s = (args["size"] as? NSNumber)?.intValue, s > 0 {
        target = min(max(s, 64), 1024)
      } else {
        target = 1024
      }
      guard let frame = arSession?.currentFrame else {
        // No frame yet (session warming up). Return nil — caller
        // treats as "skip this tick".
        result(nil)
        return
      }
      let pixelBuffer = frame.capturedImage
      // Hop off main; YUV→RGBA on a 1920×1440 source costs ~5-8 ms
      // even with the fast nearest-neighbour downsample below.
      qualityQueue.async {
        let bytes = AetherARKitPlugin.captureRgbaSquare(
          pixelBuffer: pixelBuffer,
          target: target
        )
        DispatchQueue.main.async {
          if let data = bytes {
            result([
              "width": target,
              "height": target,
              "rgba": FlutterStandardTypedData(bytes: data),
            ])
          } else {
            result(nil)
          }
        }
      }
    case "getDeviceTier":
      // Reports device memory tier so the Dart side can decide whether
      // to start MobileSAM (HIGH only — LOW devices would OOM, see
      // project_pocketworld_device_tier.md memory). Single source of
      // truth for the 5 GB threshold lives in startSession() above
      // where the 4K AR videoFormat decision uses the same boundary.
      let physMemBytes = ProcessInfo.processInfo.physicalMemory
      let physMemGB = Double(physMemBytes) / (1024.0 * 1024.0 * 1024.0)
      let tier = physMemBytes >= 5_000_000_000 ? "high" : "low"
      result([
        "tier": tier,
        "physicalMemoryBytes": NSNumber(value: physMemBytes),
        "physicalMemoryGB": physMemGB,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Session lifecycle

  private func startSession() throws {
    NSLog("[AetherARKit] startSession() — isSupported=\(ARWorldTrackingConfiguration.isSupported)")
    guard ARWorldTrackingConfiguration.isSupported else {
      throw NSError(
        domain: "AetherARKit",
        code: -1,
        userInfo: [NSLocalizedDescriptionKey:
          "ARWorldTracking not supported on this device"]
      )
    }
    let configuration = ARWorldTrackingConfiguration()
    // Auto-focus matches the iOS Aether3D capture path. Important for
    // sharpness on close-up object scans (subject typically <1 m away).
    configuration.isAutoFocusEnabled = true
    // World alignment "gravity" — Y axis points up in world coords,
    // X/Z plane left arbitrary at session start. This matches the
    // iOS reference's az/el math which assumes Y-up.
    configuration.worldAlignment = .gravity
    // Horizontal plane detection — verbatim of
    // ObjectModeV2ARDomeCoordinator.swift line 165. We don't read
    // the detected planes ourselves, but turning detection ON gives
    // ARKit a much stronger signal for gravity alignment (it fits
    // the Y axis to detected floor/table normals). Without it, the
    // Y axis comes from accelerometer alone and can drift a few
    // degrees, which leaks into elevation = atan2(rel.y, horizDist)
    // and makes the dome look "tilted when phone is level".
    configuration.planeDetection = [.horizontal]

    // 4K capture when the device supports it AND has enough RAM headroom.
    //
    // Device-tier gating (added Phase 6.4f.x):
    //   • 4 GB RAM phones (iPhone 11, 12, 12 mini): system-default
    //     1920×1440. ProcessInfo.physicalMemory reports ~3.86 GB on
    //     these. 4K AR + 4K H.264 + ARSCNView + ARWorldTracking pushes
    //     them to ~2.1 GB phys_footprint, which is at the iOS foreground
    //     jetsam threshold (~1.7–2.0 GB on 4 GB devices, iOS 14+).
    //     Long captures (60s+) reliably hit OOM at 4K on these.
    //   • 6 GB+ RAM phones (iPhone 12 Pro+, 13+, 14+, 15+): 4K AR.
    //     ProcessInfo.physicalMemory reports ~5.78 GB on 6 GB devices,
    //     ~7.83 GB on 8 GB Pro variants. The 5 GB threshold cleanly
    //     separates the two tiers and is forward-compatible with any
    //     future memory bumps.
    //
    // This same threshold gates Task 3 Phase B (MobileSAM on-device
    // inference, +180 MB peak) — 4 GB devices stay SAM-disabled.
    //
    // iOS 16+ exposes `recommendedVideoFormatFor4KResolution` on
    // ARWorldTrackingConfiguration; nil-fallback to system default
    // is kept as a safety net even on 6 GB devices.
    //
    // Must be set BEFORE `session.run` — videoFormat changes after a
    // session is already running don't take effect. AVAssetWriter setup
    // below reads `configuration.videoFormat.imageResolution`, so picking
    // the format here automatically propagates the right pixel buffer
    // dimensions to the recording path.
    let physMemBytes = ProcessInfo.processInfo.physicalMemory
    let physMemGB = Double(physMemBytes) / (1024.0 * 1024.0 * 1024.0)
    let kFourKMemThresholdBytes: UInt64 = 5_000_000_000  // 5.0 GB
    let allow4K = physMemBytes >= kFourKMemThresholdBytes
    if #available(iOS 16.0, *), allow4K {
      if let fourK = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution {
        configuration.videoFormat = fourK
        NSLog("[AetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM), using 4K videoFormat: \(fourK.imageResolution) @ \(fourK.framesPerSecond) fps")
      } else {
        NSLog("[AetherARKit] device tier HIGH (\(String(format: "%.2f", physMemGB)) GB RAM) but recommendedVideoFormatFor4KResolution returned nil; using system default \(configuration.videoFormat.imageResolution)")
      }
    } else {
      let res = configuration.videoFormat.imageResolution
      NSLog("[AetherARKit] device tier LOW (\(String(format: "%.2f", physMemGB)) GB RAM), staying on default videoFormat \(res) to avoid 4K jetsam risk")
    }

    let session = arSession ?? ARSession()
    session.delegate = sessionDelegate
    // .resetTracking gives the user a clean reference frame each
    // start (previous lock origin invalidated). .removeExistingAnchors
    // is moot since we don't add any.
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    arSession = session
    worldOrigin = nil
    worldYaw = 0
    worldSubjectAnchor = nil
    lockTimeOrigin = nil
    lastDriftLogTime = 0
  }

  private func stopSession() {
    if isRecording {
      writerInput?.markAsFinished()
      writer?.cancelWriting()
      writer = nil
      writerInput = nil
      writerAdaptor = nil
      startPTS = nil
      recordingOutputURL = nil
      isRecording = false
    }
    if let anchor = worldSubjectAnchor {
      arSession?.remove(anchor: anchor)
    }
    arSession?.pause()
    worldOrigin = nil
    worldYaw = 0
    worldSubjectAnchor = nil
    lockTimeOrigin = nil
    lastDriftLogTime = 0
  }

  // MARK: Recording lifecycle (verbatim port of
  // ObjectModeV2ARCaptureCoordinator startRecording / stopRecording)

  /// Async because `AVAssetWriter(outputURL:fileType:)` + `startWriting()`
  /// take ~1-2 s on iPhone (H.264 hardware encoder pipeline init). Doing
  /// that on the main queue blocks the ARSessionDelegate (default queue
  /// is main) → ARFrames pile up → tracking quality collapses → the dome
  /// goes "frozen gray" for 1-2 s right after the user taps lock-subject.
  /// We split into:
  ///   • main-queue prologue: cheap nil-checks + filename gen + isRecording
  ///     dedup. Captured into a stable `url`.
  ///   • background queue: the heavy AVAssetWriter init/startWriting.
  ///   • main-queue epilogue: publish writer/input/adaptor/isRecording=true.
  ///     Same queue as broadcast(frame:) → no race against the per-frame
  ///     adaptor read.
  private func startRecording(completion: @escaping (Error?) -> Void) {
    dispatchPrecondition(condition: .onQueue(.main))
    guard arSession != nil else {
      completion(NSError(
        domain: "AetherARKit",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey:
          "AR session not started — call startSession first"]
      ))
      return
    }
    if isRecording {
      completion(nil)
      return
    }

    let url: URL
    do {
      url = try makeRecordingOutputURL()
    } catch {
      completion(error)
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      guard let self = self else {
        DispatchQueue.main.async {
          completion(NSError(
            domain: "AetherARKit",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey:
              "plugin released before recording started"]
          ))
        }
        return
      }

      let w: AVAssetWriter
      do {
        w = try AVAssetWriter(outputURL: url, fileType: .mov)
      } catch {
        DispatchQueue.main.async { completion(error) }
        return
      }
      // Resolve actual capture dimensions from the currently-running
      // ARKit session's videoFormat (set in startSession() above to 4K
      // when supported, default 1920×1440 otherwise). This is the only
      // way the recording path stays in sync with whatever videoFormat
      // ARKit ended up using — hardcoding here would silently throw
      // away pixels if 4K was selected but recorded at 1920×1440.
      let videoRes: CGSize = self.arSession?.configuration?.videoFormat.imageResolution
        ?? CGSize(width: 1920, height: 1440)
      let captureWidth = Int(videoRes.width)
      let captureHeight = Int(videoRes.height)
      NSLog("[AetherARKit] startRecording: pixel buffer dims = \(captureWidth)×\(captureHeight)")

      let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: captureWidth,
        AVVideoHeightKey: captureHeight,
      ]
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      // ARFrame.capturedImage dimensions = configuration.videoFormat.imageResolution
      // (landscape-native sensor orientation). On iPhone 11+ with iOS 16+:
      // typically 3840×2160 in 4K mode, falls back to 1920×1440 if the
      // device's recommendedVideoFormatFor4KResolution is nil. We record
      // portrait — so apply a +90° clockwise rotation transform on the
      // writer input. The pixel buffers stay landscape on disk, but .mov
      // metadata tells QuickTime / ffmpeg / video_thumbnail / any
      // downstream player to rotate +90° at playback. Without this:
      // (a) the thumbnail extracted by video_thumbnail comes out sideways,
      // (b) the viewer's playback shows the world rotated 90°, (c) the
      // server-side ffmpeg frame extractor pulls landscape frames into
      // VGGT, which still works but the user-facing artifacts (thumbnail,
      // any preview) look wrong.
      input.transform = CGAffineTransform(rotationAngle: .pi / 2)
      w.add(input)

      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String:
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
          kCVPixelBufferWidthKey as String: captureWidth,
          kCVPixelBufferHeightKey as String: captureHeight,
        ]
      )

      guard w.startWriting() else {
        let err = NSError(
          domain: "AetherARKit",
          code: 3,
          userInfo: [NSLocalizedDescriptionKey:
            "AVAssetWriter startWriting failed: \(w.error?.localizedDescription ?? "unknown")"]
        )
        DispatchQueue.main.async { completion(err) }
        return
      }
      w.startSession(atSourceTime: .zero)

      DispatchQueue.main.async {
        // Re-check on main queue — caller may have stopped in the
        // intervening ~1-2 s. If so, tear down what we just built and
        // bail without flipping isRecording.
        guard self.arSession != nil, !self.isRecording else {
          input.markAsFinished()
          w.cancelWriting()
          completion(NSError(
            domain: "AetherARKit",
            code: 7,
            userInfo: [NSLocalizedDescriptionKey:
              "session ended or already recording before setup completed"]
          ))
          return
        }
        self.writer = w
        self.writerInput = input
        self.writerAdaptor = adaptor
        self.startPTS = nil
        self.recordedFrameCount = 0
        self.recordingOutputURL = url
        self.isRecording = true
        NSLog("[AetherARKit] startRecording: writing to \(url.path)")
        completion(nil)
      }
    }
  }

  private func stopRecording(
    completion: @escaping ([String: Any]?, Error?) -> Void
  ) {
    guard isRecording, let url = recordingOutputURL,
          let input = writerInput, let w = writer
    else {
      completion(nil, NSError(
        domain: "AetherARKit",
        code: 4,
        userInfo: [NSLocalizedDescriptionKey: "Not currently recording"]
      ))
      return
    }
    isRecording = false
    let frameCount = recordedFrameCount

    writerQueue.async { [weak self] in
      input.markAsFinished()
      w.finishWriting {
        guard let self = self else {
          completion(nil, NSError(
            domain: "AetherARKit",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Plugin released mid-finish"]
          ))
          return
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let duration = TimeInterval(frameCount) / 30.0
        DispatchQueue.main.async {
          self.writer = nil
          self.writerInput = nil
          self.writerAdaptor = nil
          self.startPTS = nil
          self.recordingOutputURL = nil
          NSLog("[AetherARKit] stopRecording: \(url.path) frames=\(frameCount) size=\(size)")
          completion([
            "fileURL": url.path,
            "duration": duration,
            "fileSize": size,
          ], nil)
        }
      }
    }
  }

  private func makeRecordingOutputURL() throws -> URL {
    let base = FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PocketWorldCaptures", isDirectory: true)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: true
    )
    return base.appendingPathComponent("\(UUID().uuidString.lowercased()).mov")
  }

  // MARK: Lock origin (verbatim port of lockAtCameraForward)

  /// Places the world origin at `distanceMeters` ahead of the camera's
  /// current optical axis, captures the camera's bearing as worldYaw.
  /// Returns the dictionary that becomes the Dart-side response.
  /// The phone-orientation classification (portrait vs landscape) is
  /// done on the Dart side by `PhoneOrientationClassifier` so the
  /// algorithm stays cross-platform.
  ///
  /// Returns nil when ARKit's tracking state hasn't reached `.normal`
  /// — the first few ARFrames typically arrive under `.notAvailable`
  /// / `.limited` with an identity-ish transform, and locking against
  /// one of those produces a bogus origin / worldYaw. The Dart-side
  /// retry loop in `CaptureSession._lockOriginWhenReady` keeps
  /// polling every 100 ms until tracking stabilises.
  private func lockOrigin(distanceMeters: Float) -> [String: Any]? {
    guard let frame = arSession?.currentFrame else {
      NSLog("[AetherARKit] lockOrigin: no currentFrame yet")
      return nil
    }
    switch frame.camera.trackingState {
    case .normal:
      break
    case .limited(let reason):
      NSLog("[AetherARKit] lockOrigin: tracking is .limited(\(reason)) — retrying")
      return nil
    case .notAvailable:
      NSLog("[AetherARKit] lockOrigin: tracking .notAvailable — retrying")
      return nil
    @unknown default:
      NSLog("[AetherARKit] lockOrigin: unknown trackingState — retrying")
      return nil
    }
    let t = frame.camera.transform
    let camPos = simd_float3(t.columns.3.x, t.columns.3.y, t.columns.3.z)
    // Forward = camera's optical axis (-Z column of the camera
    // transform). Lock targets whatever's at the center of the screen.
    // Y component is preserved on purpose: lock-time tilt is what makes
    // "shoot the object from 45° above → dome shows the +45° cell"
    // work without any extra orientation math.
    let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)

    // Pick the lock POSITION via a tiered raycast strategy:
    //
    //   1. `.estimatedPlane / .any` — ARKit fits a virtual plane to
    //      nearby feature points along the gaze direction, regardless
    //      of orientation. Hits upright surfaces (a paper bag's side,
    //      a chair's back, a figurine) where no detected horizontal
    //      plane exists. This is what fixes the "depth wrong" symptom
    //      where `.existingPlaneInfinite, .horizontal` silently
    //      sailed past the subject and hit the floor 0.47 m in front
    //      of the user instead of the actual subject.
    //   2. `.existingPlaneInfinite, .horizontal` — fallback for the
    //      case where ARKit hasn't accumulated enough feature points
    //      to estimate a plane yet, but has detected a real horizontal
    //      surface. Same behavior as before.
    //   3. forward × distanceMeters — final mid-air fallback if
    //      neither raycast lands.
    //
    // Cap=2.5 m: subjects beyond that are usually mis-aimed (raycast
    // sails past intended subject); fall back to forward × distance
    // so the anchor stays close enough to ARKit's feature cloud for
    // stable tracking.
    let subjectAnchorMaxRange: Float = 2.5
    var origin: simd_float3
    var positionSource: String
    if let session = arSession {
      var hits: [ARRaycastResult] = []
      var raycastSource: String = ""
      if #available(iOS 13.0, *) {
        let estimateQuery = ARRaycastQuery(
          origin: camPos,
          direction: simd_normalize(forward),
          allowing: .estimatedPlane,
          alignment: .any
        )
        hits = session.raycast(estimateQuery)
        if !hits.isEmpty { raycastSource = "estimated plane" }
      }
      if hits.isEmpty {
        let infQuery = ARRaycastQuery(
          origin: camPos,
          direction: simd_normalize(forward),
          allowing: .existingPlaneInfinite,
          alignment: .horizontal
        )
        hits = session.raycast(infQuery)
        if !hits.isEmpty { raycastSource = "existing horizontal plane" }
      }
      if let hit = hits.first {
        let hitPos = simd_float3(
          hit.worldTransform.columns.3.x,
          hit.worldTransform.columns.3.y,
          hit.worldTransform.columns.3.z
        )
        let hitDistance = simd_distance(camPos, hitPos)
        if hitDistance <= subjectAnchorMaxRange {
          origin = hitPos
          positionSource = "\(raycastSource) (\(String(format: "%.2f", hitDistance)) m)"
        } else {
          origin = camPos + simd_normalize(forward) * distanceMeters
          positionSource = "forward fallback (\(raycastSource) hit \(String(format: "%.2f", hitDistance)) m > cap \(subjectAnchorMaxRange) m)"
        }
      } else {
        origin = camPos + simd_normalize(forward) * distanceMeters
        positionSource = "forward fallback (no raycast hit)"
      }
    } else {
      origin = camPos + simd_normalize(forward) * distanceMeters
      positionSource = "forward fallback (no session)"
    }

    // Drop any previous subject anchor — a fresh lock means we're
    // starting over.
    if let oldAnchor = worldSubjectAnchor, let session = arSession {
      session.remove(anchor: oldAnchor)
      worldSubjectAnchor = nil
    }

    // Install a single named ARAnchor at the chosen origin. ARKit
    // tracks its transform across world-frame re-alignments;
    // broadcast() re-reads it every frame to update worldOrigin in
    // lock-step. WWDC 2018 §610 + Polycam polyform pattern — the
    // canonical ARKit-correct way to pin a real-world point.
    if let session = arSession {
      var transform = matrix_identity_float4x4
      transform.columns.3 = simd_float4(origin.x, origin.y, origin.z, 1)
      let anchor = ARAnchor(name: "pocketworld_subject_origin",
                            transform: transform)
      session.add(anchor: anchor)
      worldSubjectAnchor = anchor
    }

    // worldYaw = "camera's relative bearing at lock". Subsequent
    // frames' azimuth subtracts this so the dome's az=0 ↔ lock pose.
    let relInitial = camPos - origin
    let yaw = atan2(relInitial.z, relInitial.x)

    worldOrigin = origin
    worldYaw = yaw
    lockTimeOrigin = origin
    lastDriftLogTime = 0  // force first drift log on next broadcast

    NSLog("[AetherARKit] lockOrigin: SUCCESS via \(positionSource) at "
      + "(\(origin.x), \(origin.y), \(origin.z))")

    return [
      "originX": origin.x,
      "originY": origin.y,
      "originZ": origin.z,
      "worldYaw": yaw,
    ]
  }

  // MARK: Per-frame broadcast

  private func broadcast(frame: ARFrame) {
    // Verbatim of ObjectModeV2ARCaptureCoordinator.handle(_ frame:)
    // line 184-190 — append every frame unconditionally; the writer
    // input itself decides whether it's ready for more data.
    //
    // Phase 6.4f.8: dispatch the H.264 encoder append onto `writerQueue`
    // instead of running it inline on the ARSessionDelegate (= main)
    // queue. The first ~6-12 frames after `startWriting()` block 100-
    // 300 ms each while the hardware H.264 pipeline warms up. Doing
    // that on main starves the displayLink (UI freezes 2-3 s @ 2 fps)
    // AND backs up the ARSessionDelegate, which makes ARKit retain
    // 11+ ARFrames and roll trackingState back to limited(initializing).
    // Both visible in the 2026-05-04 capture log right after lockOrigin:
    //
    //   [AetherARKit] startRecording: writing to .../...mov
    //   [AetherTexture] 2.3 fps (frames=6, dt=2.595, totalRenderMs=0)
    //   ARSession: The delegate of ARSession is retaining 11 ARFrames
    //   ARSession: ... retaining 12 ARFrames
    //   ARSession: ... retaining 13 ARFrames
    //   ARWorldTrackingTechnique: ... resource constraints [33]
    //
    // CVPixelBuffer is a CF refcounted type, so capturing
    // `frame.capturedImage` in the closure auto-retains it; the encoder
    // releases on completion. PTS is computed on main first to keep
    // monotonic timing tied to ARFrame delivery cadence rather than
    // writerQueue dispatch latency.
    if isRecording, let adaptor = writerAdaptor,
       adaptor.assetWriterInput.isReadyForMoreMediaData {
      let now = CMTime(seconds: frame.timestamp, preferredTimescale: 600)
      if startPTS == nil { startPTS = now }
      let pts = CMTimeSubtract(now, startPTS ?? now)
      let pixelBuffer = frame.capturedImage  // retained by closure capture
      writerQueue.async {
        // Re-check on the writer queue: `isReadyForMoreMediaData` was
        // YES on the main thread when we dispatched, but H.264 hardware
        // back-pressure can flip it to NO before this closure runs
        // (we've seen the gap span 5-30 ms under thermal=serious load).
        // Calling `append` while NO throws NSInternalInconsistencyException
        // and crashes the writer queue. Drop the frame instead — the
        // dropped frame is invisible to the user (recording continues
        // at near-target fps), the crash isn't.
        guard adaptor.assetWriterInput.isReadyForMoreMediaData else { return }
        _ = adaptor.append(pixelBuffer, withPresentationTime: pts)
      }
      recordedFrameCount += 1
    }

    // ── Refresh worldOrigin from the subject anchor's latest transform.
    // ARKit re-aligns its world frame continuously (limited→normal
    // recovery, loop closure). Per WWDC 2018 §610 + Polycam polyform:
    // an `ARAnchor`'s transform is updated by ARKit in lock-step with
    // those re-alignments, so reading it every frame keeps `worldOrigin`
    // glued to the real-world point the user locked. We accept the
    // update unconditionally — an earlier 0.5 m drift-rejection
    // threshold got stuck rejecting forever once ARKit issued a real
    // multi-meter correction (no recovery once `diff(old, new)` stayed
    // above the cap; user-facing symptom: "白球还是会大跳去很远的地方").
    if let myAnchor = worldSubjectAnchor,
       let updatedAnchor = frame.anchors.first(
         where: { $0.identifier == myAnchor.identifier }
       ) {
      worldSubjectAnchor = updatedAnchor
      worldOrigin = simd_float3(
        updatedAnchor.transform.columns.3.x,
        updatedAnchor.transform.columns.3.y,
        updatedAnchor.transform.columns.3.z
      )
    }

    // Diagnostic: 1 Hz drift log against lock-time origin. Tells us
    // whether the anchor is sitting in a feature-rich region (drift
    // < 5 cm) or feature-poor mid-air (drift in metres).
    if let lockTime = lockTimeOrigin, let curr = worldOrigin {
      if frame.timestamp - lastDriftLogTime > 1.0 {
        let drift = simd_distance(curr, lockTime)
        NSLog(String(
          format: "[AetherARKit] anchor drift: %.3f m from lock origin "
            + "(curr=(%.3f, %.3f, %.3f) lock=(%.3f, %.3f, %.3f))",
          drift, curr.x, curr.y, curr.z,
          lockTime.x, lockTime.y, lockTime.z
        ))
        lastDriftLogTime = frame.timestamp
      }
    }

    let t = frame.camera.transform
    // Quaternion (x, y, z, w) from rotation submatrix.
    let q = simd_quaternion(t)

    let intrinsics = frame.camera.intrinsics

    let extrinsic: [Float] = [
      t.columns.0.x, t.columns.0.y, t.columns.0.z, t.columns.0.w,
      t.columns.1.x, t.columns.1.y, t.columns.1.z, t.columns.1.w,
      t.columns.2.x, t.columns.2.y, t.columns.2.z, t.columns.2.w,
      t.columns.3.x, t.columns.3.y, t.columns.3.z, t.columns.3.w,
    ]
    let intrinsicArr: [Float] = [
      intrinsics.columns.0.x, // fx
      intrinsics.columns.1.y, // fy
      intrinsics.columns.2.x, // cx
      intrinsics.columns.2.y, // cy
    ]

    let isTracking: Bool
    switch frame.camera.trackingState {
    case .normal: isTracking = true
    default: isTracking = false
    }
    let trackingStateName = Self.trackingStateString(frame.camera.trackingState)

    var payload: [String: Any] = [
      "tx": t.columns.3.x,
      "ty": t.columns.3.y,
      "tz": t.columns.3.z,
      "qx": q.imag.x,
      "qy": q.imag.y,
      "qz": q.imag.z,
      "qw": q.real,
      "extrinsic": extrinsic,
      "intrinsicFxFyCxCy": intrinsicArr,
      "isTracking": isTracking,
      "trackingStateName": trackingStateName,
      "t": frame.timestamp,
    ]

    // Throttled (6 Hz) frame-quality compute on the AR camera buffer.
    // iOS Aether3D uses AVFoundation pixel buffers from the camera
    // plugin path, but on Flutter we can't run AVCaptureSession
    // alongside ARWorldTrackingConfiguration without colliding for
    // exclusive camera access. So we tap ARFrame.capturedImage
    // directly here — same pattern iOS Aether3D uses on its AR-only
    // path (capture session reads the AR buffer too).
    //
    // Compute runs OFF the main thread (qualityQueue) so it doesn't
    // block ARKit's delegate callback chain. Result is cached in
    // `pendingQuality` and attached to the NEXT pose event (1-3
    // frames stale ≈ 17-50 ms, irrelevant for the 6 Hz sample rate).
    qDiagPoseEvents += 1
    if qDiagWindowStart == 0 { qDiagWindowStart = frame.timestamp }
    if frame.timestamp - lastQualityComputeTime >= Self.qualityInterval {
      if qualityComputeInFlight {
        // Defensive guard: previous compute hasn't finished yet (shouldn't
        // happen if compute < interval, but track for diagnostic visibility).
        qDiagSkips += 1
      } else {
        lastQualityComputeTime = frame.timestamp
        qualityComputeInFlight = true
        // Capture the pixel buffer (ARC retains the CVPixelBuffer; the
        // ARFrame itself is NOT captured, so ARKit's frame pool can
        // recycle the wrapping ARFrame as soon as broadcast returns).
        let pixelBuffer = frame.capturedImage
        let computeStart = CACurrentMediaTime()
        qualityQueue.async { [weak self] in
          let g = AetherARKitPlugin.extractGray128(pixelBuffer)
          let elapsedMs = (CACurrentMediaTime() - computeStart) * 1000
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.pendingGray128 = g
            self.qualityComputeInFlight = false
            self.qDiagFires += 1
            self.qDiagElapsedMsSum += elapsedMs
          }
        }
      }
    }
    // Attach the most-recent gray128 thumbnail (from a previous frame)
    // and clear so we don't repeat-send the same payload. Dart side
    // (platform_pose_provider.dart) re-derives sharpness / brightness /
    // signature from these 16 KB via lib/quality/quality_compute.dart.
    if let g = pendingGray128 {
      payload["q_grayW"] = AetherARKitPlugin.downsampleSide
      payload["q_grayH"] = AetherARKitPlugin.downsampleSide
      payload["q_gray128"] = FlutterStandardTypedData(bytes: g)
      pendingGray128 = nil
      qDiagAttached += 1
    }
    // 5s window aggregate log so we can sanity-check:
    //   • fires ≈ 30 per 5s (6 Hz × 5)
    //   • avgMs ≪ 16 (otherwise compute is starving the next frame)
    //   • skips=0 (compute always finishes before the next interval)
    //   • attached close to fires (every compute eventually reaches a payload)
    if frame.timestamp - qDiagWindowStart >= 5.0 {
      let avgMs = qDiagFires > 0 ? qDiagElapsedMsSum / Double(qDiagFires) : 0
      NSLog(String(
        format: "[AetherARKit] 5s quality: fires=%d skips=%d avgMs=%.1f attached=%d/%d",
        qDiagFires, qDiagSkips, avgMs, qDiagAttached, qDiagPoseEvents
      ))
      qDiagWindowStart = frame.timestamp
      qDiagFires = 0
      qDiagSkips = 0
      qDiagElapsedMsSum = 0
      qDiagAttached = 0
      qDiagPoseEvents = 0
    }
    // Include worldOrigin / worldYaw so the Dart side can do the
    // (rel = camPos - origin) math without a round-trip back into
    // ARKit. Always sent (zero before lock) so the schema is stable.
    if let origin = worldOrigin {
      payload["worldOriginX"] = origin.x
      payload["worldOriginY"] = origin.y
      payload["worldOriginZ"] = origin.z
      payload["worldYaw"] = worldYaw
      payload["hasOrigin"] = true
    } else {
      payload["worldOriginX"] = Float(0)
      payload["worldOriginY"] = Float(0)
      payload["worldOriginZ"] = Float(0)
      payload["worldYaw"] = Float(0)
      payload["hasOrigin"] = false
    }

    poseStreamHandler.send(payload)
  }
}

// MARK: - Frame quality compute (Y plane → Laplacian + signature)

@available(iOS 11.0, *)
extension AetherARKitPlugin {
  /// Side of the small grayscale signature embedded in each pose
  /// event for the GuidanceEngine's novelty / similarity check. 16² =
  /// 256 bytes — small enough for byte-by-byte comparison in Dart.
  static let signatureSide = 16
  /// Internal downsample side for Laplacian. iOS Aether3D's analyzer
  /// uses 128² for the same reason: low-pass enough to ignore sensor
  /// noise, high enough to preserve real edges.
  static let downsampleSide = 128

  // QualityReport struct removed: native no longer computes metrics.
  // All Laplacian / brightness / signature math lives in
  // lib/quality/quality_compute.dart, derived from the gray128 thumbnail
  // extracted by `extractGray128(_:)` below.

  /// Stringified `ARCamera.TrackingState` for the pose stream's
  /// `trackingStateName` field. Mirrors the enum 1:1 so the Dart side
  /// (PoseDriftTracker) can attribute degraded windows to a root cause
  /// without smuggling a Swift enum across the platform channel.
  ///
  /// `@unknown default` exists because Apple has added new
  /// `.limited(reason:)` cases between SDKs (e.g. relocalizing landed
  /// in iOS 11.3); falling through to "limited_unknown" is the
  /// forward-compatible behaviour rather than crashing.
  static func trackingStateString(_ state: ARCamera.TrackingState) -> String {
    switch state {
    case .normal:
      return "normal"
    case .notAvailable:
      return "not_available"
    case .limited(let reason):
      switch reason {
      case .initializing: return "limited_initializing"
      case .relocalizing: return "limited_relocalizing"
      case .excessiveMotion: return "limited_excessive_motion"
      case .insufficientFeatures: return "limited_insufficient_features"
      @unknown default: return "limited_unknown"
      }
    }
  }

  /// Shared CIContext for the SAM frame snapshot path. CIContext is
  /// expensive to create (~10ms cold-start, allocates Metal device +
  /// program cache), so we keep one alive for the lifetime of the
  /// process. CoreImage internally uses Metal/IOSurface and reuses
  /// pipeline state across `render(toBitmap:)` calls; per-frame cost
  /// is dominated by the YUV→RGB conversion shader + bilinear scale,
  /// typically 8–20 ms on iPhone 12 Pro+ for a 1024×1024 output.
  ///
  /// Thread-safety: CIContext.render is documented as thread-safe
  /// (see Apple's CIContext.h header). All callers run on
  /// `qualityQueue` (serial), so even if Apple's docs were wrong
  /// we'd still serialize accesses.
  private static let samCIContext: CIContext = {
    // High-quality color management adds ~30% latency for ARKit
    // YUV→RGB but doesn't change the SAM mask (SAM is colorspace-
    // agnostic at the binary mask level). Keep colorspace nil →
    // CoreImage auto-detects from CVPixelBuffer attachments.
    return CIContext(options: [
      .useSoftwareRenderer: false,  // force GPU
      .priorityRequestLow: true,    // don't compete with ARKit's
                                    // own GPU rendering for the
                                    // preview view
    ])
  }()

  /// Snapshot the current ARFrame's `capturedImage` (typically a
  /// 1920×1440 or 3840×2160 BiPlanar YUV CVPixelBuffer), convert to
  /// RGBA, and downsample bilinearly to (target × target). Used by
  /// the Dart-side `requestSamFrame` MethodChannel handler to feed
  /// MobileSAM at its native 1024×1024 input resolution.
  ///
  /// Why a square output: SAM expects ResizeLongestSide(1024) input
  /// with the short side zero-padded. Returning a square buffer
  /// already-padded keeps the Dart wrapper trivial — it can feed the
  /// bytes straight into the encoder ONNX without further reshape.
  ///
  /// We do NOT preserve the source aspect ratio. ARKit landscape
  /// frames are 4:3 (1920×1440) or 16:9 (3840×2160); both squashed
  /// to a square introduces vertical/horizontal stretch in SAM input.
  /// MobileSAM was trained on stretched-to-1024² ImageNet, so this
  /// matches its training distribution; the binary mask snaps back
  /// to a true square the worker upsamples NEAREST onto the original
  /// (non-square) JPEG, restoring the aspect.
  ///
  /// Returns nil if pixel buffer can't be wrapped as CIImage (would
  /// only happen for a corrupted ARFrame, which we've never seen in
  /// practice).
  static func captureRgbaSquare(
    pixelBuffer: CVPixelBuffer,
    target: Int
  ) -> Data? {
    let srcWidth = CVPixelBufferGetWidth(pixelBuffer)
    let srcHeight = CVPixelBufferGetHeight(pixelBuffer)
    guard srcWidth > 0, srcHeight > 0, target > 0 else {
      return nil
    }

    // CIImage(cvPixelBuffer:) accepts BiPlanar YUV directly and
    // CoreImage handles the YUV→RGB conversion lazily on render.
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)

    // Squash to (target, target) via affine scale. Independent X/Y
    // scales = stretch (matches MobileSAM's training preprocessing).
    let scaleX = CGFloat(target) / CGFloat(srcWidth)
    let scaleY = CGFloat(target) / CGFloat(srcHeight)
    let scaled = ciImage.transformed(
      by: CGAffineTransform(scaleX: scaleX, y: scaleY)
    )

    // Pre-allocate the destination RGBA8 byte buffer. CIContext.render
    // writes into this directly (no extra copy).
    var rgba = Data(count: target * target * 4)
    let rect = CGRect(x: 0, y: 0, width: target, height: target)

    rgba.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      guard let baseAddr = raw.baseAddress else { return }
      samCIContext.render(
        scaled,
        toBitmap: baseAddr,
        rowBytes: target * 4,
        bounds: rect,
        format: .RGBA8,
        colorSpace: CGColorSpaceCreateDeviceRGB()
      )
    }
    return rgba
  }

  /// Pull the Y (luma) plane out of a YUV CVPixelBuffer and nearest-
  /// neighbour downsample it to a 128×128 uint8 thumbnail.
  ///
  /// This is the new shape of what used to be `computeQuality` — the
  /// Laplacian-variance + brightness + signature math has moved to
  /// `lib/quality/quality_compute.dart` so it can run identically on
  /// iOS / Android / Web / HarmonyOS without four separate ports.
  /// Native still does the platform-specific plane extraction (only
  /// way to get at the YUV buffer) but everything past that lives in
  /// shared Dart.
  ///
  /// Cost: ~2-3 ms on iPhone 12 Pro (down from ~5-15 ms of the full
  /// pre-Dart-port quality compute). Returns nil only when the pixel
  /// buffer isn't one of the BiPlanar YUV variants ARKit normally
  /// produces — caller treats nil as "skip this quality tick".
  ///
  /// Output is exactly 128×128 = 16384 bytes, row-major, top-left
  /// origin, ready to ship across the platform channel as a single
  /// FlutterStandardTypedData blob.
  static func extractGray128(_ pixelBuffer: CVPixelBuffer) -> Data? {
    let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isYUV =
      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
      format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    guard isYUV else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

    let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let rowStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
    else { return nil }
    let src = baseAddr.assumingMemoryBound(to: UInt8.self)

    let tw = downsampleSide
    let th = downsampleSide
    var data = Data(count: tw * th)
    data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      let dst = raw.bindMemory(to: UInt8.self).baseAddress!
      // Fixed-point bilinear-step-and-pick (nearest-neighbour). Match
      // the math the previous Swift implementation used so the Dart
      // port's results are byte-identical with the old wire format
      // during the migration window.
      let sxFixed = (width << 16) / tw
      let syFixed = (height << 16) / th
      for dy in 0..<th {
        let srcY = (dy * syFixed) >> 16
        let srcRowOffset = srcY * rowStride
        let dstRowOffset = dy * tw
        for dx in 0..<tw {
          let srcX = (dx * sxFixed) >> 16
          dst[dstRowOffset + dx] = src[srcRowOffset + srcX]
        }
      }
    }
    return data
  }
}

// MARK: - EventChannel pose stream

@available(iOS 11.0, *)
private class PoseStreamHandler: NSObject, FlutterStreamHandler {
  private var sink: FlutterEventSink?

  func onListen(
    withArguments arguments: Any?,
    eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    self.sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.sink = nil
    return nil
  }

  func send(_ payload: [String: Any]) {
    // EventChannel sinks must be invoked on the main thread (Flutter
    // platform thread). ARSessionDelegate callbacks fire on a
    // dedicated AR queue, so dispatch.
    if Thread.isMainThread {
      sink?(payload)
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.sink?(payload)
      }
    }
  }
}

// MARK: - ARSessionDelegate forwarder
//
// We don't subclass ARSessionDelegate inside the plugin class because
// that pulls Objective-C inheritance into the Swift-only AetherARKitPlugin
// (would have to inherit NSObject + add @objc on every call). Cleaner
// to use a tiny forwarder.

@available(iOS 11.0, *)
private class ARSessionForwarder: NSObject, ARSessionDelegate {
  var onFrame: ((ARFrame) -> Void)?

  // Diagnostic state — log only on transitions, not every frame.
  private var loggedFirstFrame = false
  private var lastTrackingDescription: String = ""

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    if !loggedFirstFrame {
      loggedFirstFrame = true
      NSLog("[AetherARKit] first ARFrame received")
    }
    let desc: String
    switch frame.camera.trackingState {
    case .normal: desc = "normal"
    case .limited(let r): desc = "limited(\(r))"
    case .notAvailable: desc = "notAvailable"
    @unknown default: desc = "unknown"
    }
    if desc != lastTrackingDescription {
      lastTrackingDescription = desc
      NSLog("[AetherARKit] trackingState → \(desc)")
    }
    onFrame?(frame)
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    NSLog("[AetherARKit] ARSession failed: \(error.localizedDescription)")
  }

  func sessionWasInterrupted(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interrupted")
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    NSLog("[AetherARKit] ARSession interruption ended")
  }
}

// MARK: - ARKit preview platform view (verbatim port of
// ObjectModeV2ARKitPreview.swift — UIViewRepresentable → FlutterPlatformView).
//
// Defined in this file (rather than its own) so the Runner.xcodeproj
// pickup is automatic — the project only compiles files that are
// already listed in the project's PBXFileReference list, and adding
// new sources programmatically requires pbxproj surgery we'd rather
// avoid. AetherARKitPlugin.swift is already in the project; piggyback.

@available(iOS 11.0, *)
class AetherARKitPreviewFactory: NSObject, FlutterPlatformViewFactory {
  private let getSession: () -> ARSession?

  init(getSession: @escaping () -> ARSession?) {
    self.getSession = getSession
    super.init()
  }

  func create(
    withFrame frame: CGRect,
    viewIdentifier viewId: Int64,
    arguments args: Any?
  ) -> FlutterPlatformView {
    return AetherARKitPreviewView(frame: frame, getSession: getSession)
  }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    return FlutterStandardMessageCodec.sharedInstance()
  }
}

@available(iOS 11.0, *)
class AetherARKitPreviewView: NSObject, FlutterPlatformView, ARSCNViewDelegate {
  private let arscnView: ARSCNView
  private let getSession: () -> ARSession?
  private var pollTimer: Timer?

  // ── Subject marker (Remy-style locked-origin visualization) ────────
  //
  // Kept post-SAM-revert for ongoing validation: user wanted more
  // capture sessions before deciding whether the marker is signal or
  // noise. Mechanism: lockOrigin installs the named
  // `pocketworld_subject_origin` ARAnchor → ARKit fires
  // `renderer(_:didAdd:for:)` with an auto-managed SCNNode whose
  // transform tracks the anchor across ARKit world-frame
  // re-alignments. We attach a 3 cm white sphere as a CHILD of that
  // node — SceneKit hierarchy propagates ARKit's transform updates
  // automatically. WWDC 2018 §610 + Polycam polyform pattern.
  //
  // writesToDepthBuffer=false renders the sphere OVER any geometry —
  // diagnostic, not scene element. If the dot sits "behind" the
  // subject visually, the user sees that the lock missed.
  private static let subjectMarkerRadius: CGFloat = 0.03 // 3 cm
  private static let subjectAnchorName = "pocketworld_subject_origin"

  init(frame: CGRect, getSession: @escaping () -> ARSession?) {
    self.arscnView = ARSCNView(frame: frame)
    self.getSession = getSession
    super.init()
    arscnView.automaticallyUpdatesLighting = true
    arscnView.scene = SCNScene()         // empty scene — camera feed only
    arscnView.rendersContinuously = true
    arscnView.antialiasingMode = .none
    arscnView.delegate = self
    attachSessionIfReady()
  }

  func view() -> UIView {
    return arscnView
  }

  /// AetherARKitPlugin creates the ARSession lazily on `startSession`,
  /// which the Dart side does inside CaptureSession.attach(). The
  /// preview widget can be in the tree before attach() runs, so we
  /// poll briefly until the session shows up.
  ///
  /// We deliberately do NOT install `ARCoachingOverlayView` here —
  /// CapturePage's own "AR warmup" gate (1500 ms continuous
  /// trackingState == .normal before enabling the lock button) covers
  /// the same user-guidance role and is cross-platform (Android /
  /// HarmonyOS / Web each get the same widget). Polycam's UX runs
  /// effectively the same shape with their own widget — same path,
  /// our wrapper.
  private func attachSessionIfReady() {
    if let session = getSession() {
      arscnView.session = session
      NSLog("[AetherARKitPreview] attached to ARSession on first try")
      return
    }
    pollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.05, repeats: true
    ) { [weak self] timer in
      guard let self = self else {
        timer.invalidate()
        return
      }
      if let session = self.getSession() {
        self.arscnView.session = session
        NSLog("[AetherARKitPreview] attached to ARSession after poll")
        timer.invalidate()
        self.pollTimer = nil
      }
    }
  }

  // MARK: ARSCNViewDelegate

  /// Fires when ARKit adds an anchor to the session. ARSCNView creates
  /// the parent SCNNode for us; we attach a child sphere if this is OUR
  /// subject anchor (filtered by name to ignore plane anchors that
  /// `planeDetection = [.horizontal]` adds automatically).
  func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
    guard anchor.name == Self.subjectAnchorName else { return }
    let sphere = SCNSphere(radius: Self.subjectMarkerRadius)
    let material = SCNMaterial()
    material.diffuse.contents = UIColor.white
    material.lightingModel = .constant
    material.writesToDepthBuffer = false
    material.readsFromDepthBuffer = false
    material.isDoubleSided = true
    sphere.materials = [material]
    let markerNode = SCNNode(geometry: sphere)
    markerNode.renderingOrder = 100
    node.addChildNode(markerNode)
    NSLog("[AetherARKitPreview] subject marker attached as child of anchor node")
  }

  /// Fires when ARKit removes our anchor (re-lock or stopSession).
  /// SceneKit auto-removes child nodes when the parent goes — nothing
  /// to do, but log for visibility.
  func renderer(_ renderer: SCNSceneRenderer, didRemove node: SCNNode, for anchor: ARAnchor) {
    guard anchor.name == Self.subjectAnchorName else { return }
    NSLog("[AetherARKitPreview] subject anchor removed; marker went with it")
  }

  deinit {
    pollTimer?.invalidate()
  }
}
