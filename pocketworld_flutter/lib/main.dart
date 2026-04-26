// Phase 2.4 PocketWorld hello main screen.
//
// The footer Text widget below hardcodes "v0.1.0-phase2" as a placeholder.
// Phase 3.5 was supposed to replace it with a real FFI call to
// aether_version_string(); P3.4 validated the FFI design on macOS Dart CLI
// (see tool/aether_ffi_smoke.dart) but the iOS final-mile (CocoaPods static
// xcframework extraction) hit a 1.16 quirk and is deferred — see
// aether_cpp/PHASE_BACKLOG.md for the trigger to revisit.

import 'package:flutter/material.dart';

void main() {
  runApp(const PocketWorldApp());
}

class PocketWorldApp extends StatelessWidget {
  const PocketWorldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PocketWorld',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: Text(
                'PocketWorld',
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                // P2.4 placeholder. Phase 3.5 deferred — see PHASE_BACKLOG.md.
                // When iOS Pod xcframework integration is unstuck, the source
                // becomes aether_version_string() via dart:ffi (mechanics
                // already proven on macOS in tool/aether_ffi_smoke.dart).
                child: Text(
                  'v0.1.0-phase2',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
