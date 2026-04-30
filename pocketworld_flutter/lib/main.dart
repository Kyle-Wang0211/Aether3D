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
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth/auth_scope.dart';
import 'auth/current_user.dart';
import 'auth/mock_auth_service.dart';
import 'auth/supabase_auth_service.dart';
import 'i18n/locale_notifier.dart';
import 'l10n/app_localizations.dart';
import 'lifecycle_observer.dart';
import 'me/job_status_watcher.dart';
import 'object_transform.dart';
import 'orbit_controls.dart';
import 'ui/app_shell.dart';
import 'ui/auth/auth_root_view.dart';
import 'ui/design_system.dart';
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
      // Initialize Supabase with the published anon key + project URL
      // for our PocketWorld dev project. The anon key is intentionally
      // public — RLS policies on each table do the actual access
      // control. Replace with --dart-define overrides for prod.
      const supabaseUrl = String.fromEnvironment(
        'SUPABASE_URL',
        defaultValue: 'https://tzvwkqmgaourwqrmxbyb.supabase.co',
      );
      const supabaseAnonKey = String.fromEnvironment(
        'SUPABASE_ANON_KEY',
        defaultValue:
            'sb_publishable_ur4tTV2iXSV4NsL3YYttyw_SIjFAMST',
      );
      const initTimeout = Duration(seconds: 10);
      bool supabaseReady = false;
      try {
        await Supabase.initialize(
          url: supabaseUrl,
          anonKey: supabaseAnonKey,
          debug: false,
        ).timeout(initTimeout);
        supabaseReady = true;
      } catch (e) {
        debugPrint(
          '[main] Supabase.initialize failed/timeout: $e — '
          'continuing with mock auth.',
        );
      }
      if (supabaseReady) {
        // ignore: avoid_print
        print('[AUTH-DEBUG] Supabase.initialize done. '
            'currentSession exists: '
            '${Supabase.instance.client.auth.currentSession != null} '
            'currentUser: '
            '${Supabase.instance.client.auth.currentUser?.email ?? "null"}');
        currentUser.swapService(
          SupabaseAuthServiceImpl(localeNotifier: localeNotifier),
        );
      }
      await currentUser.bootstrap();
      // Belt-and-braces: kick a session refresh on cold start. Even
      // though supabase_flutter has autoRefreshToken=true and runs a
      // proactive ~10s-before-expiry refresh in the foreground, that
      // timer doesn't help if the app just woke from being killed and
      // the persisted access_token is already past its exp. The
      // AetherApiClient's 401-retry would catch this anyway, but doing
      // it here saves the first request from doing the dance and means
      // the server logs don't show spurious 401s on app launch.
      // Failure is silent — refreshSession throws if the refresh
      // token's also dead, and that's the same "session_expired" path
      // the rest of the code handles already.
      if (supabaseReady) {
        unawaited(
          Supabase.instance.client.auth
              .refreshSession()
              .then<void>((_) {})
              .catchError((Object e) {
            debugPrint('[main] cold-start refreshSession skipped: $e');
          }),
        );
      }
      // Resume any in-flight job polls after Supabase is ready (the
      // watcher needs the JWT to be loaded before it can call
      // /v1/mobile-jobs/{id} for the still-running scans).
      unawaited(JobStatusWatcher.instance.resume());
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
            home: const _AuthGate(),
            // AuthScope wraps the *route content* via builder rather than
            // sitting inside `home`. Why: `home` is only the FIRST route on
            // the Navigator. When MePage does `Navigator.push(MaterialPageRoute(
            // builder: (_) => MeSettingsPage()))`, the pushed route lives
            // as a sibling of the home route inside the Navigator's overlay
            // — its BuildContext does NOT walk up through `home`'s subtree,
            // so `context.getInheritedWidgetOfExactType<AuthScope>()` from
            // MeSettingsPage's button used to come back null and the
            // `notifier!` assertion in AuthScope.read crashed the sign-out
            // gesture (see crash 2026-04-30 in the log:
            // `AuthScope.read … _SignOutButton.build`). The `builder`
            // callback is invoked for every route MaterialApp shows, so
            // wrapping `child` here makes AuthScope available to home AND
            // every pushed route uniformly.
            builder: (context, child) => AuthScope(
              currentUser: currentUser,
              child: child!,
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
  // Tracks the previous CurrentUserState so we can detect a signedIn →
  // signedOut transition and tear down any pushed routes that were
  // sitting on top of HomeScreen (MyWorkDetailPage, MeSettingsPage,
  // …). Without this, swiping back from a stale detail page after a
  // background-kill / cold-start session-restore race reveals the auth
  // page underneath, which is jarring.
  bool _wasSignedIn = false;

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

    // signedIn → signedOut transition: pop any routes pushed on top of
    // home so the user isn't left with a stale detail / settings page
    // hovering over AuthRootView. addPostFrameCallback so this runs
    // outside of build() (Navigator.popUntil during build asserts).
    if (_wasSignedIn && state is CurrentUserSignedOut) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final navigator = Navigator.maybeOf(context);
        navigator?.popUntil((r) => r.isFirst);
      });
    }
    _wasSignedIn = state is CurrentUserSignedIn;

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

  @override
  Widget build(BuildContext context) {
    // DesignInspectorHost wrapper removed 2026-04-29 — the floating ✨
    // toggle, the dashed-border DesignBox overlays, and the bottom
    // legend were dev affordances that are no longer wanted in the
    // shipped UI. The DesignBox call sites stay (they pass through
    // their child when no DesignInspector ancestor exists), so we don't
    // have to surgically remove every one.
    //
    // _buildCapturePage / capture-page state plumbing removed 2026-04-29
    // — the old Dawn-backed CapturePage + CaptureModeSelectionPage are
    // gone, awaiting the Aether3D capture-pipeline port (ARKit + dome
    // + FrameAnalyzer + A100 remote pipeline). The "_textureId / _orbit
    // / _meshStatus" state on this State class is now dead code; left
    // in place for the moment because the texture acquisition path
    // (_requestTexture, _loadGlbAsset, _handleScaleUpdate) is what the
    // ported capture flow will reattach to.
    return Stack(
      children: [
        const AetherAppShell(),
        Positioned.fill(
          child: AetherSplashOverlay(
            visible: _splashVisible,
            progressMessage: _splashMessage(context),
          ),
        ),
      ],
    );
  }
}

