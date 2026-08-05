import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mtg_artwork_picker/features/updates/update_banner.dart';
import 'package:mtg_artwork_picker/providers/providers.dart';
import 'package:mtg_artwork_picker/services/http_client.dart';
import 'package:mtg_artwork_picker/services/update_service.dart';

/// Serves a canned pubspec instead of the real bundled one, so the test does
/// not change meaning every time the app version is bumped.
class _FakeBundle extends CachingAssetBundle {
  _FakeBundle(this.pubspec);

  final String pubspec;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.view(Uint8List.fromList(utf8.encode(pubspec)).buffer);
}

String _releaseJson(String tag) => jsonEncode({
      'tag_name': tag,
      'html_url':
          'https://github.com/dorian-bermond/proxystant/releases/tag/$tag',
    });

UpdateService _service({
  required String currentVersion,
  required String latestTag,
  int status = 200,
}) {
  final client = MockClient(
    (_) async => http.Response(_releaseJson(latestTag), status),
  );
  return UpdateService(
    AppHttpClient(client),
    assets: _FakeBundle('name: mtg_artwork_picker\nversion: $currentVersion\n'),
  );
}

Future<void> _pump(WidgetTester tester, UpdateService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [updateServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(
        home: Scaffold(body: UpdateBanner(child: Text('app'))),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('banners a newer release with both versions named', (
    tester,
  ) async {
    await _pump(
      tester,
      _service(currentVersion: '1.2.0+3', latestTag: 'v1.3.0'),
    );

    expect(
      find.text('Version 1.3.0 is available (you have 1.2.0).'),
      findsOneWidget,
    );
    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('stays silent when up to date', (tester) async {
    await _pump(
      tester,
      _service(currentVersion: '1.3.0+4', latestTag: 'v1.3.0'),
    );

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('stays silent when the running build is ahead', (tester) async {
    await _pump(
      tester,
      _service(currentVersion: '1.4.0+5', latestTag: 'v1.3.0'),
    );

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('stays silent when the API call fails', (tester) async {
    await _pump(
      tester,
      _service(currentVersion: '1.2.0+3', latestTag: 'v1.3.0', status: 503),
    );

    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('Later dismisses the banner', (tester) async {
    await _pump(
      tester,
      _service(currentVersion: '1.2.0+3', latestTag: 'v1.3.0'),
    );
    expect(find.byType(MaterialBanner), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();

    expect(find.byType(MaterialBanner), findsNothing);
  });
}
