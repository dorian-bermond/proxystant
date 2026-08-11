import 'package:collection/collection.dart';

import '../data/db/app_database.dart';
import '../data/db/daos.dart';

/// Resolves which printing a card should use once an artwork has been picked.
///
/// Shared by the artworks grid and the fullscreen preview so that setting a
/// preferred artwork always triggers the same version selection.
class VersionSelectionService {
  final AppDatabase db;
  final GlobalSettingsDao settingsDao;

  VersionSelectionService({required this.db, required this.settingsDao});

  /// Picks the printing that best matches [artwork] and stores it as the
  /// selected version of [cardId].
  ///
  /// Preference order: a printing crediting the artwork's artist in the default
  /// language, then any printing in the default language, then the first known
  /// printing. The artwork's artist is always written, even when the card has no
  /// discovered printings.
  Future<void> autoSelectVersionForArtwork({
    required int cardId,
    required Artwork artwork,
  }) async {
    final defaultLang = await settingsDao.getDefaultLanguage();
    final preferNewest = await settingsDao.getDefaultVersionNewest();

    var printings = await db.printDataDao.getDiscoveredPrintingsForCard(cardId);

    if (printings.isNotEmpty) {
      if (preferNewest) printings = printings.reversed.toList();

      final artistNorm = artwork.artist.toLowerCase().trim();

      // 1. Printing whose artist set includes the artwork artist, in default lang
      Map<String, Object?>? target = printings.firstWhereOrNull((p) {
        if ((p['lang'] as String?) != defaultLang) return false;
        final raw = (p['artists'] as String?) ?? '';
        return raw.split(',').any((a) => a.toLowerCase().trim() == artistNorm);
      });

      // 2. Any printing in default language
      target ??= printings.firstWhereOrNull(
        (p) => (p['lang'] as String?) == defaultLang,
      );

      // 3. Any printing
      target ??= printings.first;

      final setCode = target['set_code'] as String;
      final lang = target['lang'] as String;
      final collectorNumber = target['collector_number'] as String?;

      await db.cardsDao.setSelectedSet(
        cardId: cardId,
        setCode: setCode,
        lang: lang,
        isVoid: true,
        collectorNumber: collectorNumber,
      );
      await db.printDataDao.populateUsedFromPrinting(
        cardId: cardId,
        setCode: setCode,
        lang: lang,
      );
    }

    // Always write the artist from the selected artwork (populateUsedFromPrinting
    // intentionally omits it; only artwork selection should set this field).
    await db.printDataDao.setArtistForCard(cardId, artwork.artist);
  }

  /// Applies a deck-import set hint (e.g. from an Arena line
  /// "4 Lightning Bolt (M11) 149"): selects the discovered printing matching
  /// [setHint], preferring the default language.
  ///
  /// Returns true if a matching printing was found and selected; false means
  /// the hint set is not among the discovered printings and the caller should
  /// silently fall back to normal behavior.
  ///
  /// The artist is not written here — only artwork selection owns it.
  Future<bool> applyImportHint({
    required int cardId,
    required String setHint,
    String? collectorNumberHint,
  }) async {
    final defaultLang = await settingsDao.getDefaultLanguage();
    final printings = await db.printDataDao.getDiscoveredPrintingsForCard(
      cardId,
    );

    final matches = printings
        .where((p) => (p['set_code'] as String?) == setHint)
        .toList();
    if (matches.isEmpty) return false;

    final target =
        matches.firstWhereOrNull((p) => (p['lang'] as String?) == defaultLang)
            ?? matches.first;
    final lang = target['lang'] as String;

    await db.cardsDao.setSelectedSet(
      cardId: cardId,
      setCode: setHint,
      lang: lang,
      isVoid: true,
      collectorNumber:
          collectorNumberHint ?? target['collector_number'] as String?,
    );
    await db.printDataDao.populateUsedFromPrinting(
      cardId: cardId,
      setCode: setHint,
      lang: lang,
    );
    return true;
  }
}
