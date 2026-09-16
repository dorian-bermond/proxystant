import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'magicville_parser.dart';

/// Outcome of a MagicVille name search, carrying enough detail for the run log
/// to distinguish "the site refused us" from "the site answered, no match".
/// Telling those apart from the logs alone was impossible before.
class MagicVilleSearchResult {
  /// HTTP status of the search response, or 0 when the request never got one.
  final int statusCode;
  final List<String> refs;

  /// Set when the request threw instead of returning a response.
  final String? error;

  const MagicVilleSearchResult({
    required this.statusCode,
    this.refs = const [],
    this.error,
  });

  /// Cloudflare answers a challenged client with 403 (or 503 for the interstitial).
  bool get blocked => statusCode == 403 || statusCode == 503;

  String get describe {
    if (error != null) return 'request failed: $error';
    if (blocked) {
      return 'HTTP $statusCode — MagicVille refused the request '
          '(Cloudflare challenge), not a missing card';
    }
    if (statusCode != 200) return 'HTTP $statusCode';
    return 'HTTP 200, ${refs.length} ref(s)'
        '${refs.isEmpty ? "" : ": ${refs.take(8).join(", ")}"}';
  }
}

class MagicVilleClient {
  final MagicVilleParser parser;
  final HttpClient _http;

  MagicVilleClient(this.parser, {HttpClient? http})
    : _http = http ?? HttpClient() {
    // Prevent indefinite hangs
    _http.connectionTimeout = const Duration(seconds: 12);
    _http.idleTimeout = const Duration(seconds: 15);
  }

  static const _base = 'https://www.magic-ville.com/fr/';

  static const Duration _requestTimeout = Duration(seconds: 15);

  /// A real browser UA. The previous 'Mozilla/5.0 (Android; Flutter)' is an
  /// obvious bot signature, and magic-ville.com now sits behind a Cloudflare
  /// managed challenge that answers flagged clients with HTTP 403 and a
  /// "Just a moment..." page instead of the card HTML.
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

  /// Dart's HttpClient does not persist cookies between requests, so every
  /// call used to arrive session-less: the advanced search's "pre-flight GET to
  /// establish a session cookie" could never actually carry one over, and a PHP
  /// form flow that keeps its criteria in the session had nothing to work with.
  /// Cloudflare's own clearance cookies were dropped the same way.
  final Map<String, String> _cookies = {};

