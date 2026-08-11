import 'dart:io';

import 'package:drift/drift.dart';

import '../core/template_registry.dart';
import '../data/db/app_database.dart' as db;

class CardRef {
  final int cardId;
  final String name;
  const CardRef({required this.cardId, required this.name});
}

enum ReadinessKind {
  /// No artwork selected — the card will not export.
  noArtwork,

  /// Artwork selected but no version — the card will not export.
  noVersion,

  /// Checked, but the selected artwork's file is missing on disk.
  missingFile,

  /// Layout has no template support at all.
  unsupportedLayout,

  /// Layout has only partial template support.
  partialLayout,

  /// No frame on card or project — exports into the 'other/' folder.
  noFrame,

  /// One DFC face is checked while its sibling is not.
  dfcMismatch,
}

class ReadinessIssueGroup {
  final ReadinessKind kind;

  /// Blocking issues keep the card out of the export entirely.
  final bool blocking;
  final List<CardRef> cards;
  const ReadinessIssueGroup({
    required this.kind,
    required this.blocking,
    required this.cards,
  });
}

class ExportReadinessReport {
  /// Non-empty groups, blocking first.
  final List<ReadinessIssueGroup> groups;
  const ExportReadinessReport({required this.groups});

  bool get isClean => groups.isEmpty;
}

/// Computes the pre-export completeness report for a project.
class ExportReadinessService {
  final db.AppDatabase database;
  ExportReadinessService(this.database);

  Future<ExportReadinessReport> buildReport(int projectId) async {
    final rows = await database.customSelect(
      '''
      SELECT c.id, c.name, c.layout, c.frame, c.preferred_artwork_id,
             c.selected_extension_set, c.selected_extension_is_void,
             c.dfc_sibling_id, a.local_path
      FROM cards c
      LEFT JOIN artworks a ON a.id = c.preferred_artwork_id
      WHERE c.project_id = ?
      ORDER BY c.name COLLATE NOCASE
      ''',
      variables: [Variable(projectId)],
    ).get();

    final projectFrameRows = await database.customSelect(
      'SELECT frame FROM projects WHERE id = ?',
      variables: [Variable(projectId)],
    ).get();
    final projectFrame = projectFrameRows.isEmpty
        ? null
        : projectFrameRows.first.data['frame'] as String?;

    final noArtwork = <CardRef>[];
    final noVersion = <CardRef>[];
    final missingFileCandidates = <(CardRef, String?)>[];
    final unsupportedLayout = <CardRef>[];
    final partialLayout = <CardRef>[];
    final noFrame = <CardRef>[];
    final dfcMismatch = <CardRef>[];

    final byId = <int, QueryRow>{
      for (final r in rows) r.data['id'] as int: r,
    };

    bool isChecked(QueryRow r) {
      final hasArtwork = r.data['preferred_artwork_id'] != null;
      final hasVersion = r.data['selected_extension_set'] != null ||
          (r.data['selected_extension_is_void'] as int? ?? 0) != 0;
      return hasArtwork && hasVersion;
    }

    for (final r in rows) {
      final ref = CardRef(
        cardId: r.data['id'] as int,
        name: r.data['name'] as String,
      );
      final hasArtwork = r.data['preferred_artwork_id'] != null;
      final hasVersion = r.data['selected_extension_set'] != null ||
          (r.data['selected_extension_is_void'] as int? ?? 0) != 0;
      final checked = hasArtwork && hasVersion;

      if (!hasArtwork) {
        noArtwork.add(ref);
      } else if (!hasVersion) {
        noVersion.add(ref);
      }

      if (checked) {
        missingFileCandidates.add((ref, r.data['local_path'] as String?));
      }

      final layout = r.data['layout'] as String?;
      if (layout != null) {
        switch (scryfallLayoutSupport[layout]) {
          case ScryfallSupport.unsupported:
            unsupportedLayout.add(ref);
          case ScryfallSupport.partial:
          case null: // unknown layout — treat as partial
            partialLayout.add(ref);
          case ScryfallSupport.supported:
            break;
        }
      }

      if (checked &&
          (r.data['frame'] as String?) == null &&
          projectFrame == null) {
        noFrame.add(ref);
      }

      final sibId = r.data['dfc_sibling_id'] as int?;
      if (sibId != null) {
        final sib = byId[sibId];
        // Report the unchecked face of a mismatched pair.
        if (sib != null && !checked && isChecked(sib)) {
          dfcMismatch.add(ref);
        }
      }
    }

    // Disk checks only for checked cards, in bounded chunks.
    final missingFile = <CardRef>[];
    const chunkSize = 32;
    for (var i = 0; i < missingFileCandidates.length; i += chunkSize) {
      final chunk = missingFileCandidates.skip(i).take(chunkSize);
      final results = await Future.wait(chunk.map((c) async {
        final (ref, path) = c;
        if (path == null) return ref; // dangling preferred_artwork_id
        return await File(path).exists() ? null : ref;
      }));
      missingFile.addAll(results.whereType<CardRef>());
    }

    final groups = <ReadinessIssueGroup>[
      if (noArtwork.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.noArtwork,
          blocking: true,
          cards: noArtwork,
        ),
      if (noVersion.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.noVersion,
          blocking: true,
          cards: noVersion,
        ),
      if (missingFile.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.missingFile,
          blocking: true,
          cards: missingFile,
        ),
      if (dfcMismatch.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.dfcMismatch,
          blocking: false,
          cards: dfcMismatch,
        ),
      if (unsupportedLayout.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.unsupportedLayout,
          blocking: false,
          cards: unsupportedLayout,
        ),
      if (partialLayout.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.partialLayout,
          blocking: false,
          cards: partialLayout,
        ),
      if (noFrame.isNotEmpty)
        ReadinessIssueGroup(
          kind: ReadinessKind.noFrame,
          blocking: false,
          cards: noFrame,
        ),
    ];

    return ExportReadinessReport(groups: groups);
  }
}
