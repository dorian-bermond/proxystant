import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_artwork_picker/services/update_service.dart';

void main() {
  group('parseVersionLine', () {
    test('reads the top-level version key', () {
      const pubspec = '''
name: mtg_artwork_picker
description: "An app to assist in creating MTG proxies"
publish_to: "none"

version: 1.3.0+4

environment:
  sdk: ^3.10.4
''';
      expect(UpdateService.parseVersionLine(pubspec), '1.3.0');
    });

    test('ignores indented version keys from dependencies', () {
      const pubspec = '''
name: mtg_artwork_picker
dependencies:
  some_package:
    version: 9.9.9
version: 1.3.0+4
''';
      expect(UpdateService.parseVersionLine(pubspec), '1.3.0');
    });

    test('returns null when there is no version', () {
      expect(UpdateService.parseVersionLine('name: foo\n'), isNull);
      expect(UpdateService.parseVersionLine('version:\n'), isNull);
    });
  });

  group('normalizeVersion', () {
    test('strips the release tag prefix', () {
      expect(UpdateService.normalizeVersion('v1.3.0'), '1.3.0');
      expect(UpdateService.normalizeVersion('V1.3.0'), '1.3.0');
      expect(UpdateService.normalizeVersion('1.3.0'), '1.3.0');
    });

    test('strips a pubspec build suffix', () {
      expect(UpdateService.normalizeVersion('1.3.0+4'), '1.3.0');
      expect(UpdateService.normalizeVersion('v1.3.0+4'), '1.3.0');
    });
  });

  group('isNewer', () {
    test('detects a newer release', () {
      expect(UpdateService.isNewer(latest: 'v1.3.1', current: '1.3.0'), isTrue);
      expect(UpdateService.isNewer(latest: 'v1.4.0', current: '1.3.9'), isTrue);
      expect(UpdateService.isNewer(latest: 'v2.0.0', current: '1.9.9'), isTrue);
    });

    test('is false when equal, ignoring tag prefix and build suffix', () {
      expect(UpdateService.isNewer(latest: 'v1.3.0', current: '1.3.0'), isFalse);
      expect(
        UpdateService.isNewer(latest: 'v1.3.0', current: '1.3.0+4'),
        isFalse,
      );
    });

    test('is false when the running build is ahead of the last release', () {
      expect(UpdateService.isNewer(latest: 'v1.3.0', current: '1.4.0'), isFalse);
    });

    test('compares numerically, not as strings', () {
      // The bug this guards: '1.10.0' < '1.9.0' under string comparison.
      expect(UpdateService.isNewer(latest: 'v1.10.0', current: '1.9.0'), isTrue);
      expect(
        UpdateService.isNewer(latest: 'v1.9.0', current: '1.10.0'),
        isFalse,
      );
    });

    test('treats a missing part as zero', () {
      expect(UpdateService.isNewer(latest: 'v1.3', current: '1.3.0'), isFalse);
      expect(UpdateService.isNewer(latest: 'v1.3.1', current: '1.3'), isTrue);
    });

    test('never advertises a pre-release over the matching stable', () {
      expect(
        UpdateService.isNewer(latest: 'v1.3.0-beta.1', current: '1.3.0'),
        isFalse,
      );
    });

    test('handles garbage without throwing', () {
      expect(UpdateService.isNewer(latest: 'nightly', current: '1.3.0'), isFalse);
      expect(UpdateService.isNewer(latest: '', current: '1.3.0'), isFalse);
    });
  });
}
