// Phase 2.4 PocketWorld hello main screen.
//
// Throwaway scaffold to validate the Flutter UI path end-to-end on
// iOS Simulator. Real product visual language is decided later, not here.

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
                // Pre-positioned Phase 3 FFI hook. In Phase 3 (dart:ffi to
                // aether_cpp) this hardcoded string becomes a call to
                // aether_version_string() — one-line change, widget tree
                // doesn't move. Don't delete this Text on the grounds that
                // it "looks like a placeholder"; it is, deliberately.
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
