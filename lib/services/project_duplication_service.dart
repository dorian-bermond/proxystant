import 'dart:io';

import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../core/storage_paths.dart';
import '../data/db/app_database.dart' as db;

class DuplicationProgress {
  final String phase;
  final int done;
  final int total;
  const DuplicationProgress({
    required this.phase,
    required this.done,
    required this.total,
  });
}

class DuplicationResult {
  final int projectId;
  final String projectName;
  final int copiedFiles;
  final int skippedFiles;
  const DuplicationResult({
    required this.projectId,
    required this.projectName,
    required this.copiedFiles,
    required this.skippedFiles,
  });
}

/// Deep-copies a project: all DB rows (with intra-project references
/// remapped) plus the downloaded image and thumbnail files.
class ProjectDuplicationService {
  final db.AppDatabase database;
  final StoragePaths storagePaths;

  ProjectDuplicationService({
    required this.database,
    required this.storagePaths,
  });

  Future<String> _availableCopyName(String sourceName) async {
    final rows = await database
        .customSelect('SELECT name FROM projects')
        .get();
    final names = rows.map((r) => r.data['name'] as String).toSet();
    final base = 'Copy of $sourceName';
    if (!names.contains(base)) return base;
    var i = 2;
    while (names.contains('$base ($i)')) {
      i++;
    }
    return '$base ($i)';
  }

