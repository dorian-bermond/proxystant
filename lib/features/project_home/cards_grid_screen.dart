import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/artwork_file.dart';
import '../../core/grid_layout.dart';
import '../../core/progress_dialog.dart';
import '../../providers/providers.dart';
import '../../data/db/daos.dart';
import '../../data/db/app_database.dart' as db;

enum _BulkAction { autoSelectVersions, checkAll, uncheckAll }

class CardsGridScreen extends ConsumerStatefulWidget {
  final int projectId;
  const CardsGridScreen({super.key, required this.projectId});

  @override
  ConsumerState<CardsGridScreen> createState() => _CardsGridScreenState();
}

class _CardsGridScreenState extends ConsumerState<CardsGridScreen> {
  CardFilter _filter = CardFilter.all;
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  String? _layoutFilter;
  bool _bulkRunning = false;

  /// Latest layout map from the stream, reused by bulk actions so they see
  /// exactly the same filtered subset as the grid.
  Map<int, String?> _latestLayoutMap = {};

  /// Per-tile (artwork, on-disk) future cache, invalidated when the cards
  /// stream emits, so scrolling/typing doesn't re-stat files.
  final Map<String, Future<({db.Artwork? art, bool exists})>> _tileArtCache =
      {};
  List<db.Card>? _lastCardsData;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// The in-memory part of the grid filter (search + layout), applied on top
  /// of the DB-side [CardFilter].
  List<db.Card> _applyClientFilters(
    List<db.Card> cards,
    Map<int, String?> layoutMap,
  ) {
    final query = _searchQuery.trim().toLowerCase();
    final lf = _layoutFilter;
    return cards.where((c) {
      if (query.isNotEmpty && !c.name.toLowerCase().contains(query)) {
        return false;
      }
      if (lf != null && layoutMap[c.id] != lf) return false;
      return true;
    }).toList();
  }

