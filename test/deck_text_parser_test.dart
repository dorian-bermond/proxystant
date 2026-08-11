import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_artwork_picker/services/deck_text_parser.dart';

void main() {
  group('DeckTextParser.parse', () {
    test('plain quantity lines', () {
      final r = DeckTextParser.parse('4 Lightning Bolt\n2 Counterspell');
      expect(r.entries, hasLength(2));
      expect(r.entries[0].name, 'Lightning Bolt');
      expect(r.entries[0].quantity, 4);
      expect(r.entries[0].setCode, isNull);
      expect(r.entries[1].name, 'Counterspell');
      expect(r.entries[1].quantity, 2);
    });

    test('1x style quantities', () {
      final r = DeckTextParser.parse('1x Sol Ring\n3X Brainstorm');
      expect(r.entries[0].name, 'Sol Ring');
      expect(r.entries[0].quantity, 1);
      expect(r.entries[1].name, 'Brainstorm');
      expect(r.entries[1].quantity, 3);
    });

    test('Arena set and collector number hints', () {
      final r = DeckTextParser.parse('4 Lightning Bolt (M11) 149');
      final e = r.entries.single;
      expect(e.name, 'Lightning Bolt');
      expect(e.setCode, 'm11');
      expect(e.collectorNumber, '149');
    });

    test('set hint without collector number', () {
      final e = DeckTextParser.parse('2 Opt (XLN)').entries.single;
      expect(e.name, 'Opt');
      expect(e.setCode, 'xln');
      expect(e.collectorNumber, isNull);
    });

    test('bare names are kept with quantity 1', () {
      final r = DeckTextParser.parse('Lightning Bolt\n4 Shock');
      expect(r.entries, hasLength(2));
      expect(r.entries[0].name, 'Lightning Bolt');
      expect(r.entries[0].quantity, 1);
    });

    test('comments and blank lines are skipped', () {
      final r = DeckTextParser.parse(
        '# a comment\n// another\n\n4 Lightning Bolt',
      );
      expect(r.entries.single.name, 'Lightning Bolt');
    });

    test('section headers route entries', () {
      final r = DeckTextParser.parse('''
Deck
4 Lightning Bolt
Sideboard
2 Duress
Commander
1 Krenko, Mob Boss
Maybeboard
1 Ponder
''');
      expect(
        r.entries.map((e) => e.section),
        [
          DeckSection.main,
          DeckSection.sideboard,
          DeckSection.commander,
          DeckSection.maybeboard,
        ],
      );
    });

    test('MTGO SB: prefix marks a single line as sideboard', () {
      final r = DeckTextParser.parse('4 Shock\nSB: 2 Duress\n1 Opt');
      expect(r.entries[0].section, DeckSection.main);
      expect(r.entries[1].section, DeckSection.sideboard);
      expect(r.entries[1].name, 'Duress');
      expect(r.entries[1].quantity, 2);
      expect(r.entries[2].section, DeckSection.main);
    });

    test('MTGA About block sets the deck name and is not imported', () {
      final r = DeckTextParser.parse('''
About
Name Mono Red Aggro

Deck
4 Lightning Bolt (M11) 149
''');
      expect(r.deckName, 'Mono Red Aggro');
      expect(r.entries.single.name, 'Lightning Bolt');
    });

    test('Arena foil flags are stripped', () {
      final e =
          DeckTextParser.parse('1 Sol Ring (C21) 263 *F*').entries.single;
      expect(e.name, 'Sol Ring');
      expect(e.setCode, 'c21');
      expect(e.collectorNumber, '263');
    });

    test('DFC names keep their full name alongside a set hint', () {
      final e = DeckTextParser.parse(
        '2 Fable of the Mirror-Breaker // Reflection of Kiki-Jiki (NEO) 141',
      ).entries.single;
      expect(
        e.name,
        'Fable of the Mirror-Breaker // Reflection of Kiki-Jiki',
      );
      expect(e.setCode, 'neo');
      expect(e.collectorNumber, '141');
    });

    test('zero quantities are skipped', () {
      expect(DeckTextParser.parse('0 Lightning Bolt').entries, isEmpty);
    });
  });

  group('DeckTextParser.parseNameLines', () {
    test('one name per line, no quantity parsing', () {
      final entries =
          DeckTextParser.parseNameLines('4 Lightning Bolt\nSol Ring\n');
      expect(entries, hasLength(2));
      // Deck mode off: the line is the name, verbatim.
      expect(entries[0].name, '4 Lightning Bolt');
      expect(entries[1].name, 'Sol Ring');
      expect(entries[1].quantity, 1);
    });

    test('comments are skipped', () {
      final entries = DeckTextParser.parseNameLines('# nope\nIsland');
      expect(entries.single.name, 'Island');
    });
  });

  test('importedDeckSections excludes sideboard and maybeboard', () {
    expect(importedDeckSections, contains(DeckSection.main));
    expect(importedDeckSections, contains(DeckSection.commander));
    expect(importedDeckSections, contains(DeckSection.companion));
    expect(importedDeckSections, isNot(contains(DeckSection.sideboard)));
    expect(importedDeckSections, isNot(contains(DeckSection.maybeboard)));
  });
}
