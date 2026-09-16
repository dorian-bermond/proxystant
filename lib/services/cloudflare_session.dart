import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as iaw;

/// Fetches magic-ville.com through a hidden WebView, to get past the
/// Cloudflare bot check in front of it.
///
/// Cloudflare refuses `dart:io` requests to that host with HTTP 403 and a
/// "Just a moment..." page. Measured against the live site, it is the *client*
/// that is being scored, not a missing token: a real WebView loads the same
/// URLs fine while never being issued a `cf_clearance` cookie at all, so there
/// is nothing to harvest and replay — only cookies like `mvshop` come back.
/// Requests therefore have to be made from inside the WebView, where they
/// carry a browser's TLS fingerprint, HTTP/2 and header order.
///
/// [MagicVilleClient] still tries plain HTTP first, because it is far cheaper
/// and works whenever Cloudflare is not scoring the client; this is the
/// recovery path for when it does.
class CloudflareSession {
  CloudflareSession({this.origin = 'https://www.magic-ville.com/fr/'});

  /// Page loaded to give the WebView a same-origin context; any page on the
  /// host will do. `fetch` from that context is same-origin, so it is not
  /// subject to CORS and carries the site's cookies.
  final String origin;

  /// How long to wait for a navigation, including any challenge interstitial
  /// resolving itself.
  static const _navigationTimeout = Duration(seconds: 30);

  static const _pollInterval = Duration(milliseconds: 400);

  /// Cookies the WebView holds for the host. Replaying these does not get a
  /// `dart:io` request past Cloudflare on its own, but they carry the site's
  /// own session, which its PHP pages do use.
  final Map<String, String> cookies = {};

  /// The WebView's own user agent, so replayed requests at least agree with
  /// the browser the cookies came from.
  String? userAgent;

  iaw.HeadlessInAppWebView? _webView;
  String? _currentUrl;

  /// Set once the platform has proved it cannot host a WebView, so the app
  /// stops paying for attempts that can never succeed.
  bool _unavailable = false;

  Future<bool>? _pendingWarmUp;
  bool _warmedUp = false;

  /// Serializes WebView work: one headless WebView cannot render two pages at
  /// once, and this doubles as request pacing.
  Future<void> _queue = Future.value();

  bool get isSupported {
    if (_unavailable || kIsWeb) return false;
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows;
  }

  /// Whether a `cf_clearance` cookie is held. Observed to stay false against
  /// the live site — kept because a cheap cookie replay is worth attempting if
  /// Cloudflare's configuration ever starts issuing one.
  bool get hasClearance => cookies.containsKey('cf_clearance');

  /// Loads [origin] once so the WebView has a same-origin context and its
  /// cookies are known. Attempted a single time per session: when it yields no
  /// clearance cookie, repeating it just costs page loads.
  Future<bool> warmUp({bool force = false}) {
    if (!isSupported) return Future.value(false);
    if (!force && _warmedUp) return Future.value(hasClearance);
    return _pendingWarmUp ??= _runWarmUp().whenComplete(
      () => _pendingWarmUp = null,
    );
  }

  Future<bool> _runWarmUp() async {
    final html = await renderHtml(origin);
    _warmedUp = html != null;
    return hasClearance;
  }

  /// Loads [url] in the hidden WebView and returns the rendered HTML, or null
  /// when the WebView is unavailable or the page never resolved.
  Future<String?> renderHtml(String url) => _serialize(() => _render(url));

  /// Fetches [url] from inside the WebView and returns its bytes and MIME
  /// type. Used for the image endpoint, which is a PHP script on the same host
  /// and so sits behind the same bot check as the card pages, but is not HTML
  /// and cannot be read out of a rendered document.
  Future<({Uint8List bytes, String mime})?> fetchBytes(String url) =>
      _serialize(() => _fetchBytes(url));

  /// POSTs a form from inside the WebView and returns the response body.
  /// The search is a POST, so it cannot be replayed as a navigation.
  Future<String?> postForm(String url, Map<String, String> fields) =>
      _serialize(() => _postForm(url, fields));

