import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The Android download notification: an ongoing entry carrying a progress bar
/// that fills the same way the in-app `LinearProgressIndicator` does, replaced
/// by a "Download finished" entry when the run ends.
///
/// Implemented natively (android/.../DownloadNotifications.kt) because
/// flutter_foreground_task has no progress-bar API; the native side reuses the
/// foreground service's notification id so this augments that notification
/// rather than adding a second one.
///
/// Every method is a no-op off Android, where no download notification exists.
class DownloadNotifications {
  DownloadNotifications._();

  static const _channel = MethodChannel('proxystant/download_notifications');

  static bool get _supported => !kIsWeb && Platform.isAndroid;

  /// Android drops notification updates posted more than a few times a second,
  /// so identical and too-frequent posts are filtered here instead.
  static String? _lastKey;
  static DateTime _lastPostedAt = DateTime.fromMillisecondsSinceEpoch(0);
  static const _minInterval = Duration(milliseconds: 400);

  /// Updates the ongoing notification. [processed] of [total] cards drives the
  /// bar; a [total] of 0 shows an indeterminate bar.
  static Future<void> showProgress({
    required int processed,
    required int total,
    required String text,
  }) async {
    if (!_supported) return;

    final key = '$processed/$total|$text';
    if (key == _lastKey) return;
    final now = DateTime.now();
    if (now.difference(_lastPostedAt) < _minInterval) return;
    _lastKey = key;
    _lastPostedAt = now;

    await _invoke('showProgress', {
      'title': 'Downloading Artworks',
      'text': text,
      'subText': total > 0 ? '$processed/$total cards' : null,
      'processed': processed,
      'total': total,
    });
  }

  /// Replaces the ongoing notification with a dismissible completion entry.
  /// Posted under its own id, because stopping the foreground service clears
  /// the ongoing one.
  static Future<void> showFinished({
    required String title,
    required String text,
  }) async {
    _reset();
    if (!_supported) return;
    await _invoke('showFinished', {'title': title, 'text': text});
  }

  /// Clears the ongoing notification without posting a completion entry.
  static Future<void> cancel() async {
    _reset();
    if (!_supported) return;
    await _invoke('cancel', const {});
  }

  static void _reset() {
    _lastKey = null;
    _lastPostedAt = DateTime.fromMillisecondsSinceEpoch(0);
  }

  static Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (e) {
      // A notification is never worth failing a download over.
      debugPrint('DownloadNotifications.$method failed: $e');
    }
  }
}
