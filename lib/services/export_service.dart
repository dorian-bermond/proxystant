import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;

import '../core/artwork_file.dart';
import '../data/db/app_database.dart' as db;

enum ExportMode { folder, zip }

/// One artwork file in an export: where it goes and where its bytes live.
class ExportEntry {
  /// Path inside the export, e.g. 'frame/layout/Name (Artist) [SET] {1}.png'.
  final String relativePath;

  /// Absolute path of the artwork file on disk.
  final String sourcePath;

  final db.Card card;

  /// The print_data.json entry for this card (mutable so cross-links between
  /// DFC faces can be resolved in a post-pass).
  final Map<String, dynamic> json;

  ExportEntry({
    required this.relativePath,
    required this.sourcePath,
    required this.card,
    required this.json,
  });
}

/// A checked card that could not be exported.
class SkippedCard {
  final int cardId;
  final String name;
  final String reason;
  const SkippedCard({
    required this.cardId,
    required this.name,
    required this.reason,
  });
}

/// Everything an export sink needs: file list plus the print_data.json bytes.
class ExportManifest {
  final List<ExportEntry> entries;
  final List<SkippedCard> skipped;
  final Uint8List printDataJsonBytes;
  ExportManifest({
    required this.entries,
    required this.skipped,
    required this.printDataJsonBytes,
  });

  int get exportedCount => entries.length;
}

class ExportOutcome {
  final int exported;
  final List<SkippedCard> skipped;
  final String outputPath;
  ExportOutcome({
    required this.exported,
    required this.skipped,
    required this.outputPath,
  });
}

class ExportService {
  final db.AppDatabase database;
  ExportService(this.database);

