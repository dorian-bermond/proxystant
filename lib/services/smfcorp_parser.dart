import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

/// Localized card text scraped from an SMF Corp card page.
///
/// Both languages are captured: the French fields are what we are after, and
/// the English ones let a caller confirm it landed on the right card by
/// comparing them with what Scryfall already returned, rather than trusting a
/// name match.
class SmfCorpCardText {
  final String? frenchName;
  final String? frenchType;
  final String? frenchPrintedRules;

  /// French rules in current oracle wording, when the page offers it. Prefer
  /// [frenchPrintedRules] when proxying a specific printing.
  final String? frenchOracleRules;
  final String? frenchFlavor;

  /// English counterparts, for verification.
  final String? englishName;
  final String? englishType;
  final String? englishRules;
  final String? englishFlavor;

  const SmfCorpCardText({
    this.frenchName,
    this.frenchType,
    this.frenchPrintedRules,
    this.frenchOracleRules,
    this.frenchFlavor,
    this.englishName,
    this.englishType,
    this.englishRules,
    this.englishFlavor,
  });

  /// Nothing usable was found — treat the page as a miss rather than writing
  /// empty strings over existing data.
  bool get isEmpty =>
      (frenchPrintedRules ?? frenchOracleRules ?? frenchFlavor) == null;
}

/// A card page link found in a search-results fragment.
class SmfCorpSearchHit {
  /// Numeric page id, e.g. 10422 in `mtg-carte-10422-berceau-de-gaia.html`.
  final int id;

  /// Path as written in the markup.
  final String path;

  /// French name, lower-cased and hyphenated. Only a hint: several printings
  /// of one card share a name but not an id.
  final String slug;

  const SmfCorpSearchHit({
    required this.id,
    required this.path,
    required this.slug,
  });
}

/// Parses SMF Corp card pages and search fragments.
///
/// Pure string work, so it is tested against a fixture rather than the network.
/// A card page carries three parallel views of the same card, keyed by element
/// id: `printed*` (as printed, French), `oracle*` (current wording, French) and
/// `VO*` (version originale, i.e. English). `TA` is *texte d'ambiance* —
/// flavour text.
class SmfCorpParser {
  /// Mana and tap symbols arrive as `<img>` whose file name carries the token
  /// in braces, e.g. `.../%7BoT%7D.png` for `{oT}`. Only spellings that differ
  /// from Scryfall's need mapping; anything else passes through unchanged.
  static const _symbolAliases = <String, String>{
    'oT': 'T',
    'oQ': 'Q',
    'oE': 'E',
  };

  SmfCorpCardText parseCardPage(String html) {
    final doc = html_parser.parse(html);
    return SmfCorpCardText(
      frenchName: _byId(doc, 'title'),
      frenchType: _byId(doc, 'printedType'),
      frenchPrintedRules: _byId(doc, 'printedText'),
      frenchOracleRules: _byId(doc, 'oracleText'),
      frenchFlavor: _byId(doc, 'printedTA'),
      englishName: _byId(doc, 'VOtitle'),
      englishType: _byId(doc, 'VOType'),
      englishRules: _byId(doc, 'VOText'),
      englishFlavor: _byId(doc, 'VOTA'),
    );
  }

  /// Card links in a search-results fragment, in document order, deduplicated
  /// by id. The site returns one entry per printing.
  ///
  /// Kept as a scan over the raw markup so it works on the bare HTML fragment
  /// the search endpoint returns, not only on a whole document.
  List<SmfCorpSearchHit> parseSearchResults(String html) {
    final seen = <int>{};
    final hits = <SmfCorpSearchHit>[];
    for (final m in RegExp(
      r'(mtg-carte-(\d+)-([a-z0-9\-]+)\.html)',
      caseSensitive: false,
    ).allMatches(html)) {
      final id = int.tryParse(m.group(2)!);
      if (id == null || !seen.add(id)) continue;
      hits.add(SmfCorpSearchHit(
        id: id,
        path: m.group(1)!,
        slug: m.group(3)!,
      ));
    }
    return hits;
  }

  String? _byId(Document doc, String id) {
    final el = doc.getElementById(id);
    if (el == null) return null;
    final text = _plainText(el);
    return text.isEmpty ? null : text;
  }

  /// Element content as plain text: `<br>` becomes a newline and symbol images
  /// become their `{X}` token. Entity decoding comes free from the parser.
  ///
  /// Line structure is preserved because flavour text puts its attribution on
  /// its own line; only runs of spaces within a line are collapsed.
  String _plainText(Element el) {
    final buf = StringBuffer();

    void walk(Node node) {
      for (final child in node.nodes) {
        if (child is Text) {
          buf.write(child.text);
        } else if (child is Element) {
          switch (child.localName?.toLowerCase()) {
            case 'br':
              buf.write('\n');
            case 'img':
              buf.write(_symbolFromSrc(child.attributes['src']));
            default:
              walk(child);
          }
        }
      }
    }

    walk(el);

    final lines = buf
        .toString()
        .split('\n')
        .map((l) => l.replaceAll(RegExp(r'[\s ]+'), ' ').trim())
        .toList();
    while (lines.isNotEmpty && lines.first.isEmpty) {
      lines.removeAt(0);
    }
    while (lines.isNotEmpty && lines.last.isEmpty) {
      lines.removeLast();
    }
    return lines.join('\n');
  }

  /// The `{X}` token an image stands for, or '' when it is not a symbol.
  String _symbolFromSrc(String? src) {
    if (src == null || src.isEmpty) return '';
    String decoded;
    try {
      decoded = Uri.decodeFull(src);
    } catch (_) {
      decoded = src;
    }
    final token = RegExp(r'\{([^}]{1,6})\}').firstMatch(decoded)?.group(1);
    if (token == null) return '';
    return '{${_symbolAliases[token] ?? token}}';
  }
}