  Future<({db.Artwork? art, bool exists})> _tileArt(db.Card c) {
    final key = '${c.id}:${c.preferredArtworkId}';
    return _tileArtCache.putIfAbsent(key, () async {
      final art = await ref
          .read(dbProvider)
          .artworksDao
          .getPreferredOrFirstArtworkForCard(c.id, c.preferredArtworkId);
      if (art == null) return (art: null, exists: false);
      return (art: art, exists: await artworkFileExists(art));
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _runBulkAction(_BulkAction action) async {
    final database = ref.read(dbProvider);
    final bulk = ref.read(bulkCardActionsServiceProvider);

    // Snapshot the currently visible subset (DB filter + search + layout).
    final dbCards = await database.cardsDao
        .getCardsFiltered(widget.projectId, filter: _filter);
    if (!mounted) return;
    final cards = _applyClientFilters(dbCards, _latestLayoutMap);
    if (cards.isEmpty) {
      _snack('No cards match the current filter.');
      return;
    }

    bool hasVersion(db.Card c) =>
        c.selectedSetCode != null || c.selectedSetIsVoid;

    setState(() => _bulkRunning = true);
    try {
      switch (action) {
        case _BulkAction.autoSelectVersions:
          final affected = cards
              .where((c) => c.preferredArtworkId != null && !hasVersion(c))
              .length;
          if (affected == 0) {
            _snack('No cards with artwork and no version in this view.');
            return;
          }
          final ok = await _confirm(
            title: 'Auto-select versions',
            message:
                'Auto-select a version for $affected card(s)? Cards with a '
                'version already chosen are skipped.',
          );
          if (!ok || !mounted) return;
          final done = await runWithProgressDialog<int>(
            context: context,
            title: 'Auto-selecting versions…',
            task: (report) => bulk.autoSelectVersions(
              cards,
              onProgress: report,
            ),
          );
          if (mounted) _snack('Versions selected for $done card(s).');

        case _BulkAction.checkAll:
          final candidateIds = cards
              .where((c) => c.preferredArtworkId == null || !hasVersion(c))
              .map((c) => c.id)
              .toList();
          if (candidateIds.isEmpty) {
            _snack('All cards in this view are already checked.');
            return;
          }
          final withArt = await database.artworksDao
              .getCardIdsWithArtworks(candidateIds);
          final skipCount = candidateIds.length - withArt.length;
          if (!mounted) return;
          final ok = await _confirm(
            title: 'Check all',
            message:
                'Check ${withArt.length} card(s)? The first downloaded '
                'artwork is selected and a version auto-picked.'
                '${skipCount > 0 ? '\n$skipCount card(s) without any artwork will be skipped.' : ''}',
          );
          if (!ok || !mounted) return;
          final done = await runWithProgressDialog<int>(
            context: context,
            title: 'Checking cards…',
            task: (report) => bulk.checkAll(cards, onProgress: report),
          );
          if (mounted) {
            _snack(
              'Checked $done card(s)'
              '${skipCount > 0 ? ', $skipCount skipped (no artwork)' : ''}.',
            );
          }

        case _BulkAction.uncheckAll:
          final ok = await _confirm(
            title: 'Uncheck all',
            message:
                'Uncheck ${cards.length} card(s)? This clears the artwork '
                'choice, version AND flavor-text selections.',
            destructive: true,
          );
          if (!ok || !mounted) return;
          final done = await bulk.uncheckAll(
            cards.map((c) => c.id).toList(),
          );
          if (mounted) _snack('Unchecked $done card(s).');
      }
    } catch (e) {
      if (mounted) _snack('Bulk action failed: $e');
    } finally {
      if (mounted) setState(() => _bulkRunning = false);
    }
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    bool destructive = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(
                      backgroundColor: scheme.error,
                      foregroundColor: scheme.onError,
                    )
                  : null,
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: Text(title),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final cardRepo = ref.read(cardRepoProvider);
    final database = ref.read(dbProvider);
    final thumbPath = ref.read(thumbPathProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cards'),
        actions: [
          StreamBuilder<int>(
            stream: cardRepo.watchChecked(widget.projectId),
            builder: (context, checkedSnap) {
              final checked = checkedSnap.data ?? 0;
              return StreamBuilder<int>(
                stream: cardRepo.watchTotal(widget.projectId),
                builder: (context, totalSnap) {
                  final total = totalSnap.data ?? 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(child: Text('$checked/$total')),
                  );
                },
              );
            },
          ),
          PopupMenuButton<_BulkAction>(
            enabled: !_bulkRunning,
            tooltip: 'Bulk actions (current filter)',
            onSelected: _runBulkAction,
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: _BulkAction.autoSelectVersions,
                child: ListTile(
                  leading: Icon(Icons.auto_fix_high_outlined),
                  title: Text('Auto-select versions'),
                  subtitle: Text('Cards with artwork, no version'),
                ),
              ),
              PopupMenuItem(
                value: _BulkAction.checkAll,
                child: ListTile(
                  leading: Icon(Icons.check_circle_outline),
                  title: Text('Check all'),
                  subtitle: Text('Pick first artwork + version'),
                ),
              ),
              PopupMenuItem(
                value: _BulkAction.uncheckAll,
                child: ListTile(
                  leading: Icon(Icons.remove_done),
                  title: Text('Uncheck all…'),
                ),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search cards…',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchQuery.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                setState(() => _searchQuery = '');
                              },
                            ),
                      isDense: true,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _searchQuery = v),
                  ),
                ),
                const SizedBox(width: 8),
                StreamBuilder<List<String>>(
                  stream: database.cardsDao
                      .watchDistinctLayoutsForProject(widget.projectId),
                  builder: (context, layoutSnap) {
                    final layouts = layoutSnap.data ?? [];
                    if (layouts.isEmpty) return const SizedBox.shrink();
                    return DropdownButton<String?>(
                      value: _layoutFilter,
                      hint: const Text('Layout'),
                      isDense: true,
                      items: [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('All layouts'),
                        ),
                        ...layouts.map(
                          (l) => DropdownMenuItem(value: l, child: Text(l)),
                        ),
                      ],
                      onChanged: (v) => setState(() => _layoutFilter = v),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('All'),
                selected: _filter == CardFilter.all,
                onSelected: (_) => setState(() => _filter = CardFilter.all),
              ),
              ChoiceChip(
                label: const Text('Complete'),
                selected: _filter == CardFilter.checked,
                onSelected: (_) => setState(() => _filter = CardFilter.checked),
              ),
              ChoiceChip(
                label: const Text('Partial'),
                selected: _filter == CardFilter.partial,
                onSelected: (_) => setState(() => _filter = CardFilter.partial),
              ),
              ChoiceChip(
                label: const Text('Unchecked'),
                selected: _filter == CardFilter.unchecked,
                onSelected: (_) =>
                    setState(() => _filter = CardFilter.unchecked),
              ),
              ChoiceChip(
                label: const Text('Up to date'),
                selected: _filter == CardFilter.upToDate,
                onSelected: (_) =>
                    setState(() => _filter = CardFilter.upToDate),
              ),
              ChoiceChip(
                label: const Text('Pending'),
                selected: _filter == CardFilter.pending,
                onSelected: (_) =>
                    setState(() => _filter = CardFilter.pending),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: StreamBuilder<Map<int, String?>>(
              stream: database.cardsDao
                  .watchLayoutMapForProject(widget.projectId),
              builder: (context, layoutMapSnap) {
                final layoutMap = layoutMapSnap.data ?? {};
                _latestLayoutMap = layoutMap;
                return StreamBuilder<List<db.Card>>(
                  stream: cardRepo.watchCards(widget.projectId, _filter),
                  builder: (context, snapshot) {
                    final allCards = snapshot.data ?? const [];
                    // A fresh stream emission means card rows changed —
                    // re-check artwork files on disk.
                    if (!identical(allCards, _lastCardsData)) {
                      _lastCardsData = allCards;
                      _tileArtCache.clear();
                    }
                    final cards = _applyClientFilters(allCards, layoutMap);
                    if (cards.isEmpty) {
                      return const Center(child: Text('No cards found.'));
                    }

                    return GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate: cardGridDelegate(
                        columns: forcedGridColumns(ref, context),
                      ),
                      itemCount: cards.length,
                      itemBuilder: (context, i) {
                        final c = cards[i];
                        final setSelected =
                            c.selectedSetCode != null ||
                            c.selectedSetIsVoid;
                        final hasArtwork = c.preferredArtworkId != null;
                        final isComplete = hasArtwork && setSelected;
                        final isPartial = hasArtwork ^ setSelected;

                        return InkWell(
                          onTap: () => context.push(
                            '/projects/${widget.projectId}/cards/${c.id}',
                          ),
                          child: Stack(
                            children: [
                              // pending indicator (top-right): shown when the
                              // pipeline has not yet run successfully for this card
                              if (c.isUpToDate != true)
                                const Positioned(
                                  top: 10,
                                  right: 10,
                                  child: Icon(
                                    Icons.schedule,
                                    color: Colors.grey,
                                    size: 18,
                                  ),
                                ),
                              Card(
                                clipBehavior: Clip.antiAlias,
                                child: Column(
                                  children: [
                                    Expanded(
                                      child: FutureBuilder<
                                          ({db.Artwork? art, bool exists})>(
                                        future: _tileArt(c),
                                        builder: (context, artSnap) {
                                          final art = artSnap.data?.art;
                                          if (art == null) {
                                            return Container(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .surfaceContainerHighest,
                                              child: const Center(
                                                child: Icon(
                                                  Icons.image_outlined,
                                                ),
                                              ),
                                            );
                                          }

                                          return FutureBuilder<String>(
                                            future: thumbPath.thumbForOriginal(
                                              projectId: widget.projectId,
                                              originalPath: art.localPath,
                                            ),
                                            builder: (context, thumbSnap) {
                                              final tp = thumbSnap.data;
                                              if (tp == null) {
                                                return Container(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .surfaceContainerHighest,
                                                  child: const Center(
                                                    child:
                                                        CircularProgressIndicator(),
                                                  ),
                                                );
                                              }

                                              return Image.file(
                                                File(tp),
                                                fit: BoxFit.cover,
                                                errorBuilder: (_, _, _) {
                                                  return Container(
                                                    color: Theme.of(context)
                                                        .colorScheme
                                                        .surfaceContainerHighest,
                                                    child: const Center(
                                                      child: Icon(
                                                        Icons
                                                            .broken_image_outlined,
                                                      ),
                                                    ),
                                                  );
                                                },
                                              );
                                            },
                                          );
                                        },
                                      ),
                                    ),
                                    Padding(
                                      padding: const EdgeInsets.all(8),
                                      child: Text(
                                        c.name,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              if (isComplete)
                                const Positioned(
                                  top: 10,
                                  left: 10,
                                  child: Icon(
                                    Icons.check_circle,
                                    color: Colors.green,
                                  ),
                                )
                              else if (isPartial)
                                const Positioned(
                                  top: 10,
                                  left: 10,
                                  child: Icon(
                                    Icons.check_circle_outline,
                                    color: Colors.orange,
                                  ),
                                ),

                              // Download state badge (bottom-right):
                              // grey = nothing downloaded, red = the selected
                              // artwork's file is missing on disk.
                              FutureBuilder<({db.Artwork? art, bool exists})>(
                                future: _tileArt(c),
                                builder: (context, artSnap) {
                                  final data = artSnap.data;
                                  if (data == null ||
                                      (data.art != null && data.exists)) {
                                    return const SizedBox.shrink();
                                  }
                                  final missing = data.art != null;
                                  return Positioned(
                                    bottom: 10,
                                    right: 10,
                                    child: Tooltip(
                                      message: missing
                                          ? 'Artwork file missing on disk'
                                          : 'No artwork downloaded yet',
                                      child: Icon(
                                        missing
                                            ? Icons.image_not_supported
                                            : Icons.file_download_off,
                                        size: 16,
                                        color: missing
                                            ? Theme.of(context)
                                                .colorScheme
                                                .error
                                            : Colors.grey,
                                      ),
                                    ),
                                  );
                                },
                              ),

                              // DFC badge: this card is one face of a
                              // double-faced/split card.
                              if (c.dfcSiblingId != null)
                                Positioned(
                                  top: 34,
                                  right: 10,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      color: Colors.black
                                          .withValues(alpha: 0.45),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Padding(
                                      padding: EdgeInsets.all(3),
                                      child: Icon(
                                        Icons.flip_outlined,
                                        size: 14,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
