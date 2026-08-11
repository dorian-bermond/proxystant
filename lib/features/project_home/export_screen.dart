import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../providers/providers.dart';
import '../../services/export_readiness_service.dart';
import '../../services/export_service.dart';
import 'widgets/export_readiness_panel.dart';

class ExportScreen extends ConsumerStatefulWidget {
  final int projectId;
  const ExportScreen({super.key, required this.projectId});

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _running = false;
  String? _status;
  List<SkippedCard> _skipped = const [];

  ExportMode _mode = ExportMode.zip;
  bool _flatten = false;
  String? _folderDir;
  String _projectName = '';

  Future<ExportReadinessReport>? _reportFuture;

  @override
  void initState() {
    super.initState();
    _refreshReport();
    _loadPersistedOptions();
  }

  void _refreshReport() {
    setState(() {
      _reportFuture = ref
          .read(exportReadinessServiceProvider)
          .buildReport(widget.projectId);
    });
  }

  Future<void> _loadPersistedOptions() async {
    final settings = ref.read(globalSettingsDaoProvider);
    final database = ref.read(dbProvider);
    final format = await settings.getExportFormatDefault();
    final flatten = await settings.getExportFlatten();
    final dir = await settings.getProjectExportDir(widget.projectId);
    final project = await (database.select(database.projects)
          ..where((t) => t.id.equals(widget.projectId)))
        .getSingleOrNull();
    if (!mounted) return;
    setState(() {
      // Folder export is desktop-only; ignore a persisted 'folder' on mobile.
      _mode = format == 'folder' && _isDesktop
          ? ExportMode.folder
          : ExportMode.zip;
      _flatten = flatten;
      _folderDir = dir;
      _projectName = project?.name ?? '';
    });
  }

  String _sanitizeFileName(String input) {
    final cleaned = input
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return cleaned.isEmpty ? 'project_${widget.projectId}' : cleaned;
  }

  /// Returns the path the ZIP was written to, or null if the user cancelled.
  Future<String?> _saveOnDesktop(List<int> zipBytes, String fileName) async {
    const typeGroup = XTypeGroup(label: 'ZIP archive', extensions: ['zip']);
    final location = await getSaveLocation(
      suggestedName: fileName,
      acceptedTypeGroups: [typeGroup],
    );
    if (location == null) return null;

    await File(location.path).writeAsBytes(zipBytes, flush: true);
    return location.path;
  }

  /// Writes the ZIP to a temp file first: the mobile dialog copies from a
  /// source path rather than taking bytes.
  Future<String?> _saveOnMobile(List<int> zipBytes, String fileName) async {
    final tempDir = await getTemporaryDirectory();
    final tempZipFile = File(p.join(tempDir.path, fileName));
    await tempZipFile.writeAsBytes(zipBytes, flush: true);

    return FlutterFileDialog.saveFile(
      params: SaveFileDialogParams(
        sourceFilePath: tempZipFile.path,
        fileName: fileName,
      ),
    );
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(initialDirectory: _folderDir);
    if (dir == null || !mounted) return;
    setState(() => _folderDir = dir);
    await ref
        .read(globalSettingsDaoProvider)
        .setProjectExportDir(widget.projectId, dir);
  }

