import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_artwork_picker/services/smfcorp_parser.dart';

void main() {
  final parser = SmfCorpParser();
  final html =
      File('test/fixtures/smfcorp_card_page.html').readAsStringSync();

  group('parseCardPage', () {
    test('pulls the French fields, which are the point of the scrape', () {
      final card = parser.parseCardPage(html);
      expect(card.frenchName, 'Nom Français');
      expect(card.frenchType, 'Terrain légendaire');
      expect(card.frenchPrintedRules, startsWith('{T} : Ajoutez {G}'));
      expect(card.frenchFlavor, contains('Première ligne'));
      expect(card.isEmpty, isFalse);
    });

    test('pulls the English fields so a caller can verify the match', () {
      final card = parser.parseCardPage(html);
      expect(card.englishName, 'English Name');
      expect(card.englishType, 'Legendary Land');
      expect(card.englishRules, startsWith('{T}: Add {G}'));
      expect(card.englishFlavor, contains('First flavour line'));
    });

    test('mana images become Scryfall-style tokens, with {oT} mapped to {T}',
        () {
      final card = parser.parseCardPage(html);
      // The site writes the tap symbol as {oT}; Scryfall writes {T}.
      expect(card.frenchPrintedRules, contains('{T}'));
      expect(card.frenchPrintedRules, isNot(contains('{oT}')));
      expect(card.frenchPrintedRules, contains('{G}'));
      // No leftover markup or file names.
      expect(card.frenchPrintedRules, isNot(contains('<')));
      expect(card.frenchPrintedRules, isNot(contains('.png')));
    });

    test('flavour keeps its line breaks, since attribution sits on its own line',
        () {
      final card = parser.parseCardPage(html);
      final lines = card.frenchFlavor!.split('\n');
      expect(lines, hasLength(2));
      expect(lines[1], contains('Auteur'));
    });

    test('the printed and oracle wordings are kept apart', () {
      final card = parser.parseCardPage(html);
      expect(card.frenchPrintedRules, isNot(card.frenchOracleRules));
      expect(card.frenchOracleRules, contains('par créature'));
      // The oracle type line contains a link in the markup; text only, please.
      expect(card.frenchType, isNot(contains('href')));
    });

    test('entities are decoded rather than left raw', () {
      final card = parser.parseCardPage(html);
      for (final field in [
        card.frenchName,
        card.frenchType,
        card.frenchFlavor,
        card.frenchPrintedRules,
      ]) {
        expect(field, isNotNull);
        expect(field, isNot(contains('&')));
        expect(field, isNot(contains(';')));
      }
    });

    test('a page without the card fields reports empty instead of blanks', () {
      final card = parser.parseCardPage('<html><body>nothing here</body></html>');
      expect(card.isEmpty, isTrue);
      expect(card.frenchFlavor, isNull);
      expect(card.frenchPrintedRules, isNull);
    });
  });

  group('parseSearchResults', () {
    test('finds card links, absolute or relative, deduplicated by id', () {
      final hits = parser.parseSearchResults(html);
      expect(hits.map((h) => h.id), [10422, 133615, 133633]);
      expect(hits.first.slug, 'nom-francais');
      expect(hits.first.path, 'mtg-carte-10422-nom-francais.html');
    });

    test('a fragment with no card links yields nothing', () {
      expect(parser.parseSearchResults('<div>aucun résultat</div>'), isEmpty);
    });
  });
}
