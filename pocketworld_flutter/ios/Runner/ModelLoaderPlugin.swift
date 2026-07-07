import Flutter
import Foundation
import UIKit

// ModelLoaderPlugin — iOS-side On-Demand Resources bridge for the DA3
// CoreML tier-dispatch system.
//
// Target install path:
//   pocketworld_flutter/ios/Runner/ModelLoaderPlugin.swift
//
// What this exposes
// -----------------
// MethodChannel `pocketworld/model_loader`
//   `getDeviceTier`         → "low" | "high"
//   `getLocalModelPath`     → String? (nullable absolute CoreML path)
//   `ensureModelDownloaded` → String  (absolute CoreML path)
//
// EventChannel `pocketworld/model_loader/progress`
//   {tag: String, progress: Double in [0, 1]}
//
// ODR tag mapping
// ---------------
//   tier:low   → DA3BASE_280x504_N35_image_only.mlmodelc/.mlpackage  (legacy alias)
//   tier:high  → DA3BASE_280x504_N35_image_only.mlmodelc/.mlpackage  (K=35, official preprocess)
//
// Why the tag dictates the filename here (not in Dart)
// ----------------------------------------------------
// The Dart side is intentionally backend-agnostic: it knows only logical
// tags (tier:low, tier:high). Each platform's plugin maps that tag to
// its native packaging unit:
//   - iOS:        ODR tag → CoreML filename in main bundle Resources
//   - Android:    PAD pack name → file in /data/data/.../assets/
//   - Web:        tag → CDN URL
//   - HarmonyOS:  Asset Pack tag → app sandbox path
//
// Memory note (project_pocketworld_device_tier.md): tier threshold is
// physicalMemory >= 5 GB. This MUST match the gating logic in
// AetherARKitPlugin.swift line 446 (kFourKMemThresholdBytes: 5_000_000_000).
// Any change here without a matching change there will mis-tier devices.

final class ModelLoaderPlugin: NSObject {

    // MARK: Tag → file mapping

    /// ODR tag string and the bundled CoreML filename for that tag.
    /// Filename has no extension because Xcode may expose either a
    /// compiled `.mlmodelc` or source `.mlpackage` in Bundle.main.
    private struct ModelEntry {
        let tag: String
        let resourceName: String        // e.g. "DA3BASE_280x504_N35_image_only"
    }

    private static let entries: [String: ModelEntry] = [
        "tier:low": ModelEntry(
            tag: "tier:low",
            resourceName: "DA3BASE_280x504_N35_image_only"
        ),
        "tier:high": ModelEntry(
            tag: "tier:high",
            resourceName: "DA3BASE_280x504_N35_image_only"
        ),
    ]

    // MARK: Channels

    private let methodChannel: FlutterMethodChannel
    private let progressEventChannel: FlutterEventChannel
    private let progressStreamHandler = ProgressStreamHandler()

    /// Retained NSBundleResourceRequest per tag. Keeping a strong
    /// reference is mandatory — releasing it before
    /// `endAccessingResources` is called purges the resource from the
    /// device cache, forcing a re-download on the next request.
    private var liveRequests: [String: NSBundleResourceRequest] = [:]

    /// KVO observers we attach to `request.progress.fractionCompleted`.
    /// Stored separately so we can `invalidate()` them on completion
    /// without nuking the request itself.
    private var liveObservers: [String: NSKeyValueObservation] = [:]

    // MARK: Registration

    static func register(with messenger: FlutterBinaryMessenger) {
        let plugin = ModelLoaderPlugin(messenger: messenger)
        // Retain via the channels' callback closures — Flutter doesn't
        // own plugin instances by default.
        plugin.methodChannel.setMethodCallHandler { [weak plugin] call, result in
            plugin?.handle(call: call, result: result)
        }
        plugin.progressEventChannel.setStreamHandler(plugin.progressStreamHandler)
    }

    private init(messenger: FlutterBinaryMessenger) {
        self.methodChannel = FlutterMethodChannel(
            name: "pocketworld/model_loader",
            binaryMessenger: messenger
        )
        self.progressEventChannel = FlutterEventChannel(
            name: "pocketworld/model_loader/progress",
            binaryMessenger: messenger
        )
        super.init()
    }

    // MARK: MethodChannel dispatch

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getDeviceTier":
            result(Self.deviceTierString())