  Future<void> _export() async {
    final exporter = ref.read(exportServiceProvider);

    setState(() {
      _running = true;
      _status = null;
      _skipped = const [];
    });

    try {
      final manifest = await exporter.buildManifest(
        projectId: widget.projectId,
        flatten: _flatten,
      );

      if (manifest.entries.isEmpty) {
        setState(() {
          _skipped = manifest.skipped;
          _status = manifest.skipped.isEmpty
              ? 'Nothing to export.'
              : 'Nothing exported — all checked cards were skipped.';
        });
        return;
      }

      String? savedPath;
      if (_mode == ExportMode.folder) {
        final dir = _folderDir;
        if (dir == null) return; // button is disabled in this state
        final outcome = await exporter.writeFolder(manifest, dir);
        savedPath = outcome.outputPath;
      } else {
        final zipBytes = await exporter.encodeZip(manifest);
        final fileName = '${_sanitizeFileName(_projectName)}.zip';
        // flutter_file_dialog is Android/iOS-only, so desktop goes through
        // file_selector's native save dialog instead.
        savedPath = _isDesktop
            ? await _saveOnDesktop(zipBytes, fileName)
            : await _saveOnMobile(zipBytes, fileName);
      }

      if (!mounted) return;
      setState(() {
        _skipped = manifest.skipped;
        if (savedPath == null) {
          _status = 'Export cancelled.';
        } else {
          final skippedNote = manifest.skipped.isEmpty
              ? ''
              : ' · ${manifest.skipped.length} skipped';
          _status =
              'Exported ${manifest.exportedCount} cards$skippedNote:\n$savedPath';
        }
      });
      _refreshReport();
    } catch (e) {
      setState(() => _status = 'Export failed: $e');
    } finally {
      if (mounted) {
        setState(() => _running = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderModeMissingDir = _mode == ExportMode.folder && _folderDir == null;

    return Scaffold(
      appBar: AppBar(title: const Text('Export')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FutureBuilder<ExportReadinessReport>(
            future: _reportFuture,
            builder: (context, snap) {
              final report = snap.data;
              if (report == null) {
                return const Card(
                  child: ListTile(
                    leading: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    title: Text('Checking export readiness…'),
                  ),
                );
              }
              return ExportReadinessPanel(
                projectId: widget.projectId,
                report: report,
                onReturnedFromCard: _refreshReport,
              );
            },
          ),
          const SizedBox(height: 16),

          SegmentedButton<ExportMode>(
            segments: [
              const ButtonSegment(
                value: ExportMode.zip,
                label: Text('ZIP'),
                icon: Icon(Icons.folder_zip_outlined),
              ),
              if (_isDesktop)
                const ButtonSegment(
                  value: ExportMode.folder,
                  label: Text('Folder'),
                  icon: Icon(Icons.folder_open),
                ),
            ],
            selected: {_mode},
            onSelectionChanged: _running
                ? null
                : (s) {
                    setState(() => _mode = s.first);
                    ref.read(globalSettingsDaoProvider).setExportFormatDefault(
                          s.first == ExportMode.folder ? 'folder' : 'zip',
                        );
                  },
          ),

          if (_mode == ExportMode.folder) ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.folder),
              title: Text(
                _folderDir ?? 'No destination folder chosen',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: const Text(
                'Remembered per project — point it at your renderer\'s art '
                'folder. Existing files with the same name are overwritten.',
              ),
              trailing: TextButton(
                onPressed: _running ? null : _pickFolder,
                child: Text(_folderDir == null ? 'Choose' : 'Change'),
              ),
            ),
          ],

          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Flatten'),
            subtitle: const Text('No frame/layout subfolders'),
            value: _flatten,
            onChanged: _running
                ? null
                : (v) {
                    setState(() => _flatten = v);
                    ref.read(globalSettingsDaoProvider).setExportFlatten(v);
                  },
          ),
          const SizedBox(height: 8),

          FilledButton.icon(
            onPressed: _running || folderModeMissingDir ? null : _export,
            icon: const Icon(Icons.upload_file),
            label: Text(_running ? 'Exporting…' : 'Export checked cards'),
          ),
          if (folderModeMissingDir)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('Choose a destination folder first.'),
            ),

          const SizedBox(height: 16),
          if (_status != null)
            Text(
              _status!,
              style: TextStyle(
                color: _status!.startsWith('Export failed')
                    ? Colors.red
                    : null,
              ),
            ),
          if (_skipped.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: Text(
                '${_skipped.length} card(s) skipped — file missing on disk',
              ),
              children: [
                for (final s in _skipped)
                  ListTile(dense: true, title: Text(s.name)),
              ],
            ),

          const SizedBox(height: 24),
          const Text(
            'The export contains the preferred artwork for each checked card '
            'plus print_data.json.',
          ),
        ],
      ),
    );
  }
}