  Future<DuplicationResult> duplicateProject(
    int sourceProjectId, {
    void Function(DuplicationProgress progress)? onProgress,
  }) async {
    final source = await (database.select(database.projects)
          ..where((t) => t.id.equals(sourceProjectId)))
        .getSingle();

    final newName = await _availableCopyName(source.name);
    final newId = await database.projectsDao.insertProject(
      newName,
      DateTime.now(),
    );

    try {
      final newImagesDir = await storagePaths.projectImagesDir(newId);
      final newThumbsDir = await storagePaths.projectThumbsDir(newId);
      final oldThumbsDir = await storagePaths.projectThumbsDir(sourceProjectId);

      // (from, to) pairs collected during the DB copy, written after commit.
      final fileCopies = <(String, String)>[];

      await database.transaction(() async {
        if (source.frame != null) {
          await database.projectsDao.setFrame(newId, source.frame);
        }

        await database.customStatement(
          'INSERT OR IGNORE INTO project_sources (project_id, source_provider_id)'
          ' SELECT ?, source_provider_id FROM project_sources WHERE project_id = ?',
          [newId, sourceProjectId],
        );
        await database.customStatement(
          'INSERT OR IGNORE INTO project_layout_frames (project_id, layout, frame)'
          ' SELECT ?, layout, frame FROM project_layout_frames WHERE project_id = ?',
          [newId, sourceProjectId],
        );
        await database.customStatement(
          'INSERT OR IGNORE INTO project_type_frames (project_id, type, frame)'
          ' SELECT ?, type, frame FROM project_type_frames WHERE project_id = ?',
          [newId, sourceProjectId],
        );

        final sourceCards = await (database.select(database.cards)
              ..where((t) => t.projectId.equals(sourceProjectId))
              ..orderBy([(t) => OrderingTerm(expression: t.id)]))
            .get();

        // Pass 1: copy card rows, leaving intra-project references NULL.
        final cardIdMap = <int, int>{};
        for (final card in sourceCards) {
          final newCardId = await database.into(database.cards).insert(
                card.toCompanion(false).copyWith(
                      id: const Value.absent(),
                      projectId: Value(newId),
                      preferredArtworkId: const Value(null),
                      selectedFlavorTextId: const Value(null),
                      dfcSiblingId: const Value(null),
                    ),
              );
          cardIdMap[card.id] = newCardId;
        }

        final artworkIdMap = <int, int>{};
        final flavorIdMap = <int, int>{};

        var done = 0;
        onProgress?.call(DuplicationProgress(
          phase: 'Copying card data',
          done: done,
          total: sourceCards.length,
        ));

        for (final card in sourceCards) {
          final newCardId = cardIdMap[card.id]!;

          // Print data first, so discovered printings can remap their FK.
          final printDataIdMap = <int, int>{};
          final printData = await (database.select(database.cardPrintData)
                ..where((t) => t.cardId.equals(card.id)))
              .get();
          for (final pd in printData) {
            final newPdId =
                await database.into(database.cardPrintData).insert(
                      pd.toCompanion(false).copyWith(
                            id: const Value.absent(),
                            cardId: Value(newCardId),
                          ),
                    );
            printDataIdMap[pd.id] = newPdId;
          }

          final printings =
              await (database.select(database.cardDiscoveredPrintings)
                    ..where((t) => t.cardId.equals(card.id)))
                  .get();
          for (final row in printings) {
            await database.into(database.cardDiscoveredPrintings).insert(
                  row.toCompanion(false).copyWith(
                        id: const Value.absent(),
                        cardId: Value(newCardId),
                        printDataId: Value(
                          row.printDataId == null
                              ? null
                              : printDataIdMap[row.printDataId],
                        ),
                      ),
                );
          }

          await database.customStatement(
            'INSERT OR IGNORE INTO card_discovered_sets (card_id, set_code)'
            ' SELECT ?, set_code FROM card_discovered_sets WHERE card_id = ?',
            [newCardId, card.id],
          );

          final artworks = await (database.select(database.artworks)
                ..where((t) => t.cardId.equals(card.id)))
              .get();
          for (final art in artworks) {
            final baseName = p.basename(art.localPath);
            final newLocalPath = p.join(newImagesDir.path, baseName);
            final newArtId = await database.into(database.artworks).insert(
                  art.toCompanion(false).copyWith(
                        id: const Value.absent(),
                        cardId: Value(newCardId),
                        localPath: Value(newLocalPath),
                      ),
                );
            artworkIdMap[art.id] = newArtId;

            fileCopies.add((art.localPath, newLocalPath));
            final thumbName = '${p.basenameWithoutExtension(baseName)}.jpg';
            fileCopies.add((
              p.join(oldThumbsDir.path, thumbName),
              p.join(newThumbsDir.path, thumbName),
            ));
          }

          final flavors = await (database.select(database.flavorTextOptions)
                ..where((t) => t.cardId.equals(card.id)))
              .get();
          for (final f in flavors) {
            final newFlavorId =
                await database.into(database.flavorTextOptions).insert(
                      f.toCompanion(false).copyWith(
                            id: const Value.absent(),
                            cardId: Value(newCardId),
                          ),
                    );
            flavorIdMap[f.id] = newFlavorId;
          }

          final used = await (database.select(database.cardUsedPrintData)
                ..where((t) => t.cardId.equals(card.id)))
              .getSingleOrNull();
          if (used != null) {
            await database.into(database.cardUsedPrintData).insert(
                  used.toCompanion(false).copyWith(cardId: Value(newCardId)),
                  mode: InsertMode.insertOrIgnore,
                );
          }

          onProgress?.call(DuplicationProgress(
            phase: 'Copying card data',
            done: ++done,
            total: sourceCards.length,
          ));
        }

        // Pass 2: remap intra-project references (dangling refs stay NULL).
        for (final card in sourceCards) {
          if (card.preferredArtworkId == null &&
              card.selectedFlavorTextId == null &&
              card.dfcSiblingId == null) {
            continue;
          }
          await (database.update(database.cards)
                ..where((t) => t.id.equals(cardIdMap[card.id]!)))
              .write(db.CardsCompanion(
            preferredArtworkId: Value(
              card.preferredArtworkId == null
                  ? null
                  : artworkIdMap[card.preferredArtworkId],
            ),
            selectedFlavorTextId: Value(
              card.selectedFlavorTextId == null
                  ? null
                  : flavorIdMap[card.selectedFlavorTextId],
            ),
            dfcSiblingId: Value(
              card.dfcSiblingId == null
                  ? null
                  : cardIdMap[card.dfcSiblingId],
            ),
          ));
        }
      });

      // File copies after the DB commit — best effort: a missing file just
      // means the artwork can be re-downloaded, and thumbs regenerate lazily.
      var copied = 0;
      var skipped = 0;
      onProgress?.call(DuplicationProgress(
        phase: 'Copying images',
        done: 0,
        total: fileCopies.length,
      ));
      for (final (from, to) in fileCopies) {
        try {
          await File(from).copy(to);
          copied++;
        } catch (_) {
          skipped++;
        }
        onProgress?.call(DuplicationProgress(
          phase: 'Copying images',
          done: copied + skipped,
          total: fileCopies.length,
        ));
      }

      return DuplicationResult(
        projectId: newId,
        projectName: newName,
        copiedFiles: copied,
        skippedFiles: skipped,
      );
    } catch (e) {
      // Clean up the half-made project (dir first, then all DB rows).
      try {
        await storagePaths.deleteProjectDir(newId);
      } catch (_) {}
      try {
        await database.projectsDao.deleteProjectById(newId);
      } catch (_) {}
      rethrow;
    }
  }
}
