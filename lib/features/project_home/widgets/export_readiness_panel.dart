import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../services/export_readiness_service.dart';

String _groupLabel(ReadinessKind kind, int count) {
  final cards = count == 1 ? 'card' : 'cards';
  switch (kind) {
    case ReadinessKind.noArtwork:
      return '$count $cards with no artwork selected (won\'t export)';
    case ReadinessKind.noVersion:
      return '$count $cards with no version selected (won\'t export)';
    case ReadinessKind.missingFile:
      return '$count $cards with the artwork file missing on disk';
    case ReadinessKind.unsupportedLayout:
      return '$count $cards with an unsupported layout (no template)';
    case ReadinessKind.partialLayout:
      return '$count $cards with partial template support';
    case ReadinessKind.noFrame:
      return '$count $cards without a frame (export to "other/")';
    case ReadinessKind.dfcMismatch:
      return '$count DFC faces unchecked while the other face is checked';
  }
}

/// Summary of export blockers/warnings, shown above the export button.
/// Each group opens a bottom sheet of card names that navigate to the card.
class ExportReadinessPanel extends StatelessWidget {
  final int projectId;
  final ExportReadinessReport report;

  /// Called when the user returns from a card detail screen, so the parent
  /// can recompute the report.
  final VoidCallback? onReturnedFromCard;

  const ExportReadinessPanel({
    super.key,
    required this.projectId,
    required this.report,
    this.onReturnedFromCard,
  });

  void _showCards(BuildContext context, ReadinessIssueGroup group) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  _groupLabel(group.kind, group.cards.length),
                  style: Theme.of(sheetContext).textTheme.titleSmall,
                ),
              ),
              const SizedBox(height: 4),
              for (final c in group.cards)
                ListTile(
                  dense: true,
                  title: Text(c.name),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    context
                        .push('/projects/$projectId/cards/${c.cardId}')
                        .then((_) => onReturnedFromCard?.call());
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    if (report.isClean) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.check_circle, color: Colors.green),
          title: const Text('Ready to export — no issues found'),
        ),
      );
    }

    return Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final group in report.groups)
            ListTile(
              leading: group.blocking
                  ? Icon(Icons.error_outline, color: scheme.error)
                  : Icon(Icons.warning_amber_outlined, color: scheme.tertiary),
              title: Text(_groupLabel(group.kind, group.cards.length)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _showCards(context, group),
            ),
        ],
      ),
    );
  }
}
