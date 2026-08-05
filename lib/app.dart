import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'features/updates/update_banner.dart';
import 'providers/providers.dart';

class App extends ConsumerWidget {
  final GoRouter router;
  const App({super.key, required this.router});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncMode = ref.watch(themeModeProvider);
    final themeMode = switch (asyncMode) {
      AsyncData(:final value) => value,
      _ => ThemeMode.system,
    };
    return MaterialApp.router(
      title: 'MTG Artwork Picker',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.teal,
        brightness: Brightness.dark,
      ),
      themeMode: themeMode,
      // Android 15+ always renders edge-to-edge, so screens would otherwise
      // paint underneath the system navigation bar. Insetting here once covers
      // every route, dialog and bottom sheet. The top is left alone so AppBars
      // keep extending behind the status bar; left/right handle the landscape
      // nav bar and display cutouts. The ColoredBox fills the reserved strip
      // with the same color a Scaffold uses, instead of the Android window
      // background.
      builder: (context, child) => ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: SafeArea(
          top: false,
          child: UpdateBanner(child: child ?? const SizedBox.shrink()),
        ),
      ),
      routerConfig: router,
    );
  }
}
