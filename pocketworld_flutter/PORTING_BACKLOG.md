# Aether3D → PocketWorld Flutter — Porting backlog

Living document tracking every TestFlight-era Swift/Metal module that's
been ported, partially ported, or deferred. Status as of 2026-04-27
late-evening session (a single long sprint after the iOS visual gate
passed). Numbers correspond to the "Phase" taxonomy the user laid out
in-session:

- **B = Auth / local persistence**  (ready to ship; Firebase wired)
- **C = Cloud pipeline (broker client)**  (skeleton wired; real broker
  not exercised end-to-end)
- **D = Realtime AR / quality / training signals**  (Dart scaffolding
  landed; real native AR + shader runtime deferred)

---

## Summary: port status table

| # | Swift/Metal source | Flutter target | Status | Notes |
|---|---|---|---|---|
| B1.a | `Core/Auth/AuthModels.swift` | `lib/auth/auth_models.dart` | ✅ port | 1:1 types + sealed class SignIn/SignUp requests |
| B1.b | `Core/Auth/AuthService.swift` | `lib/auth/auth_service.dart` | ✅ port | Protocol identical |
| B1.c | `Core/Auth/AuthError.swift` | `lib/auth/auth_error.dart` | ✅ port | Chinese messages kept |
| B1.d | `Core/Auth/FirebaseAuthService.swift` | `lib/auth/firebase_auth_service.dart` | ✅ port | Uses `firebase_auth` plugin; error mapping 1:1 |
| B1.e | `Core/Auth/MockAuthService.swift` | `lib/auth/mock_auth_service.dart` | ✅ port | For tests / preview |
| B1.f | `Core/Auth/CurrentUser.swift` | `lib/auth/current_user.dart` | ✅ port | ChangeNotifier; 30-day idle logout kept |
| B1.g | `App/Auth/AuthRootView.swift` | `lib/ui/auth/auth_root_view.dart` | ✅ port | B&W light theme (prototype was dark) |
| B1.h | `App/Auth/EmailSignInView.swift` + EmailSignUpView | `lib/ui/auth/email_sign_in_view.dart` | ✅ port | Password reset kept |
| B1.i | `App/Auth/PhoneSignInView.swift` | `lib/ui/auth/phone_sign_in_view.dart` | ✅ port | Two-step flow; hidden by default in `AuthRootView` (same as Swift prototype) |
| B1.j | `App/Auth/AuthSharedViews.swift` | `lib/ui/auth/auth_shared_widgets.dart` | ✅ port | AuthField + AuthPrimaryButton |
| B1.k | (new) | `lib/auth/firebase_bootstrap.dart` | ✅ new | iOS uses bundled GoogleService-Info.plist auto-read; Android / web defer DefaultFirebaseOptions |
| B1.l | (new) | `lib/auth/auth_scope.dart` | ✅ new | InheritedNotifier<CurrentUser> |
| B2.a | `App/Home/ScanRecordStore.swift` (local SQLite + file tree) | — | ❌ deferred | User direction 2026-04-27 evening: "本地存储不用管，即将升级到云端"; cloud-first ScanRecord/HomeViewModel already uses mock data and will switch to broker queries at C1 |
| C1.a | `Core/Pipeline/RemoteB1Client.swift` (protocol) | `lib/pipeline/remote_b1_client.dart` | ✅ port | Types, sealed JobStatus, artifact format enum |
| C1.b | `Core/Pipeline/PipelineBackend.swift` | `lib/pipeline/pipeline_backend.dart` | ✅ port | |
| C1.c | `Core/Pipeline/NotConfiguredRemoteB1Client.swift` | `lib/pipeline/not_configured_client.dart` | ✅ port | |
| C1.d | `Core/Pipeline/BackgroundUploadBrokerClient.swift` (~4100 lines Swift) | `lib/pipeline/background_upload_broker_client.dart` | 🟡 partial | Core HTTP surface (createJob / pollStatus / download / cancel / clientEvent / rename). Deferred: BackgroundURLSession resume, AVFoundation transcoding, detailed retry matrix — see "Broker client gaps" below |
| C1.e | `Core/Pipeline/Artifacts/ArtifactManifest.swift` **(source not found in repo snapshot)** | `lib/pipeline/artifact_manifest.dart` | 🟡 Dart-first | Wrote from user's description + broker references: `BrokerArtifactManifest` + SHA256 verify + `kDefaultScanRecordName = '未命名作品'` + legacy `'草稿'` accepted on read + rename API. **Need to verify the broker JSON shape matches Swift when the real server is reachable.** |
| C1.f | (new glue) | `lib/pipeline/pipeline_runner.dart` | ✅ new | `pipelineClient()` factory: reads `AETHER_BROKER_BASE_URL` etc. from dart-define; falls back to NotConfigured |
| C1.g | `Core/Pipeline/DanishGoldenRemoteB1Client.swift` (SSH) | — | ❌ won't port | Legacy fallback — broker path supersedes |
| C1.h | `Core/Pipeline/LocalAetherRemoteB1Client.swift` (local PLY fake) | — | ❌ won't port | Dev-only |
| D1.a | `App/ObjectModeV2/ObjectModeV2DomeView.swift` + `ObjectModeV2DomeUpdateObserver.swift` | `lib/dome/dome_view.dart` | 🟡 2D proxy | Swift uses 3D sphere of wedge quads + Metal PBR+ripple shader; Flutter Dart version renders an orthographic projection of the sphere as a CustomPainter. UX is equivalent (coverage visualization + live cursor). **True 3D PBR dome requires `ScanGuidance.metal → WGSL` + a Flutter 3D scene — not shipped today**. See D1.b |
| D1.b | `App/ScanGuidance/Shaders/ScanGuidance.metal` (PBR + ripple + border animation) | — | ❌ deferred | Only needed if we go back to 3D PBR dome. Phase 7+ when the spec is clearer on dome fidelity |
| D1.c | `App/ObjectModeV2/ObjectModeV2CoverageMap.swift` | `lib/dome/coverage_map.dart` | ✅ port | 24 × 9 bin grid; completionFraction; nearestUnvisited |
| D1.d | (new) | `lib/dome/ar_pose.dart` + `mock_pose_provider.dart` + `platform_pose_provider.dart` | ✅ new | Platform-independent pose abstraction; Dart Mock drives the dome today. **iOS ARKit MethodChannel (`aether_arkit`) skeleton not wired on native side yet** — falls back to mock when the channel is absent |
| D1.e | iOS ARKit MethodChannel implementation | `ios/Runner/AetherARKitPlugin.swift` | ❌ deferred | Needs ARKit.framework link + Info.plist camera permission. Tracked as first follow-up after this session |
| D1.f | Android ARCore / HarmonyOS / WebXR implementations | — | ❌ deferred | Phase 7+ platform expansion |
| D2.a | `App/Shaders/QualityMetrics.metal` (blur / brightness / motion) | `aether_cpp/shaders/wgsl/quality_metrics_{blur,brightness,motion}.wgsl` | ✅ port | 3 WGSL kernels, identical math + atomic ops. **Not yet exercised end-to-end** — needs Dart host-side FFI binding + a camera frame → texture pipeline before blur/brightness/motion numbers flow back to GuidanceEngine |
| D2.b | `App/Shaders/QualityOverlay.metal` | — | ❌ deferred | Point-cloud overlay — Phase 7 when we have a real point-cloud source in the capture page |
| D2.c | `App/ObjectModeV2/ObjectModeV2GuidanceEngine.swift` (hard-reject + soft-downgrade + hint taxonomy) | `lib/quality/guidance_engine.dart` | ✅ port | 1:1 acceptance-threshold + similarity / novelty / coverage math. Uses placeholder `FrameQualityConstants` values — real tuning happens on-device |
| D2.d | (new) | `lib/quality/frame_quality_constants.dart` | ✅ new | Central threshold store |
| D3.a | `App/GaussianSplatting/Shaders/GaussianTraining.metal` (depthPearsonReducePartial / Final / densificationStats / adamUpdate) | `aether_cpp/shaders/wgsl/*` (already present via Phase 6.3a) | ✅ already WGSL | Brush training kernels were ported in Phase 6.3a; math already validated in aether_cpp |
| D3.b | `App/ObjectModeV2/ObjectModeV2QualityDebugOverlay.swift` | `lib/quality/quality_debug_overlay.dart` | ✅ port | Same rows, same color thresholds |
| D3.c | `App/LocalPreview/LocalPreviewProductProfile.swift` (6 phase enum + progressBasis / startFraction / defaultActiveFraction) | `lib/quality/local_preview_profile.dart` | ✅ port | |
| D3.d | C ABI `aether_train_get_convergence_stats()` for reading `depth_pearson` / `densification_rate` / `loss` from the running training session | **not written yet in aether_cpp** | ❌ deferred | Dart side uses `MockTrainingConvergenceProvider` today. Adding the C ABI requires aether_cpp rebuild; tracked as the first task after C1 broker is reachable |
| D3.e | (new) | `lib/quality/training_convergence.dart` | ✅ new | `TrainingConvergenceProvider` interface + Mock + snapshot data class |

