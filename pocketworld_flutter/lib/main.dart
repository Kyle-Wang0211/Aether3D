// Aether3D PocketWorld — Flutter entry point.
//
// Responsibilities (deliberately narrow so UI iterations stay in lib/ui/
// and domain code lives in its own lib/ folder per module):
//   • Firebase init + AuthService selection (Firebase vs Mock fallback)
//   • CurrentUser ChangeNotifier instantiation + bootstrap
//   • AuthGate: bootstrapping → AuthRootView | AppShell
//   • Dawn texture + gesture lifecycle (same as before; only runs once
//     the user is signed in so the GPU isn't wasted on the auth screen)
//
// Modules:
//   lib/auth/             — protocol + Firebase + Mock + CurrentUser + AuthScope
//   lib/pipeline/         — RemoteB1Client + BackgroundUploadBroker Dart port
//   lib/quality/          — GuidanceEngine Dart port + QualityMetrics glue
//   lib/dome/             — arcball AR pose abstraction + sphere wedge renderer
//   lib/ui/               — design tokens + splash + shell + pages
//   lib/ui/auth/          — AuthRootView + EmailSignIn + PhoneSignIn + shared widgets

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'aether_ffi.dart';
import 'auth/auth_scope.dart';
import 'auth/current_user.dart';
import 'auth/firebase_auth_service.dart';
import 'auth/firebase_bootstrap.dart';
import 'auth/mock_auth_service.dart';
import 'i18n/locale_notifier.dart';
import 'l10n/app_localizations.dart';
import 'lifecycle_observer.dart';
import 'object_transform.dart';
import 'orbit_controls.dart';
import 'ui/app_shell.dart';
import 'ui/auth/auth_root_view.dart';
import 'ui/capture_page.dart';
import 'ui/design_system.dart';
import 'ui/scan_record.dart';
import 'ui/splash_overlay.dart';

Future<void> main() async {
  // SMOKE LOG: if you don't see this print in Xcode console, Dart
  // main never got invoked by FlutterEngine — problem is above us
  // (iOS 26 + Flutter JIT handshake, plugin register blocking, etc).
  // If you see it but no UI, problem is below us (widget tree build).
  // ignore: avoid_print
  print('[AET-SMOKE] Dart main entered');

  FlutterError.onError = (details) {
    // ignore: avoid_print
    print('[FlutterError] ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };

  // CRITICAL: ensureInitialized() AND runApp() MUST be called in the
  // SAME zone, otherwise Flutter emits "Zone mismatch" and
  // zone-specific configuration (error handlers, async tracking)
  // becomes inconsistent. Both live inside the runZonedGuarded
  // callback below.
  //
  // Defense-in-depth: any setup exception routes to the fallback
  // handler and the app still comes up (with mock auth) so the user
  // sees the sign-in page instead of a blank crash.
  runZonedGuarded<Future<void>>(() async {
    // ignore: avoid_print
    print('[AET-SMOKE] inside runZonedGuarded');
    WidgetsFlutterBinding.ensureInitialized();
    // ignore: avoid_print
    print('[AET-SMOKE] ensureInitialized done, about to runApp');

    // Launch the app with a mock auth service so runApp fires on the
    // very next microtask and the splash paints immediately. Firebase
    // is initialized in the background and swapped into CurrentUser
    // once it's up (or after a 10-second timeout fallback to mock).
    final currentUser = CurrentUser(service: MockAuthServiceImpl());
    final localeNotifier = LocaleNotifier();
    unawaited(localeNotifier.bootstrap());
    runApp(PocketWorldApp(
      currentUser: currentUser,
      localeNotifier: localeNotifier,
    ));
    // ignore: avoid_print
    print('[AET-SMOKE] runApp returned');

    // Did Flutter actually paint the first frame?
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // ignore: avoid_print
      print('[AET-SMOKE] first frame PAINTED');
    });
    WidgetsBinding.instance.waitUntilFirstFrameRasterized.then((_) {
      // ignore: avoid_print
      print('[AET-SMOKE] first frame RASTERIZED');
    });

    unawaited(() async {
      const firebaseInitTimeout = Duration(seconds: 10);
      final firebaseReady = await initializeFirebaseSafely()
          .timeout(firebaseInitTimeout, onTimeout: () {
        debugPrint(
          '[main] Firebase.initializeApp timed out after '
          '${firebaseInitTimeout.inSeconds}s — continuing with mock auth.',
        );
        return false;
      });
      if (firebaseReady) {
        currentUser.swapService(FirebaseAuthServiceImpl());
      }
      await currentUser.bootstrap();
    }());
  }, (error, stack) {
    // ignore: avoid_print
    print('[main.runZonedGuarded] uncaught: $error\n$stack');
    try {
      WidgetsFlutterBinding.ensureInitialized();
      final fallback =
          CurrentUser(service: MockAuthServiceImpl())..bootstrap();
      runApp(PocketWorldApp(
        currentUser: fallback,
        localeNotifier: LocaleNotifier(),
      ));
    } catch (e) {
      // ignore: avoid_print
      print('[main] fallback runApp also failed: $e');
    }
  });
}