  void _prepare(HttpClientRequest req, {String? referer}) {
    req.headers
      ..set(HttpHeaders.userAgentHeader, _userAgent)
      ..set(
        HttpHeaders.acceptHeader,
        'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      )
      ..set(HttpHeaders.acceptLanguageHeader, 'fr-FR,fr;q=0.9,en;q=0.8');
    if (referer != null && referer.isNotEmpty) {
      req.headers.set(HttpHeaders.refererHeader, referer);
    }
    if (_cookies.isNotEmpty) {
      req.headers.set(
        HttpHeaders.cookieHeader,
        _cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
      );
    }
  }

  void _rememberCookies(HttpClientResponse res) {
    for (final c in res.cookies) {
      if (c.value.isEmpty) {
        _cookies.remove(c.name);
      } else {
        _cookies[c.name] = c.value;
      }
    }
  }

  Future<String> _getHtml(Uri uri) async {
    final req = await _http
        .getUrl(uri)
        .timeout(
          _requestTimeout,
          onTimeout: () {
            throw TimeoutException(
              'MagicVille getUrl timeout',
              _requestTimeout,
            );
          },
        );

    _prepare(req, referer: _base);

    final res = await req.close().timeout(
      _requestTimeout,
      onTimeout: () {
        throw TimeoutException('MagicVille close timeout', _requestTimeout);
      },
    );
    _rememberCookies(res);

    // Read bytes first (avoids decodeStream hanging + lets us pick encoding)
    final bytes = await consolidateHttpClientResponseBytes(res).timeout(
      _requestTimeout,
      onTimeout: () {
        throw TimeoutException(
          'MagicVille read bytes timeout',
          _requestTimeout,
        );
      },
    );

    if (res.statusCode != 200) {
      throw HttpException('MagicVille HTTP ${res.statusCode}', uri: uri);
    }

    // Decode according to declared charset (Magic-Ville often isn’t UTF-8)
    final charset = res.headers.contentType?.charset?.toLowerCase().trim();
    final Encoding enc =
        (charset == 'iso-8859-1' ||
            charset == 'iso_8859-1' ||
            charset == 'latin1' ||
            charset == 'windows-1252')
        ? latin1
        : utf8;

    try {
      return enc.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  Future<(List<MagicVilleArtworkInfo>, List<String>)> fetchArtworkInfo({
    required String ref,
  }) async {
    final uri = Uri.parse('${_base}carte_art?ref=$ref');
    final htmlText = await _getHtml(uri);
    return parser.parseArtworkPage(htmlText);
  }

  /// Non-throwing probe: returns null on network/HTTP error.
  /// A non-null result with an empty artwork list means the page exists but
  /// has no scan_art image; the refs list still contains edition links.
  Future<(List<MagicVilleArtworkInfo>, List<String>)?> tryFetchArtworkInfo({
    required String ref,
  }) async {
    try {
      return await fetchArtworkInfo(ref: ref);
    } catch (_) {
      return null;
    }
  }

  /// Matches links to a card page or an artwork page, with or without a
  /// leading slash, as they appear in search results and on card pages.
  static final RegExp _refLink = RegExp(
    r'carte(?:_art)?\?ref=([a-z0-9]+)',
    caseSensitive: false,
  );

  List<String> _extractRefs(String html) {
    final seen = <String>{};
    for (final m in _refLink.allMatches(html)) {
      final ref = m.group(1);
      if (ref != null && ref.isNotEmpty) seen.add(ref);
    }
    return seen.toList();
  }

  /// POST to MagicVille's advanced search (`resultats`) on the card title and
  /// return every ref found in the results page. The caller downloads all of
  /// them so the user can choose the illustration they prefer.
  ///
  /// [speType] narrows the search to a special card type (`TK` for tokens);
  /// omit it to search every card.
  Future<MagicVilleSearchResult> _searchRefsByTitle(
    String name, {
    String? speType,
  }) async {
    final formUri = Uri.parse('${_base}rech_avancee');
    final postUri = Uri.parse('${_base}resultats');

    // Pre-flight GET to establish a session cookie before the POST.
    try {
      await _getHtml(formUri);
    } catch (_) {}

    final params = <String, String>{
      'manachecksum': '',
      if (speType != null) 'spe_options': 'selected',
      'manaonly': '1',
      'color_search': '1',
      'type_search': '1',
      'spe_type': ?speType,
      'graph_aff': '1',
      'fra': '1',
      'eng': '1',
      'recherche_titre': name.toLowerCase(),
      'recherche_type': '',
      'recherche_texte': '',
      'costx': '1',
      'forx': '1',
      'endx': '1',
      'x': '0',
      'y': '0',
      'dci': '',
    };

    final body = params.entries
        .map(
          (e) =>
              '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}',
        )
        .join('&');
    final bodyBytes = utf8.encode(body);

    final request = await _http
        .postUrl(postUri)
        .timeout(
          _requestTimeout,
          onTimeout: () => throw TimeoutException(
            'MagicVille search timeout',
            _requestTimeout,
          ),
        );
    _prepare(request, referer: '${_base}rech_avancee');
    request.headers
      ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
      ..set(HttpHeaders.contentLengthHeader, '${bodyBytes.length}')
      ..set('Origin', 'https://www.magic-ville.com');
    request.add(bodyBytes);

    final response = await request.close().timeout(
      _requestTimeout,
      onTimeout: () => throw TimeoutException(
        'MagicVille search close timeout',
        _requestTimeout,
      ),
    );
    debugPrint(
      'MV search "$name" spe=${speType ?? "-"} status=${response.statusCode} '
      'location=${response.headers.value(HttpHeaders.locationHeader)}',
    );
    _rememberCookies(response);
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>().catchError((_) {});
      return MagicVilleSearchResult(statusCode: response.statusCode);
    }

    final html = await _readBody(response);
    final refs = _extractRefs(html);
    debugPrint('MV search "$name" refs found: $refs');
    return MagicVilleSearchResult(statusCode: 200, refs: refs);
  }

  /// All token refs matching [name], via the advanced search restricted to
  /// `spe_type=TK`.
  Future<List<String>> findAllTokenRefsForName(String name) async =>
      (await _searchRefsByTitle(name, speType: 'TK')).refs;

  /// Reads a response body and decodes it with the charset the server declared
  /// (Magic-Ville often serves latin1, which would make a plain utf8 decode
  /// throw on accented card names).
  Future<String> _readBody(HttpClientResponse response) async {
    final bytes = await consolidateHttpClientResponseBytes(
      response,
    ).timeout(_requestTimeout);
    final charset = response.headers.contentType?.charset?.toLowerCase().trim();
    final enc =
        (charset == 'iso-8859-1' ||
            charset == 'iso_8859-1' ||
            charset == 'latin1' ||
            charset == 'windows-1252')
        ? latin1
        : utf8;
    return _safeDecode(enc, bytes);
  }

  String _safeDecode(Encoding enc, List<int> bytes) {
    try {
      return enc.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// Non-throwing: first ref matching [name], or null.
  Future<String?> tryFindCardRefByName(String name) async {
    final refs = await findAllCardRefsByName(name);
    return refs.isEmpty ? null : refs.first;
  }

  /// Searches MagicVille for [name] and reports how the site answered.
  ///
  /// Tries the advanced search first; the `upn_search` quick-search endpoint is
  /// only an autocomplete helper and no longer yields card links on its own, so
  /// it is kept purely as a fallback. Never throws.
  Future<MagicVilleSearchResult> searchRefsByName(String name) async {
    MagicVilleSearchResult result;
    try {
      result = await _searchRefsByTitle(name);
    } catch (e) {
      debugPrint('MV name search for "$name" failed: $e');
      result = MagicVilleSearchResult(statusCode: 0, error: '$e');
    }
    if (result.refs.isNotEmpty) return result;

    final quick = await _quickSearchRefsByName(name);
    if (quick.isNotEmpty) {
      return MagicVilleSearchResult(statusCode: 200, refs: quick);
    }
    return result;
  }

  /// Returns ALL card refs found in MagicVille's name-search results.
  Future<List<String>> findAllCardRefsByName(String name) async =>
      (await searchRefsByName(name)).refs;

  /// Legacy quick-search (autocomplete) endpoint, used as a fallback.
  Future<List<String>> _quickSearchRefsByName(String name) async {
    final uri = Uri.parse(
      '${_base}upn_search',
    ).replace(queryParameters: {'n': name.toLowerCase()});

    try {
      final request = await _http.postUrl(uri).timeout(_requestTimeout);
      _prepare(request, referer: _base);
      request.headers.set(HttpHeaders.contentLengthHeader, '0');

      final response = await request.close().timeout(_requestTimeout);
      _rememberCookies(response);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        debugPrint('MV quick search "$name" status=${response.statusCode}');
        return [];
      }

      final refs = _extractRefs(await _readBody(response));
      debugPrint('MV quick search "$name" refs found: $refs');
      return refs;
    } catch (e) {
      debugPrint('MV quick search "$name" failed: $e');
      return [];
    }
  }

  /// Fetches the card page (carte?ref=) and extracts all artwork/card refs
  /// linked from it. This discovers alternate-edition refs that the artwork
  /// page cross-links don't include.
  Future<List<String>> findRefsFromCardPage(String ref) async {
    final uri = Uri.parse('${_base}carte?ref=$ref');
    try {
      return _extractRefs(await _getHtml(uri));
    } catch (_) {
      return [];
    }
  }

  Future<(List<int> bytes, String contentType)> downloadImage(
    String imageUrl, {
    String? referer,
  }) async {
    final uri = Uri.parse(imageUrl);

    final req = await _http
        .getUrl(uri)
        .timeout(
          _requestTimeout,
          onTimeout: () {
            throw TimeoutException(
              'MagicVille image getUrl timeout',
              _requestTimeout,
            );
          },
        );

    _prepare(req, referer: referer ?? _base);

    final res = await req.close().timeout(
      _requestTimeout,
      onTimeout: () {
        throw TimeoutException(
          'MagicVille image close timeout',
          _requestTimeout,
        );
      },
    );

    if (res.statusCode != 200) {
      throw HttpException(
        'Failed to download image: HTTP ${res.statusCode}',
        uri: uri,
      );
    }

    final mime =
        res.headers.contentType?.mimeType ?? 'application/octet-stream';
    final bytes = await consolidateHttpClientResponseBytes(res).timeout(
      _requestTimeout,
      onTimeout: () {
        throw TimeoutException(
          'MagicVille image read timeout',
          _requestTimeout,
        );
      },
    );

    if (bytes.isEmpty) throw Exception('Downloaded image is empty');
    return (bytes, mime);
  }

  void close() {
    _http.close(force: true);
  }
}
