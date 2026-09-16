// A console tool: print is the whole point of it.
// ignore_for_file: avoid_print

// Standalone probe for the MagicVille endpoints the app depends on.
//
//   dart run tool/mv_probe.dart "Aeve, Progenitor Ooze"
//
// Run it from the machine or network the app runs on and read the status codes:
// they are the only way to tell "MagicVille refused us" (403 + a Cloudflare
// "Just a moment..." body) from "MagicVille answered, nothing matched"
// (200 with no refs). The app cannot report this from a phone without a
// console, and magic-ville.com is unreachable from CI.
//
// Deliberately self-contained — plain dart:io, no Flutter imports — so it can
// run with `dart run` outside the app. It mirrors what MagicVilleClient sends:
// same user agent, same cookie jar, same form fields.

import 'dart:convert';
import 'dart:io';

const base = 'https://www.magic-ville.com/fr/';

const userAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

final cookies = <String, String>{};
final http = HttpClient()
  ..connectionTimeout = const Duration(seconds: 12)
  ..idleTimeout = const Duration(seconds: 15);

final refLink = RegExp(r'carte(?:_art)?\?ref=([a-z0-9]+)', caseSensitive: false);

void prepare(HttpClientRequest req, {String? referer}) {
  req.headers
    ..set(HttpHeaders.userAgentHeader, userAgent)
    ..set(
      HttpHeaders.acceptHeader,
      'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    )
    ..set(HttpHeaders.acceptLanguageHeader, 'fr-FR,fr;q=0.9,en;q=0.8');
  if (referer != null) {
    req.headers.set(HttpHeaders.refererHeader, referer);
  }
  if (cookies.isNotEmpty) {
    req.headers.set(
      HttpHeaders.cookieHeader,
      cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    );
  }
}

String decode(HttpClientResponse res, List<int> bytes) {
  final charset = res.headers.contentType?.charset?.toLowerCase().trim();
  final enc =
      (charset == 'iso-8859-1' ||
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

Future<void> report(String label, HttpClientRequest req) async {
  try {
    final res = await req.close().timeout(const Duration(seconds: 20));
    for (final c in res.cookies) {
      cookies[c.name] = c.value;
    }
    final bytes = <int>[];
    await res.forEach(bytes.addAll);
    final body = decode(res, bytes);
    final refs = refLink
        .allMatches(body)
        .map((m) => m.group(1)!)
        .toSet()
        .toList();

    final challenged =
        body.contains('Just a moment') || body.contains('cf-browser-verification');

    print(label);
    print('  HTTP ${res.statusCode}  ${bytes.length} bytes  '
        '${res.headers.contentType ?? "(no content-type)"}');
    if (challenged) {
      print('  >> CLOUDFLARE CHALLENGE — the app can never read this page.');
    }
    if (!challenged) {
      print('  refs: ${refs.isEmpty ? "(none)" : refs.take(12).join(", ")}'
          '${refs.length > 12 ? " … ${refs.length} total" : ""}');
    }
    if (res.statusCode == 200 && refs.isEmpty && !challenged) {
      final snippet = body
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
      print('  body[0..200]: '
          '${snippet.length > 200 ? snippet.substring(0, 200) : snippet}');
    }
    print('');
  } catch (e) {
    print(label);
    print('  FAILED: $e\n');
  }
}

Future<void> get(String label, String url, {String? referer}) async {
  final req = await http.getUrl(Uri.parse(url));
  prepare(req, referer: referer);
  await report('$label  GET $url', req);
}

Future<void> postForm(
  String label,
  String url,
  Map<String, String> fields, {
  String? referer,
}) async {
  final body = fields.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');
  final bytes = utf8.encode(body);

  final req = await http.postUrl(Uri.parse(url));
  prepare(req, referer: referer);
  req.headers
    ..set(HttpHeaders.contentTypeHeader, 'application/x-www-form-urlencoded')
    ..set(HttpHeaders.contentLengthHeader, '${bytes.length}')
    ..set('Origin', 'https://www.magic-ville.com');
  req.add(bytes);
  await report('$label  POST $url', req);
}

Map<String, String> searchFields(String name, {String? speType}) => {
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

Future<void> main(List<String> args) async {
  final name = args.isNotEmpty ? args[0] : 'Aeve, Progenitor Ooze';
  // A ref known to exist, so a failure here means access, not a bad guess.
  final ref = args.length > 1 ? args[1] : 'mh2148';

  print('Probing MagicVille for "$name" (known ref: $ref)\n');

  await get('[1] home (warm-up)', base);
  await get('[2] card page', '${base}carte?ref=$ref');
  await get('[3] artwork page', '${base}carte_art?ref=$ref');
  await get('[4] search form', '${base}rech_avancee');
  await postForm('[5] advanced search', '${base}resultats', searchFields(name),
      referer: '${base}rech_avancee');
  await postForm('[6] advanced search (.php)', '${base}resultats.php',
      searchFields(name), referer: '${base}rech_avancee');
  await postForm('[7] token search', '${base}resultats',
      searchFields(name, speType: 'TK'), referer: '${base}rech_avancee');
  await postForm('[8] quick search',
      '${base}upn_search?n=${Uri.encodeQueryComponent(name.toLowerCase())}',
      const {}, referer: base);

  print('Cookies collected: '
      '${cookies.isEmpty ? "(none)" : cookies.keys.join(", ")}');
  print('''
How to read this:
  [2]/[3] 403 + CLOUDFLARE  -> the whole integration is blocked; endpoints are
                               not the problem, access is.
  [2]/[3] 200 but [5] empty -> access is fine, the search request is wrong;
                               paste [5]'s body snippet.
  [5] 200 with refs         -> the search works and the app should too.''');

  http.close(force: true);
}
