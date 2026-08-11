import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/db/app_database.dart' as db;
import '../../providers/providers.dart';
import '../../services/project_duplication_service.dart';

enum _ProjectAction { duplicate, delete }

class ProjectsListScreen extends ConsumerWidget {
  const ProjectsListScreen({super.key});

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    db.Project project,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete project?'),
        content: const Text(
          'This permanently deletes the project and all downloaded artwork files.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final storage = ref.read(storagePathsProvider);

    // delete folder first
    await storage.deleteProjectDir(project.id);

    // then delete DB
    await ref.read(projectRepoProvider).deleteProject(project.id);
  }

  Future<void> _duplicate(
    BuildContext context,
    WidgetRef ref,
    db.Project project,
  ) async {
    final progress = ValueNotifier<DuplicationProgress?>(null);

    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text('Duplicating "${project.name}"…'),
          content: ValueListenableBuilder<DuplicationProgress?>(
            valueListenable: progress,
            builder: (context, value, _) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: value == null || value.total == 0
                        ? null
                        : value.done / value.total,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    value == null
                        ? 'Preparing…'
                        : '${value.phase} (${value.done}/${value.total})',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );

    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await ref
          .read(projectDuplicationServiceProvider)
          .duplicateProject(project.id, onProgress: (p) => progress.value = p);
      final skippedNote = result.skippedFiles > 0
          ? ' (${result.skippedFiles} file(s) could not be copied)'
          : '';
      messenger.showSnackBar(
        SnackBar(content: Text('Duplicated as "${result.projectName}"$skippedNote')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Duplication failed: $e')),
      );
    } finally {
      if (context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      await dialog;
      progress.dispose();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(projectRepoProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Projects'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: 'Settings',
            onPressed: () => context.go('/settings'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.go('/projects/create'),
        icon: const Icon(Icons.add),
        label: const Text('Create'),
      ),
      body: StreamBuilder(
        stream: repo.watchProjects(),
        builder: (context, snapshot) {
          final allProjects = snapshot.data ?? const [];
          final basicsId = switch (ref.watch(basicsProjectIdProvider)) {
            AsyncData(:final value) => value,
            _ => null,
          };
          final framesId = switch (ref.watch(globalFramesProjectIdProvider)) {
            AsyncData(:final value) => value,
            _ => null,
          };
          final hiddenIds = <int>{if (basicsId != null) basicsId, if (framesId != null) framesId};
          final projects = hiddenIds.isNotEmpty
              ? allProjects.where((p) => !hiddenIds.contains(p.id)).toList()
              : allProjects;
          if (projects.isEmpty) {
            return const Center(child: Text('No projects yet.'));
          }

          return ListView.separated(
            itemCount: projects.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final p = projects[i];
              return ListTile(
                title: Text(p.name),
                subtitle: Text('Created: ${p.createdAt.toLocal()}'),
                onTap: () => context.go('/projects/${p.id}'),
                trailing: PopupMenuButton<_ProjectAction>(
                  tooltip: 'Project actions',
                  onSelected: (action) => switch (action) {
                    _ProjectAction.duplicate => _duplicate(context, ref, p),
                    _ProjectAction.delete => _confirmDelete(context, ref, p),
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: _ProjectAction.duplicate,
                      child: ListTile(
                        leading: Icon(Icons.copy_outlined),
                        title: Text('Duplicate'),
                      ),
                    ),
                    PopupMenuItem(
                      value: _ProjectAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Delete'),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
