import '../../core/normalize.dart';
import '../../services/deck_text_parser.dart';
import '../db/app_database.dart';
import '../db/daos.dart';

class CardRepository {
  final AppDatabase db;
  CardRepository(this.db);

  Stream<int> watchTotal(int projectId) =>
      db.cardsDao.watchTotalCount(projectId);
  Stream<int> watchChecked(int projectId) =>
      db.cardsDao.watchCheckedCount(projectId);

  Stream<List<Card>> watchCards(int projectId, CardFilter filter) =>
      db.cardsDao.watchCards(projectId, filter: filter);

  Future<void> insertCardsFromLines(int projectId, List<String> lines) async {
    final cleaned = lines
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final items = cleaned
        .map((name) => (name, normalizeCardName(name)))
        .toList();
    await db.cardsDao.insertCardsBulk(projectId, items);
  }

  /// Inserts parsed deck entries, deduping by normalized name (first
  /// occurrence wins, including its set/collector-number hints).
  Future<void> insertCardsFromEntries(
    int projectId,
    List<ParsedDeckEntry> entries,
  ) async {
    final seen = <String>{};
    final items =
        <({String name, String normalized, String? setHint, String? cnHint})>[];
    for (final e in entries) {
      final norm = normalizeCardName(e.name);
      if (norm.isEmpty || !seen.add(norm)) continue;
      items.add((
        name: e.name.trim(),
        normalized: norm,
        setHint: e.setCode,
        cnHint: e.collectorNumber,
      ));
    }
    await db.cardsDao.insertCardsWithHints(projectId, items);
  }
}
