import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/normalize.dart';
import '../../data/db/app_database.dart';
import '../../providers/providers.dart';
import '../../data/models/provider_id.dart';
import '../../services/deck_text_parser.dart';

class CreateProjectScreen extends ConsumerStatefulWidget {
  final int? projectId;

  const CreateProjectScreen({super.key, this.projectId});

  bool get isEditing => projectId != null;

  @override
  ConsumerState<CreateProjectScreen> createState() =>
      _CreateProjectScreenState();
}

class _CreateProjectScreenState extends ConsumerState<CreateProjectScreen> {
  final _nameCtrl = TextEditingController();
  final _cardsCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  bool _deckMode = false;
  bool _importTokensOnly = false;
  bool _loadedInitialData = false;

  bool _creating = false;
  String? _error;

  bool _fetchingUrl = false;
  String? _fetchError;
  String? _importedDeckName;

  @override
  void dispose() {
    _nameCtrl.dispose();
    _cardsCtrl.dispose();
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_loadedInitialData) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadInitialData();
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit project' : 'Create project'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            TextField(
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Project name',
                border: OutlineInputBorder(),
              ),
            ),
            if (widget.isEditing) ...[
              const SizedBox(height: 20),
              Row(
                children: [
                  Icon(
                    Icons.playlist_add,
                    size: 20,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Add Cards',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                'Only new cards will be added. Existing cards in the project will be kept.',
              ),
            ],

            // ── URL Import ────────────────────────────────────────────────
            const SizedBox(height: 20),
            Text(
              'Import from URL',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _urlCtrl,
                    enabled: !_fetchingUrl && !_creating,
                    decoration: const InputDecoration(
                      hintText: 'Moxfield, Archidekt or MTGGoldfish deck URL',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    keyboardType: TextInputType.url,
                    onSubmitted: (_) => _fetchFromUrl(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed:
                      _fetchingUrl || _creating ? null : _fetchFromUrl,
                  child: _fetchingUrl
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Fetch'),
                ),
              ],
            ),
            if (_fetchError != null) ...[
              const SizedBox(height: 6),
              Text(
                _fetchError!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
            if (_importedDeckName != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 16,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'Imported: "$_importedDeckName"',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.primary,
                          ),
                    ),
                  ),
                ],
              ),
            ],

            // ── Manual input ──────────────────────────────────────────────
            const SizedBox(height: 20),
            Text(
              'Or paste manually',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Deck mode',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    value: _deckMode,
                    onChanged: _creating
                        ? null
                        : (v) => setState(() => _deckMode = v),
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Import tokens only',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    value: _importTokensOnly,
                    onChanged: _creating
                        ? null
                        : (v) => setState(() => _importTokensOnly = v),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current configuration',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    _deckMode
                        ? '• Deck mode: accepts "4 Card name", "1x Card name" and Arena lines like "4 Card name (M11) 149" — the (SET) becomes the pre-selected version. Quantities are deduplicated; comments (#, //) and section headers are understood; sideboard lines are skipped.'
                        : '• Deck mode off: each non-empty line is one card name.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _importTokensOnly
                        ? '• Import tokens only: listed cards are looked up on Scryfall and only their tokens are added to the project.'
                        : '• Import tokens off: listed cards are added directly.',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _cardsCtrl,
              decoration: InputDecoration(
                labelText: _deckMode
                    ? 'Deck list (e.g. "4 Lightning Bolt (M11) 149")'
                    : 'MTG card names (one per line)',
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              minLines: 10,
              maxLines: 18,
            ),
          ],
        ),
      ),
      bottomNavigationBar: _submitBar(context),
    );
  }

  /// Sticky bar holding the submit button, so it stays reachable without
  /// scrolling to the bottom of the form.
  Widget _submitBar(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 8),
            ],
            FilledButton.icon(
              onPressed: _creating ? null : _submit,
              icon: const Icon(Icons.check),
              label: Text(
                _creating
                    ? (widget.isEditing ? 'Saving…' : 'Creating…')
                    : (widget.isEditing
                          ? (_importTokensOnly
                              ? 'Import tokens'
                              : 'Save project / add cards')
                          : (_importTokensOnly
                              ? 'Create project & import tokens'
                              : 'Create project')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _submit() async {
    final projects = ref.read(projectRepoProvider);
    final cardRepo = ref.read(cardRepoProvider);

    final parsed = _parseInputCards(_cardsCtrl.text);
    final entries = parsed.entries;
    final cardNames = entries.map((e) => e.name).toList();

    var name = _nameCtrl.text.trim();
    // An MTGA "About / Name X" block can supply the project name.
    if (name.isEmpty && (parsed.deckName?.isNotEmpty ?? false)) {
      name = parsed.deckName!;
      _nameCtrl.text = name;
    }
    if (name.isEmpty) {
      setState(() => _error = 'Project name is required.');
      return;
    }

    final router = GoRouter.of(context);

    setState(() {
      _creating = true;
      _error = null;
    });

    try {
      final existingProjectId = widget.projectId;
      late final int id;

      if (existingProjectId == null) {
        if (entries.isEmpty) {
          setState(() {
            _error = _deckMode
                ? 'Please paste at least one valid deck line like "4 Lightning Bolt".'
                : 'Please paste at least one card name.';
          });
          return;
        }

        id = await projects.createProject(
          name: name,
          enabledProviders: [SourceProviderId.scryfallMagicville],
        );

        final storage = ref.read(storagePathsProvider);
        await storage.projectImagesDir(id);
        await storage.projectThumbsDir(id);

        if (_importTokensOnly) {
          await ref
              .read(downloadPipelineProvider)
              .importTokensFromCardNames(id, cardNames);
        } else {
          await cardRepo.insertCardsFromEntries(id, entries);
          final globalDao = ref.read(globalSettingsDaoProvider);
          await globalDao.copyBasicsToProject(id, cardNames);
          await globalDao.applyGlobalFramesToProject(id);
        }
      } else {
        id = existingProjectId;

        final database = ref.read(dbProvider);

        await (database.update(database.projects)
              ..where((t) => t.id.equals(id)))
            .write(ProjectsCompanion(name: Value(name)));

        if (entries.isNotEmpty) {
          if (_importTokensOnly) {
            await ref
                .read(downloadPipelineProvider)
                .importTokensFromCardNames(id, cardNames);
          } else {
            final newEntriesOnly = await _removeExistingProjectCards(
              id,
              entries,
            );
            if (newEntriesOnly.isNotEmpty) {
              await cardRepo.insertCardsFromEntries(id, newEntriesOnly);
            }
          }
        }
      }

      if (!mounted) return;
      router.go('/projects/$id');
    } catch (e) {
      setState(() => _error = 'Failed: $e');
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _fetchFromUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) return;

    setState(() {
      _fetchingUrl = true;
      _fetchError = null;
      _importedDeckName = null;
    });

    try {
      final service = ref.read(deckImportServiceProvider);
      final result = await service.importFromUrl(url);

      if (!mounted) return;
      setState(() {
        _cardsCtrl.text = result.cardLines.join('\n');
        _deckMode = true;
        _importedDeckName = result.deckName;
        // Pre-fill project name if empty
        if (_nameCtrl.text.trim().isEmpty) {
          _nameCtrl.text = result.deckName;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetchError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _fetchingUrl = false);
    }
  }

  /// Parses the paste box. In deck mode the rich parser handles quantities,
  /// Arena "(SET) 123" hints, comments and section headers (sideboard and
  /// maybeboard lines are skipped). Deduplication happens at insert time.
  DeckParseResult _parseInputCards(String input) {
    final service = ref.read(deckImportServiceProvider);
    if (!_deckMode) {
      return DeckParseResult(entries: service.parseNameLines(input));
    }
    final result = service.parseText(input);
    return DeckParseResult(
      entries: result.entries
          .where((e) => importedDeckSections.contains(e.section))
          .toList(),
      deckName: result.deckName,
    );
  }

  Future<void> _loadInitialData() async {
    if (_loadedInitialData) return;
    _loadedInitialData = true;

    final projectId = widget.projectId;
    if (projectId == null) return;

    final database = ref.read(dbProvider);

    final project = await (database.select(
      database.projects,
    )..where((t) => t.id.equals(projectId))).getSingleOrNull();

    if (!mounted) return;

    _nameCtrl.text = project?.name ?? '';
    _cardsCtrl.text = '';
  }

  Future<List<ParsedDeckEntry>> _removeExistingProjectCards(
    int projectId,
    List<ParsedDeckEntry> entries,
  ) async {
    final database = ref.read(dbProvider);

    final existingCards = await (database.select(
      database.cards,
    )..where((t) => t.projectId.equals(projectId))).get();

    final existingNormalized = existingCards
        .map((c) => c.normalizedName)
        .toSet();

    return entries.where((e) {
      return !existingNormalized.contains(normalizeCardName(e.name));
    }).toList();
  }
}