const Color _aetherColdStartBackground = AetherColors.bg;

class PocketWorldApp extends StatelessWidget {
  final CurrentUser currentUser;
  final LocaleNotifier localeNotifier;

  const PocketWorldApp({
    super.key,
    required this.currentUser,
    required this.localeNotifier,
  });

  @override
  Widget build(BuildContext context) {
    return LocaleScope(
      notifier: localeNotifier,
      child: AnimatedBuilder(
        animation: localeNotifier,
        builder: (context, _) {
          return MaterialApp(
            title: 'PocketWorld',
            debugShowCheckedModeBanner: false,
            theme: ThemeData(
              colorScheme: ColorScheme.fromSeed(
                seedColor: AetherColors.primary,
                brightness: Brightness.light,
              ),
              scaffoldBackgroundColor: _aetherColdStartBackground,
              canvasColor: _aetherColdStartBackground,
              useMaterial3: true,
            ),
            locale: localeNotifier.locale,
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            home: AuthScope(
              currentUser: currentUser,
              child: const _AuthGate(),
            ),
          );
        },
      ),
    );
  }
}

/// Routes between the three CurrentUser states:
///   bootstrapping → animated splash
///   signedOut     → AuthRootView (email / phone sign-in)
///   signedIn      → HomeScreen (vault + me + 3D texture)
class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _splashMinElapsed = false;
  Timer? _splashMinTimer;

  @override
  void initState() {
    super.initState();
    // Minimum splash duration — avoids a jarring flicker when bootstrap
    // completes in a few ms (e.g. mock service / cached user).
    _splashMinTimer = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      setState(() => _splashMinElapsed = true);
    });
  }

  @override
  void dispose() {
    _splashMinTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthScope.of(context);
    final state = user.state;

    // During bootstrap OR until min-splash elapsed, show the splash.
    final splashVisible =
        state is CurrentUserBootstrapping || !_splashMinElapsed;

    Widget body;
    if (state is CurrentUserSignedIn) {
      body = const HomeScreen();
    } else if (state is CurrentUserSignedOut) {
      body = AuthRootView(currentUser: user);
    } else {
      body = const SizedBox.expand();
    }

    return Stack(
      children: [
        body,
        Positioned.fill(
          child: AetherSplashOverlay(
            visible: splashVisible,
            progressMessage: _bootstrapMessage(context, state),
          ),
        ),
      ],
    );
  }

  String _bootstrapMessage(BuildContext context, CurrentUserState state) {
    final l = AppL10n.of(context);
    if (state is CurrentUserBootstrapping) return l.splashRestoringSession;
    if (state is CurrentUserSignedOut) return l.splashPreparingSignIn;
    return l.splashWaking3DEngine;
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _channel = MethodChannel('aether_texture');
  int? _textureId;
  String? _textureError;
  bool _isRetrying = false;

  String? _meshStatus = 'warming up renderer...';
  bool _meshStatusBusy = true;
  bool _meshStatusError = false;
  Timer? _meshStatusHideTimer;

  static const _splashMinDurationMs = 1200;
  static const _splashMaxDurationMs = 20000;
  bool _splashMinElapsed = false;
  bool _splashForceHidden = false;
  Timer? _splashMinTimer;
  Timer? _splashMaxTimer;

  final OrbitControls _orbit = OrbitControls();
  final ObjectTransform _object = ObjectTransform();
  LifecycleObserver? _lifecycle;

  static const double _fovYRadians = 60.0 * 3.14159265 / 180.0;
  static const Size _textureWidgetSize = Size(256, 256);

  @override
  void initState() {
    super.initState();
    _lifecycle = LifecycleObserver(
      orbit: _orbit,
      obj: _object,
      onStateChanged: () {
        if (!mounted) return;
        setState(() {});
        _pushMatrices();
      },
    );
    _splashMinTimer = Timer(
      const Duration(milliseconds: _splashMinDurationMs),
      () {
        if (!mounted) return;
        setState(() => _splashMinElapsed = true);
      },
    );
    _splashMaxTimer = Timer(
      const Duration(milliseconds: _splashMaxDurationMs),
      () {
        if (!mounted) return;
        setState(() => _splashForceHidden = true);
      },
    );
    _requestTexture();
  }

  bool get _splashVisible {
    if (_splashForceHidden) return false;
    if (!_splashMinElapsed) return true;
    final rendererReady = _textureId != null;
    final meshSettled = !_meshStatusBusy || _meshStatusError;
    return !(rendererReady && meshSettled);
  }

  String _splashMessage(BuildContext context) {
    final l = AppL10n.of(context);
    if (_textureError != null) return l.splashRendererUnavailable;
    if (_textureId == null) return l.splashWaking3DEngine;
    if (_meshStatusBusy) return l.splashWaking3DEngine;
    return l.splashWaking3DEngine;
  }

  Future<void> _requestTexture({bool isManualRetry = false}) async {
    if (_isRetrying) return;
    setState(() {
      _isRetrying = true;
      _textureError = null;
      if (isManualRetry) _textureId = null;
      _meshStatus = 'warming up renderer...';
      _meshStatusBusy = true;
      _meshStatusError = false;
    });
    try {
      final id = await _channel.invokeMethod<int>('createSharedNativeTexture');
      if (!mounted) return;
      setState(() {
        _textureId = id;
        _isRetrying = false;
        _meshStatus = 'loading DamagedHelmet.glb...';
        _meshStatusBusy = true;
        _meshStatusError = false;
      });
      if (id != null) {
        _pushMatrices();
        unawaited(_loadDefaultGlb(id));
      }
    } on MissingPluginException {
      if (!mounted) return;
      setState(() {
        _textureError =
            'plugin not registered (running on a non-iOS/macOS target?)';
        _isRetrying = false;
        _meshStatus = 'renderer unavailable';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _textureError = '${e.code}: ${e.message}';
        _isRetrying = false;
        _meshStatus = 'renderer unavailable';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    }
  }

  @override
  void dispose() {
    _meshStatusHideTimer?.cancel();
    _splashMinTimer?.cancel();
    _splashMaxTimer?.cancel();
    _lifecycle?.dispose();
    final id = _textureId;
    if (id != null) {
      _channel
          .invokeMethod('disposeTexture', {'textureId': id})
          .catchError((_) {});
    }
    super.dispose();
  }

  Future<void> _loadDefaultGlb(int textureId) async {
    const filename = 'DamagedHelmet.glb';
    String? found = await _materializeBundledGlb(filename);

    final cwd = Directory.current.path;
    final candidates = <String>[
      '$cwd/aether_cpp/build/test_assets/$filename',
      '$cwd/../aether_cpp/build/test_assets/$filename',
      '$cwd/../../aether_cpp/build/test_assets/$filename',
      '/Users/kaidongwang/Documents/Aether3D-cross/aether_cpp/build/test_assets/$filename',
    ];
    if (found == null) {
      for (final c in candidates) {
        try {
          if (await File(c).exists()) {
            found = c;
            break;
          }
        } catch (_) {}
      }
    }
    if (found == null) {
      if (!mounted) return;
      setState(() {
        _meshStatus =
            'mesh: $filename not found (asset bundle + cwd / ../ / ../../ / dev abspath)';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
      return;
    }
    try {
      if (!mounted) return;
      setState(() {
        _meshStatus = 'loading $filename...';
        _meshStatusBusy = true;
        _meshStatusError = false;
      });
      await _channel.invokeMethod('loadGlb', {
        'textureId': textureId,
        'path': found,
      });
      if (!mounted) return;
      const readyStatus = 'mesh ready';
      setState(() {
        _meshStatus = readyStatus;
        _meshStatusBusy = false;
        _meshStatusError = false;
      });
      _scheduleMeshStatusAutoHide(readyStatus);
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _meshStatus = 'mesh: ${e.code} - ${e.message ?? "(no message)"}';
        _meshStatusBusy = false;
        _meshStatusError = true;
      });
    }
  }

  /// Switches the running viewer scene to a different bundled GLB without
  /// recreating the IOSurface. Called from VaultPage taps on sample
  /// cards; idempotent against re-loads of the same file.
  String? _currentlyLoadedGlbAsset;
  Future<void> _loadGlbAsset(String filename) async {
    final id = _textureId;
    if (id == null) return;
    if (_currentlyLoadedGlbAsset == filename) return;
    _currentlyLoadedGlbAsset = filename;
    final found = await _materializeBundledGlb(filename);
    if (found == null) return;
    try {
      await _channel.invokeMethod('loadGlb', {
        'textureId': id,
        'path': found,
      });
    } catch (_) {
      _currentlyLoadedGlbAsset = null; // allow retry on next tap
    }
  }

  Future<String?> _materializeBundledGlb(String filename) async {
    final assetPath = 'assets/models/$filename';
    try {
      final bytes = await rootBundle.load(assetPath);
      final dir = Directory('${Directory.systemTemp.path}/aether3d_assets');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      final file = File('${dir.path}/$filename');
      await file.writeAsBytes(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        flush: false,
      );
      return file.path;
    } catch (e) {
      debugPrint('[PocketWorld] bundled GLB materialize miss: $e');
      return null;
    }
  }

  void _scheduleMeshStatusAutoHide(String statusToHide) {
    _meshStatusHideTimer?.cancel();
    _meshStatusHideTimer = Timer(const Duration(milliseconds: 1400), () {
      if (!mounted || _meshStatus != statusToHide) return;
      setState(() {
        _meshStatus = null;
        _meshStatusBusy = false;
        _meshStatusError = false;
      });
    });
  }

  void _pushMatrices() {
    final id = _textureId;
    if (id == null) return;
    final viewBytes = _orbit.viewMatrix();
    final modelBytes = _object.modelMatrix();
    _channel
        .invokeMethod('setMatrices', {
          'textureId': id,
          'view': viewBytes,
          'model': modelBytes,
        })
        .catchError((_) {});
  }

  void _handleScaleUpdate(
    double scale,
    Offset focalDelta,
    double rotation,
    int pointerCount,
    Size widgetSize,
  ) {
    setState(() {
      if (pointerCount <= 1) {
        _orbit.rotate(focalDelta.dx, focalDelta.dy, widgetSize);
      } else {
        _orbit.dolly(scale);
        _object.pan(
          focalDelta,
          _orbit.viewMatrix(),
          _fovYRadians,
          _orbit.distance,
          widgetSize,
        );
        _object.rotate(rotation);
        _orbit.target.setFrom(_object.position);
      }
    });
    _pushMatrices();
  }

  Widget _buildCapturePage(
    BuildContext ctx,
    CaptureMode mode, {
    bool viewerMode = false,
    String? viewerTitle,
    String? viewerGlbAsset,
  }) {
    // Side-effect: when a viewer wants a different GLB than what the
    // shared scene renderer currently has loaded, fire a loadGlb on the
    // method channel before mounting the CapturePage. The native side
    // re-uploads the new mesh into the existing IOSurface, so we don't
    // need to recreate the texture or restart the orbit controls.
    if (viewerMode && viewerGlbAsset != null) {
      unawaited(_loadGlbAsset(viewerGlbAsset));
    }
    return CapturePage(
      mode: mode,
      textureId: _textureId,
      textureError: _textureError,
      isRetrying: _isRetrying,
      onRetryTexture: () => _requestTexture(isManualRetry: true),
      meshStatus: _meshStatus,
      meshStatusBusy: _meshStatusBusy,
      meshStatusError: _meshStatusError,
      orbit: _orbit,
      textureWidgetSize: _textureWidgetSize,
      onScaleUpdate: _handleScaleUpdate,
      resolveVersionFooter: _resolveVersionFooter,
      viewerMode: viewerMode,
      viewerTitle: viewerTitle,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DesignInspectorHost(
      child: Stack(
        children: [
          AetherAppShell(capturePageBuilder: _buildCapturePage),
          Positioned.fill(
            child: AetherSplashOverlay(
              visible: _splashVisible,
              progressMessage: _splashMessage(context),
            ),
          ),
        ],
      ),
    );
  }
}

String _resolveVersionFooter() {
  try {
    return AetherFfi.versionString();
  } on FfiResolutionError catch (e) {
    return 'FFI miss: ${e.message}';
  } on ArgumentError catch (e) {
    return 'FFI miss: ${e.message ?? e.toString()}';
  } catch (e) {
    return 'FFI error: ${e.runtimeType}';
  }
}
