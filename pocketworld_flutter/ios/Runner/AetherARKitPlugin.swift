import ARKit
@preconcurrency import AVFoundation
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

  /// `worldOrigin` is the user-locked center of the captured object.
  /// `worldYaw` is the camera's bearing at lock time. Subsequent frames'
  /// azimuth = atan2(rel.z, rel.x) − worldYaw, so the dome's az = 0
  /// always corresponds to "where the user was standing at lock".
  private var worldOrigin: simd_float3?
  private var worldYaw: Float = 0

  /// When `lockOrigin` succeeds via plane raycast, we keep a handle on
  /// the underlying ARPlaneAnchor + the offset of the hit point from
  /// the plane's center. Each broadcast frame we re-read the plane's
  /// latest transform (ARKit refines plane geometry continuously as
  /// it sees more of the scene) and recompute `worldOrigin = plane +
  /// offset`. This is what stops the world origin from drifting —
  /// Polycam-style anchored origin instead of the previous static
  /// camPos+forward*0.5 floating point. If raycast doesn't hit a
  /// plane (no horizontal surface visible yet), `worldPlaneAnchor`
  /// stays nil and the floating fallback is used (origin doesn't
  /// auto-correct, same as the previous behavior).
  private var worldPlaneAnchor: ARPlaneAnchor?
  private var worldOffsetFromAnchor: simd_float3 = simd_float3(0, 0, 0)

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
  /// Latest QualityReport from the background compute. Read & cleared
  /// only on the main thread (ARKit delegate queue) inside `broadcast`,
  /// so no lock needed. Stale by 1-3 ARFrames (~17-50 ms) which is
  /// well under the 167 ms qualityInterval.
  private var pendingQuality: QualityReport?
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

    let session = arSession ?? ARSession()
    session.delegate = sessionDelegate
    // .resetTracking gives the user a clean reference frame each
    // start (previous lock origin invalidated). .removeExistingAnchors
    // is moot since we don't add any.
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    arSession = session
    worldOrigin = nil
    worldYaw = 0
    worldPlaneAnchor = nil
    worldOffsetFromAnchor = simd_float3(0, 0, 0)
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
    arSession?.pause()
    worldOrigin = nil
    worldYaw = 0
    worldPlaneAnchor = nil
    worldOffsetFromAnchor = simd_float3(0, 0, 0)
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
      let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 1920,
        AVVideoHeightKey: 1440,
      ]
      let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
      input.expectsMediaDataInRealTime = true
      // ARFrame.capturedImage is always 1920×1440 landscape (sensor native
      // orientation), regardless of how the user is holding the phone. We
      // record portrait — so apply a +90° clockwise rotation transform on
      // the writer input. The pixel buffers stay landscape on disk, but
      // .mov metadata tells QuickTime / ffmpeg / video_thumbnail / any
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
          kCVPixelBufferWidthKey as String: 1920,
          kCVPixelBufferHeightKey as String: 1440,
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
    // Verbatim of ObjectModeV2ARDomeCoordinator.lockAtCameraForward
    // lines 300-307. Forward keeps its Y component on purpose: lock-
    // time tilt is what makes "shoot the object from 45° above → dome
    // shows the +45° cell" work without any extra orientation math.
    let forward = -simd_float3(t.columns.2.x, t.columns.2.y, t.columns.2.z)

    // ── Step 1: Try to anchor the origin to a horizontal plane that
    // ARKit has detected. Polycam-style — the plane's transform gets
    // refined by ARKit continuously as it sees more of the scene, and
    // we re-read the latest transform on every broadcast frame. This
    // is what stops the world origin from drifting (the earlier static
    // simd_float3 origin wasn't tracked by ARKit, so it visibly drifted
    // over a long capture, throwing off azimuth/elevation calculations).
    // If raycast misses (no plane visible yet),
    // fall through to the floating-origin fallback.
    var origin: simd_float3
    var anchorSource: String
    if let session = arSession {
      let raycastQuery = ARRaycastQuery(
        origin: camPos,
        direction: simd_normalize(forward),
        allowing: .existingPlaneInfinite,
        alignment: .horizontal
      )
      let hits = session.raycast(raycastQuery)
      if let hit = hits.first, let plane = hit.anchor as? ARPlaneAnchor {
        let hitPos = simd_float3(
          hit.worldTransform.columns.3.x,
          hit.worldTransform.columns.3.y,
          hit.worldTransform.columns.3.z
        )
        let planePos = simd_float3(
          plane.transform.columns.3.x,
          plane.transform.columns.3.y,
          plane.transform.columns.3.z
        )
        worldPlaneAnchor = plane
        worldOffsetFromAnchor = hitPos - planePos
        origin = hitPos
        anchorSource = "plane raycast (anchor=\(plane.identifier.uuidString.prefix(8)))"
      } else {
        worldPlaneAnchor = nil
        origin = camPos + simd_normalize(forward) * distanceMeters
        anchorSource = "floating fallback (no plane in raycast)"
      }
    } else {
      worldPlaneAnchor = nil
      origin = camPos + simd_normalize(forward) * distanceMeters
      anchorSource = "floating fallback (no session)"
    }

    // worldYaw = "camera's relative bearing at lock". Subsequent
    // frames' azimuth subtracts this so the dome's az=0 ↔ lock pose.
    let relInitial = camPos - origin
    let yaw = atan2(relInitial.z, relInitial.x)

    worldOrigin = origin
    worldYaw = yaw

    NSLog("[AetherARKit] lockOrigin: SUCCESS via \(anchorSource) at "
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
        _ = adaptor.append(pixelBuffer, withPresentationTime: pts)
      }
      recordedFrameCount += 1
    }

    // ── Refresh worldOrigin from the plane anchor's latest transform.
    // ARKit refines plane geometry continuously; reading the anchor's
    // current transform on every frame is what makes the origin STAY
    // put (in algorithm-space — there's no visual reticle anymore) as
    // the user walks around. Without this, the anchor's static initial
    // transform drifts away from the table over the course of a long
    // capture, corrupting azimuth/elevation. Only kicks in if
    // `lockOrigin` got a plane raycast hit.
    if let myAnchor = worldPlaneAnchor {
      if let updatedAnchor = frame.anchors.first(
        where: { $0.identifier == myAnchor.identifier }
      ) as? ARPlaneAnchor {
        worldPlaneAnchor = updatedAnchor
        let planePos = simd_float3(
          updatedAnchor.transform.columns.3.x,
          updatedAnchor.transform.columns.3.y,
          updatedAnchor.transform.columns.3.z
        )
        worldOrigin = planePos + worldOffsetFromAnchor
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
          let q = AetherARKitPlugin.computeQuality(pixelBuffer)
          let elapsedMs = (CACurrentMediaTime() - computeStart) * 1000
          DispatchQueue.main.async {
            guard let self = self else { return }
            self.pendingQuality = q
            self.qualityComputeInFlight = false
            self.qDiagFires += 1
            self.qDiagElapsedMsSum += elapsedMs
          }
        }
      }
    }
    // Attach the most-recent computed quality (from a previous frame)
    // and clear so we don't repeat-send the same report.
    if let q = pendingQuality {
      payload["q_sharpness"] = q.sharpness
      payload["q_meanBrightness"] = q.meanBrightness
      payload["q_globalVariance"] = q.globalVariance
      payload["q_sigW"] = AetherARKitPlugin.signatureSide
      payload["q_sigH"] = AetherARKitPlugin.signatureSide
      payload["q_signature"] = FlutterStandardTypedData(bytes: q.signature)
      pendingQuality = nil
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

  struct QualityReport {
    let sharpness: Double      // Laplacian variance
    let meanBrightness: Double // mean luma 0..255
    let globalVariance: Double // luma variance, used for low-texture
                               // soft downgrade in GuidanceEngine
    let signature: Data        // signatureSide² bytes, block-mean
  }

  /// Compute Laplacian variance, mean brightness, global variance and
  /// a 16×16 grayscale signature from the Y plane of the supplied
  /// CVPixelBuffer. Returns nil if the buffer's pixel format isn't a
  /// planar YUV variant ARKit normally hands us.
  static func computeQuality(_ pixelBuffer: CVPixelBuffer) -> QualityReport? {
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
    var small = [UInt8](repeating: 0, count: tw * th)
    let sxFixed = (width << 16) / tw
    let syFixed = (height << 16) / th
    for dy in 0..<th {
      let srcY = (dy * syFixed) >> 16
      let srcRowOffset = srcY * rowStride
      let dstRowOffset = dy * tw
      for dx in 0..<tw {
        let srcX = (dx * sxFixed) >> 16
        small[dstRowOffset + dx] = src[srcRowOffset + srcX]
      }
    }

    // Laplacian variance + pixel mean / variance, in one pass.
    var lapSum: Double = 0
    var lapSumSq: Double = 0
    var lapN = 0
    var pixSum: Double = 0
    var pixSumSq: Double = 0
    for y in 0..<th {
      let row = y * tw
      for x in 0..<tw {
        let i = row + x
        let c = Double(small[i])
        pixSum += c
        pixSumSq += c * c
        if y >= 1 && y < th - 1 && x >= 1 && x < tw - 1 {
          let t = Double(small[i - tw])
          let b = Double(small[i + tw])
          let l = Double(small[i - 1])
          let r = Double(small[i + 1])
          let lap = 4 * c - t - b - l - r
          lapSum += lap
          lapSumSq += lap * lap
          lapN += 1
        }
      }
    }
    let lapMean = lapSum / Double(lapN)
    let sharpness = (lapSumSq / Double(lapN)) - (lapMean * lapMean)
    let pixN = Double(tw * th)
    let pixMean = pixSum / pixN
    let globalVariance = (pixSumSq / pixN) - (pixMean * pixMean)

    // 16×16 signature — block-mean down-sample of the 128 thumbnail.
    let sw = signatureSide
    let blockW = tw / sw
    let blockH = th / sw
    var sig = Data(count: sw * sw)
    sig.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
      let dst = raw.bindMemory(to: UInt8.self).baseAddress!
      for by in 0..<sw {
        for bx in 0..<sw {
          var acc = 0
          let by0 = by * blockH
          let bx0 = bx * blockW
          for py in 0..<blockH {
            let srcRow = (by0 + py) * tw + bx0
            for px in 0..<blockW {
              acc += Int(small[srcRow + px])
            }
          }
          dst[by * sw + bx] = UInt8(min(255, acc / (blockW * blockH)))
        }
      }
    }

    return QualityReport(
      sharpness: sharpness,
      meanBrightness: pixMean,
      globalVariance: globalVariance,
      signature: sig
    )
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
class AetherARKitPreviewView: NSObject, FlutterPlatformView {
  private let arscnView: ARSCNView
  private let getSession: () -> ARSession?
  private var pollTimer: Timer?

  init(frame: CGRect, getSession: @escaping () -> ARSession?) {
    self.arscnView = ARSCNView(frame: frame)
    self.getSession = getSession
    super.init()
    arscnView.automaticallyUpdatesLighting = true
    arscnView.scene = SCNScene()         // empty scene — camera feed only
    arscnView.rendersContinuously = true
    arscnView.antialiasingMode = .none
    attachSessionIfReady()
  }

  func view() -> UIView {
    return arscnView
  }

  /// AetherARKitPlugin creates the ARSession lazily on `startSession`,
  /// which the Dart side does inside CaptureSession.attach(). The
  /// preview widget can be in the tree before attach() runs, so we
  /// poll briefly until the session shows up. Once attached, stop the
  /// timer.
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

  deinit {
    pollTimer?.invalidate()
  }
}