        case "getLocalModelPath":
            guard let args = call.arguments as? [String: Any],
                  let tag = args["tag"] as? String,
                  let entry = Self.entries[tag] else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "getLocalModelPath needs {tag}",
                                    details: nil))
                return
            }
            // Bundle.main.url returns non-nil iff the resource is
            // currently present on device. For ODR-tagged resources
            // that have not been requested yet, this is nil — which is
            // exactly the "not cached, request needed" signal.
            let url = Self.resolveBundledCoreMLURL(resourceName: entry.resourceName)
            result(url?.path)

        case "ensureModelDownloaded":
            guard let args = call.arguments as? [String: Any],
                  let tag = args["tag"] as? String,
                  let entry = Self.entries[tag] else {
                result(FlutterError(code: "BAD_ARGS",
                                    message: "ensureModelDownloaded needs {tag}",
                                    details: nil))
                return
            }
            beginAccessing(entry: entry, result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: Device tier

    /// Mirror of AetherARKitPlugin's gating: physicalMemory >= 5 GB → HIGH.
    /// 5 GB threshold separates 4 GB devices (reported ~3.86 GB) from
    /// 6 GB devices (reported ~5.78 GB). Forward-compatible with future
    /// RAM bumps.
    static func deviceTierString() -> String {
        let kHighTierThresholdBytes: UInt64 = 5_000_000_000
        return ProcessInfo.processInfo.physicalMemory >= kHighTierThresholdBytes
            ? "high"
            : "low"
    }

    // MARK: NSBundleResourceRequest

    private func beginAccessing(
        entry: ModelEntry,
        result: @escaping FlutterResult
    ) {
        let tag = entry.tag

        // If we already have a live request for this tag (e.g. user
        // tapped the dialog while a previous attempt was racing), wait
        // on the same one — don't double-request.
        if let existing = liveRequests[tag] {
            // Re-check completion: existing.progress.isFinished tells
            // us if it has already resolved.
            if existing.progress.isFinished {
                respondWithBundlePath(entry: entry, result: result)
                return
            }
            // Otherwise let the in-flight call complete — but the
            // Flutter `result` callback can only be invoked once per
            // MethodCall, so we still need to attach a new completion
            // handler. NSBundleResourceRequest has no built-in
            // "wait for current" API; the simplest safe path is to
            // attach another beginAccessingResources call. iOS will
            // coalesce internally and just signal success quickly.
        }

        let request = NSBundleResourceRequest(tags: [tag])
        // Prevent iOS from purging this resource while the app is
        // active — without this the request can be evicted under
        // memory pressure mid-capture.
        request.loadingPriority = NSBundleResourceRequestLoadingPriorityUrgent
        liveRequests[tag] = request

        // KVO on fractionCompleted is the only progress signal iOS
        // exposes for ODR. Reports at roughly 10 Hz; we just forward.
        let observer = request.progress.observe(\.fractionCompleted, options: [.new]) {
            [weak self] _, change in
            let f = change.newValue ?? 0.0
            self?.progressStreamHandler.emit(tag: tag, fraction: f)
        }
        liveObservers[tag] = observer

        request.beginAccessingResources { [weak self] error in
            guard let self = self else { return }
            // Run on main thread for Flutter callback safety. Apple
            // does not guarantee the completion thread.
            DispatchQueue.main.async {
                // Final 1.0 progress so the UI can settle at 100% even
                // if the last KVO tick was 0.99x and got debounced.
                self.progressStreamHandler.emit(tag: tag, fraction: 1.0)

                self.liveObservers[tag]?.invalidate()
                self.liveObservers.removeValue(forKey: tag)

                if let error = error {
                    NSLog("[ModelLoader] beginAccessingResources(\(tag)) failed: \(error)")
                    // Drop the failed request so the next call retries.
                    self.liveRequests.removeValue(forKey: tag)
                    result(FlutterError(
                        code: "ODR_FAIL",
                        message: error.localizedDescription,
                        details: nil
                    ))
                    return
                }
                // Resource is now present in the bundle and pinned
                // (via liveRequests retention). Return its path.
                // Note: do NOT call endAccessingResources here — that
                // would let iOS purge between capture sessions. We
                // hold the request for the whole app lifetime; iOS
                // ARC nukes it cleanly on terminate.
                self.respondWithBundlePath(entry: entry, result: result)
            }
        }
    }

    private func respondWithBundlePath(
        entry: ModelEntry,
        result: @escaping FlutterResult
    ) {
        guard let url = Self.resolveBundledCoreMLURL(resourceName: entry.resourceName) else {
            // ODR claimed success but the resource isn't visible — most
            // likely a tag/filename mismatch in the Xcode project. Fail
            // loudly so the build break gets caught in QA, not by users.
            result(FlutterError(
                code: "ODR_BUNDLE_MISS",
                message: "Resource \(entry.resourceName).mlmodelc/.mlpackage " +
                         "not found in main bundle after beginAccessingResources " +
                         "succeeded. Check the ODR tag mapping in the Xcode " +
                         "project — tag '\(entry.tag)' must be set on the " +
                         "corresponding CoreML resource.",
                details: nil
            ))
            return
        }
        result(url.path)
    }

    private static func resolveBundledCoreMLURL(resourceName: String) -> URL? {
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
}

// MARK: - Progress EventChannel handler

/// Stream handler that fans out KVO progress events to the Dart side.
/// Buffered between `onListen` calls — if a download finishes before
/// Dart subscribes, the last fraction is still delivered as soon as the
/// subscription opens.
private final class ProgressStreamHandler: NSObject, FlutterStreamHandler {
    private var sink: FlutterEventSink?
    private var lastEvent: [String: Any]?

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        if let cached = lastEvent {
            events(cached)
        }
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        return nil
    }

    func emit(tag: String, fraction: Double) {
        let payload: [String: Any] = [
            "tag": tag,
            "progress": fraction,
        ]
        lastEvent = payload
        DispatchQueue.main.async {
            self.sink?(payload)
        }
    }
}