---

## Broker client gaps (C1.d — deferred inside the broker port)

Listed in priority order. Each is a self-contained task.

1. **iOS BackgroundURLSession resume** — needed so uploads keep running
   when the user backgrounds the app. Swift uses
   `URLSession(configuration: .background(withIdentifier: ...))`. Flutter
   side requires a plugin (recommended: wrap `background_downloader`
   with the same `AETHER_BROKER_BACKGROUND_SESSION_ID` identifier the
   Swift project already uses, so the OS can resume uploads started in
   previous app launches).
2. **AVFoundation video transcoding** (`StreamFriendlyUploadPreparer`)
   — today Dart `BackgroundUploadBrokerClient.upload()` sends the file
   as-is. For long-form captures this hurts upload time materially.
   Easy path: `video_compress` plugin for iOS/Android; full path: FFI
   to a shared video-preparer in `aether_cpp`.
3. **Fallback URL retry taxonomy** (`shouldRetryWithFallback` etc.) —
   today Dart maps 5xx + timeout to a single dio retry. Swift has a
   ~60-state retry matrix tuned against broker behavior. Port when
   real broker traffic reveals which retries matter.
4. **Managed staging directory** (`ManagedPreparedUploadSourceStore`,
   `~/Documents/Aether3D/stream-friendly-uploads`) — temp file cleanup
   + metadata persistence for in-flight uploads. Not needed until the
   app goes offline-tolerant (Phase 7+).
