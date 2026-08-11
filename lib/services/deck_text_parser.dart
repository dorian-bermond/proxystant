/// Pure-Dart parser for pasted decklists.
///
/// Understands plain lists, MTGA exports ("4 Lightning Bolt (M11) 149",
/// About/Name blocks, Deck/Sideboard headers) and MTGO-style lists
/// ("1x Card", "SB: 2 Duress"). Comment lines starting with `#` or `//`
/// are skipped (a card line never starts with `//`; DFC separators appear
/// mid-line).
library;

enum DeckSection { main, sideboard, commander, companion, maybeboard }

class ParsedDeckEntry {
  /// Card name, possibly a DFC name containing ' // '.
  final String name;
  final int quantity;

  /// Lowercase Scryfall set code from an Arena-style "(M11)" suffix.
  final String? setCode;

  /// Collector number from an Arena-style trailing number.
  final String? collectorNumber;
  final DeckSection section;

  const ParsedDeckEntry({
    required this.name,
    required this.quantity,
    this.setCode,
    this.collectorNumber,
    this.section = DeckSection.main,
  });
}

class DeckParseResult {
  final List<ParsedDeckEntry> entries;

  /// Deck name from an MTGA "About / Name X" block, if present.
  final String? deckName;

  const DeckParseResult({required this.entries, this.deckName});
}

class DeckTextParser {
  // "4 Name" / "4x Name"
  static final _qtyRe = RegExp(r'^(\d+)[xX]?\s+(.+)$');
  // "Name (M11) 149" / "Name (M11)" — set code 2-6 alphanumerics.
  static final _setSuffixRe =
      RegExp(r'^(.+?)\s+\(([A-Za-z0-9]{2,6})\)(?:\s+([\w\-★†]+))?$');
  // Arena flags like "*F*" at end of line.
  static final _arenaFlagRe = RegExp(r'\s+\*[A-Z]+\*$');

  static DeckSection? _sectionForHeader(String line) {
    switch (line.toLowerCase().replaceAll(':', '').trim()) {
      case 'deck':
      case 'main':
      case 'mainboard':
        return DeckSection.main;
      case 'sideboard':
      case 'side':
        return DeckSection.sideboard;
      case 'commander':
        return DeckSection.commander;
      case 'companion':
        return DeckSection.companion;
      case 'maybeboard':
      case 'considering':
        return DeckSection.maybeboard;
    }
    return null;
  }

  /// Rich parsing for deck mode: quantities, set hints, sections, comments.
  static DeckParseResult parse(String input) {
    final entries = <ParsedDeckEntry>[];
    String? deckName;
    var section = DeckSection.main;
    var inAboutBlock = false;

    for (final rawLine in input.split('\n')) {
      var line = rawLine.trim();
      if (line.isEmpty) {
        // A blank line ends an MTGA About block; sections persist.
        inAboutBlock = false;
        continue;
      }
      if (line.startsWith('//') || line.startsWith('#')) continue;

      if (line.toLowerCase().replaceAll(':', '').trim() == 'about') {
        inAboutBlock = true;
        continue;
      }
      if (inAboutBlock) {
        final m = RegExp(r'^Name\s+(.+)$', caseSensitive: false)
            .firstMatch(line);
        if (m != null) deckName = m.group(1)!.trim();
        continue;
      }

      final header = _sectionForHeader(line);
      if (header != null) {
        section = header;
        continue;
      }

      var lineSection = section;
      if (line.toUpperCase().startsWith('SB:')) {
        line = line.substring(3).trim();
        lineSection = DeckSection.sideboard;
        if (line.isEmpty) continue;
      }

      line = line.replaceFirst(_arenaFlagRe, '');

      var quantity = 1;
      var rest = line;
      final qtyMatch = _qtyRe.firstMatch(line);
      if (qtyMatch != null) {
        quantity = int.parse(qtyMatch.group(1)!);
        rest = qtyMatch.group(2)!.trim();
      }
      if (quantity <= 0 || rest.isEmpty) continue;

      String name = rest;
      String? setCode;
      String? collectorNumber;
      final setMatch = _setSuffixRe.firstMatch(rest);
      if (setMatch != null) {
        name = setMatch.group(1)!.trim();
        setCode = setMatch.group(2)!.toLowerCase();
        collectorNumber = setMatch.group(3);
      }

      entries.add(ParsedDeckEntry(
        name: name,
        quantity: quantity,
        setCode: setCode,
        collectorNumber: collectorNumber,
        section: lineSection,
      ));
    }

    return DeckParseResult(entries: entries, deckName: deckName);
  }

  /// Deck-mode-off parsing: every non-empty, non-comment line is one card
  /// name (no quantity/hint parsing).
  static List<ParsedDeckEntry> parseNameLines(String input) {
    final entries = <ParsedDeckEntry>[];
    for (final rawLine in input.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('//') || line.startsWith('#')) continue;
      entries.add(ParsedDeckEntry(name: line, quantity: 1));
    }
    return entries;
  }
}

/// Sections that get imported into a project; sideboard/maybeboard lines are
/// skipped, matching the URL importers' behavior.
const importedDeckSections = {
  DeckSection.main,
  DeckSection.commander,
  DeckSection.companion,
};
