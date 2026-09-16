// End-to-end check of the Cloudflare countermeasure, run as a real app so the
// platform WebView is available:
//
//   flutter run -d windows -t tool/cf_check.dart
//
// It solves the challenge in the hidden WebView, prints the cookies and user
// agent it won, then exercises the three things the download pipeline needs —
// an artwork page, a name search, and an image download — and exits.
//
// tool/mv_probe.dart is the plain-HTTP counterpart: it shows what happens with
// no WebView at all. Run that one first; this one answers whether the WebView
// recovers it.

// A console tool: print is the whole point of it.
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:mtg_artwork_picker/services/cloudflare_session.dart';
import 'package:mtg_artwork_picker/services/magicville_client.dart';
import 'package:mtg_artwork_picker/services/magicville_parser.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final name = args.isNotEmpty ? args[0] : 'Aeve, Progenitor Ooze';
  final ref = args.length > 1 ? args[1] : 'mh2148';

  final session = CloudflareSession();
  final client = MagicVilleClient(MagicVilleParser(), cloudflare: session);

  print('--- CloudflareSession ---');
  print('supported on this platform: ${session.isSupported}');

  final warmed = await session.warmUp();
  print('warm-up yielded a clearance cookie: $warmed');
  print('cookies: ${session.cookies.keys.toList()}');
  print('cf_clearance held: ${session.hasClearance}');
  print('webview user agent: ${session.userAgent ?? "(none)"}');

  print('\n--- artwork page (ref=$ref) ---');
  try {
    final (artworks, pageRefs) = await client.fetchArtworkInfo(ref: ref);
    print('OK: ${artworks.length} artwork(s), ${pageRefs.length} edition(s)');
    for (final a in artworks.take(3)) {
      print('  imid=${a.imid} artist="${a.artist}" card="${a.pageCardName}"');
    }

    print('\n--- image download ---');
    if (artworks.isEmpty) {
      print('SKIPPED: no artwork on that page');
    } else {
      final (bytes, mime) = await client.downloadImage(
        artworks.first.imageUrl,
        referer: 'https://www.magic-ville.com/fr/carte_art?ref=$ref',
      );
      final head = bytes
          .take(4)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
      final format = (bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8)
          ? 'JPEG'
          : (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50)
                ? 'PNG'
                : 'NOT AN IMAGE';
      print('OK: ${bytes.length} bytes, mime=$mime, magic=[$head] -> $format');
    }
  } catch (e) {
    print('FAILED: $e');
  }

  print('\n--- name search ("$name") ---');
  try {
    final result = await client.searchRefsByName(name);
    print(result.describe);
  } catch (e) {
    print('FAILED: $e');
  }

  await session.dispose();
  client.close();
  print('\ndone');
  exit(0);
}
