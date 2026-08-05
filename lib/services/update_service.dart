import 'dart:convert';

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

import 'http_client.dart';

/// A newer release than the one currently running.
class AvailableUpdate {
  final String currentVersion;
  final String latestVersion;

  /// GitHub release page, where the build artifacts are attached.
  final String downloadUrl;

  const AvailableUpdate({
    required this.currentVersion,
    required this.latestVersion,
    required this.downloadUrl,
  });
}

/// Compares the running app version against the latest published GitHub
/// release.
///
/// The release workflow publishes a Release for every `v*` tag, so the latest
/// release is the newest downloadable build.
class UpdateService {
  static const _releasesApi =
      'https://api.github.com/repos/dorian-bermond/proxystant/releases/latest';

  /// Fallback when the API cannot be reached but a link is still useful.
  static const releasesPage =
      'https://github.com/dorian-bermond/proxystant/releases/latest';

  static const _timeout = Duration(seconds: 8);

  final AppHttpClient http;

  /// Overridable so tests can supply a pubspec without touching the bundle.
  final AssetBundle assets;

  UpdateService(this.http, {AssetBundle? assets})
      : assets = assets ?? rootBundle;

  /// The running app's version, read from the bundled pubspec.
  ///
  /// pubspec.yaml is shipped as an asset so this cannot drift from the version
  /// the release tag is cut from.
  Future<String?> currentVersion() async {
    final pubspec = await assets.loadString('pubspec.yaml');
    return parseVersionLine(pubspec);
  }

  /// Extracts the value of the top-level `version:` key from [pubspec].
  static String? parseVersionLine(String pubspec) {
    for (final line in pubspec.split('\n')) {
      // Top-level key only: a nested `version:` is indented.
      if (!line.startsWith('version:')) continue;
      final value = line.substring('version:'.length).trim();
      if (value.isEmpty) return null;
      return normalizeVersion(value);
    }
    return null;
  }

  /// Returns the available update, or null when up to date.
  ///
  /// Never throws: this runs on startup, where a failed check (offline, rate
  /// limited, malformed response) must be indistinguishable from being up to
  /// date rather than something the user has to acknowledge.
  Future<AvailableUpdate?> checkForUpdate() async {
    try {
      final current = await currentVersion();
      if (current == null) return null;

      final res = await http
          .getUrl(
            _releasesApi,
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Proxystant',
            },
          )
          .timeout(_timeout);

      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;

      final tag = body['tag_name'] as String?;
      if (tag == null || tag.isEmpty) return null;

      final latestVersion = normalizeVersion(tag);
      if (!isNewer(latest: latestVersion, current: current)) return null;

      return AvailableUpdate(
        currentVersion: current,
        latestVersion: latestVersion,
        downloadUrl: (body['html_url'] as String?) ?? releasesPage,
      );
    } catch (_) {
      return null;
    }
  }

  /// Strips the `v` prefix used by the release tags, and any build suffix that
  /// pubspec-style versions carry (`1.3.0+4` -> `1.3.0`).
  static String normalizeVersion(String raw) {
    var v = raw.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    final plus = v.indexOf('+');
    if (plus != -1) v = v.substring(0, plus);
    return v.trim();
  }

  /// True when [latest] is a strictly higher version than [current].
  ///
  /// Compares dot-separated numeric parts, so 1.10.0 correctly beats 1.9.0. A
  /// missing part counts as 0 (1.3 == 1.3.0). Anything non-numeric — a
  /// pre-release suffix such as `1.4.0-beta.1` — stops the comparison at that
  /// part and is treated as equal, so a pre-release never advertises itself
  /// over the matching stable version.
  static bool isNewer({required String latest, required String current}) {
    final a = _parts(normalizeVersion(latest));
    final b = _parts(normalizeVersion(current));

    for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
      final x = i < a.length ? a[i] : 0;
      final y = i < b.length ? b[i] : 0;
      if (x != y) return x > y;
    }
    return false;
  }

  static List<int> _parts(String version) {
    final out = <int>[];
    for (final part in version.split('.')) {
      final n = int.tryParse(part);
      if (n == null) break;
      out.add(n);
    }
    return out;
  }
}
