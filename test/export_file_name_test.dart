import 'package:flutter_test/flutter_test.dart';
import 'package:mtg_artwork_picker/services/export_service.dart';

void main() {
  group('exportZipFileName', () {
    test('is the project name suffixed with a timestamp', () {
      expect(
        exportZipFileName(
          projectName: 'Modern Burn',
          projectId: 7,
          when: DateTime(2026, 8, 11, 21, 5, 33),
        ),
        'Modern Burn_2026-08-11_21-05-33.zip',
      );
    });

    test('pads single-digit date and time parts', () {
      expect(
        exportZipFileName(
          projectName: 'Deck',
          projectId: 1,
          when: DateTime(2026, 1, 2, 3, 4, 5),
        ),
        'Deck_2026-01-02_03-04-05.zip',
      );
    });

    test('keeps accents and apostrophes, which file systems allow', () {
      expect(
        exportZipFileName(
          projectName: "L'âme des cartes",
          projectId: 5,
          when: DateTime(2026, 8, 11, 9, 0, 0),
        ),
        "L'âme des cartes_2026-08-11_09-00-00.zip",
      );
    });

    test('replaces characters a file name cannot contain', () {
      final name = exportZipFileName(
        projectName: 'Deck: "Burn" / v2 <final>|?*',
        projectId: 1,
        when: DateTime(2026, 8, 11, 21, 5, 33),
      );
      // The timestamp uses dashes precisely so no colon survives here.
      expect(name, isNot(contains(':')));
      for (final illegal in ['<', '>', '"', '/', r'\', '|', '?', '*']) {
        expect(name, isNot(contains(illegal)), reason: 'contains $illegal');
      }
      expect(name, endsWith('_2026-08-11_21-05-33.zip'));
    });

    test('falls back to the project id when the name is empty', () {
      expect(
        exportZipFileName(
          projectName: '   ',
          projectId: 42,
          when: DateTime(2026, 8, 11, 21, 5, 33),
        ),
        'project_42_2026-08-11_21-05-33.zip',
      );
    });

    test('falls back when the name is only illegal characters', () {
      expect(
        exportZipFileName(
          projectName: '///',
          projectId: 9,
          when: DateTime(2026, 8, 11, 21, 5, 33),
        ),
        startsWith('___'),
      );
    });

    test('exports of one project sort chronologically by name', () {
      String at(DateTime when) => exportZipFileName(
        projectName: 'Deck',
        projectId: 1,
        when: when,
      );
      final names = [
        at(DateTime(2026, 12, 1, 8, 0, 0)),
        at(DateTime(2026, 2, 3, 23, 59, 59)),
        at(DateTime(2027, 1, 1, 0, 0, 0)),
      ]..sort();

      expect(names.first, contains('2026-02-03'));
      expect(names.last, contains('2027-01-01'));
    });
  });

  group('sanitizeFileNamePart', () {
    test('collapses whitespace and trims', () {
      expect(sanitizeFileNamePart('  a   b  '), 'a b');
    });

    test('leaves an already-safe name alone', () {
      expect(sanitizeFileNamePart('Lightning Bolt'), 'Lightning Bolt');
    });
  });
}
