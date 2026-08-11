import '../data/db/app_database.dart' as db;
import 'version_selection_service.dart';

/// Bulk operations over a set of cards, built on the single-card
/// [VersionSelectionService] primitives.
class BulkCardActionsService {
  final db.AppDatabase database;
  final VersionSelectionService versionSelection;

  BulkCardActionsService({
    required this.database,
    required this.versionSelection,
  });

  bool _hasVersion(db.Card c) =>
      c.selectedSetCode != null || c.selectedSetIsVoid;

  /// Runs version auto-select for every card that has a preferred artwork.
  /// With [onlyUnselected] (default), cards that already have a version are
  /// skipped — auto-select resets flavor-text choices, so manual picks are
  /// protected. Returns the number of cards updated.
  Future<int> autoSelectVersions(
    List<db.Card> cards, {
    bool onlyUnselected = true,
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = cards
        .where(
          (c) =>
              c.preferredArtworkId != null &&
              (!onlyUnselected || !_hasVersion(c)),
        )
        .toList();

    var done = 0;
    onProgress?.call(done, targets.length);
    for (final card in targets) {
      final artwork = await database.artworksDao.getById(
        card.preferredArtworkId!,
      );
      if (artwork != null) {
        await versionSelection.autoSelectVersionForArtwork(
          cardId: card.id,
          artwork: artwork,
        );
      }
      onProgress?.call(++done, targets.length);
    }
    return done;
  }

  /// Checks every card that isn't fully checked yet: picks the preferred (or
  /// first non-discarded) artwork and auto-selects a version when none is
  /// chosen. Cards without any artwork are skipped. Returns the number of
  /// cards processed.
  Future<int> checkAll(
    List<db.Card> cards, {
    void Function(int done, int total)? onProgress,
  }) async {
    final targets = cards
        .where((c) => c.preferredArtworkId == null || !_hasVersion(c))
        .toList();

    var done = 0;
    var processed = 0;
    onProgress?.call(done, targets.length);
    for (final card in targets) {
      final artwork = await database.artworksDao
          .getPreferredOrFirstArtworkForCard(card.id, card.preferredArtworkId);
      if (artwork == null) {
        onProgress?.call(++done, targets.length);
        continue; // nothing downloaded for this card
      }
      if (card.preferredArtworkId == null) {
        await database.cardsDao.setPreferredArtwork(card.id, artwork.id);
      }
      if (!_hasVersion(card)) {
        await versionSelection.autoSelectVersionForArtwork(
          cardId: card.id,
          artwork: artwork,
        );
      }
      processed++;
      onProgress?.call(++done, targets.length);
    }
    return processed;
  }

  /// Unchecks all given cards in one set-based update (clears artwork,
  /// version and flavor state). Returns the number of affected rows.
  Future<int> uncheckAll(List<int> cardIds) {
    return database.cardsDao.uncheckCards(cardIds);
  }
}