  /// Runs [action] after any queued WebView work, keeping the chain alive when
  /// one step fails.
  Future<T?> _serialize<T>(Future<T?> Function() action) {
    if (!isSupported) return Future.value(null);
    final next = _queue.then((_) => action());
    _queue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<String?> _render(String url) async {
    final controller = await _controller();
    if (controller == null) return null;

    try {
      await controller.loadUrl(
        urlRequest: iaw.URLRequest(url: iaw.WebUri(url)),
      );

      final deadline = DateTime.now().add(_navigationTimeout);
      String? html;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollInterval);
        final current = await _outerHtml(controller);
        if (current == null || current.length < 200) continue; // navigating
        if (_looksChallenged(current)) continue; // interstitial still up
        html = current;
        break;
      }

      await _harvest(controller);
      if (html == null) {
        debugPrint('CloudflareSession: $url never resolved past the challenge');
        return null;
      }
      _currentUrl = url;
      return html;
    } catch (e, st) {
      debugPrint('CloudflareSession.renderHtml($url) failed: $e\n$st');
      return null;
    }
  }

  /// Recognizes Cloudflare's interstitial.
  ///
  /// Deliberately does NOT look for 'challenge-platform': Cloudflare injects
  /// that beacon script into *successful* responses too, so matching it made
  /// every good page look blocked.
  static bool _looksChallenged(String html) =>
      html.contains('<title>Just a moment') ||
      html.contains('cf-browser-verification') ||
      html.contains('id="challenge-running"') ||
      html.contains('id="cf-challenge-running"');

  /// Ensures the WebView sits on a page of [origin]'s host, so that `fetch`
  /// from it is same-origin.
  Future<iaw.InAppWebViewController?> _sameOriginContext() async {
    final controller = await _controller();
    if (controller == null) return null;

    final host = Uri.parse(origin).host;
    final current = _currentUrl;
    if (current != null && Uri.tryParse(current)?.host == host) {
      return controller;
    }
    return await _render(origin) == null ? null : controller;
  }

  Future<({Uint8List bytes, String mime})?> _fetchBytes(String url) async {
    final controller = await _sameOriginContext();
    if (controller == null) return null;

    try {
      // Chunked so String.fromCharCode is not called with a huge argument
      // list, which blows the JS engine's stack on a full-size scan.
      final result = await controller.callAsyncJavaScript(
        functionBody: r'''
          const response = await fetch(url, { credentials: 'include' });
          if (!response.ok) return { status: response.status };
          const bytes = new Uint8Array(await response.arrayBuffer());
          let binary = '';
          const chunk = 0x8000;
          for (let i = 0; i < bytes.length; i += chunk) {
            binary += String.fromCharCode.apply(
              null, bytes.subarray(i, i + chunk),
            );
          }
          return {
            status: response.status,
            mime: response.headers.get('content-type') || '',
            data: btoa(binary),
          };
        ''',
        arguments: {'url': url},
      );

      if (result?.error != null) {
        debugPrint('CloudflareSession.fetchBytes($url): ${result?.error}');
        return null;
      }
      final value = result?.value;
      if (value is! Map) return null;

      final data = value['data'];
      if (data is! String || data.isEmpty) {
        debugPrint(
          'CloudflareSession.fetchBytes($url): HTTP ${value['status']}',
        );
        return null;
      }
      final mime = (value['mime'] as String?) ?? 'application/octet-stream';
      return (bytes: base64Decode(data), mime: mime.split(';').first.trim());
    } catch (e, st) {
      debugPrint('CloudflareSession.fetchBytes($url) failed: $e\n$st');
      return null;
    }
  }

  Future<String?> _postForm(String url, Map<String, String> fields) async {
    final controller = await _sameOriginContext();
    if (controller == null) return null;

    try {
      final result = await controller.callAsyncJavaScript(
        functionBody: r'''
          const response = await fetch(url, {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
            body: new URLSearchParams(fields).toString(),
          });
          return { status: response.status, body: await response.text() };
        ''',
        arguments: {'url': url, 'fields': fields},
      );

      if (result?.error != null) {
        debugPrint('CloudflareSession.postForm($url): ${result?.error}');
        return null;
      }
      final value = result?.value;
      if (value is! Map) return null;
      final body = value['body'];
      if (body is! String) return null;
      if (_looksChallenged(body)) {
        debugPrint('CloudflareSession.postForm($url): challenged');
        return null;
      }
      return body;
    } catch (e, st) {
      debugPrint('CloudflareSession.postForm($url) failed: $e\n$st');
      return null;
    }
  }

  Future<String?> _outerHtml(iaw.InAppWebViewController controller) async {
    try {
      final result = await controller.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      return result is String ? result : result?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<void> _harvest(iaw.InAppWebViewController controller) async {
    try {
      final jar = await iaw.CookieManager.instance().getCookies(
        url: iaw.WebUri(origin),
      );
      for (final c in jar) {
        final value = c.value.toString();
        if (value.isNotEmpty) cookies[c.name] = value;
      }
    } catch (e) {
      debugPrint('CloudflareSession: reading cookies failed: $e');
    }

    userAgent ??= await _readUserAgent(controller);
  }

  Future<String?> _readUserAgent(iaw.InAppWebViewController controller) async {
    try {
      final ua = await controller.evaluateJavascript(
        source: 'navigator.userAgent',
      );
      final text = ua is String ? ua : ua?.toString();
      return (text != null && text.isNotEmpty) ? text : null;
    } catch (_) {
      return null;
    }
  }

  Future<iaw.InAppWebViewController?> _controller() async {
    final existing = _webView;
    if (existing != null && existing.isRunning()) {
      return existing.webViewController;
    }

    try {
      final webView = iaw.HeadlessInAppWebView(
        initialSettings: iaw.InAppWebViewSettings(
          javaScriptEnabled: true,
          incognito: false,
          clearCache: false,
        ),
      );
      await webView.run();
      _webView = webView;
      _currentUrl = null;
      return webView.webViewController;
    } catch (e, st) {
      // No WebView here (or no WebView2 runtime on Windows).
      debugPrint('CloudflareSession: no WebView available: $e\n$st');
      _unavailable = true;
      await _disposeWebView();
      return null;
    }
  }

  Future<void> _disposeWebView() async {
    final webView = _webView;
    _webView = null;
    _currentUrl = null;
    if (webView == null) return;
    try {
      await webView.dispose();
    } catch (_) {}
  }

  Future<void> dispose() async {
    await _disposeWebView();
    cookies.clear();
    userAgent = null;
    _warmedUp = false;
  }
}