  String _sanitize(String input) {
    return input
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  String _exportFolder(String? layout, String? frame) {
    final f = frame?.trim();
    final l = layout?.trim();
    final framePart = (f != null && f.isNotEmpty) ? _sanitize(f) : 'other';
    final layoutPart = (l != null && l.isNotEmpty) ? _sanitize(l) : 'other';
    return '$framePart/$layoutPart';
  }

  String _uniqueFileName(Set<String> used, String baseName, String ext) {
    var name = '${_sanitize(baseName)}.$ext';
    if (!used.contains(name)) {
      used.add(name);
      return name;
    }
    var i = 1;
    while (true) {
      final cand = '${_sanitize(baseName)}_$i.$ext';
      if (!used.contains(cand)) {
        used.add(cand);
        return cand;
      }
      i++;
    }
  }

  Future<String?> _loadProjectFrame(int projectId) async {
    final rows = await database.customSelect(
      'SELECT frame FROM projects WHERE id = ?',
      variables: [Variable(projectId)],
    ).get();
    if (rows.isEmpty) return null;
    return rows.first.data['frame'] as String?;
  }

  /// Checked cards (preferred artwork AND a selected/void version — the same
  /// definition the UI uses) joined with their preferred artwork.
  Future<List<_ExportRow>> _loadCheckedCardsWithPreferredArtwork(
    int projectId,
  ) async {
    final c = database.cards;
    final a = database.artworks;

    final query = database.select(c).join([
      innerJoin(a, a.id.equalsExp(c.preferredArtworkId)),
    ])..where(
        c.projectId.equals(projectId) &
            c.preferredArtworkId.isNotNull() &
            (c.selectedSetCode.isNotNull() | c.selectedSetIsVoid.equals(true)),
      );

    final rows = await query.get();

    final out = <_ExportRow>[];
    for (final row in rows) {
      out.add(_ExportRow(card: row.readTable(c), artwork: row.readTable(a)));
    }
    return out;
  }

  static List<dynamic>? _parseJsonList(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      return jsonDecode(json) as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _buildPrintDataEntry({
    required db.Card card,
    required db.Artwork artwork,
    required db.UsedPrintData? used,
    required String exportedFileName,
    required String? frame,
  }) {
    final entry = <String, dynamic>{
      'object': 'card',
      'exported_file_name': exportedFileName,
      'lang': used?.lang ?? '',
      'name': used?.name ?? card.name,
      'layout': used?.layout ?? card.layout ?? '',
      'artist': used?.artist ?? artwork.artist,
      'set': used?.setCode ?? card.selectedSetCode ?? '',
      'set_name': used?.setName ?? '',
      'collector_number': used?.collectorNumber ?? card.selectedCollectorNumber ?? '',
      'rarity': used?.rarity ?? '',
    };

    // Only emit a face index we actually know. Defaulting an unknown face to 0
    // would label both halves of a DFC as the front, which is worse for a
    // renderer than the key being absent.
    if (card.dfcSiblingId != null && card.faceIndex != null) {
      entry['face_index'] = card.faceIndex;
    }

    if (frame != null) entry['frame'] = frame;

    final mana = used?.manaCost;
    if (mana != null) entry['mana_cost'] = mana;

    final typeLine = used?.typeLine;
    if (typeLine != null) entry['type_line'] = typeLine;

    final oracle = used?.oracleText;
    if (oracle != null) entry['oracle_text'] = oracle;

    final flavor = used?.flavorText;
    if (flavor != null) entry['flavor_text'] = flavor;

    final flavorName = used?.flavorName;
    if (flavorName != null) entry['flavor_name'] = flavorName;

    final power = used?.power;
    if (power != null) entry['power'] = power;

    final toughness = used?.toughness;
    if (toughness != null) entry['toughness'] = toughness;

    final loyalty = used?.loyalty;
    if (loyalty != null) entry['loyalty'] = loyalty;

    final colors = _parseJsonList(used?.colors);
    entry['colors'] = colors ?? <dynamic>[];

    final colorIdentity = _parseJsonList(used?.colorIdentity);
    entry['color_identity'] = colorIdentity ?? <dynamic>[];

    final keywords = _parseJsonList(used?.keywords);
    entry['keywords'] = keywords ?? <dynamic>[];

    return entry;
  }

  static Uint8List _encodePrintDataJson(List<Map<String, dynamic>> data) {
    const encoder = JsonEncoder.withIndent('  ');
    final root = {
      'object': 'list',
      'total_cards': data.length,
      'data': data,
    };
    return utf8.encode(encoder.convert(root));
  }

  /// Builds the full export (paths + print_data.json) without writing
  /// anything. Missing artwork files are reported in [ExportManifest.skipped]
  /// instead of being silently dropped. With [flatten], the
  /// `<frame>/<layout>/` subfolders are omitted.
  Future<ExportManifest> buildManifest({
    required int projectId,
    bool flatten = false,
  }) async {
    final rows = await _loadCheckedCardsWithPreferredArtwork(projectId);
    final projectFrame = await _loadProjectFrame(projectId);

    final usedNamesByFolder = <String, Set<String>>{};
    final entries = <ExportEntry>[];
    final skipped = <SkippedCard>[];

    for (final r in rows) {
      if (!await artworkFileExists(r.artwork)) {
        skipped.add(SkippedCard(
          cardId: r.card.id,
          name: r.card.name,
          reason: 'artwork file missing on disk',
        ));
        continue;
      }

      final used = await database.printDataDao.getUsed(r.card.id);
      final ext =
          p.extension(r.artwork.localPath).replaceFirst('.', '').toLowerCase();
      final setLabel =
          (used?.setCode ?? r.card.selectedSetCode ?? 'UNKNOWN').toUpperCase();
      final collectorNumber =
          used?.collectorNumber ?? r.card.selectedCollectorNumber;
      final base = collectorNumber != null
          ? '${r.card.name} (${r.artwork.artist}) [$setLabel] {$collectorNumber}'
          : '${r.card.name} (${r.artwork.artist}) [$setLabel]';
      final resolvedFrame = r.card.frame ?? projectFrame;
      final folder =
          flatten ? '' : _exportFolder(r.card.layout, resolvedFrame);
      final folderNames =
          usedNamesByFolder.putIfAbsent(folder, () => <String>{});
      final fileName = _uniqueFileName(folderNames, base, ext);
      final exportedPath = folder.isEmpty ? fileName : '$folder/$fileName';

      entries.add(ExportEntry(
        relativePath: exportedPath,
        sourcePath: r.artwork.localPath,
        card: r.card,
        json: _buildPrintDataEntry(
          card: r.card,
          artwork: r.artwork,
          used: used,
          exportedFileName: exportedPath,
          frame: resolvedFrame,
        ),
      ));
    }

    // Cross-link DFC faces that both made it into the export.
    final pathByCardId = {
      for (final e in entries) e.card.id: e.relativePath,
    };
    for (final e in entries) {
      final sib = e.card.dfcSiblingId;
      if (sib != null && pathByCardId.containsKey(sib)) {
        e.json['other_face_exported_file_name'] = pathByCardId[sib];
      }
    }

    return ExportManifest(
      entries: entries,
      skipped: skipped,
      printDataJsonBytes:
          _encodePrintDataJson([for (final e in entries) e.json]),
    );
  }

  Future<Uint8List> encodeZip(ExportManifest manifest) async {
    final archive = Archive();
    for (final e in manifest.entries) {
      final bytes = await File(e.sourcePath).readAsBytes();
      archive.addFile(ArchiveFile(e.relativePath, bytes.length, bytes));
    }
    archive.addFile(ArchiveFile(
      'print_data.json',
      manifest.printDataJsonBytes.length,
      manifest.printDataJsonBytes,
    ));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<ExportOutcome> writeZipFile(
    ExportManifest manifest,
    String outputPath,
  ) async {
    final bytes = await encodeZip(manifest);
    final zipFile = File(outputPath);
    await zipFile.writeAsBytes(bytes, flush: true);
    return ExportOutcome(
      exported: manifest.exportedCount,
      skipped: manifest.skipped,
      outputPath: zipFile.path,
    );
  }

  /// Writes the export into [directoryPath] (created if needed). Files with
  /// the same name are overwritten — this is what makes re-exporting into a
  /// renderer's art directory (e.g. Proxyshop) a one-click operation.
  Future<ExportOutcome> writeFolder(
    ExportManifest manifest,
    String directoryPath,
  ) async {
    final dir = Directory(directoryPath);
    if (!await dir.exists()) await dir.create(recursive: true);

    for (final e in manifest.entries) {
      final target = File(p.join(dir.path, e.relativePath));
      await target.parent.create(recursive: true);
      await File(e.sourcePath).copy(target.path);
    }

    final jsonFile = File(p.join(dir.path, 'print_data.json'));
    await jsonFile.writeAsBytes(manifest.printDataJsonBytes, flush: true);

    return ExportOutcome(
      exported: manifest.exportedCount,
      skipped: manifest.skipped,
      outputPath: dir.path,
    );
  }
}

class _ExportRow {
  final db.Card card;
  final db.Artwork artwork;
  _ExportRow({required this.card, required this.artwork});
}