5. **`renameRecord` PATCH contract** — The Swift broker likely uses a
   different shape than my inferred `{ "display_name": "..." }`. Verify
   against the real backend and adjust.
6. **ArtifactManifest JSON shape** — ported from the user's verbal
   description; may need field adjustments once the broker is
   reachable. Wire a fixture into `test/widget_test.dart` as a
   round-trip test when the real payload is available.

## Firebase config gaps (B1 — affects real-device auth)

1. **Bundle ID mismatch**: copied `GoogleService-Info.plist` from
   the TestFlight `com.kyle.Aether3D` project; Flutter Runner's bundle
   is `com.kyle.PocketWorld`. Firebase email/password auth usually
   works despite the mismatch, but Push / Analytics / Dynamic Links
   need exact-match. Two fix paths:
   - Change Flutter Runner's bundle to `com.kyle.Aether3D` (pbxproj
     edit) — cleanest; requires re-provisioning profile on Kyle's
     device.
   - Add a second iOS app to the Firebase project (bundle
     `com.kyle.PocketWorld`) and regenerate the plist — won't impact
     the TestFlight Aether3D app.
2. **Android / web Firebase**: Not configured. Run `flutterfire
   configure` once those targets come online; it'll generate
   `lib/firebase_options.dart` which `firebase_bootstrap.dart`
   already has a TODO for.
3. **Email verification flow** — `FirebaseAuthService.sendEmailVerification`
   is implemented but no UI surfaces "未验证邮箱" state. Vault page
   or Me page should add a banner when `currentUser.emailVerified ==
   false`. Not critical for sign-in but a production hygiene TODO.

## Native iOS plugins to add (when we want full functionality)

- `aether_arkit` MethodChannel + EventChannel for AR pose (D1.e)
- `aether_ffmpeg` or `video_compress` for broker upload preparation
  (C1 gap #2)
- `background_downloader` configuration that reuses
  `AETHER_BROKER_BACKGROUND_SESSION_ID` (C1 gap #1)
- Camera frame sampling hook that feeds the QualityMetrics WGSL
  pipeline (D2.a) — today there's no camera preview in the app

## Known failures / warnings

- `ArtifactManifest.swift` was referenced by the user but not present
  in the repo snapshot — the Dart version is a best-effort write.
  When the real file appears, do a diff pass against the Dart version.
- `flutterfire` CLI is not installed on this machine — firebase_options
  generation is therefore manual / deferred.

---

## What's demo-able today (without real broker)

- Email sign-in / sign-up against real Firebase Auth (pending bundle ID
  fix above — email flows should work regardless).
- Vault page waterfall with 8 mock records.
- Capture mode selection → capture page with the Dawn-rendered
  DamagedHelmet (unchanged from iOS visual gate).
- `DomeView` with `MockARPoseProvider` showing a 60-second synthetic
  orbit; coverage ring progresses 0→100% over that run.
- Design Inspector toggle (right-bottom 🎨) overlays role badges on
  every UI region.

## What requires the next session

- Wire AR plugin (D1.e) + camera preview + hook QualityMetrics WGSL
  through FFI → end-to-end realtime capture audit.
- Reach the broker and exercise C1 end-to-end (upload + poll +
  download artifact with SHA256 verify).
- Expose C ABI for training convergence metrics (D3.d) + replace
  Mock training provider with FFI one.
- Decide whether true 3D PBR dome (D1.b) is worth the effort or the
  2D proxy is enough for v1.

