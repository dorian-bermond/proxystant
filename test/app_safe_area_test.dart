import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mtg_artwork_picker/app.dart';

void main() {
  testWidgets('app body is inset above the system navigation bar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    tester.view.viewPadding = const FakeViewPadding(top: 60, bottom: 48);
    tester.view.padding = const FakeViewPadding(top: 60, bottom: 48);
    addTearDown(tester.view.reset);

    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(title: const Text('T')),
            body: Container(key: const Key('body'), color: Colors.red),
          ),
        ),
      ],
    );

    await tester.pumpWidget(ProviderScope(child: App(router: router)));
    await tester.pump();

    final body = tester.getRect(find.byKey(const Key('body')));
    // 2400 tall screen, 48 of nav bar reserved at the bottom.
    expect(body.bottom, 2400 - 48);

    // AppBar still extends behind the status bar.
    expect(tester.getRect(find.byType(AppBar)).top, 0);
  });
}
